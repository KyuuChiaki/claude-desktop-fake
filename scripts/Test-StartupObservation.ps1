[CmdletBinding()]
param([ValidateRange(8,256)][int]$Samples=24,[switch]$RequireThreeSeconds,[switch]$AllStartEvents,[string]$OutputPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Startup-Observation.ps1')
. (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Text){if(-not $Ok){throw $Text};$checks.Add($Text)}
function Wait-For([scriptblock]$Condition,[string]$Description,[int]$Seconds=12){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do{
        if(& $Condition){return}
        if($observer.shared.startError -or $observer.shared.fileError){throw ($observer.shared.startError+' '+$observer.shared.fileError)}
        Start-Sleep -Milliseconds 50
    }while($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw "Timed out waiting for $Description."
}
function New-Fixture([string]$Path){
    $info=[Diagnostics.ProcessStartInfo]::new($Path,'/d /q')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($info)
    $children.Add($p)
    return $p
}
function Close-Fixtures{
    foreach($p in $children){
        try{
            if(-not $p.HasExited){$p.StandardInput.WriteLine('exit');$p.StandardInput.Close()}
            if(-not $p.WaitForExit(3000)){throw 'The offline fixture did not exit.'}
        }finally{$p.Dispose()}
    }
    $children.Clear()
}
function Find-Sample($Process){
    if(-not $observer.shared.starts){return $null}
    $created=$Process.StartTime.ToUniversalTime()
    foreach($row in $observer.shared.starts.recent){
        if($row.pid -eq $Process.Id -and [datetime]::Parse($row.createdUtc).ToUniversalTime() -eq $created){return $row}
    }
    return $null
}
function Peek-Cache([string]$Path){
    $entry=$null
    if($observer.shared.cache.TryGetValue($Path,[ref]$entry)){return $entry}
    return $null
}
function Save-Manifest($Images){[IO.File]::WriteAllText($manifest,(@{images=@($Images)}|ConvertTo-Json -Depth 5),$utf8)}
function Metrics($Items,[string]$Key){
    $numbers=@($Items|ForEach-Object {$_.$Key}|Sort-Object)
    [pscustomobject]@{p50=$numbers[[int][math]::Ceiling($numbers.Count*0.50)-1];p95=$numbers[[int][math]::Ceiling($numbers.Count*0.95)-1]
        p99=$numbers[[int][math]::Ceiling($numbers.Count*0.99)-1];max=$numbers[-1]}
}
$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot=Join-Path $base ('CdfStartupObservation-'+[guid]::NewGuid().ToString('N'))
$watched=Join-Path $fixtureRoot 'watched'
$other=Join-Path $fixtureRoot 'other'
$newDirectory=Join-Path $fixtureRoot 'watch-new-version'
$manifest=Join-Path $fixtureRoot 'images.json'
$published=Join-Path $fixtureRoot 'observation.json'
$utf8=[Text.UTF8Encoding]::new($false)
$files=[Collections.Generic.List[string]]::new()
$nested=[Collections.Generic.List[string]]::new()
$children=[Collections.Generic.List[Diagnostics.Process]]::new()
$observer=$null
$observations=[Collections.Generic.List[object]]::new()
$cmdExe=Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
$paths=@()
try{
    [void][IO.Directory]::CreateDirectory($watched)
    [void][IO.Directory]::CreateDirectory($other)
    Save-Manifest @()
    $scope=@([pscustomobject]@{path=$fixtureRoot;folderNamePattern='watch*'})
    $traceParent=if($AllStartEvents){0}else{$PID}
    $observer=Start-CdfStartupObservation -Directories $scope -Manifest $manifest -ParentFilter $traceParent -StatusPath $published
    Wait-For {$observer.shared.fileReady -and $observer.shared.startReady -and [IO.File]::Exists($published)} 'both independent workers'
    for($i=0;$i -lt $Samples;$i++){
        $path=Join-Path $watched ('CdfObs{0:D3}.exe' -f $i)
        $stage=$path+'.part'
        $files.Add($stage);$files.Add($path)
        [IO.File]::Copy($cmdExe,$stage);[IO.File]::Move($stage,$path)
        $paths+=$path
    }
    $excluded=Join-Path $other 'CdfOutside.exe';$files.Add($excluded);[IO.File]::Copy($cmdExe,$excluded)
    Wait-For {@($paths|Where-Object {-not (Peek-Cache $_)}).Count -eq 0} 'preverification after atomic rename' 45
    Check (-not (Peek-Cache $excluded)) 'Directory wildcard excludes unrelated siblings from preverification'
    [void][IO.Directory]::CreateDirectory($newDirectory)
    $busyFile=Join-Path $newDirectory 'CdfWriting.exe';$files.Add($busyFile)
    $writer=[IO.File]::Open($busyFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try{
        $source=[IO.File]::OpenRead($cmdExe)
        try{$source.CopyTo($writer);$writer.Flush()}finally{$source.Dispose()}
        Wait-For {$observer.shared.files -and $observer.shared.files.watchRoots -ge 2} 'discovery of a new matching directory'
        Check (-not (Peek-Cache $busyFile)) 'An executable still held by the updater cannot be preverified'
    }finally{$writer.Dispose()}
    Wait-For {Peek-Cache $busyFile} 'preverification after the writer exits' 15
    Check ((Peek-Cache $busyFile).origin -eq 'file') 'New version directories and delayed writer completion feed the file worker'
    $deep=$newDirectory
    while($deep.Length -lt 270){$deep=[IO.Path]::Combine($deep,('nested-'+('z'*24)));$nested.Add($deep)}
    [void][IO.Directory]::CreateDirectory((Get-CdfObservationIoPath $deep))
    $longFile=[IO.Path]::Combine($deep,'CdfLong.exe');$files.Add($longFile)
    [IO.File]::Copy($cmdExe,(Get-CdfObservationIoPath $longFile))
    Wait-For {Peek-Cache $longFile} 'preverification of an executable beyond MAX_PATH'
    $longResult=Read-CdfObservedSignature $observer.shared $longFile 'startup'
    Check ($longResult.source -eq 'preverified' -and $longResult.status -eq 'Valid') 'A long physical path has a usable cached signature and a verified file identity'
    Check ((Get-CdfObservedRegistration $longResult.file @{} ($longResult.file.ChangeTimeUtcTicks-1)) -eq 'changed-since-start') 'A disk identity newer than the process cannot be attributed to the started image'
    $expected=Get-CdfImageIdentity $paths[0]
    Save-Manifest @($expected)
    # Keep the controlling thread busy while the workers operate. All fixture
    # processes are harmless command interpreters with an open, private stdin.
    for($i=0;$i -lt $Samples;$i+=4){
        for($j=$i;$j -lt [math]::Min($i+4,$Samples);$j++){[void](New-Fixture $paths[$j])}
        if($i -eq 0){[Threading.Thread]::Sleep(3200)}
        Wait-For {@($children|Where-Object {-not (Find-Sample $_)}).Count -eq 0} 'start observations'
        foreach($proc in $children){$observations.Add((Find-Sample $proc))}
        Close-Fixtures
    }
    $known=@($observations|Where-Object registration -eq 'registered')
    Check ($known.Count -eq 1 -and $known[0].image -eq [IO.Path]::GetFileName($paths[0])) 'Matches the exact registered image in the fixture manifest'
    Check (@($observations|Where-Object registration -eq 'unlisted').Count -eq $Samples-1) 'Recognizes new filenames independently of a slow controller'
    Check (@($observations|Where-Object {$_.signature -ne 'Valid' -or $_.source -ne 'preverified'}).Count -eq 0) 'Launches reuse genuine valid signatures preverified before first execution'
    Check (@($observations|Where-Object anthropicSigner).Count -eq 0) 'Microsoft-signed fixtures do not match the Anthropic publisher'
    Check (@($observations|Where-Object {$_.creationToReceiptMs -lt 0 -or $_.creationToVerdictMs -lt $_.creationToReceiptMs}).Count -eq 0) 'Receipt and completed-verdict timings are ordered'
    $removed=$null
    Check ($observer.shared.cache.TryRemove($paths[3],[ref]$removed)) 'Cold-verification fixture has no cached verdict'
    $started=New-Fixture $paths[3]
    Wait-For {Find-Sample $started} 'on-demand signing'
    $cold=Find-Sample $started
    Check ($cold.source -eq 'startup-verification' -and $cold.signature -eq 'Valid' -and $cold.registration -eq 'unlisted') 'Cold startup actually verifies the present file'
    Close-Fixtures
    $started=New-Fixture $paths[3]
    Wait-For {Find-Sample $started} 'subsequent startup cache hit'
    Check ((Find-Sample $started).source -eq 'startup-cache') 'A subsequent launch uses the verified startup entry'
    Close-Fixtures
    $replace=Join-Path $watched 'replacement.part';$files.Add($replace)
    [IO.File]::Copy($cmdExe,$replace);[IO.File]::SetLastWriteTimeUtc($replace,[IO.File]::GetLastWriteTimeUtc($paths[0]))
    [IO.File]::Replace($replace,$paths[0],[Management.Automation.Language.NullString]::Value)
    $newId=Get-CdfImageIdentity $paths[0]
    Check ($newId.fileId -ne $expected.fileId -and $newId.size -eq $expected.size) 'Replacement fixture has a new File ID and identical content length'
    $started=New-Fixture $paths[0]
    Wait-For {Find-Sample $started} 'identity replacement verdict'
    Check ((Find-Sample $started).registration -eq 'file-changed') 'Old registration does not match an atomic replacement'
    Close-Fixtures
    [IO.File]::WriteAllText($manifest,'{invalid',$utf8)
    $started=New-Fixture $paths[1]
    Wait-For {Find-Sample $started} 'unavailable manifest verdict'
    $bad=Find-Sample $started
    Check ($bad.registration -eq 'manifest-unavailable' -and -not $bad.withinThreeSeconds) 'Bad manifest is inconclusive rather than a successful timed decision'
    Close-Fixtures
    $f=$paths[2];$mtime=[IO.File]::GetLastWriteTimeUtc($f)
    $cached=Peek-Cache $f
    $stream=[IO.File]::Open($f,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try{
        $rejected=$false
        try{$null=Read-CdfObservedSignature $observer.shared $f 'startup'}catch [IO.IOException]{$rejected=$true}
        Check $rejected 'An open writer prevents reuse even before file timestamps change'
        $stream.WriteByte(0)
    }finally{$stream.Dispose()}
    [IO.File]::SetLastWriteTimeUtc($f,$mtime)
    $recheck=Read-CdfObservedSignature $observer.shared $f 'startup'
    Check ($cached.stamp -cne (Get-CdfObservationStamp $recheck.file) -and $recheck.status -ne 'Valid' -and $recheck.source -eq 'startup-verification') 'Same-length in-place change with restored modification time invalidates the signature cache'
    $me=[CdfObservedProcess]::Read([uint32]$PID,1L)
    Check ($me.State -eq 'pid-reused' -and -not $me.Path) 'Process ID younger than its notification is inconclusive'
    $fast=[Diagnostics.ProcessStartInfo]::new($paths[1],'/d /c exit 0')
    $fast.UseShellExecute=$false;$fast.CreateNoWindow=$true
    $short=[Diagnostics.Process]::Start($fast)
    try{
        if(-not $short.WaitForExit(3000)){throw 'Short fixture did not exit normally.'}
        $departed=[CdfObservedProcess]::Read([uint32]$short.Id,[datetime]::UtcNow.ToFileTimeUtc())
        Check ($departed.State -eq 'exited' -and -not $departed.Path) 'An already-exited process has no reliable image verdict'
    }finally{$short.Dispose()}
    Wait-For {$status=Get-Content -Raw -LiteralPath $published|ConvertFrom-Json
        $status.ready -and $status.ownerPid -eq $PID -and $status.processStarts.classified -ge $Samples} 'independently published status'
    Check ($true) 'Status file is published independently of the controller'
    $completed=@($observations|Where-Object withinThreeSeconds).Count
    $pass= -not $RequireThreeSeconds -or $completed -eq $Samples
    $result=[pscustomobject]@{passed=$pass;observedUtc=[datetime]::UtcNow.ToString('o');shell=$PSVersionTable.PSVersion.ToString();checks=$checks.ToArray()
        measured=$Samples;withinThreeSeconds=$completed;overThreeSeconds=$Samples-$completed;creationToReceiptMs=(Metrics $observations 'creationToReceiptMs')
        creationToVerdictMs=(Metrics $observations 'creationToVerdictMs');scope='held-open offline Microsoft-signed cmd.exe copies; identity observation'
        subscription=$(if($AllStartEvents){'all-process-starts'}else{'fixture-parent'});coldVerdictMs=$cold.creationToVerdictMs;results=$observations.ToArray()}
    $json=$result|ConvertTo-Json -Depth 6
    if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,$utf8)}
    if(-not $pass){throw ("Completed "+$completed+" of "+$Samples+" observations within three seconds.")}
    $json
}finally{
    try{Close-Fixtures}finally{
        if($observer){Stop-CdfStartupObservation $observer}
        foreach($file in $files){[IO.File]::Delete((Get-CdfObservationIoPath $file))}
        for($i=$nested.Count-1;$i -ge 0;$i--){
            $ioPath=Get-CdfObservationIoPath $nested[$i]
            if([IO.Directory]::Exists($ioPath)){[IO.Directory]::Delete($ioPath,$false)}
        }
        foreach($file in @($manifest,$published)){[IO.File]::Delete($file)}
        foreach($dir in @($watched,$other,$newDirectory,$fixtureRoot)){if([IO.Directory]::Exists($dir)){[IO.Directory]::Delete($dir,$false)}}
    }
}
