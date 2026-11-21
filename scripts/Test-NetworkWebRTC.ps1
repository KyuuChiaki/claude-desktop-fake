[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$electron=Join-Path $root 'out\runtime-fixtures\electron-44.9.3\CdfElectronProbe64.exe'
if(-not [IO.File]::Exists($electron)){throw 'Prepare the Electron 44.9.3 test fixture first.'}
$directory=Join-Path $BuildDirectory ('test-results\webrtc-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$probe=[Diagnostics.Process]::new()
$probe.StartInfo.FileName=$electron
$probe.StartInfo.UseShellExecute=$false
$probe.StartInfo.CreateNoWindow=$true
$probe.StartInfo.RedirectStandardError=$true
$probe.StartInfo.RedirectStandardOutput=$true
$probe.StartInfo.ArgumentList.Add((Join-Path $root 'tests\network_webrtc.cjs'))
$probe.StartInfo.Environment['CDF_WEBRTC_TEST_DIRECTORY']=$directory
foreach($key in @('ELECTRON_RUN_AS_NODE','NODE_OPTIONS')){[void]$probe.StartInfo.Environment.Remove($key)}
try{
    [void]$probe.Start()
    $stdout=$probe.StandardOutput.ReadToEndAsync();$stderr=$probe.StandardError.ReadToEndAsync()
    $timedOut=-not $probe.WaitForExit(30000)
    if($timedOut){$probe.Kill($true);$probe.WaitForExit()}
    [IO.File]::WriteAllText((Join-Path $directory 'stdout.txt'),$stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $directory 'stderr.txt'),$stderr.GetAwaiter().GetResult())
    if($timedOut){throw "The isolated WebRTC fixture timed out. Logs are in $directory."}
    $reportPath=Join-Path $directory 'report.json'
    if(-not [IO.File]::Exists($reportPath)){throw "Missing WebRTC report at $directory"}
    $report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
    $report|Add-Member -NotePropertyName reportPath -NotePropertyValue $reportPath
    $report|ConvertTo-Json -Depth 8
    if($probe.ExitCode -ne 0 -or -not $report.passed){throw 'WebRTC session gate failed its isolated checks.'}
}finally{$probe.Dispose()}
