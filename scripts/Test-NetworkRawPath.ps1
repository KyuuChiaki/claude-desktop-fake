#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProxyProfilePath,[Parameter(Mandatory)][string]$InterfaceAlias,[string]$TunInterfaceAlias='Mihomo',[string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Network-Trace.ps1')
$manager=Join-Path $PSScriptRoot 'Manage-Network.ps1';$image='CdfNetworkProbe64.exe';$bin=Join-Path $BuildDirectory 'bin'
if((& $manager -Action Status -ImageName $image|ConvertFrom-Json).managed){throw 'An existing registration will not be borrowed.'}
$physical=@(Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4|Where-Object AddressState -eq Preferred)[0].IPAddress
$tun=@(Get-NetIPAddress -InterfaceAlias $TunInterfaceAlias -AddressFamily IPv4|Where-Object AddressState -eq Preferred)[0].IPAddress
Add-Type -AssemblyName System.Security
$plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($ProxyProfilePath),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
try{$endpoint=([Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json).server}finally{[Array]::Clear($plain,0,$plain.Length)}
$run=Join-Path $BuildDirectory ('test-results\network-raw-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $run
$ready=Join-Path $run 'ready.json';$stop=Join-Path $run 'stop';$headers=Join-Path $run 'headers.json'
$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=(Get-Command python).Source;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardError=$true
foreach($argument in @((Join-Path $PSScriptRoot 'Observe-NetworkHeaders.py'),'--physical',$physical,'--tun',$tun,'--upstream',$endpoint,'--ready',$ready,'--stop',$stop,'--output',$headers)){$info.ArgumentList.Add($argument)}
$observer=[Diagnostics.Process]::Start($info);$observerErrors=$observer.StandardError.ReadToEndAsync();$installed=$false;$trace=$null;$ids=@();$failure=$null;$observation=$null;$exitCode=$null
try{
    for($i=0;$i -lt 50 -and -not [IO.File]::Exists($ready);$i++){Start-Sleep -Milliseconds 100}
    if(-not [IO.File]::Exists($ready)){throw 'Header observer did not become ready.'}
    $trace=Start-CdfNetworkTrace $run
    & $manager -Action Install -ImageName $image -ProviderPath (Join-Path $bin 'CdfNetwork64.dll') -TransportPath (Join-Path $bin 'CdfProxyTransport64.dll') -ProxyProfilePath $ProxyProfilePath -InterfaceAlias $InterfaceAlias|Out-Null;$installed=$true
    $probe=Start-Process -FilePath (Join-Path $bin $image) -ArgumentList @('--https','https://api.ipify.org?format=json') -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $run 'probe.json') -RedirectStandardError (Join-Path $run 'probe.stderr');$ids=@($probe.Id)
    if(-not $probe.WaitForExit(20000)){$probe.Kill();$probe.WaitForExit();throw 'Physical-path probe timed out.'};$exitCode=$probe.ExitCode
}catch{$failure=$_.Exception.Message}
finally{
    if($installed){& $manager -Action Uninstall -ImageName $image|Out-Null}
    [IO.File]::WriteAllText($stop,'stop')
    if(-not $observer.WaitForExit(10000)){$observer.Kill();$observer.WaitForExit()}
    if($trace){$observation=Stop-CdfNetworkTrace $trace $ids $endpoint $run}
    [IO.File]::WriteAllText((Join-Path $run 'observer.stderr'),$observerErrors.GetAwaiter().GetResult())
}
$raw=[IO.File]::ReadAllText($headers)|ConvertFrom-Json
$probeData=if([IO.File]::Exists((Join-Path $run 'probe.json'))){[IO.File]::ReadAllText((Join-Path $run 'probe.json'))|ConvertFrom-Json}else{$null}
$ports=@();if($observation){$ports=@($observation.events|Where-Object {$_.destination -eq $endpoint -and $_.port -eq 443}|ForEach-Object sourcePort|Sort-Object -Unique)}
$matched=@($raw.records|Where-Object {$_.interface -eq 'physical' -and $_.destination -eq $endpoint -and $_.sourcePort -in $ports})
$tunnel=@($raw.records|Where-Object {$_.interface -eq 'tun' -and $_.destination -eq $endpoint -and $_.sourcePort -in $ports})
$exitIp=if($probeData){($probeData.body|ConvertFrom-Json).ip}else{$null}
$passed=-not $failure -and $exitCode -eq 0 -and $probeData.passed -and $observation.passed -and $matched.Count -gt 0 -and $tunnel.Count -eq 0 -and @($raw.channels).Count -eq 2 -and @($raw.errors.PSObject.Properties).Count -eq 0
$report=[pscustomobject]@{passed=$passed;failure=$failure;runDirectory=$run;method=$raw.method;processIds=$ids;physical=$physical;tun=$tun;upstream=$endpoint;upstreamPorts=$ports;physicalPackets=$matched.Count;tunMatchingPackets=$tunnel.Count;exitIp=$exitIp;httpStatus=$(if($probeData){$probeData.httpStatus}else{$null});providerSha256=(Get-FileHash (Join-Path $bin 'CdfNetwork64.dll')).Hash;scope='Only this owned PID and sampling window; no IPv6 or all-system guarantee';realClaudeStarted=$false;restored=(-not (& $manager -Action Status -ImageName $image|ConvertFrom-Json).managed)}
$report|ConvertTo-Json -Depth 6|Out-File (Join-Path $BuildDirectory 'test-results\network-raw-path.json') -Encoding utf8
$report|ConvertTo-Json -Depth 6
if(-not $passed){throw 'Physical-path observation did not pass; inspect the retained evidence.'}
