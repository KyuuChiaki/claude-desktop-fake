[CmdletBinding()]
param(
    [string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),
    [string]$ProxyProfilePath=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\network\active.dpapi'),
    [string]$TransportPath=(Join-Path $BuildDirectory 'bin\CdfProxyTransport64.dll'),
    [Parameter(Mandatory)][string]$InterfaceAlias,
    [switch]$Online,
    [ValidateRange(1,10)][int]$Iterations=1,
    [switch]$Observe
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$bin=Join-Path $BuildDirectory 'bin';$results=Join-Path $BuildDirectory 'test-results'
$null=New-Item -ItemType Directory -Force -Path $results
$run=Join-Path $results ('network-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $run
$manager=Join-Path $PSScriptRoot 'Manage-Network.ps1'
$evidence=[Collections.Generic.List[object]]::new();$cleanup=[Collections.Generic.List[object]]::new()
$failure=$null
. (Join-Path $PSScriptRoot 'Network-Trace.ps1')
$trace=$null;$observation=$null
function Invoke-NetworkProbe([string]$Image,[string[]]$Arguments,[string]$Label){
    $stdout=Join-Path $run ($Label+'.json');$stderr=Join-Path $run ($Label+'.stderr')
    $proc=Start-Process -FilePath (Join-Path $bin $Image) -ArgumentList $Arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $timeout=-not $proc.WaitForExit(50000)
    if($timeout){Stop-Process -Id $proc.Id -ErrorAction Stop;$proc.WaitForExit()}
    $record=[pscustomobject]@{label=$Label;image=$Image;processId=$proc.Id;exitCode=$proc.ExitCode;timedOut=$timeout;output=$stdout;stderr=$stderr;data=$null}
    if([IO.File]::Exists($stdout) -and [IO.File]::ReadAllText($stdout).Trim()) {try{$record.data=[IO.File]::ReadAllText($stdout)|ConvertFrom-Json}catch{}}
    $evidence.Add($record)
    if($timeout -or $record.exitCode -ne 0 -or -not $record.data -or -not $record.data.passed){throw "Probe failed: $Label. Evidence: $stdout"}
    return $record
}
try{
    if($Observe){$trace=Start-CdfNetworkTrace $run}
    foreach($image in @('CdfNetworkProbe64.exe','CdfNetworkProbeOther64.exe')){
        if(-not [IO.File]::Exists((Join-Path $bin $image))){throw "Build is missing: $image"}
        $before=& $manager -Action Status -ImageName $image | ConvertFrom-Json
        if($before.managed){throw "A pre-existing managed test image will not be borrowed: $image"}
        $null=Invoke-NetworkProbe $image @('--baseline') ($image+'-before')
        try{
            & $manager -Action Install -ImageName $image -ProviderPath (Join-Path $bin 'CdfNetwork64.dll') -TransportPath $TransportPath -ProxyProfilePath $ProxyProfilePath -InterfaceAlias $InterfaceAlias | Out-File (Join-Path $run ($image+'-install.json')) -Encoding utf8
            for($i=0;$i -lt $Iterations;$i++){$null=Invoke-NetworkProbe $image @('--policy') ($image+'-policy-'+$i)}
            $null=Invoke-NetworkProbe $image @('--denials') ($image+'-denials')
            $null=Invoke-NetworkProbe $image @('--ipv4-only') ($image+'-ipv4')
            if($Online){
                $null=Invoke-NetworkProbe $image @('--async') ($image+'-async')
                $null=Invoke-NetworkProbe $image @('--async-cancel') ($image+'-async-cancel')
                $null=Invoke-NetworkProbe $image @('--async-event') ($image+'-async-event')
                $null=Invoke-NetworkProbe $image @('--async-event-skip-port') ($image+'-async-event-skip-port')
                $null=Invoke-NetworkProbe $image @('--dns-contracts') ($image+'-dns-contracts')
                $null=Invoke-NetworkProbe $image @('--resolve','cleanip.io') ($image+'-dns')
                for($i=0;$i -lt $Iterations;$i++){$null=Invoke-NetworkProbe $image @('--https','https://cleanip.io/who-am-i') ($image+'-https-'+$i)}
            }
        }finally{
            try{$restored=& $manager -Action Uninstall -ImageName $image | ConvertFrom-Json;$cleanup.Add([pscustomobject]@{image=$image;restored=(-not $restored.managed)})}
            catch{$cleanup.Add([pscustomobject]@{image=$image;restored=$false;error=$_.Exception.Message});throw}
        }
        $null=Invoke-NetworkProbe $image @('--baseline') ($image+'-after')
    }
}catch{$failure=$_.Exception.Message}
finally{if($trace){try{
    Add-Type -AssemblyName System.Security
    $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($ProxyProfilePath),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try{$endpoint=([Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json).server}finally{[Array]::Clear($plain,0,$plain.Length)}
    $observation=Stop-CdfNetworkTrace $trace @($evidence|ForEach-Object processId) $endpoint $run
    if(-not $observation.passed -and -not $failure){$failure='Independent metadata observation did not pass.'}
}catch{if(-not $failure){$failure=$_.Exception.Message}}}}
$report=[pscustomobject]@{schemaVersion=1;passed=($null -eq $failure);failure=$failure;online=[bool]$Online;runDirectory=$run;cases=$evidence;cleanup=$cleanup;observation=$observation;acceptanceLevel='native-integration';fullPlanAccepted=$false}
$report | ConvertTo-Json -Depth 14 | Out-File (Join-Path $results 'network-integration.json') -Encoding utf8
$report | Select-Object passed,failure,online,runDirectory,cleanup | ConvertTo-Json -Depth 5
if($failure){throw $failure}
