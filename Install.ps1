# 把 gitclean 函数写入当前用户的 PowerShell 配置文件。
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$profilePath = $PROFILE
if ([string]::IsNullOrWhiteSpace($profilePath)) {
    Write-Host '无法确定 PowerShell 配置文件路径。' -ForegroundColor Red
    exit 1
}

$scriptPath = Join-Path $PSScriptRoot 'gitclean.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Host "找不到入口脚本: $scriptPath" -ForegroundColor Red
    exit 1
}

$scriptPath = (Resolve-Path -LiteralPath $scriptPath).Path
$escaped = $scriptPath.Replace('"', '`"')
$directory = Split-Path -Parent $profilePath
if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$encodingName = 'utf8'
$existing = ''
if (Test-Path -LiteralPath $profilePath) {
    $reader = New-Object System.IO.StreamReader($profilePath, $true)
    try {
        $existing = $reader.ReadToEnd()
        $codePage = $reader.CurrentEncoding.CodePage
        if ($codePage -eq 1200) {
            $encodingName = 'unicode'
        }
        elseif ($codePage -eq 1201) {
            $encodingName = 'bigendianunicode'
        }
    }
    finally {
        $reader.Dispose()
    }
    $existing = $existing.TrimStart([char]0xFEFF)
}

if ($existing -match '(?m)^\s*function\s+gitclean\b') {
    Write-Host '配置文件中已存在 gitclean 函数，未重复追加。'
    Write-Host $profilePath
    exit 0
}

$invocation = '@args'
$block = @"

function gitclean {
    & "$escaped" $invocation
}
"@

if (-not (Test-Path -LiteralPath $profilePath)) {
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($profilePath, $block.TrimStart(), $utf8Bom)
}
else {
    $append = $block
    if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) {
        $append = "`r`n" + $block.TrimStart()
    }
    if ($encodingName -eq 'unicode') {
        $payload = [System.Text.Encoding]::Unicode.GetBytes($append)
    }
    elseif ($encodingName -eq 'bigendianunicode') {
        $payload = [System.Text.Encoding]::BigEndianUnicode.GetBytes($append)
    }
    else {
        $payload = (New-Object System.Text.UTF8Encoding $false).GetBytes($append)
    }
    $stream = [System.IO.File]::Open($profilePath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $stream.Write($payload, 0, $payload.Length)
    }
    finally {
        $stream.Dispose()
    }
}

Write-Host "已将 gitclean 写入 $profilePath"
Write-Host '请新开一个 PowerShell 窗口后使用。'
exit 0
