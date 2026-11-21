#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InterfaceAlias='以太网',
    [string]$ProxyProfilePath=(Join-Path $env:ProgramData 'ClaudeDesktopFake\network\active.dpapi'),
    [string]$Url='https://cleanip.io/who-am-i',
    [string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),
    [switch]$Worker,
    [string]$SessionDirectory
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot;$bin=Join-Path $BuildDirectory 'bin'
. (Join-Path $PSScriptRoot 'Network-Deployment.ps1')
$image='CdfNetworkBrowser64.exe';$manager=Join-Path $PSScriptRoot 'Manage-Network.ps1'
if(-not $Worker){
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Use an elevated 64-bit PowerShell session.'}
    if(-not [Environment]::Is64BitProcess){throw 'Use 64-bit PowerShell.'}
    if(@(Get-Process -Name CdfNetworkBrowser64 -ErrorAction SilentlyContinue).Count){throw 'The owned test browser is already running.'}
    if((& $manager -Action Status -ImageName $image|ConvertFrom-Json).managed){throw 'An existing browser registration will not be borrowed.'}
    $fixture=Join-Path $root 'out\runtime-fixtures\electron-44.9.3';$template=Join-Path $fixture 'CdfElectronProbe64.exe';$destination=Join-Path $fixture $image
    $hash=(Get-FileHash -LiteralPath $template).Hash;$marker=$destination+'.cdf-network.json'
    if([IO.File]::Exists($destination)){
        if(-not [IO.File]::Exists($marker) -or ([IO.File]::ReadAllText($marker)|ConvertFrom-Json).sha256 -ne $hash -or (Get-FileHash -LiteralPath $destination).Hash -ne $hash){throw 'Existing browser image is unowned or changed.'}
    }else{Copy-Item -LiteralPath $template -Destination $destination;[IO.File]::WriteAllText($marker,(@{sha256=$hash}|ConvertTo-Json))}
    $run=Join-Path $BuildDirectory ('test-results\network-browser-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $run
    $network=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\network'
    $config=[ordered]@{image=$destination;imageSha256=$hash;addon=(Join-Path $bin 'CdfNetworkNative64.node');interfaceAlias=$InterfaceAlias;profile=(Resolve-Path -LiteralPath $ProxyProfilePath).ProviderPath;url=$Url;buildDirectory=$BuildDirectory;webRTCDisabled=(Get-CdfWebRTCPolicy $network).disabled}
    [IO.File]::WriteAllText((Join-Path $run 'config.json'),($config|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($argument in @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Worker','-SessionDirectory',$run)){$start.ArgumentList.Add($argument)}
    $watcher=[Diagnostics.Process]::Start($start)
    $record=[pscustomobject]@{sessionDirectory=$run;watcherProcessId=$watcher.Id;imageName=$image;automaticUninstall='When this browser exits';profile='CurrentUser DPAPI';interfaceAlias=$InterfaceAlias}
    $record|ConvertTo-Json|Out-File (Join-Path $BuildDirectory 'test-results\network-browser-current.json') -Encoding utf8
    $record|ConvertTo-Json
    return
}
if(-not $SessionDirectory){throw 'Worker requires a session directory.'}
$config=[IO.File]::ReadAllText((Join-Path $SessionDirectory 'config.json'))|ConvertFrom-Json
$bin=Join-Path $config.buildDirectory 'bin';$installed=$false;$started=$false;$failure=$null;$proc=$null;$outTask=$null;$errTask=$null;$restored=$false
function Write-Session([string]$Phase){
    $record=[pscustomobject]@{phase=$Phase;watcherProcessId=$PID;browserProcessId=$(if($started){$proc.Id}else{$null});imageName=$image;interfaceAlias=$config.interfaceAlias;failure=$failure;restored=$restored;updated=(Get-Date).ToUniversalTime().ToString('o')}
    $path=Join-Path $SessionDirectory 'session.json';$tmp=$path+'.tmp'
    [IO.File]::WriteAllText($tmp,($record|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$path)}
}
try{
    Write-Session 'installing'
    if((Get-FileHash -LiteralPath $config.image).Hash -ne $config.imageSha256){throw 'Fixture changed before launch.'}
    & $manager -Action Install -ImageName $image -ProviderPath (Join-Path $bin 'CdfNetwork64.dll') -TransportPath (Join-Path $bin 'CdfProxyTransport64.dll') -ProxyProfilePath $config.profile -InterfaceAlias $config.interfaceAlias|Out-File (Join-Path $SessionDirectory 'install.json') -Encoding utf8
    $installed=$true
    $proc=[Diagnostics.Process]::new();$start=$proc.StartInfo;$start.FileName=$config.image;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.ArgumentList.Add((Join-Path $root 'tests\network_browser.cjs'));$start.Environment['CDF_BROWSER_SESSION']=$SessionDirectory
    foreach($name in @('ELECTRON_RUN_AS_NODE','NODE_OPTIONS')){[void]$start.Environment.Remove($name)}
    [void]$proc.Start();$started=$true;$outTask=$proc.StandardOutput.ReadToEndAsync();$errTask=$proc.StandardError.ReadToEndAsync();Write-Session 'running'
    $ready=$false;$clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not $proc.WaitForExit(1000)){
        if([IO.File]::Exists((Join-Path $SessionDirectory 'browser.json'))){$ready=$true}
        if(-not $ready -and $clock.Elapsed.TotalSeconds -gt 45){$proc.Kill($true);$proc.WaitForExit();throw 'Browser did not create its ready window.'}
        Write-Session 'running'
    }
    if($proc.ExitCode -ne 0){throw "Browser exited with code $($proc.ExitCode); inspect startup-error.txt and stderr.txt."}
}catch{$failure=$_.Exception.Message}
finally{
    if($started){[IO.File]::WriteAllText((Join-Path $SessionDirectory 'stdout.txt'),$outTask.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $SessionDirectory 'stderr.txt'),$errTask.GetAwaiter().GetResult())}
    if($installed){try{& $manager -Action Uninstall -ImageName $image|Out-File (Join-Path $SessionDirectory 'cleanup.json') -Encoding utf8;$restored=$true}catch{$failure=$_.Exception.Message}}
    Write-Session $(if($failure){'error'}else{'closed'})
    if($proc){$proc.Dispose()}
}
