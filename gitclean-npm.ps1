# 从 NPM 脚本启动时询问扫描目录，避免把路径写死在 package.json 里。
#Requires -Version 5.1
[CmdletBinding()]
param(
    [int]$Depth = 3,
    [string[]]$Keep = @()
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$defaultRoot = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..')).FullName

Write-Host "扫描目录，直接回车使用: $defaultRoot" -ForegroundColor Cyan
$entered = Read-Host '扫描目录'
if ([string]::IsNullOrWhiteSpace($entered)) {
    $root = $defaultRoot
}
else {
    $root = $entered.Trim().Trim('"')
}

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Host "目录不存在: $root" -ForegroundColor Red
    exit 1
}

$root = (Get-Item -LiteralPath $root).FullName
& (Join-Path $PSScriptRoot 'gitclean.ps1') -Root $root -Depth $Depth -Keep $Keep
