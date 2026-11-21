[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Enable','Status','Disable')][string]$Action)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
. (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
$project=Split-Path -Parent $PSScriptRoot
$networkPolicy=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\network\claude.json'
$networkConfigured=(Test-Path -LiteralPath $networkPolicy) -and (Get-Content -LiteralPath $networkPolicy -Raw -Encoding UTF8|ConvertFrom-Json).enabled
$coreAction=$Action
if($Action -eq 'Enable'){
    if($networkConfigured){
        # Its manager preserves the verified deployed time build while adding
        # the signed network provider to the same refresh transaction.
        $automaticResult=& (Join-Path $PSScriptRoot 'Manage-ClaudeNetwork.ps1') -Action Enable
    }else{$automaticResult=& (Join-Path $PSScriptRoot 'Manage-ClaudeAuto.ps1') -Action Enable}
    if(-not $?){throw 'Automatic refresh enable failed.'}
    $coreAction='Status'
}
if($networkConfigured){
    $autoPath=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude-auto\state.json'
    if(Test-Path -LiteralPath $autoPath){
        $active=Get-Content -LiteralPath $autoPath -Raw -Encoding UTF8|ConvertFrom-Json
        $activeDll=Join-Path $active.release 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll'
        $deployedDll=Join-Path $env:SystemRoot 'System32\CdfClaudeTimeZone64.dll'
        if((Cdf-Hash $activeDll) -and (Cdf-Hash $activeDll) -ceq (Cdf-Hash $deployedDll)){
            $project=$active.release
            . (Join-Path $project 'scripts\Claude-ProcessDiagnostics.ps1')
        }
    }
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
if(Test-Path -LiteralPath $networkPolicy){$result|Add-Member -NotePropertyName network -NotePropertyValue (& (Join-Path $PSScriptRoot 'Manage-ClaudeNetwork.ps1') -Action Status|ConvertFrom-Json)}
$result|ConvertTo-Json -Depth 24
