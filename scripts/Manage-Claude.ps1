[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Enable','Status','Disable')][string]$Action)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
. (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
$project=Split-Path -Parent $PSScriptRoot
$coreAction=$Action
if($Action -eq 'Enable'){
    $automaticResult=& (Join-Path $PSScriptRoot 'Manage-ClaudeAuto.ps1') -Action Enable
    if(-not $?){throw 'Automatic refresh enable failed.'}
    $coreAction='Status'
}
if($Action -eq 'Disable'){
    & (Join-Path $PSScriptRoot 'Manage-ClaudeAuto.ps1') -Action Disable|Out-Null
    if(-not $?){throw 'Automatic refresh shutdown failed; IFEO was preserved.'}
}
$context=New-CdfClaudeContext -Root (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude') `
    -SourceDll (Join-Path $project 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll') -DllName 'CdfClaudeTimeZone64.dll'
$context.EnumerationConfigPath=Join-Path $project 'config\claude-targets.json'
$result=Invoke-CdfClaudeManager -Context $context -Action $coreAction
$automatic=(& (Join-Path $PSScriptRoot 'Manage-ClaudeAuto.ps1') -Action Status|ConvertFrom-Json)
$result|Add-Member -NotePropertyName automaticRefresh -NotePropertyValue $automatic
$result|ConvertTo-Json -Depth 24
