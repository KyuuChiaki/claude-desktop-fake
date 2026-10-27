[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReportPath,[string]$FixtureDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\runtime-fixtures\electron-44.9.3'),[string]$ExplicitLang,[string]$StartupTZ,[switch]$Capture,[string]$ImageName='CdfElectronProbe64.exe',[string]$TestFault,[long]$ExpectedExitCode=0,[ValidateRange(1,120)][int]$TimeoutSeconds=45,[switch]$TestHang)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Runtime-ProcessFailure.ps1')
$projectRoot=Split-Path -Parent $PSScriptRoot
$output=[IO.Path]::GetFullPath($ReportPath);$userData=$output+'.userdata'
$process=[Diagnostics.Process]::new();$info=$process.StartInfo
$info.FileName=Join-Path $FixtureDirectory $ImageName
$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
$info.ArgumentList.Add((Join-Path $projectRoot 'tests\runtime_electron.cjs'))
if($ExplicitLang){$info.ArgumentList.Add('--lang='+$ExplicitLang)}
$info.Environment['CDF_RUNTIME_REPORT']=$output;$info.Environment['CDF_RUNTIME_USER_DATA']=$userData
$info.Environment['CDF_RUNTIME_NATIVE']=Join-Path $projectRoot 'out\build\x64-release\bin\CdfRuntimeNative64.node'
$info.Environment['CDF_RUNTIME_TEST_TZ']='1'
if($TestFault){$info.Environment['CDF_RUNTIME_TEST_FAULT']=$TestFault}else{$info.Environment.Remove('CDF_RUNTIME_TEST_FAULT')|Out-Null}
if($Capture){$info.Environment['CDF_RUNTIME_HOLD']='1'}
if($TestHang){$info.Environment['CDF_RUNTIME_TEST_HANG']='1'}else{[void]$info.Environment.Remove('CDF_RUNTIME_TEST_HANG')}
$info.Environment.Remove('ELECTRON_RUN_AS_NODE')|Out-Null;$info.Environment.Remove('NODE_OPTIONS')|Out-Null
$info.Environment.Remove('TZ')|Out-Null;if($StartupTZ){$info.Environment['TZ']=$StartupTZ}
$start=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();$watch=[Diagnostics.Stopwatch]::StartNew()
$started=$false;$timedOut=$false;$creation=$null;$o=$null;$e=$null
try{
    [void]$process.Start();$started=$true;$o=$process.StandardOutput.ReadToEndAsync();$e=$process.StandardError.ReadToEndAsync()
    $creation=$null;try{$creation=$process.StartTime.ToUniversalTime().ToFileTimeUtc()}catch{}
    if($Capture){
        $captured=$false
        while(-not $process.WaitForExit(100)){
            if((Test-Path -LiteralPath $output) -and -not $captured){
                $tree=@([int]$process.Id);$all=@(Get-CimInstance Win32_Process -Filter ("Name='"+$ImageName+"'"))
                do{$oldCount=$tree.Count;foreach($item in $all){if($item.ParentProcessId -in $tree -and $item.ProcessId -notin $tree){$tree+=([int]$item.ProcessId)}}}while($tree.Count -gt $oldCount)
                foreach($id in $tree){try{$null=& (Join-Path $PSScriptRoot 'Capture-Runtime.ps1') -ProcessId $id -OutputPath ($output+'.capture.'+$id+'.json')}catch{[IO.File]::WriteAllText(($output+'.capture.'+$id+'.error.txt'),$_.Exception.Message)}}
                $captured=$true
            }
            if($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds+5){$timedOut=$true;$process.Kill($true);$process.WaitForExit();throw 'Isolated capture fixture timed out.'}
        }
    }elseif(-not $process.WaitForExit($TimeoutSeconds*1000)){$timedOut=$true;$process.Kill($true);$process.WaitForExit();throw 'Isolated Electron probe timed out.'}
    $watch.Stop();$end=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $reference=[pscustomobject]@{utcStartMs=$start;utcEndMs=$end;elapsedMs=$watch.Elapsed.TotalMilliseconds;realCreationFileTime=$creation;exitCode=$process.ExitCode;unsignedExitCode=([long]$process.ExitCode -band 4294967295L);stdout=$o.GetAwaiter().GetResult();stderr=$e.GetAwaiter().GetResult()}
    $reference|ConvertTo-Json -Depth 6|Set-Content -LiteralPath ($output+'.controller.json') -Encoding utf8
    if($reference.unsignedExitCode -ne $ExpectedExitCode){throw "Isolated Electron probe exit $($process.ExitCode): $($reference.stderr)"}
    if($ExpectedExitCode -ne 0){return $reference}
    $r=Get-Content -Raw -LiteralPath $output|ConvertFrom-Json
    if($r.PSObject.Properties['error']){throw "Isolated Electron probe failed: $($r.error.message)"}
    [pscustomobject]@{report=$output;versions=$r.main.process.versions;electron=$r.electron;main=$r.main.intlDate;renderer=$r.renderer.intlDate;navigator=$r.renderer.navigator;preferred=$r.native.winrtLanguages;network=$r.networkDefault;dateVsOriginMs=($r.main.now-$r.main.performance.absolute);creationVsOriginMs=($r.main.process.creationTime-$r.main.performance.timeOrigin)}
}catch{
    if(-not(Test-Path -LiteralPath ($output+'.controller.json'))){Save-CdfRuntimeProcessFailure $process $started $o $e ($output+'.controller.json') $start $creation $_ $timedOut}
    throw
}finally{$process.Dispose()}
