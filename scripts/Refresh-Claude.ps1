param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-AutoCore.ps1')
try{$result=Cdf-AutoRefresh $StateRoot;Cdf-Save $ResultPath ([pscustomobject]@{success=$true;finishedAtUtc=[DateTime]::UtcNow.ToString('o');result=$result;error=$null})}
catch{Cdf-Save $ResultPath ([pscustomobject]@{success=$false;finishedAtUtc=[DateTime]::UtcNow.ToString('o');result=$null;error=$_.Exception.Message});exit 1}
