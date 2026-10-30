[CmdletBinding()]
param([Parameter(Mandatory)][string]$StateRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$statePath=Join-Path $StateRoot 'state.json';$healthPath=Join-Path $StateRoot 'health.json'
$singleton=[Threading.Mutex]::new($false,'Global\ClaudeDesktopFake.AutoRefresh.Worker');$owned=$false;$hub=$null;$refresh=$null
$eventId='CdfProcessStart-'+$PID;$subscription=$null;$health=$null
try{
    . (Join-Path $PSScriptRoot 'Claude-AutoCore.ps1')
    try{$owned=$singleton.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){return}
    $state=Cdf-AutoReadJson $statePath;Cdf-AutoVerifyRelease $state
    $context=Cdf-AutoContext $state.release $state;$directories=Cdf-AutoDirectories $context (Cdf-DiscoverPackage $context)
    $hub=Cdf-AutoWatchers $directories
    $generation=$hub.Generation;$dirty=$true;$dirtySince=[DateTime]::UtcNow;$nextFull=[DateTime]::UtcNow
    $nextSweep=[DateTime]::MinValue;$lastAttempt=[DateTime]::MinValue;$lastHash=$null;$signatureCache=@{};$images=@();$actions=[Collections.Generic.List[object]]::new()
    $queue=[Collections.Generic.HashSet[int]]::new();$resultPath=Join-Path $StateRoot 'refresh-result.json'
    $manifest=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude\images.json'
    $health=[ordered]@{schemaVersion=1;pid=$PID;state='starting';lastAttemptUtc=$null;lastSuccessUtc=$null;lastError=$null;images=0;events=0;heartbeatUtc=$null;actions=@();processTrace=$false;executionWindow='post-start monitoring; unknown image names are not intercepted before first instruction'}
    try{$subscription=Register-CimIndicationEvent -Namespace root/cimv2 -Query 'SELECT * FROM Win32_ProcessStartTrace' -SourceIdentifier $eventId;$health.processTrace=$true}catch{$health.lastError=$_.Exception.Message}
    while($true){
        $state=Cdf-AutoReadJson $statePath;if(-not $state.enabled){break}
        $now=[DateTime]::UtcNow
        if($hub.Generation -ne $generation){$generation=$hub.Generation;if(-not $dirty){$dirtySince=$now};$dirty=$true;$signatureCache.Clear()}
        foreach($event in @(Get-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue)){
            if($queue.Count -lt 1024){[void]$queue.Add([int]$event.SourceEventArgs.NewEvent.ProcessID)}else{$nextSweep=[DateTime]::MinValue}
            Remove-Event -EventIdentifier $event.EventIdentifier
        }
        if($now -ge $nextSweep){
            foreach($item in @(Get-CimInstance Win32_Process -Property ProcessId)){[void]$queue.Add([int]$item.ProcessId)}
            $nextSweep=$now.AddSeconds(15)
        }
        try{$images=@((Cdf-AutoReadJson $manifest).images)}catch{$health.lastError=$_.Exception.Message}
        foreach($id in @($queue|Select-Object -First 16)){
            [void]$queue.Remove($id)
            $inspection=Cdf-AutoInspectProcess -ProcessId $id -Images $images -SignatureCache $signatureCache -DiagnosticDll $context.SourceDll
            if($inspection.action -eq 'initializing'){[void]$queue.Add($id);continue}
            if($inspection.action -in @('terminated','termination-failed')){
                $actions.Add($inspection);while($actions.Count -gt 20){$actions.RemoveAt(0)}
                try{Cdf-AutoRememberImage $StateRoot $inspection.path}catch{$health.lastError=$_.Exception.Message}
                if(-not $dirty){$dirtySince=$now};$dirty=$true
            }
        }
        if($refresh -and $refresh.HasExited){
            $refresh.Dispose();$refresh=$null
            if(Test-Path -LiteralPath $resultPath){
                $result=Cdf-AutoReadJson $resultPath
                if($result.success){
                    $health.lastSuccessUtc=$result.finishedAtUtc;$health.lastError=$null;$health.images=$result.result.images
                    $changed=$lastHash -cne $result.result.manifestHash;$lastHash=$result.result.manifestHash
                    $previous=$hub;$hub=Cdf-AutoWatchers $result.result.directories;$previous.Dispose();$generation=$hub.Generation
                    if($changed){$dirty=$true;$dirtySince=$now}
                    $nextFull=$now.AddSeconds(300)
                }else{$health.lastError=$result.error;$nextFull=$now.AddSeconds(10)}
            }else{$health.lastError='Refresh helper exited without a result.';$nextFull=$now.AddSeconds(10)}
        }
        $quiet=$hub.ChangedTicks -eq 0 -or ($now.Ticks-$hub.ChangedTicks) -ge 10000000L
        if(-not $refresh -and (($dirty -and ($quiet -or ($now-$dirtySince).TotalSeconds -ge 5) -and ($now-$lastAttempt).TotalSeconds -ge 3) -or $now -ge $nextFull)){
            if(Test-Path -LiteralPath $resultPath){[IO.File]::Delete($resultPath)}
            $lastAttempt=$now;$health.lastAttemptUtc=$now.ToString('o');$dirty=$false
            $refresh=[Diagnostics.Process]::new();$refresh.StartInfo.FileName=$state.shell;$refresh.StartInfo.UseShellExecute=$false;$refresh.StartInfo.CreateNoWindow=$true
            $worker=Join-Path $PSScriptRoot 'Refresh-Claude.ps1'
            $refresh.StartInfo.Arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$worker+'" -StateRoot "'+$StateRoot+'" -ResultPath "'+$resultPath+'"'
            [void]$refresh.Start()
        }
        if($hub.LastError){$health.lastError='Watcher event loss: '+$hub.LastError;$dirty=$true}
        $health.state=if($refresh){'refreshing'}elseif($health.lastError){'retrying'}else{'watching'}
        $health.actions=$actions.ToArray();$health.events=$hub.Generation;$health.heartbeatUtc=[DateTime]::UtcNow.ToString('o');Cdf-Save $healthPath $health
        [void]$hub.Wait(500)
    }
    $health.state='stopped';$health.heartbeatUtc=[DateTime]::UtcNow.ToString('o');Cdf-Save $healthPath $health
}catch{
    $failure=$_.Exception.Message
    try{
        if(-not $health){$health=[ordered]@{schemaVersion=1;pid=$PID;state='failed';lastError=$failure;heartbeatUtc=[DateTime]::UtcNow.ToString('o')}}
        else{$health.state='failed';$health.lastError=$failure;$health.heartbeatUtc=[DateTime]::UtcNow.ToString('o')}
        [IO.File]::WriteAllText($healthPath,($health|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }catch{}
    throw
}finally{
    if($subscription){Unregister-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue}
    if($hub){$hub.Dispose()};if($refresh){$refresh.Dispose()};if($owned){$singleton.ReleaseMutex()};$singleton.Dispose()
}
