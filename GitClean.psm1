# 批量清理远程已删除、本地仍保留的 Git 分支。
#Requires -Version 5.1

Set-StrictMode -Version Latest

function Test-SkippedRepositoryPath {
    param([string]$Path)

    $segments = $Path.Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments) {
        if ($segment -eq 'node_modules') {
            return $true
        }
    }
    return $false
}

function Get-GitRepository {
    [CmdletBinding()]
    param(
        [string[]]$Root = @('.'),
        [int]$Depth = 3
    )

    if ($Depth -lt 0) {
        $Depth = 0
    }

    $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($rootItem in $Root) {
        if ([string]::IsNullOrWhiteSpace($rootItem)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $rootItem -PathType Container)) {
            Write-Host "目录不存在: $rootItem" -ForegroundColor Red
            continue
        }

        $rootFull = (Get-Item -LiteralPath $rootItem).FullName
        $pending = [System.Collections.Generic.Queue[object]]::new()
        $pending.Enqueue([pscustomobject]@{
            Path  = $rootFull
            Level = 0
        })

        while ($pending.Count -gt 0) {
            $current = $pending.Dequeue()
            if (Test-SkippedRepositoryPath -Path $current.Path) {
                continue
            }

            $gitMarker = Join-Path $current.Path '.git'
            if (Test-Path -LiteralPath $gitMarker) {
                [void]$found.Add($current.Path.TrimEnd('\', '/'))
            }

            if ($current.Level -ge $Depth) {
                continue
            }

            $children = @(Get-ChildItem -LiteralPath $current.Path -Directory -Force -ErrorAction SilentlyContinue)
            foreach ($child in $children) {
                if ($null -eq $child) {
                    continue
                }
                if ($child.Name -eq '.git' -or $child.Name -eq 'node_modules') {
                    continue
                }
                if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    continue
                }
                $pending.Enqueue([pscustomobject]@{
                    Path  = $child.FullName
                    Level = $current.Level + 1
                })
            }
        }
    }

    $sorted = @($found | Sort-Object)
    return ,$sorted
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $previousErrorAction = $ErrorActionPreference
    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    $ErrorActionPreference = 'Continue'
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        $output = & git --no-pager -c color.ui=never -c core.quotepath=false @ArgumentList 2>&1
        $code = $LASTEXITCODE
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($output)) {
            if ($null -ne $item -and -not [string]::IsNullOrEmpty([string]$item)) {
                $lines.Add([string]$item)
            }
        }
        return [pscustomobject]@{
            Code  = $code
            Lines = $lines.ToArray()
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
        if ($null -eq $previousPrompt) {
            Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        }
        else {
            $env:GIT_TERMINAL_PROMPT = $previousPrompt
        }
    }
}

function ConvertTo-GoneBranchName {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    # git branch -vv: "  feature abc123 [origin/feature: gone] subject"
    if ($Line -match '^\*?\s*(\S+)\s+\S+\s+\[[^\]]*:\s*gone\]') {
        return $Matches[1]
    }
    return $null
}

function Get-GoneBranch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    $fetch = Invoke-Git -ArgumentList @('-C', $RepoPath, 'fetch', '-p')
    if ($fetch.Code -ne 0) {
        return [pscustomobject]@{
            Ok       = $false
            Error    = ($fetch.Lines -join [Environment]::NewLine).Trim()
            Branches = @()
        }
    }

    $branch = Invoke-Git -ArgumentList @('-C', $RepoPath, 'branch', '-vv')
    if ($branch.Code -ne 0) {
        return [pscustomobject]@{
            Ok       = $false
            Error    = ($branch.Lines -join [Environment]::NewLine).Trim()
            Branches = @()
        }
    }

    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $branch.Lines) {
        $name = ConvertTo-GoneBranchName -Line $line
        if ($name) {
            [void]$names.Add($name)
        }
    }

    $sortedNames = New-Object string[] $names.Count
    if ($names.Count -gt 0) {
        $names.CopyTo($sortedNames)
        [Array]::Sort($sortedNames)
    }

    return [pscustomobject]@{
        Ok       = $true
        Error    = $null
        Branches = $sortedNames
    }
}

function Clear-GoneBranch {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Protected
    )

    $result = [pscustomobject]@{
        Matched = 0
        Deleted = 0
        Skipped = 0
        Failed  = 0
    }

    Write-Host "正在处理: $RepoPath" -ForegroundColor Cyan
    $gone = Get-GoneBranch -RepoPath $RepoPath
    if (-not $gone.Ok) {
        Write-Host "获取远程状态失败: $RepoPath" -ForegroundColor Red
        if ($gone.Error) {
            Write-Host $gone.Error -ForegroundColor Red
        }
        $result.Failed++
        return $result
    }

    $current = ''
    $currentResult = Invoke-Git -ArgumentList @('-C', $RepoPath, 'rev-parse', '--abbrev-ref', 'HEAD')
    if ($currentResult.Code -eq 0 -and $currentResult.Lines.Count -gt 0) {
        $current = $currentResult.Lines[0].Trim()
        if ($current -eq 'HEAD') {
            $current = ''
        }
    }

    $goneNames = ConvertTo-CleanStringArray $gone.Branches
    if ($goneNames.Count -eq 0) {
        Write-Host '没有需要删除的本地分支。' -ForegroundColor Green
        return $result
    }

    foreach ($branch in $goneNames) {
        if ([string]::IsNullOrWhiteSpace($branch)) {
            continue
        }
        $result.Matched++
        if ($current -and [string]::Equals($branch, $current, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "跳过当前分支: $branch" -ForegroundColor DarkYellow
            $result.Skipped++
            continue
        }
        if ($Protected.Contains($branch)) {
            Write-Host "跳过保护分支: $branch" -ForegroundColor DarkYellow
            $result.Skipped++
            continue
        }

        Write-Host "正在删除本地分支: $branch" -ForegroundColor Yellow
        $deleted = Invoke-Git -ArgumentList @('-C', $RepoPath, 'branch', '-D', '--', $branch)
        if ($deleted.Code -ne 0) {
            Write-Host "删除失败: $branch" -ForegroundColor Red
            if ($deleted.Lines.Count -gt 0) {
                Write-Host ($deleted.Lines -join [Environment]::NewLine) -ForegroundColor Red
            }
            $result.Failed++
            continue
        }
        $result.Deleted++
    }

    return $result
}

function New-RepositorySelection {
    param([int]$Count)

    [pscustomobject]@{
        Count    = $Count
        Selected = [bool[]]::new($Count)
        Index    = 0
        Action   = 'Continue'
    }
}

function Update-RepositorySelection {
    param(
        $State,
        [System.ConsoleKey]$Key
    )

    if ($Key -eq [System.ConsoleKey]::UpArrow) {
        if ($State.Index -gt 0) {
            $State.Index--
        }
    }
    elseif ($Key -eq [System.ConsoleKey]::DownArrow) {
        if ($State.Index -lt ($State.Count - 1)) {
            $State.Index++
        }
    }
    elseif ($Key -eq [System.ConsoleKey]::Spacebar) {
        $State.Selected[$State.Index] = -not $State.Selected[$State.Index]
    }
    elseif ($Key -eq [System.ConsoleKey]::Enter) {
        $State.Action = 'Confirm'
    }
    elseif ($Key -eq [System.ConsoleKey]::Escape) {
        $State.Action = 'Cancel'
    }

    return $State
}

function Get-ConsoleLineWidth {
    try {
        $width = [Console]::WindowWidth
        if ($width -gt 1) {
            return $width - 1
        }
    }
    catch {
    }
    return 80
}

function Get-PickerPageSize {
    param([int]$ItemCount)

    $available = 8
    try {
        $height = [Console]::WindowHeight
        if ($height -gt 0) {
            $available = $height - 3
        }
    }
    catch {
    }
    if ($available -lt 1) {
        $available = 1
    }
    if ($ItemCount -lt $available) {
        return $ItemCount
    }
    return $available
}

function Format-PickerText {
    param(
        [string]$Text,
        [int]$Width
    )

    if ($null -eq $Text) {
        $Text = ''
    }

    $builder = [System.Text.StringBuilder]::new()
    $used = 0
    foreach ($char in $Text.ToCharArray()) {
        $charWidth = 1
        if ([int]$char -gt 127) {
            $charWidth = 2
        }
        if (($used + $charWidth) -gt $Width) {
            break
        }
        [void]$builder.Append($char)
        $used += $charWidth
    }
    if ($used -lt $Width) {
        [void]$builder.Append(''.PadRight($Width - $used))
    }
    return $builder.ToString()
}

function Write-PickerLine {
    param(
        [string]$Text,
        [int]$Width,
        [switch]$Active,
        [switch]$Header,
        [switch]$Hint
    )

    $Text = Format-PickerText -Text $Text -Width $Width

    if ($Active) {
        Write-Host $Text -ForegroundColor Black -BackgroundColor Cyan
    }
    elseif ($Header) {
        Write-Host $Text -ForegroundColor Cyan
    }
    elseif ($Hint) {
        Write-Host $Text -ForegroundColor DarkGray
    }
    else {
        Write-Host $Text
    }
}

function Draw-RepositoryPicker {
    param(
        [string[]]$Items,
        $State,
        [int]$PageSize
    )

    $width = Get-ConsoleLineWidth
    $offset = 0
    if ($State.Count -gt $PageSize) {
        $offset = $State.Index - [Math]::Floor($PageSize / 2)
        $maxOffset = $State.Count - $PageSize
        if ($offset -lt 0) {
            $offset = 0
        }
        if ($offset -gt $maxOffset) {
            $offset = $maxOffset
        }
    }

    [Console]::SetCursorPosition(0, 0)
    Write-PickerLine -Text ("找到 {0} 个 Git 仓库，请选择要清理的仓库。" -f $State.Count) -Width $width -Header

    for ($row = 0; $row -lt $PageSize; $row++) {
        $itemIndex = $offset + $row
        if ($itemIndex -ge $State.Count) {
            Write-PickerLine -Text '' -Width $width
            continue
        }
        $box = if ($State.Selected[$itemIndex]) { '[x]' } else { '[ ]' }
        $cursor = if ($itemIndex -eq $State.Index) { '>' } else { ' ' }
        $text = '{0} {1} {2}' -f $cursor, $box, $Items[$itemIndex]
        if ($itemIndex -eq $State.Index) {
            Write-PickerLine -Text $text -Width $width -Active
        }
        else {
            Write-PickerLine -Text $text -Width $width
        }
    }

    $hint = '↑↓ 移动  空格 勾选  回车 清理  Esc 取消'
    if ($State.Count -gt $PageSize) {
        $hint = '{0}  {1}/{2}' -f $hint, ($State.Index + 1), $State.Count
    }
    Write-PickerLine -Text $hint -Width $width -Hint
}

function ConvertTo-SelectionResult {
    param(
        [string[]]$Items,
        $State
    )

    if ($State.Action -ne 'Confirm') {
        return [pscustomobject]@{
            Cancelled = $true
            Selected  = @()
        }
    }

    $selected = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($State.Selected[$i]) {
            $selected.Add($Items[$i])
        }
    }

    return [pscustomobject]@{
        Cancelled = $false
        Selected  = $selected.ToArray()
    }
}

function Select-GitRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Repository,
        [System.ConsoleKey[]]$InputKey
    )

    $items = @($Repository)
    $state = New-RepositorySelection -Count $items.Count

    if ($PSBoundParameters.ContainsKey('InputKey')) {
        foreach ($key in @($InputKey)) {
            $state = Update-RepositorySelection -State $state -Key $key
            if ($state.Action -ne 'Continue') {
                break
            }
        }
        if ($state.Action -eq 'Continue') {
            $state.Action = 'Cancel'
        }
        return ConvertTo-SelectionResult -Items $items -State $state
    }

    $pageSize = Get-PickerPageSize -ItemCount $items.Count
    $drawnLines = $pageSize + 2
    $cursorVisible = $true
    try {
        $cursorVisible = [Console]::CursorVisible
    }
    catch {
        throw '当前终端不支持交互选择。'
    }

    try {
        [Console]::CursorVisible = $false
        [Console]::Clear()
        Draw-RepositoryPicker -Items $items -State $state -PageSize $pageSize

        while ($state.Action -eq 'Continue') {
            $keyInfo = [Console]::ReadKey($true)
            $state = Update-RepositorySelection -State $state -Key $keyInfo.Key
            if ($state.Action -eq 'Continue') {
                Draw-RepositoryPicker -Items $items -State $state -PageSize $pageSize
            }
        }
    }
    finally {
        try {
            [Console]::CursorVisible = $cursorVisible
            $nextRow = $drawnLines
            $bufferHeight = [Console]::BufferHeight
            if ($nextRow -ge $bufferHeight) {
                $nextRow = $bufferHeight - 1
            }
            [Console]::SetCursorPosition(0, $nextRow)
        }
        catch {
        }
    }

    return ConvertTo-SelectionResult -Items $items -State $state
}

function New-ProtectedBranchSet {
    param([string[]]$Keep)

    $protected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('main', 'master', 'develop')) {
        [void]$protected.Add($name)
    }
    foreach ($name in @($Keep)) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$protected.Add($name.Trim())
        }
    }
    return ,$protected
}

function ConvertTo-CleanStringArray {
    param($Values)

    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $list.Add([string]$value)
        }
    }
    return ,$list.ToArray()
}

function Invoke-GitClean {
    [CmdletBinding()]
    param(
        [string[]]$Root = @('.'),
        [int]$Depth = 3,
        [string[]]$Keep = @(),
        [Parameter(DontShow)]
        [string[]]$ChosenRepository,
        [Parameter(DontShow)]
        [System.ConsoleKey[]]$InputKey
    )

    $protected = New-ProtectedBranchSet -Keep $Keep

    if ($PSBoundParameters.ContainsKey('ChosenRepository')) {
        $chosen = ConvertTo-CleanStringArray $ChosenRepository
    }
    else {
        $repos = Get-GitRepository -Root $Root -Depth $Depth
        if ($null -eq $repos -or $repos.Count -eq 0) {
            Write-Host '未找到 Git 仓库。' -ForegroundColor Yellow
            return 0
        }

        if ($PSBoundParameters.ContainsKey('InputKey')) {
            $selection = Select-GitRepository -Repository $repos -InputKey $InputKey
        }
        else {
            $selection = Select-GitRepository -Repository $repos
        }
        if ($selection.Cancelled) {
            Write-Host '已取消。' -ForegroundColor Yellow
            return 0
        }

        $chosen = ConvertTo-CleanStringArray $selection.Selected
        if ($chosen.Count -eq 0) {
            Write-Host '未选择仓库。' -ForegroundColor Yellow
            return 0
        }
    }

    $totals = [pscustomobject]@{
        Matched = 0
        Deleted = 0
        Skipped = 0
        Failed  = 0
    }

    foreach ($repo in $chosen) {
        $one = Clear-GoneBranch -RepoPath $repo -Protected $protected
        $totals.Matched += $one.Matched
        $totals.Deleted += $one.Deleted
        $totals.Skipped += $one.Skipped
        $totals.Failed += $one.Failed
    }

    Write-Host '执行完成。' -ForegroundColor Green
    $summary = '选中仓库: {0}  命中分支: {1}  已删除: {2}  跳过: {3}  失败: {4}' -f $chosen.Count, $totals.Matched, $totals.Deleted, $totals.Skipped, $totals.Failed
    Write-Host $summary
    return $totals.Failed
}

Export-ModuleMember -Function Get-GitRepository, Select-GitRepository, Get-GoneBranch, Invoke-GitClean
