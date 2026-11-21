#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProxyProfilePath,[Parameter(Mandatory)][string]$InterfaceAlias,[string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$manager=Join-Path $PSScriptRoot 'Manage-Network.ps1';$bin=Join-Path $BuildDirectory 'bin';$image='CdfNetworkProbe64.exe'
if((& $manager -Action Status -ImageName $image|ConvertFrom-Json).managed){throw 'Pre-existing test registration will not be borrowed.'}
$run=Join-Path $BuildDirectory ('test-results\network-failure-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $run
Add-Type -AssemblyName System.Security
$cases=[Collections.Generic.List[object]]::new();$failure=$null
. (Join-Path $PSScriptRoot 'Network-Trace.ps1')
$trace=Start-CdfNetworkTrace $run;$processIds=[Collections.Generic.List[int]]::new();$endpoint=$null;$observation=$null
try{
    foreach($fault in @('invalid-reality-key','closed-upstream-port')){
        $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($ProxyProfilePath),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        try{$config=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json}finally{[Array]::Clear($plain,0,$plain.Length)}
        $endpoint=$config.server
        if($fault -eq 'invalid-reality-key'){$random=[byte[]]::new(32);[Security.Cryptography.RandomNumberGenerator]::Fill($random);$config.'reality-opts'.'public-key'=[Convert]::ToBase64String($random).TrimEnd('=').Replace('+','-').Replace('/','_')}
        else{$config.port=1}
        $path=Join-Path $run ($fault+'.dpapi');$bytes=[Text.Encoding]::UTF8.GetBytes(($config|ConvertTo-Json -Depth 12 -Compress));$config=$null
        try{[IO.File]::WriteAllBytes($path,[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))}finally{[Array]::Clear($bytes,0,$bytes.Length)}
        $installed=$false
        try{
            & $manager -Action Install -ImageName $image -ProviderPath (Join-Path $bin 'CdfNetwork64.dll') -TransportPath (Join-Path $bin 'CdfProxyTransport64.dll') -ProxyProfilePath $path -InterfaceAlias $InterfaceAlias|Out-Null;$installed=$true
            $out=Join-Path $run ($fault+'.json');$err=Join-Path $run ($fault+'.stderr')
            $process=Start-Process -FilePath (Join-Path $bin $image) -ArgumentList '--async' -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
            $processIds.Add($process.Id)
            if(-not $process.WaitForExit(25000)){$process.Kill();$process.WaitForExit();throw "Fault case timed out: $fault"}
            $data=[IO.File]::ReadAllText($out)|ConvertFrom-Json
            $passed=$process.ExitCode -ne 0 -and -not $data.passed -and $data.proxiedConnections -eq 0 -and ($data.body|ConvertFrom-Json).completionError -ne 0
            $cases.Add([pscustomobject]@{fault=$fault;passed=$passed;exitCode=$process.ExitCode;output=$out;usesFallback=$false})
            if(-not $passed){throw "Failure did not fail closed: $fault"}
        }finally{if($installed){& $manager -Action Uninstall -ImageName $image|Out-Null}}
    }
}catch{$failure=$_.Exception.Message}
finally{
    # Restore the ordinary encrypted profile without leaving any IFEO target active.
    & $manager -Action Install -ImageName $image -ProviderPath (Join-Path $bin 'CdfNetwork64.dll') -TransportPath (Join-Path $bin 'CdfProxyTransport64.dll') -ProxyProfilePath $ProxyProfilePath -InterfaceAlias $InterfaceAlias|Out-Null
    & $manager -Action Uninstall -ImageName $image|Out-Null
    if($trace -and -not $trace.stopped){$observation=Stop-CdfNetworkTrace $trace @($processIds) $endpoint $run;if(-not $observation.passed -and -not $failure){$failure='Independent fault-path observation did not pass.'}}
}
$report=[pscustomobject]@{passed=($null -eq $failure);failure=$failure;cases=$cases;observation=$observation;runDirectory=$run;restored=(-not (& $manager -Action Status -ImageName $image|ConvertFrom-Json).managed);realClaudeStarted=$false}
$report|ConvertTo-Json -Depth 6|Out-File (Join-Path $BuildDirectory 'test-results\network-failure.json') -Encoding utf8
$report|Select-Object passed,failure,cases,runDirectory,restored|ConvertTo-Json -Depth 6
if($failure){throw $failure}
