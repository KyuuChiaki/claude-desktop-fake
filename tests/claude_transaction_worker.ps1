param([string]$Project,[string]$Root,[string]$Manifest,[string]$SourceDll,[string]$Probe,[string]$Second,[ValidateSet('Enable','Disable')][string]$Action='Enable')
$ErrorActionPreference='Stop'
. (Join-Path $Project 'scripts\Claude-FileIdentity.ps1')
. (Join-Path $Project 'scripts\Claude-ManagerCore.ps1')
$context=New-CdfClaudeContext -Root $Root -SourceDll $SourceDll -DllName 'CdfClaudeTimeZoneTest64.dll'
$context.Manifest=$Manifest
$fixture=[pscustomobject]@{root=(Split-Path -Parent $Probe);packageId='fixture_1.0.0.0_x64__fnn82j28hfe8t';main=$Probe;services=@();files=@($Probe,$Second)}
$context.Discover={$fixture}.GetNewClosure()
$context.Signature={param($path)[pscustomobject]@{status='Valid';signer='Anthropic, PBC'}}
# Deliberately terminate the isolated manager, leaving the write-ahead journal.
$context.Fault={param($writes)if($writes -eq 4){[Environment]::Exit(87)}}
Invoke-CdfClaudeManager $context $Action|Out-Null
exit 1
