# Passive startup diagnostics. Workers share only an in-memory signature cache
# and immutable status snapshots. Neither worker publishes admission decisions.
Set-StrictMode -Version Latest

function Get-CdfObservationIoPath([string]$Path) {
    if($Path.Length -ge 248 -and -not $Path.StartsWith('\\?\')){return '\\?\'+$Path}
    return $Path
}
function Get-CdfObservationFile([string]$Path) {
    if($Path.Length -ge 248){return [CdfClaudeFile]::Observe($Path)}
    return [CdfClaudeFile]::Get($Path)
}

function Get-CdfObservationStamp($File) {
    $change=if($File.PSObject.Properties['ChangeTimeUtcTicks']){$File.ChangeTimeUtcTicks}
        else{(Get-FileHash -Algorithm SHA256 -LiteralPath (Get-CdfObservationIoPath $File.Path) -ErrorAction Stop).Hash}
    '{0}/{1}/{2}/{3}/{4}' -f $File.VolumeSerial,$File.FileId,$File.Size,$File.LastWriteTimeUtcTicks,$change
}

function Test-CdfObservationLocalPath([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:\\' -or [IO.DriveInfo]::new($Path.Substring(0,1)).DriveType -eq [IO.DriveType]::Network){return $false}
    $part=$Path
    while($part){
        if([IO.File]::GetAttributes((Get-CdfObservationIoPath $part)) -band [IO.FileAttributes]::ReparsePoint){return $false}
        $part=[IO.Path]::GetDirectoryName($part)
    }
    return $true
}

function Read-CdfObservedSignature($Shared,[string]$Path,[string]$Origin) {
    if(-not (Test-CdfObservationLocalPath $Path)){throw 'Image is outside the local physical filesystem.'}
    # Take the same read lease on cache hits as on cold checks. Metadata may
    # still carry the old modification time while a writer holds the file.
    $ioPath=Get-CdfObservationIoPath $Path
    $lease=[IO.File]::Open($ioPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
    try{
        $file=Get-CdfObservationFile $Path
        $stamp=Get-CdfObservationStamp $file
        $cached=$null
        if($Shared.cache.TryGetValue($Path,[ref]$cached) -and $cached.stamp -ceq $stamp -and $cached.expiresUtc -gt [datetime]::UtcNow){
            $source=if($cached.origin -eq 'file'){'preverified'}else{'startup-cache'}
            return [pscustomobject]@{file=$file;status='Valid';signer=$cached.signer;source=$source}
        }
        $signature=Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $ioPath -ErrorAction Stop
        # Atomic replacement is permitted during signing.
        if((Get-CdfObservationStamp (Get-CdfObservationFile $Path)) -cne $stamp){throw 'Image changed while its signature was being checked.'}
    }finally{$lease.Dispose()}
    $signer=if($signature.SignerCertificate){$signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)}else{''}
    if($signature.Status -eq 'Valid'){
        if($Shared.cache.Count -ge 512 -and -not $Shared.cache.ContainsKey($Path)){
            $discard=$null
            foreach($entry in @($Shared.cache.GetEnumerator()|Sort-Object {$_.Value.expiresUtc}|Select-Object -First 32)){
                [void]$Shared.cache.TryRemove($entry.Key,[ref]$discard)
            }
        }
        $Shared.cache[$Path]=[pscustomobject]@{stamp=$stamp;signer=$signer;origin=$Origin;expiresUtc=[datetime]::UtcNow.AddMinutes(2)}
    }
    [pscustomobject]@{file=$file;status=$signature.Status.ToString();signer=$signer;source=$Origin+'-verification'}
}

function Read-CdfObservationManifest([string]$Path) {
    $index=@{}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{
        if($stream.Length -gt 4MB){throw 'Image manifest is too large.'}
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        try{$manifest=ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop}finally{$reader.Dispose()}
    }finally{$stream.Dispose()}
    if($manifest.images -isnot [array]){throw 'Missing image list.'}
    foreach($image in $manifest.images){
        if(-not $image.nativePath -or $index.ContainsKey($image.nativePath)){throw 'Invalid or ambiguous image manifest.'}
        $index[$image.nativePath]=$image
    }
    return $index
}

function Get-CdfObservedRegistration($File,$Index,[long]$Created) {
    # The reported path can be replaced while a WMI event is in transit.
    # A later disk identity cannot establish what the process started with.
    if($File.LastWriteTimeUtcTicks -gt $Created -or
        ($File.PSObject.Properties['ChangeTimeUtcTicks'] -and $File.ChangeTimeUtcTicks -gt $Created)){return 'changed-since-start'}
    if($null -eq $Index){return 'manifest-unavailable'}
    $entry=$Index[$File.NativePath]
    if(-not $entry){return 'unlisted'}
    if($entry.volumeSerial -ieq $File.VolumeSerial -and $entry.fileId -ieq $File.FileId -and
        $entry.size -eq $File.Size -and $entry.lastWriteTimeUtcTicks -eq $File.LastWriteTimeUtcTicks){return 'registered'}
    return 'file-changed'
}

function Invoke-CdfStartEvents($Shared) {
    $eventName='CdfStartupObservation-'+[guid]::NewGuid().ToString('N')
    $query='SELECT * FROM Win32_ProcessStartTrace'
    if($Shared.parentFilter){$query+=' WHERE ParentProcessID = '+[uint32]$Shared.parentFilter}
    $null=Register-CimIndicationEvent -Namespace root/cimv2 -Query $query -SourceIdentifier $eventName -ErrorAction Stop
    $recent=[Collections.Generic.Queue[object]]::new()
    $received=0L;$exited=0L;$unavailable=0L;$reused=0L;$classified=0L;$overBudget=0L;$dropped=0L;$inconclusive=0L
    $nextPublish=[datetime]::MinValue
    try{
        $Shared.startReady=$true
        while(-not $Shared.stop){
            $events=@(Get-Event -SourceIdentifier $eventName -ErrorAction SilentlyContinue)
            if($events.Count -gt 1024){
                $extra=$events.Count-1024
                foreach($item in @($events|Select-Object -First $extra)){Remove-Event -EventIdentifier $item.EventIdentifier}
                $received+=$extra;$dropped+=$extra
                $events=@($events|Select-Object -Last 1024)
            }
            foreach($item in @($events|Select-Object -First 16)){
                if($Shared.stop){break}
                Remove-Event -EventIdentifier $item.EventIdentifier
                $received++
                $observed=[datetime]::UtcNow
                $eventData=$item.SourceEventArgs.NewEvent
                $id=[uint32]$eventData.ProcessID
                $at=[long]$eventData.TIME_CREATED
                $process=[CdfObservedProcess]::Read($id,$at)
                if($process.State -eq 'exited'){$exited++;continue}
                if($process.State -eq 'pid-reused'){$reused++;continue}
                if($process.State -ne 'available'){$unavailable++;continue}
                $scoped=Cdf-PathInEnumeration $process.Path $Shared.directories
                $source='unavailable';$signature='unavailable';$publisher=$null;$registration='unknown'
                try{
                    $verdict=Read-CdfObservedSignature $Shared $process.Path 'startup'
                    $source=$verdict.source;$signature=$verdict.status
                    $publisher=$signature -eq 'Valid' -and $verdict.signer -ieq 'Anthropic, PBC'
                    if(-not $scoped -and -not $publisher){continue}
                    try{$index=Read-CdfObservationManifest $Shared.manifest}catch{$index=$null}
                    $registration=Get-CdfObservedRegistration $verdict.file $index $process.Created
                }catch{
                    $unavailable++
                    if(-not $scoped){continue}
                }
                $done=[datetime]::UtcNow
                $created=[datetime]::FromFileTimeUtc($process.Created)
                $latency=[math]::Round(($done-$created).TotalMilliseconds,1)
                $known=$signature -in @('Valid','NotSigned','HashMismatch') -and $registration -in @('registered','unlisted','file-changed') -and $latency -ge 0
                if($known){$classified++;if($latency -gt 3000){$overBudget++}}else{$inconclusive++}
                if($recent.Count -eq 64){[void]$recent.Dequeue()}
                $recent.Enqueue([pscustomobject]@{pid=$id;image=[IO.Path]::GetFileName($process.Path);createdUtc=$created.ToString('o')
                    receivedUtc=$observed.ToString('o');observedUtc=$done.ToString('o');signature=$signature;anthropicSigner=$publisher
                    registration=$registration;source=$source;creationToReceiptMs=[math]::Round(($observed-$created).TotalMilliseconds,1)
                    creationToVerdictMs=$latency;withinThreeSeconds=($known -and $latency -ge 0 -and $latency -le 3000)})
            }
            if([datetime]::UtcNow -ge $nextPublish -or $events.Count){
                $Shared.starts=[pscustomobject]@{received=$received;exitedBeforeInspection=$exited;unavailable=$unavailable;reusedPid=$reused
                    dropped=$dropped;classified=$classified;inconclusive=$inconclusive;overThreeSeconds=$overBudget;recent=@($recent.ToArray());updatedUtc=[datetime]::UtcNow.ToString('o')}
                if([datetime]::UtcNow -ge $nextPublish){
                    if($Shared.statusPath){
                        try{Cdf-Save $Shared.statusPath (Get-CdfStartupSnapshot $Shared);$Shared.writeError=$null}
                        catch{$Shared.writeError=$_.Exception.Message}
                    }
                    $nextPublish=[datetime]::UtcNow.AddSeconds(1)
                }
            }
            if(-not $events.Count){[Threading.Thread]::Sleep(30)}
        }
    }finally{
        Unregister-Event -SourceIdentifier $eventName -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $eventName -ErrorAction SilentlyContinue|ForEach-Object {Remove-Event -EventIdentifier $_.EventIdentifier}
    }
}

function Invoke-CdfFilePreverification($Shared) {
    $hub=[CdfStartupFileEvents]::new()
    $dirs=[Collections.Generic.Queue[string]]::new()
    $queued=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $todo=[Collections.Generic.LinkedList[string]]::new()
    $files=@{}
    $retry=@{};$verified=0L;$errors=0L;$overflows=0L
    $nextRoots=[datetime]::MinValue;$nextPublish=[datetime]::MinValue
    function Queue-Directory([string]$Path){
        if($dirs.Count -ge 8192){return $false}
        if($queued.Add($Path)){$dirs.Enqueue($Path)}
        return $true
    }
    function Queue-File([string]$Path,[bool]$Priority=$false){
        if($files.ContainsKey($Path)){
            if($Priority){$node=$files[$Path];$todo.Remove($node);$todo.AddFirst($node)}
            return $true
        }
        if($todo.Count -ge 2048){return $false}
        $files[$Path]=if($Priority){$todo.AddFirst($Path)}else{$todo.AddLast($Path)}
        return $true
    }
    try{
        while(-not $Shared.stop){
            $now=[datetime]::UtcNow
            $repair=$hub.TakeRescan()
            if($now -ge $nextRoots -or $repair){
                $roots=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach($scope in $Shared.directories){
                    try{
                        $scopeIo=Get-CdfObservationIoPath $scope.path
                        if(-not [IO.Directory]::Exists($scopeIo) -or -not (Test-CdfObservationLocalPath $scope.path)){continue}
                        $pattern=Cdf-EnumerationFolderPattern $scope
                        if($pattern){
                            foreach($dir in [IO.Directory]::GetDirectories($scopeIo,$pattern)){
                                if($dir.StartsWith('\\?\')){$dir=$dir.Substring(4)}
                                if(Test-CdfObservationLocalPath $dir){[void]$roots.Add($dir)}
                            }
                        }else{[void]$roots.Add($scope.path)}
                    }catch{$errors++}
                }
                foreach($dir in $hub.Roots){if($repair -or -not $roots.Contains($dir)){$hub.RemoveRoot($dir)}}
                foreach($dir in $roots){
                    try{if($hub.AddRoot($dir) -or $repair){if(-not (Queue-Directory $dir)){$overflows++}}}catch{$errors++}
                }
                $nextRoots=$now.AddSeconds(1)
                $Shared.fileReady=$true
            }
            foreach($path in $hub.TakeDue(64)){
                if([IO.Path]::GetExtension($path) -ieq '.exe'){
                    if([IO.File]::Exists((Get-CdfObservationIoPath $path))){if(-not (Queue-File $path $true)){$overflows++}}
                    else{$discard=$null;[void]$Shared.cache.TryRemove($path,[ref]$discard);$retry.Remove($path)}
                }elseif([IO.Directory]::Exists((Get-CdfObservationIoPath $path))){if(-not (Queue-Directory $path)){$overflows++}}
            }
            foreach($path in @($retry.Keys)){
                if($retry[$path].due -le $now -and -not (Queue-File $path)){$overflows++}
            }
            # Interleave enumeration, signing and new file notices even for a
            # populated directory that was moved into scope in one operation.
            for($i=0;$i -lt 4 -and $dirs.Count;$i++){
                $dir=$dirs.Dequeue();[void]$queued.Remove($dir)
                try{
                    if(-not (Test-CdfObservationLocalPath $dir)){continue}
                    $listing=Cdf-ReadEnumerationDirectory $dir
                    foreach($entry in $listing.entries){
                        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
                        $full=$entry.FullName
                        if($full.StartsWith('\\?\')){$full=$full.Substring(4)}
                        if($entry.PSIsContainer){if(-not (Queue-Directory $full)){$overflows++}}
                        elseif($entry.Extension -ieq '.exe'){if(-not (Queue-File $full)){$overflows++}}
                    }
                }catch{$errors++}
            }
            if($todo.Count){
                $path=$todo.First.Value;$todo.RemoveFirst();[void]$files.Remove($path)
                try{
                    if(Cdf-PathInEnumeration $path $Shared.directories){
                        $check=Read-CdfObservedSignature $Shared $path 'file'
                        if($check.source -eq 'file-verification' -and $check.status -eq 'Valid'){$verified++}
                    }
                    $retry.Remove($path)
                }catch{
                    $errors++
                    $attempt=if($retry.ContainsKey($path)){1+$retry[$path].attempt}else{1}
                    if($attempt -le 7 -and $retry.Count -lt 512 -and [IO.File]::Exists((Get-CdfObservationIoPath $path))){
                        $retry[$path]=@{attempt=$attempt;due=$now.AddSeconds([math]::Min(30,[math]::Pow(2,$attempt-1)))}
                    }else{$retry.Remove($path)}
                }
            }
            if($now -ge $nextPublish){
                $Shared.files=[pscustomobject]@{watchRoots=$hub.Roots.Count;verified=$verified;errors=$errors
                    eventLoss=$hub.Losses;queueOverflow=$overflows;cachedImages=$Shared.cache.Count;updatedUtc=$now.ToString('o')}
                $nextPublish=$now.AddSeconds(1)
            }
            if(-not $dirs.Count -and -not $todo.Count){[Threading.Thread]::Sleep(40)}
        }
    }finally{$hub.Dispose()}
}

function Start-CdfStartupObservation([object[]]$Directories,[string]$Manifest,[uint32]$ParentFilter=0,[string]$StatusPath,$WatchedMonitor=$null) {
    . (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
    if(-not ('CdfStartupFileEvents' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'StartupFileEvents.cs') -ErrorAction Stop}
    $shared=[hashtable]::Synchronized(@{stop=$false;directories=$Directories;manifest=$Manifest;parentFilter=$ParentFilter
        ownerPid=$PID;ownerStartedUtc=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
        watchedMonitor=$WatchedMonitor;startedUtc=[datetime]::UtcNow.ToString('o');statusPath=$StatusPath;writeError=$null
        cache=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        startReady=$false;fileReady=$false;starts=$null;files=$null;startError=$null;fileError=$null})
    $jobs=[Collections.Generic.List[object]]::new()
    $worker={
        param($folder,$shared,$part)
        $ErrorActionPreference='Stop'
        try{
            . (Join-Path $folder 'Startup-Observation.ps1')
            . (Join-Path $folder 'Claude-Enumeration.ps1')
            if($part -eq 'start' -and $shared.statusPath){. (Join-Path $folder 'Claude-ManagerCore.ps1')}
            if($part -eq 'start'){Invoke-CdfStartEvents $shared}else{Invoke-CdfFilePreverification $shared}
        }catch{$shared[$part+'Error']=$_.Exception.Message}
        finally{$shared[$part+'Ready']=$false}
    }
    try{
        foreach($part in @('start','file')){
            $ps=[PowerShell]::Create()
            try{
                [void]$ps.AddScript($worker.ToString()).AddArgument($PSScriptRoot).AddArgument($shared).AddArgument($part)
                $jobs.Add([pscustomobject]@{shell=$ps;work=$ps.BeginInvoke()})
            }catch{$ps.Dispose();throw}
        }
    }catch{Stop-CdfStartupObservation ([pscustomobject]@{shared=$shared;jobs=$jobs});throw}
    [pscustomobject]@{shared=$shared;jobs=$jobs}
}
function Get-CdfStartupSnapshot($s) {
    [pscustomobject]@{schemaVersion=1;mode='observation';ownerPid=$s.ownerPid;ownerStartedUtc=$s.ownerStartedUtc;watchedMonitor=$s.watchedMonitor
        startedUtc=$s.startedUtc;updatedUtc=[datetime]::UtcNow.ToString('o')
        ready=($s.startReady -and $s.fileReady);startError=$s.startError;fileError=$s.fileError;statusWriteError=$s.writeError
        processStarts=$s.starts;preverification=$s.files}
}
function Stop-CdfStartupObservation($Observer) {
    if(-not $Observer){return}
    $Observer.shared.stop=$true
    foreach($job in $Observer.jobs){
        try{
            if(-not $job.work.AsyncWaitHandle.WaitOne(2000)){$job.shell.Stop()}
            try{$null=$job.shell.EndInvoke($job.work)}catch [Management.Automation.PipelineStoppedException]{}
        }finally{$job.shell.Dispose()}
    }
}
