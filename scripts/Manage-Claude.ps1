[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Enable','Status','Disable')][string]$Action)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
. (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
$project=Split-Path -Parent $PSScriptRoot
$context=New-CdfClaudeContext -Root (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude') `
    -SourceDll (Join-Path $project 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll') -DllName 'CdfClaudeTimeZone64.dll'
Invoke-CdfClaudeManager -Context $context -Action $Action | ConvertTo-Json -Depth 24
