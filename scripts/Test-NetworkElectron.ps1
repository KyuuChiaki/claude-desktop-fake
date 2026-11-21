#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),
    [string]$FixtureDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\runtime-fixtures\electron-44.9.3'),
    [Parameter(Mandatory)][string]$ProxyProfilePath,
    [Parameter(Mandatory)][string]$InterfaceAlias,
    [ValidateRange(15,180)][int]$TimeoutSeconds=90
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot;$bin=Join-Path $BuildDirectory 'bin'
$results=Join-Path $BuildDirectory 'test-results';$run=Join-Path $results ('network-electron-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Force -Path $run
$template=Join-Path $FixtureDirectory 'CdfElectronProbe64.exe';$image='CdfNetworkElectron64.exe';$destination=Join-Path $FixtureDirectory $image
$hash=(Get-FileHash -LiteralPath $template).Hash;$marker=$destination+'.cdf-network.json'
if([IO.File]::Exists($destination)){
    if(-not [IO.File]::Exists($marker) -or ([IO.File]::ReadAllText($marker)|ConvertFrom-Json).sha256 -ne $hash -or (Get-FileHash -LiteralPath $destination).Hash -ne $hash){throw 'The existing fixture image is unowned or changed.'}
}else{Copy-Item -LiteralPath $template -Destination $destination;[IO.File]::WriteAllText($marker,(@{sha256=$hash}|ConvertTo-Json))}
if(@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($image)) -ErrorAction SilentlyContinue).Count){throw 'An existing network fixture process will not be borrowed.'}
$manager=Join-Path $PSScriptRoot 'Manage-Network.ps1';$before=& $manager -Action Status -ImageName $image|ConvertFrom-Json
if($before.managed){throw 'A pre-existing fixture registration will not be borrowed.'}
$output=Join-Path $run 'electron.json';$controller=Join-Path $run 'controller.json'
$proc=[Diagnostics.Process]::new();$info=$proc.StartInfo;$info.FileName=$destination;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
$info.ArgumentList.Add((Join-Path $root 'tests\network_electron.cjs'))
$info.Environment['CDF_NETWORK_REPORT']=$output;$info.Environment['CDF_NETWORK_USER_DATA']=Join-Path $run 'userdata';$info.Environment['CDF_NETWORK_ADDON']=Join-Path $bin 'CdfNetworkNative64.node'
foreach($name in @('ELECTRON_RUN_AS_NODE','NODE_OPTIONS')){[void]$info.Environment.Remove($name)}
$failure=$null;$started=$false;$timedOut=$false;$restored=$false;$captured=$false;$known=[Collections.Generic.HashSet[int]]::new();$stdout=$null;$stderr=$null
try{
    & $manager -Action Install -ImageName $image -ProviderPath (Join-Path $bin 'CdfNetwork64.dll') -TransportPath (Join-Path $bin 'CdfProxyTransport64.dll') -ProxyProfilePath $ProxyProfilePath -InterfaceAlias $InterfaceAlias | Out-File (Join-Path $run 'install.json') -Encoding utf8
    [void]$proc.Start();$started=$true;[void]$known.Add($proc.Id);$stdout=$proc.StandardOutput.ReadToEndAsync();$stderr=$proc.StandardError.ReadToEndAsync();$watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not $proc.WaitForExit(100)){
        if([IO.File]::Exists($output) -and -not $captured){
            $data=[IO.File]::ReadAllText($output)|ConvertFrom-Json
            foreach($item in $data.processes){[void]$known.Add([int]$item.pid)}
            foreach($targetId in $known){try{& (Join-Path $PSScriptRoot 'Capture-Network.ps1') -ProcessId $targetId -BuildDirectory $BuildDirectory -OutputPath (Join-Path $run ('capture-'+$targetId+'.json'))|Out-Null}catch{[IO.File]::WriteAllText((Join-Path $run ('capture-'+$targetId+'.error.txt')),$_.Exception.Message)}}
            $captured=$true
        }
        if($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds){$timedOut=$true;$proc.Kill($true);$proc.WaitForExit();throw 'Isolated network Electron fixture timed out.'}
    }
    $data=if([IO.File]::Exists($output)){[IO.File]::ReadAllText($output)|ConvertFrom-Json}else{$null}
    if($proc.ExitCode -ne 0 -or -not $data -or -not $data.passed){throw "Isolated Electron acceptance failed; evidence: $output"}
}catch{$failure=$_.Exception.Message}
finally{
    # Only descendants of this run's unique root process are eligible for cleanup.
    if($started){
        $children=@(Get-CimInstance Win32_Process -Filter ("Name='"+$image+"'"))
        do{$oldCount=$known.Count;foreach($child in $children){if($known.Contains([int]$child.ParentProcessId)){[void]$known.Add([int]$child.ProcessId)}}}while($known.Count -gt $oldCount)
        foreach($child in $children){if($known.Contains([int]$child.ProcessId)){try{$owned=[Diagnostics.Process]::GetProcessById([int]$child.ProcessId);if($owned.MainModule.FileName -ieq $destination){$owned.Kill();$owned.WaitForExit(5000)|Out-Null};$owned.Dispose()}catch{}}}
    }
    try{& $manager -Action Uninstall -ImageName $image|Out-File (Join-Path $run 'cleanup.json') -Encoding utf8;$restored=$true}catch{if(-not $failure){$failure=$_.Exception.Message}}
    $record=[pscustomobject]@{passed=($null -eq $failure);failure=$failure;started=$started;timedOut=$timedOut;exitCode=$(if($started -and $proc.HasExited){$proc.ExitCode}else{$null});processIds=@($known);stdout=$(if($stdout){$stdout.GetAwaiter().GetResult()}else{''});stderr=$(if($stderr){$stderr.GetAwaiter().GetResult()}else{''});restored=$restored;runDirectory=$run;acceptanceLevel='isolated-electron';realClaudeStarted=$false;fullPlanAccepted=$false}
    $record|ConvertTo-Json -Depth 6|Out-File $controller -Encoding utf8
    $record|ConvertTo-Json -Depth 6|Out-File (Join-Path $results 'network-electron.json') -Encoding utf8
    $proc.Dispose()
}
$record|Select-Object passed,failure,restored,runDirectory|ConvertTo-Json
if($failure){throw $failure}
