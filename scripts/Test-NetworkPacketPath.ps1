#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProxyProfilePath,[Parameter(Mandatory)][string]$InterfaceAlias,[string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$run=Join-Path $BuildDirectory ('test-results\network-packets-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $run
$status=(& pktmon.exe status 2>&1)-join "`n"
if($status -notmatch '没有运行|not running'){throw 'Packet Monitor is already active or its state is unknown; it will not be borrowed.'}
Add-Type -AssemblyName System.Security
$plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($ProxyProfilePath),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
try{$endpoint=([Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json).server}finally{[Array]::Clear($plain,0,$plain.Length)}
$filter='CDF-'+[Guid]::NewGuid().ToString('N');$started=$false;$added=$false;$failure=$null
$etl=Join-Path $run 'headers.etl';$text=Join-Path $run 'headers.txt'
try{
    & pktmon.exe comp list |Out-File (Join-Path $run 'components.txt') -Encoding utf8
    & pktmon.exe filter add $filter -i $endpoint -t TCP -p 443 |Out-Null
    if($LASTEXITCODE -ne 0){throw 'Cannot create the owned packet filter.'};$added=$true
    & pktmon.exe start --capture --comp nics --pkt-size 54 --file-size 16 --file-name $etl |Out-Null
    if($LASTEXITCODE -ne 0){throw 'Cannot start the owned packet capture.'};$started=$true
    & (Join-Path $PSScriptRoot 'Test-Network.ps1') -BuildDirectory $BuildDirectory -ProxyProfilePath $ProxyProfilePath -InterfaceAlias $InterfaceAlias -Online -Observe -Iterations 1 |Out-File (Join-Path $run 'native-run.json') -Encoding utf8
}catch{$failure=$_.Exception.Message}
finally{
    if($started){& pktmon.exe stop|Out-Null;if($LASTEXITCODE -ne 0){$failure='Cannot stop the owned packet capture.'}}
    if($added){& pktmon.exe filter remove $filter|Out-Null;if($LASTEXITCODE -ne 0){$failure='Cannot remove the owned packet filter.'}}
}
if([IO.File]::Exists($etl)){
    & pktmon.exe etl2txt $etl --out $text|Out-Null
    if($LASTEXITCODE -ne 0){$failure='Cannot decode the captured packet headers.'}
}
$native=[IO.File]::ReadAllText((Join-Path $BuildDirectory 'test-results\network-integration.json'))|ConvertFrom-Json
$hasPackets=[IO.File]::Exists($text) -and [IO.File]::ReadAllText($text) -match 'PktGroupId|PacketGroupId|ComponentId|组件 ID'
if(-not $hasPackets -and -not $failure){$failure='The trace contains no packet events; physical NIC/TUN evidence is unavailable.'}
$report=[pscustomobject]@{passed=($null -eq $failure -and $native.passed -and $hasPackets);nativeTestsPassed=$native.passed;failure=$failure;packetEventsObserved=[bool]$hasPackets;runDirectory=$run;nativeRun=$native.runDirectory;upstream=$endpoint;interfaceAlias=$InterfaceAlias;adapterGuid=(Get-NetAdapter -Name $InterfaceAlias).InterfaceGuid;captureBytesPerPacket=54;containsApplicationPayload=$false;requiresComponentAndTupleReview=$true;rawHeaders=$text;realClaudeStarted=$false}
$report|ConvertTo-Json -Depth 5|Out-File (Join-Path $BuildDirectory 'test-results\network-packet-path.json') -Encoding utf8
$report|ConvertTo-Json -Depth 5
if($failure){throw $failure}
