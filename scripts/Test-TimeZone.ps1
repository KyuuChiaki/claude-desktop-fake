[CmdletBinding()]
param(
    [string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),
    [ValidateRange(1,100)][int]$Iterations = 10
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$manager = Join-Path $PSScriptRoot 'Manage-TimeZone.ps1'
$binaryDirectory = Join-Path $BuildDirectory 'bin'
$dll = Join-Path $binaryDirectory 'CdfTimeZone64.dll'
$probe = Join-Path $binaryDirectory 'CdfTimeProbe64.exe'
$late = Join-Path $binaryDirectory 'CdfTimeLate64.dll'
$images = @('CdfTimeProbe64.exe','CdfTimeProbeOther64.exe')
$runtime = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2'
$config = Join-Path $runtime 'timezone.json'
$deployment = Join-Path $runtime 'deployment.json'
$reports = Join-Path $BuildDirectory 'test-results'
$null = New-Item -ItemType Directory -Path $reports -Force
$run = Join-Path $reports ('time-run-'+[Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $run
$other = Join-Path $run $images[1]
$owned = [Collections.Generic.List[string]]::new()
$cases = [Collections.Generic.List[object]]::new()
$cleanup = [Collections.Generic.List[string]]::new()
$snapshots = @{}
$baselineContracts = $null
$baselineClass93Contracts = $null
$failure = $null
$originalConfig = if (Test-Path -LiteralPath $config) { [IO.File]::ReadAllBytes($config) } else { $null }
$expectedConfigHash = if ($null -ne $originalConfig) { (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash } else { $null }
$expectedDeploymentHash = if (Test-Path -LiteralPath $deployment) { (Get-FileHash -LiteralPath $deployment -Algorithm SHA256).Hash } else { $null }
$usedDeployment = $false
if ($null -ne $originalConfig) { [IO.File]::WriteAllBytes((Join-Path $run 'original-timezone.json'), $originalConfig) }
if (Test-Path -LiteralPath $deployment) { Copy-Item -LiteralPath $deployment -Destination (Join-Path $run 'original-deployment.json') }
$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
$ifeo = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',$false)

function Snapshot([string]$Image) {
    $key = $ifeo.OpenSubKey($Image,$false)
    try {
        if ($null -eq $key) { return 'null' }
        $values = @($key.GetValueNames() | Sort-Object | ForEach-Object {
            [pscustomobject]@{name=$_;kind=$key.GetValueKind($_).ToString();data=$key.GetValue($_,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
        })
        return ConvertTo-Json -InputObject ([pscustomobject]@{values=$values;children=@($key.GetSubKeyNames() | Sort-Object)}) -Depth 12 -Compress
    } finally { if ($null -ne $key) { $key.Dispose() } }
}
function Remember-Deployment {
    $script:usedDeployment = $true
    $script:expectedConfigHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $script:expectedDeploymentHash = (Get-FileHash -LiteralPath $deployment -Algorithm SHA256).Hash
}
function Manager([string]$Action,[string]$Image,[string]$SourceConfig = '') {
    if ($Action -eq 'Install') {
        $result = & $manager -Action Install -ImageName $Image -DllPath $dll -ConfigPath $SourceConfig | ConvertFrom-Json
        Remember-Deployment
        return $result
    }
    return (& $manager -Action $Action -ImageName $Image | ConvertFrom-Json)
}
function New-Config([string]$Zone,[long]$Offset,[bool]$Enabled = $true) {
    $path = Join-Path $run ([Guid]::NewGuid().ToString('N')+'.json')
    $value = [ordered]@{schemaVersion=1;enabled=$Enabled;timeZoneId=$Zone;utcOffsetSeconds=$Offset}
    [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $value),[Text.UTF8Encoding]::new($false))
    return $path
}
function Set-RawConfig([byte[]]$Bytes) {
    if ($null -eq $script:expectedConfigHash) {
        if (Test-Path -LiteralPath $config) { throw 'Unexpected configuration appeared during testing.' }
    } elseif (-not (Test-Path -LiteralPath $config) -or (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -cne $script:expectedConfigHash) {
        throw 'External configuration change detected; refusing to overwrite it.'
    }
    $temporary = $config+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        if ([IO.File]::Exists($config)) { [IO.File]::Replace($temporary,$config,[Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$config) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    $script:expectedConfigHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
}
function New-Probe([string]$Path,[string]$Expectation,[string]$Zone,[long]$Offset,[switch]$WaitInput) {
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $Path
    $process.StartInfo.Arguments = '--expect '+$Expectation+' --offset '+$Offset+' --late "'+$late+'"'
    if ($Zone) { $process.StartInfo.Arguments += ' --zone "'+$Zone+'"' }
    if ($WaitInput) { $process.StartInfo.Arguments += ' --wait-for-input'; $process.StartInfo.RedirectStandardInput = $true }
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.EnvironmentVariables.Remove('TZ')
    return $process
}
function Assert-Observation($Observation,[string]$Expectation,[long]$Offset,[long]$Start,[long]$End,[long]$TickStart,[long]$TickEnd) {
    if (-not $Observation.matched) { throw "Probe mismatch: $($Observation.failures -join '; ')" }
    $actualOffset = if ($Expectation -eq 'active') { $Offset*10000000L } else { 0L }
    foreach ($stage in @('early','tls','main','late')) {
        foreach ($value in $Observation.$stage.utcTicks) {
            if ([long]$value -lt $Start+$actualOffset-1000000L -or [long]$value -gt $End+$actualOffset+1000000L) {
                throw "UTC differs from unregistered controller: $stage, value=$value, expected=[$($Start+$actualOffset),$($End+$actualOffset)]"
            }
        }
        $current = [long]$Observation.$stage.timeOfDay.current
        if ($current -lt $Start+$actualOffset-1000000L -or $current -gt $End+$actualOffset+1000000L) { throw 'Native time-of-day clock offset mismatch.' }
        $uptime = ($current-[long]$Observation.$stage.timeOfDay.boot)/10000L
        if ($uptime -lt $TickStart-2000L -or $uptime -gt $TickEnd+2000L) { throw 'Native boot/current difference disagrees with unchanged uptime.' }
    }
    if ([long]$Observation.timers.tickCount64 -lt $TickStart-100L -or [long]$Observation.timers.tickCount64 -gt $TickEnd+100L) { throw 'GetTickCount64 absolute value changed.' }
    $contracts = ConvertTo-Json -InputObject $Observation.queryContracts -Depth 8 -Compress
    if ($null -eq $script:baselineContracts) { $script:baselineContracts = $contracts }
    elseif ($script:baselineContracts -cne $contracts) { throw 'Native query status, length or buffer boundary differs from the unregistered baseline.' }
    $class93 = ConvertTo-Json -InputObject $Observation.class93Contracts -Depth 8 -Compress
    if (@($Observation.class93Contracts).Count -ne 84) { throw 'Class 93 contract matrix is incomplete.' }
    if ($null -eq $script:baselineClass93Contracts) { $script:baselineClass93Contracts = $class93 }
    elseif ($script:baselineClass93Contracts -cne $class93) { throw 'Class 93 query status, probing, output, ReturnLength or LastError differs from the unregistered baseline.' }
}
function Invoke-Probe([string]$Path,[string]$Expectation,[string]$Label,[string]$Zone = '',[long]$Offset = 0,[int]$TimeoutMs = 15000,[switch]$WaitInput) {
    $process = New-Probe $Path $Expectation $Zone $Offset -WaitInput:$WaitInput
    $record = [ordered]@{label=$Label;expectation=$Expectation;timeZoneId=$Zone;utcOffsetSeconds=$Offset;passed=$false;expectedFailure=$false;timedOut=$false;exitCode=$null;stdout='';stderr='';error=$null;reference=$null;observation=$null}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $start = [DateTime]::UtcNow.ToFileTimeUtc(); $tickStart = [Environment]::TickCount64
        if (-not $process.Start()) { throw 'Probe creation returned false.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMs); $record.timedOut=$timedOut
        if ($timedOut) { $process.Kill(); $process.WaitForExit() }
        $end = [DateTime]::UtcNow.ToFileTimeUtc(); $tickEnd = [Environment]::TickCount64
        $record.reference=[pscustomobject]@{utcStartTicks=$start;utcEndTicks=$end;tickStartMs=$tickStart;tickEndMs=$tickEnd}
        $record.exitCode = $process.ExitCode; $record.stdout = $stdout.GetAwaiter().GetResult().Trim(); $record.stderr = $stderr.GetAwaiter().GetResult().Trim()
        if ($timedOut) { throw "Probe timed out after $TimeoutMs milliseconds." }
        if ($record.stdout) { $record.observation = $record.stdout | ConvertFrom-Json }
        if ($record.exitCode -ne 0 -or $null -eq $record.observation) { throw "Probe exited with $($record.exitCode): $($record.stdout) $($record.stderr)" }
        Assert-Observation $record.observation $Expectation $Offset $start $end $tickStart $tickEnd
        $record.passed = $true; $record.stdout = ''
        return $record.observation
    } catch { $record.error=$_.Exception.Message; throw }
    finally { $record.durationMs=$watch.ElapsedMilliseconds; $cases.Add([pscustomobject]$record); $process.Dispose() }
}
function Invoke-SnapshotTest([string]$NewConfig) {
    $process = New-Probe $probe active 'Pacific Standard Time' 0 -WaitInput
    $record = [ordered]@{label='existing process retains startup snapshot';passed=$false;exitCode=$null;stdout='';stderr='';error=$null;reference=$null;observation=$null}
    $started = $false; $stdout = $null; $stderr = $null; $lineTask = $null
    try {
        $start = [DateTime]::UtcNow.ToFileTimeUtc(); $tickStart = [Environment]::TickCount64
        $started = $process.Start()
        if (-not $started) { throw 'Snapshot probe creation returned false.' }
        $stderr = $process.StandardError.ReadToEndAsync()
        $lineTask = $process.StandardOutput.ReadLineAsync()
        if (-not $lineTask.Wait(5000)) { throw 'Snapshot probe did not become ready.' }
        $ready = $lineTask.GetAwaiter().GetResult() | ConvertFrom-Json
        $stdout = $process.StandardOutput.ReadToEndAsync()
        if (-not $ready.ready) { throw 'Snapshot readiness mismatch.' }
        Set-RawConfig ([IO.File]::ReadAllBytes($NewConfig))
        $null = Invoke-Probe $other active 'new process reads modified JSON' 'Eastern Standard Time' 3600
        $process.StandardInput.WriteLine('continue'); $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) { throw 'Snapshot probe timed out.' }
        $record.exitCode=$process.ExitCode; $record.observation=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        if ($process.ExitCode -ne 0) { throw "Snapshot probe failed: $($record.observation.failures -join '; ') $($stderr.GetAwaiter().GetResult())" }
        $end=[DateTime]::UtcNow.ToFileTimeUtc(); $tickEnd=[Environment]::TickCount64
        $record.reference=[pscustomobject]@{utcStartTicks=$start;utcEndTicks=$end;tickStartMs=$tickStart;tickEndMs=$tickEnd}
        Assert-Observation $record.observation active 0 $start $end $tickStart $tickEnd
        $record.passed=$true
    } catch { $record.error=$_.Exception.Message; throw }
    finally {
        if ($started) {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $record.exitCode = $process.ExitCode
            if ($null -ne $stdout) { $record.stdout = $stdout.GetAwaiter().GetResult().Trim() }
            elseif ($null -ne $lineTask) {
                $record.stdout = $lineTask.GetAwaiter().GetResult()+$process.StandardOutput.ReadToEnd()
            }
            if ($null -ne $stderr) { $record.stderr = $stderr.GetAwaiter().GetResult().Trim() }
            if ($record.passed) { $record.stdout = '' }
        }
        $process.Dispose(); $cases.Add([pscustomobject]$record)
    }
}

try {
    foreach ($image in $images) {
        $snapshots[$image]=Snapshot $image
        if ($snapshots[$image] -ne 'null' -or (Manager Status $image).managed) { throw "Test image already configured: $image" }
    }
    Copy-Item -LiteralPath $probe -Destination $other
    Copy-Item -LiteralPath (Join-Path $binaryDirectory 'CdfTimeEarly64.dll') -Destination $run
    $executables=@($probe,$other)
    foreach ($path in $executables) { $null=Invoke-Probe $path absent 'unregistered baseline' }
    $matrix=@(
        @{zone='Pacific Standard Time';offset=0L;count=$Iterations},
        @{zone='Eastern Standard Time';offset=0L;count=$Iterations},
        @{zone='Pacific Standard Time';offset=3600L;count=1},
        @{zone='Eastern Standard Time';offset=-3600L;count=1},
        @{zone='UTC';offset=3600L;count=1},
        @{zone='India Standard Time';offset=90000L;count=1},
        @{zone='Eastern Standard Time';offset=-90000L;count=1}
    )
    foreach ($scenario in $matrix) {
        $source=New-Config $scenario.zone $scenario.offset
        foreach ($image in $images) {
            $owned.Add($image); $installed=Manager Install $image $source
            if (-not $installed.managed -or -not $installed.matchesInstalled) { throw 'Installation mismatch.' }
            $hash=(Get-FileHash -LiteralPath $installed.recoveryRecord -Algorithm SHA256).Hash
            $again=Manager Install $image $source
            if ((Get-FileHash -LiteralPath $again.recoveryRecord -Algorithm SHA256).Hash -cne $hash) { throw 'Idempotent install replaced the original recovery record.' }
        }
        for ($i=0;$i -lt $images.Count;++$i) {
            for ($n=1;$n -le $scenario.count;++$n) {
                $null=Invoke-Probe $executables[$i] active "$($images[$i])/$($scenario.zone)/$($scenario.offset)/$n" $scenario.zone $scenario.offset
            }
        }
        if ($scenario.zone -eq 'Pacific Standard Time' -and $scenario.offset -eq 0) {
            $saved=[IO.File]::ReadAllBytes($config)
            try { Invoke-SnapshotTest (New-Config 'Eastern Standard Time' 3600) }
            finally { Set-RawConfig $saved }
        }
        foreach ($image in $images) { $null=Manager Uninstall $image; $null=$owned.Remove($image) }
    }
    # Runtime failures are produced only after a valid, owned installation.
    $validSource=New-Config 'Pacific Standard Time' 0
    $owned.Add($images[0]); $null=Manager Install $images[0] $validSource
    # Exercise diagnostics while registration is live; the same final cleanup
    # path must still remove this image's IFEO settings after these failures.
    $caught=$false
    try { $null=Invoke-Probe $probe active 'expected timeout with active registration' 'Pacific Standard Time' 0 1000 -WaitInput }
    catch { if ($_.Exception.Message -notmatch 'timed out') { throw }; $caught=$true }
    $timeoutCase=$cases[$cases.Count-1]
    if (-not $caught -or -not $timeoutCase.timedOut -or $null -eq $timeoutCase.exitCode -or $timeoutCase.stdout -notmatch '"ready":true') { throw 'Timeout diagnostic/exit code was not retained.' }
    $timeoutCase.expectedFailure=$true; $timeoutCase.passed=$true
    $caught=$false
    try { $null=Invoke-Probe (Join-Path $run 'MissingProbe.exe') active 'expected process creation failure' 'Pacific Standard Time' 0 }
    catch { $caught=$true }
    $creationCase=$cases[$cases.Count-1]
    if (-not $caught -or -not $creationCase.error -or $null -ne $creationCase.exitCode) { throw 'Process creation failure diagnostic was not retained.' }
    $creationCase.expectedFailure=$true; $creationCase.passed=$true
    if (-not (Manager Status $images[0]).matchesInstalled) { throw 'Transport failure damaged registry configuration.' }
    $saved=[IO.File]::ReadAllBytes($config)
    $inactive=@(
        @{label='disabled';text='{"schemaVersion":1,"enabled":false,"timeZoneId":"Pacific Standard Time","utcOffsetSeconds":0}';stage=0;code=0},
        @{label='malformed JSON';text='{';stage=1;code=13},
        @{label='missing comma';text='{"schemaVersion":1 "enabled":true,"timeZoneId":"UTC","utcOffsetSeconds":0}';stage=1;code=13},
        @{label='unknown zone';text='{"schemaVersion":1,"enabled":true,"timeZoneId":"Cdf Missing Time Zone","utcOffsetSeconds":0}';stage=2;code=2},
        @{label='multiplication overflow';text='{"schemaVersion":1,"enabled":true,"timeZoneId":"UTC","utcOffsetSeconds":9223372036854775807}';stage=1;code=534},
        @{label='date range overflow';text='{"schemaVersion":1,"enabled":true,"timeZoneId":"UTC","utcOffsetSeconds":-200000000000}';stage=3;code=534}
    )
    foreach ($scenario in $inactive) {
        try {
            Set-RawConfig ([Text.Encoding]::UTF8.GetBytes($scenario.text))
            $observed=Invoke-Probe $probe inactive $scenario.label
            if ($observed.tls.status.errorStage -ne $scenario.stage -or $observed.tls.status.errorCode -ne $scenario.code) { throw "Wrong failure diagnostic: $($scenario.label)" }
        } finally { Set-RawConfig $saved }
    }
    try {
        if ((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -cne $expectedConfigHash) { throw 'External modification before missing-file test.' }
        [IO.File]::Delete($config); $expectedConfigHash=$null
        $observed=Invoke-Probe $probe inactive 'missing configuration'
        if ($observed.tls.status.errorStage -ne 1 -or $observed.tls.status.errorCode -ne 2) { throw 'Wrong missing-file diagnostic.' }
    } finally { Set-RawConfig $saved }
    $null=Manager Uninstall $images[0]; $null=$owned.Remove($images[0])
    foreach ($path in $executables) { $null=Invoke-Probe $path absent 'after uninstall baseline' }
} catch { $failure=$_.Exception.Message }
finally {
    foreach ($image in @($owned.ToArray())) { try { $null=Manager Uninstall $image } catch { $cleanup.Add("${image}: $($_.Exception.Message)") } }
    foreach ($image in $images) { if ($snapshots.ContainsKey($image) -and (Snapshot $image) -cne $snapshots[$image]) { $cleanup.Add("Registry baseline differs: $image") } }
    if ($usedDeployment) {
        try {
            if ((Get-FileHash -LiteralPath $deployment -Algorithm SHA256).Hash -cne $expectedDeploymentHash) { throw 'External deployment-record change; preserving recovery files.' }
            if ($null -ne $originalConfig) { Set-RawConfig $originalConfig }
            else {
                if ((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -cne $expectedConfigHash) { throw 'External configuration change; preserving recovery files.' }
                [IO.File]::Delete($config); $expectedConfigHash=$null
            }
            $record=Get-Content -LiteralPath $deployment -Raw | ConvertFrom-Json
            $record.configSha256=$expectedConfigHash
            [IO.File]::WriteAllText($deployment,(ConvertTo-Json -InputObject $record -Depth 8),[Text.UTF8Encoding]::new($false))
        } catch { $cleanup.Add("Configuration restore: $($_.Exception.Message)") }
    }
    $ifeo.Dispose(); $base.Dispose()
    $report=[pscustomobject]@{passed=($null -eq $failure -and $cleanup.Count -eq 0);failure=$failure;cleanupErrors=@($cleanup.ToArray());registryRestored=($cleanup.Count -eq 0);
        class93ContractsPerProcess=84;class93ContractsMatchedBaseline=($null -ne $baselineClass93Contracts -and $null -eq $failure);
        iterationsPerImageAndZone=$Iterations;cases=@($cases.ToArray());runDirectory=$run;bootstrapPath=(Join-Path $env:SystemRoot 'System32\CdfTimeZone64.dll')}
    $reportPath=Join-Path $reports 'timezone-integration.json'
    $report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $reportPath -Encoding utf8
}
if (-not $report.passed) { throw "Time provider integration failed: $failure; cleanup=$($cleanup -join '; '); report=$reportPath" }
[pscustomobject]@{passed=$true;cases=$cases.Count;registryRestored=$true;report=$reportPath} | ConvertTo-Json -Compress
