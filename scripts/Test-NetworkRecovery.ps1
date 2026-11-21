[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Network-Deployment.ps1')
$directory=Join-Path $BuildDirectory ('test-results\network-recovery-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
$checks=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Fixture([string]$Name,[switch]$Committed){
    $dir=Join-Path $directory $Name;$null=New-Item -ItemType Directory -Path $dir
    $files=@();$paths=@('CdfProxyTransport64.dll','active.dpapi','policy.bin')
    for($i=0;$i -lt 3;$i++){
        $path=Join-Path $dir $paths[$i];$backup=$path+'.network-backup'
        [IO.File]::WriteAllText($backup,'before-'+$i);$before=(Get-FileHash $backup).Hash
        [IO.File]::WriteAllText($path,'after-'+$i);$after=(Get-FileHash $path).Hash
        $files+=@{index=$i;path=$path;backup=$backup;beforeHash=$before;afterHash=$after}
    }
    $old='{"schemaVersion":1,"phase":"before"}'
    $record=@{schemaVersion=1;transportSha256=$files[0].afterHash;profileSha256=$files[1].afterHash;policySha256=$files[2].afterHash;previousRecord=$old;files=$files}
    [IO.File]::WriteAllText((Join-Path $dir 'transport-deployment.json'),$(if($Committed){$record|ConvertTo-Json -Depth 8}else{$old}))
    [IO.File]::WriteAllText((Join-Path $dir 'transport-deployment.json.pending.json'),($record|ConvertTo-Json -Depth 8))
    return $dir
}
$rollback=Fixture 'rollback';Restore-CdfNetworkPending $rollback
Assert ([IO.File]::ReadAllText((Join-Path $rollback 'active.dpapi')) -ceq 'before-1') 'Interrupted replacement did not restore old data.'
Assert (-not [IO.File]::Exists((Join-Path $rollback 'transport-deployment.json.pending.json'))) 'Journal not cleared after verified recovery.'
$locked=Fixture 'unchanged-locked';$lockedDll=Join-Path $locked 'CdfProxyTransport64.dll'
[IO.File]::WriteAllText($lockedDll,'before-0')
$handle=[IO.File]::Open($lockedDll,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try{
    Restore-CdfNetworkPending $locked
    Assert ([IO.File]::ReadAllText((Join-Path $locked 'policy.bin')) -ceq 'before-2') 'Recovery did not restore changed data while the unchanged DLL was in use.'
    Assert (-not [IO.File]::Exists((Join-Path $locked 'transport-deployment.json.pending.json'))) 'An unchanged locked DLL kept a recovered journal.'
}finally{$handle.Dispose()}
$committed=Fixture 'committed' -Committed;Restore-CdfNetworkPending $committed
Assert ([IO.File]::ReadAllText((Join-Path $committed 'active.dpapi')) -ceq 'after-1') 'Committed bytes were rolled back.'
$conflict=Fixture 'conflict';[IO.File]::WriteAllText((Join-Path $conflict 'policy.bin'),'external')
$rejected=$false;try{Restore-CdfNetworkPending $conflict}catch{$rejected=$_.Exception.Message -like '*External deployment conflict*'}
Assert $rejected 'An external modification was not rejected.'
Assert ([IO.File]::ReadAllText((Join-Path $conflict 'CdfProxyTransport64.dll')) -ceq 'after-0') 'Conflict preflight partially overwrote another file.'
Assert ([IO.File]::Exists((Join-Path $conflict 'active.dpapi.network-backup'))) 'Conflict recovery evidence was removed.'
$tamper=Fixture 'backup-tamper';[IO.File]::WriteAllText((Join-Path $tamper 'active.dpapi.network-backup'),'changed')
$rejected=$false;try{Restore-CdfNetworkPending $tamper}catch{$rejected=$_.Exception.Message -like '*backup*changed*'}
Assert $rejected 'A changed backup was accepted.'
$report=[pscustomobject]@{passed=$true;checks=$checks;directory=$directory;touchesRegistry=$false;usesCredentials=$false}
$report|ConvertTo-Json|Out-File (Join-Path $BuildDirectory 'test-results\network-recovery.json') -Encoding utf8
$report|ConvertTo-Json
