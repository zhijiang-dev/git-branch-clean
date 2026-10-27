# 批量清理远程已删除、本地仍保留的 Git 分支。
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$Root = @('.'),
    [int]$Depth = 3,
    [string[]]$Keep = @()
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$modulePath = Join-Path $PSScriptRoot 'GitClean.psm1'
Import-Module $modulePath -Force
$failed = Invoke-GitClean -Root $Root -Depth $Depth -Keep $Keep
exit $failed
