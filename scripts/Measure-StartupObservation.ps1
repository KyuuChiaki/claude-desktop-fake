[CmdletBinding(DefaultParameterSetName='Sample')]
param([Parameter(ParameterSetName='Sample')][ValidateRange(1,3600)][int]$Seconds=15,
    [Parameter(Mandatory,ParameterSetName='Session')][switch]$FollowCurrentMonitor)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-AutoCore.ps1')
. (Join-Path $PSScriptRoot 'Startup-Observation.ps1')
$root=Cdf-AutoRoot
$state=Cdf-AutoReadJson (Join-Path $root 'state.json')
$packageRoot=$state.packageRoot
$latest=Join-Path $root 'refresh-result.json'
if([IO.File]::Exists($latest)){
    try{$r=Cdf-AutoReadJson $latest;if($r.success){$packageRoot=$r.result.packageRoot}}catch [IO.FileNotFoundException]{}
}
$context=[pscustomobject]@{EnumerationConfigPath=(Join-Path $state.release 'config\claude-targets.json')
    PackageName='AnthropicPBC.Claude';FolderOverrides=$state.folderOverrides}
$directories=Cdf-AutoDirectories $context ([pscustomobject]@{root=$packageRoot})
$manifest=Join-Path (Split-Path -Parent $root) 'claude\images.json'
$observer=$null;$owner=$null;$mutex=$null;$held=$false
try{
    $statusPath=$null;$watch=$null
    if($FollowCurrentMonitor){
        if(-not $state.enabled){throw 'The managed monitor is switched off.'}
        $healthPath=Join-Path $root 'health.json'
        $h=Cdf-AutoReadJson $healthPath
        if($h.state -notin @('starting','watching','refreshing','retrying')){throw 'The managed monitor is not running.'}
        if($h.PSObject.Properties['startupObservationStartedUtc']){throw 'This monitor already hosts startup observation.'}
        $owner=[Diagnostics.Process]::GetProcessById([int]$h.pid)
        if($owner.MainModule.FileName -ine $state.shell -or $owner.StartTime.ToUniversalTime() -gt ([datetime]$h.heartbeatUtc).ToUniversalTime()){
            throw 'The recorded monitor process has changed.'
        }
        $watch=[pscustomobject]@{pid=$owner.Id;startedUtc=$owner.StartTime.ToUniversalTime().ToString('o');release=[IO.Path]::GetFileName($state.release)}
        $mutex=[Threading.Mutex]::new($false,('Global\ClaudeDesktopFake.StartupObservation.'+$owner.Id))
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'A read-only observer is already attached to this monitor.'}
        $statusPath=Join-Path $root 'startup-observation-session.json'
    }
    $observer=Start-CdfStartupObservation -Directories $directories -Manifest $manifest -StatusPath $statusPath -WatchedMonitor $watch
    $startup=[Diagnostics.Stopwatch]::StartNew()
    do{
        $snapshot=Get-CdfStartupSnapshot $observer.shared
        if($snapshot.startError -or $snapshot.fileError){throw ($snapshot.startError+' '+$snapshot.fileError)}
        if(-not $snapshot.ready){Start-Sleep -Milliseconds 100}
    }while(-not $snapshot.ready -and $startup.Elapsed.TotalSeconds -lt 15)
    if(-not $snapshot.ready){throw 'The startup observer did not become ready.'}
    if($FollowCurrentMonitor){
        $lastRefresh=[datetime]::MinValue
        while(-not $owner.HasExited){
            $running=Cdf-AutoReadJson (Join-Path $root 'state.json')
            if(-not $running.enabled -or $running.release -ine $state.release){break}
            if($observer.shared.startError -or $observer.shared.fileError -or $observer.shared.writeError){
                throw ($observer.shared.startError+' '+$observer.shared.fileError+' '+$observer.shared.writeError)
            }
            $changed=[IO.File]::GetLastWriteTimeUtc($latest)
            if($changed -ne $lastRefresh -and [IO.File]::Exists($latest)){
                try{$r=Cdf-AutoReadJson $latest;if($r.success){$observer.shared.directories=@($r.result.directories)};$lastRefresh=$changed}
                catch [IO.FileNotFoundException]{}
            }
            Start-Sleep -Seconds 1
        }
    }else{
        Start-Sleep -Seconds $Seconds
        Get-CdfStartupSnapshot $observer.shared | ConvertTo-Json -Depth 7
    }
}finally{
    try{Stop-CdfStartupObservation $observer}finally{
        if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()};if($owner){$owner.Dispose()}
    }
}
