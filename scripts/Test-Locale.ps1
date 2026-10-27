[CmdletBinding()]
param(
    [string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),
    [ValidateRange(1,100)][int]$Iterations=10
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$manager=Join-Path $PSScriptRoot 'Manage-TimeZone.ps1'
$binaryDirectory=Join-Path $BuildDirectory 'bin'
$dll=Join-Path $binaryDirectory 'CdfTimeZone64.dll'
$probe=Join-Path $binaryDirectory 'CdfLocaleProbe64.exe'
$late=Join-Path $binaryDirectory 'CdfLocaleLate64.dll'
$images=@('CdfLocaleProbe64.exe','CdfLocaleProbeOther64.exe','CdfLocaleTimeCheck64.exe')
$runtime=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2'
$config=Join-Path $runtime 'timezone.json'; $deployment=Join-Path $runtime 'deployment.json'
$reports=Join-Path $BuildDirectory 'test-results'
$null=New-Item -ItemType Directory -Path $reports -Force
$run=Join-Path $reports ('locale-run-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $run
$other=Join-Path $run $images[1]; $timeProbe=Join-Path $run $images[2]
$owned=[Collections.Generic.List[string]]::new(); $cases=[Collections.Generic.List[object]]::new(); $cleanup=[Collections.Generic.List[string]]::new()
$snapshots=@{}; $references=@{}; $baseline=$null; $failure=$null; $usedDeployment=$false
$hostVariations=[Collections.Generic.List[object]]::new()
$originalConfig=if(Test-Path -LiteralPath $config){[IO.File]::ReadAllBytes($config)}else{$null}
$expectedConfigHash=if($null -ne $originalConfig){(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash}else{$null}
$expectedDeploymentHash=if(Test-Path -LiteralPath $deployment){(Get-FileHash -LiteralPath $deployment -Algorithm SHA256).Hash}else{$null}
if($null -ne $originalConfig){[IO.File]::WriteAllBytes((Join-Path $run 'original-timezone.json'),$originalConfig)}
if(Test-Path -LiteralPath $deployment){Copy-Item -LiteralPath $deployment -Destination (Join-Path $run 'original-deployment.json')}
$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
$ifeo=$base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',$false)
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

function New-Config([string]$Region='en-US',[string]$Ui='en-US',[bool]$TimeEnabled=$true,[bool]$LocaleEnabled=$true,[long]$Offset=0,[string]$Zone='Pacific Standard Time') {
    $value=[ordered]@{schemaVersion=2;time=[ordered]@{enabled=$TimeEnabled;timeZoneId=$Zone;utcOffsetSeconds=$Offset};locale=[ordered]@{enabled=$LocaleEnabled;formatLocale=$Region;uiLanguage=$Ui}}
    $path=Join-Path $run ([Guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    return $path
}
function New-Probe([string]$Path,[string]$Expectation,[string]$Region='en-US',[string]$Ui='en-US',[switch]$WaitInput) {
    $p=[Diagnostics.Process]::new(); $p.StartInfo.FileName=$Path
    $p.StartInfo.Arguments='--expect '+$Expectation+' --format '+$Region+' --ui '+$Ui+' --late "'+$late+'"'
    if($WaitInput){$p.StartInfo.Arguments+=' --wait-for-input';$p.StartInfo.RedirectStandardInput=$true}
    $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
    foreach($name in @('TZ','LC_ALL','LC_NUMERIC','LC_TIME','LANG','LANGUAGE')){$p.StartInfo.EnvironmentVariables.Remove($name)}
    return $p
}
function Assert-Observation($Value,[string]$Expectation) {
    if(-not $Value.passed){throw "Probe mismatch: $($Value.failures -join '; ')"}
    if($null -eq $script:baseline){$script:baseline=$Value}
    if((ConvertTo-Json -InputObject $Value.nativeContracts -Compress) -cne (ConvertTo-Json -InputObject $script:baseline.nativeContracts -Compress)){
        throw 'Native query status/probing contracts differ from the unregistered baseline.'
    }
    if((ConvertTo-Json -InputObject $Value.nameContracts -Compress) -cne (ConvertTo-Json -InputObject $script:baseline.nameContracts -Compress)){
        throw 'Default locale-name return/error/write-length contracts differ from the unregistered control.'
    }
    if($Expectation -eq 'active' -and $script:references.ContainsKey($Value.nlsReference.locale)){
        if((ConvertTo-Json -InputObject $Value.nlsReference -Compress -Depth 8) -cne $script:references[$Value.nlsReference.locale]){
            throw 'Explicit NLS reference differs from the unregistered control process.'
        }
    }
    if($Expectation -ne 'active'){
        foreach($stage in @('early','tls','main','late')){
            foreach($field in @('user','system','userLCID','systemLCID','threadLCID','userUI','systemUI','threadUI','shortDate','currency','preferred')){
                if((ConvertTo-Json -InputObject $Value.$stage.$field -Compress) -cne (ConvertTo-Json -InputObject $script:baseline.$stage.$field -Compress)){
                    if($Value.$stage.originalEntries -and $field -in @('user','userLCID','threadLCID')){
                        # This host has inconsistent HKCU LocaleName/Locale and
                        # NLS caches. Require original import/export ownership;
                        # preserve every differing host result in the report.
                        $hostVariations.Add([pscustomobject]@{stage=$stage;field=$field;baseline=$script:baseline.$stage.$field;actual=$Value.$stage.$field;originalEntries=$true})
                        continue
                    }
                    throw "Inactive/baseline locale differs: $stage/$field"
                }
            }
        }
    }
}
function Invoke-Probe([string]$Path,[string]$Expectation,[string]$Label,[string]$Region='en-US',[string]$Ui='en-US',[int]$TimeoutMs=15000,[switch]$WaitInput) {
    $p=New-Probe $Path $Expectation $Region $Ui -WaitInput:$WaitInput
    $record=[ordered]@{label=$Label;passed=$false;expectedFailure=$false;timedOut=$false;exitCode=$null;stdout='';stderr='';error=$null;observation=$null}
    try{
        if(-not $p.Start()){throw 'Probe creation returned false.'}
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit($TimeoutMs)){$record.timedOut=$true;$p.Kill();$p.WaitForExit()}
        $record.exitCode=$p.ExitCode;$record.stdout=$stdout.GetAwaiter().GetResult();$record.stderr=$stderr.GetAwaiter().GetResult()
        if($record.timedOut){throw "Probe timed out after $TimeoutMs milliseconds."}
        if($record.stdout){$record.observation=$record.stdout|ConvertFrom-Json}
        if($record.exitCode -ne 0 -or $null -eq $record.observation){throw "Probe exited with $($record.exitCode): $($record.stdout) $($record.stderr)"}
        Assert-Observation $record.observation $Expectation
        $record.passed=$true;$record.stdout='';return $record.observation
    }catch{$record.error=$_.Exception.Message;throw}
    finally{$cases.Add([pscustomobject]$record);$p.Dispose()}
}
function Time-Check([string]$Expectation,[string]$Zone='Pacific Standard Time',[long]$Offset=0) {
    $p=[Diagnostics.Process]::new();$p.StartInfo.FileName=$timeProbe
    $p.StartInfo.Arguments='--expect '+$Expectation+' --zone "'+$Zone+'" --offset '+$Offset+' --late "'+(Join-Path $binaryDirectory 'CdfTimeLate64.dll')+'"'
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    $p.StartInfo.EnvironmentVariables.Remove('TZ')
    $record=[ordered]@{label="time group/$Expectation/$Zone/$Offset";passed=$false;timedOut=$false;exitCode=$null;stdout='';stderr='';error=$null;observation=$null}
    try{
        if(-not $p.Start()){throw 'Time probe creation returned false.'}
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(15000)){$record.timedOut=$true;$p.Kill();$p.WaitForExit()}
        $record.exitCode=$p.ExitCode;$record.stdout=$stdout.GetAwaiter().GetResult();$record.stderr=$stderr.GetAwaiter().GetResult()
        if($record.timedOut){throw 'Time probe timed out after 15000 milliseconds.'}
        $record.observation=$record.stdout|ConvertFrom-Json
        if($p.ExitCode -ne 0 -or -not $record.observation.matched){throw "Time group cross-check failed: $($record.observation.failures -join '; ')"}
        $record.passed=$true;$record.stdout=''
    }catch{$record.error=$_.Exception.Message;throw}
    finally{$cases.Add([pscustomobject]$record);$p.Dispose()}
}
function Snapshot-Test([string]$NextConfig) {
    $p=New-Probe $probe active en-US en-US -WaitInput
    $record=[ordered]@{label='existing locale process keeps startup snapshot';passed=$false;exitCode=$null;stdout='';stderr='';error=$null;observation=$null}
    $started=$false; $stdout=$null; $stderr=$null
    try{
        $started=$p.Start();if(-not $started){throw 'Snapshot process creation failed.'}
        $stderr=$p.StandardError.ReadToEndAsync();$ready=$p.StandardOutput.ReadLineAsync()
        if(-not $ready.Wait(5000) -or -not ($ready.GetAwaiter().GetResult()|ConvertFrom-Json).ready){throw 'Snapshot readiness failed.'}
        $stdout=$p.StandardOutput.ReadToEndAsync();Set-RawConfig ([IO.File]::ReadAllBytes($NextConfig))
        $null=Invoke-Probe $other active 'new process reads changed locale JSON' de-DE fr-FR
        $p.StandardInput.WriteLine('continue');$p.StandardInput.Close()
        if(-not $p.WaitForExit(15000)){throw 'Snapshot process timeout.'}
        $record.exitCode=$p.ExitCode;$record.stdout=$stdout.GetAwaiter().GetResult();$record.stderr=$stderr.GetAwaiter().GetResult()
        if($p.ExitCode -ne 0){throw "Snapshot process failed: $($record.stdout)"}
        $record.observation=$record.stdout|ConvertFrom-Json;Assert-Observation $record.observation active
        $record.passed=$true;$record.stdout=''
    }catch{$record.error=$_.Exception.Message;throw}
    finally{
        if($started -and -not $p.HasExited){$p.Kill();$p.WaitForExit()}
        if($started){$record.exitCode=$p.ExitCode;if($null -ne $stdout -and -not $record.passed){$record.stdout=$stdout.GetAwaiter().GetResult()};if($null -ne $stderr){$record.stderr=$stderr.GetAwaiter().GetResult()}}
        $p.Dispose();$cases.Add([pscustomobject]$record)
    }
}

try{
    foreach($image in $images){$snapshots[$image]=Snapshot $image;if($snapshots[$image] -ne 'null' -or (Manager Status $image).managed){throw "Test image already configured: $image"}}
    Copy-Item -LiteralPath $probe -Destination $other
    Copy-Item -LiteralPath (Join-Path $binaryDirectory 'CdfLocaleEarly64.dll') -Destination $run
    Copy-Item -LiteralPath (Join-Path $binaryDirectory 'CdfTimeProbe64.exe') -Destination $timeProbe
    Copy-Item -LiteralPath (Join-Path $binaryDirectory 'CdfTimeEarly64.dll') -Destination $run
    foreach($path in @($probe,$other)){$null=Invoke-Probe $path absent 'unregistered baseline'}
    foreach($region in @('en-US','en-GB','de-DE','fr-FR','zh-CN','ja-JP')){
        $reference=Invoke-Probe $probe absent "unregistered NLS reference/$region" $region
        $references[$region]=ConvertTo-Json -InputObject $reference.nlsReference -Compress -Depth 8
    }
    $matrix=@(
        @{region='en-US';ui='en-US';zone='Pacific Standard Time';offset=0L;time=$true;count=$Iterations},
        @{region='de-DE';ui='en-US';zone='Eastern Standard Time';offset=3600L;time=$true;count=$Iterations},
        @{region='fr-FR';ui='de-DE';zone='Pacific Standard Time';offset=-3600L;time=$true;count=1},
        @{region='zh-CN';ui='ja-JP';zone='India Standard Time';offset=90000L;time=$true;count=1},
        @{region='ja-JP';ui='zh-CN';zone='UTC';offset=-90000L;time=$true;count=1},
        @{region='en-GB';ui='fr-FR';zone='UTC';offset=0L;time=$false;count=1}
    )
    foreach($m in $matrix){
        $source=New-Config $m.region $m.ui $m.time $true $m.offset $m.zone
        foreach($image in $images){
            $owned.Add($image);$installed=Manager Install $image $source
            if(-not $installed.matchesInstalled){throw 'Installation mismatch.'}
            $hash=(Get-FileHash -LiteralPath $installed.recoveryRecord -Algorithm SHA256).Hash
            $again=Manager Install $image $source
            if((Get-FileHash -LiteralPath $again.recoveryRecord -Algorithm SHA256).Hash -cne $hash){throw 'Idempotent install changed the original recovery record.'}
        }
        foreach($path in @($probe,$other)){for($n=1;$n -le $m.count;++$n){$null=Invoke-Probe $path active "$([IO.Path]::GetFileName($path))/$($m.region)/$($m.ui)/$n" $m.region $m.ui}}
        Time-Check $(if($m.time){'active'}else{'inactive'}) $m.zone $m.offset
        if($m.region -eq 'en-US'){
            $saved=[IO.File]::ReadAllBytes($config)
            try{Snapshot-Test (New-Config de-DE fr-FR)}finally{Set-RawConfig $saved}
        }
        foreach($image in $images){$null=Manager Uninstall $image;$null=$owned.Remove($image)}
    }
    $valid=New-Config
    foreach($image in $images){$owned.Add($image);$null=Manager Install $image $valid}
    $saved=[IO.File]::ReadAllBytes($config)
    $inactive=@(
        @{label='locale group disabled';source=(New-Config en-US en-US $true $false);stage=0;time='active'},
        @{label='unknown format locale';source=(New-Config zz-ZZ en-US);stage=2;time='active'},
        @{label='neutral UI locale';source=(New-Config en-US en);stage=2;time='active'},
        @{label='both groups disabled';source=(New-Config en-US en-US $false $false);stage=0;time='inactive'}
    )
    foreach($m in $inactive){try{
        Set-RawConfig ([IO.File]::ReadAllBytes($m.source));$value=Invoke-Probe $probe inactive $m.label
        if($value.tls.errorStage -ne $m.stage){throw "Wrong locale error stage: $($m.label)"};Time-Check $m.time
    }finally{Set-RawConfig $saved}}
    try{
        $broken=New-Config de-DE en-US $true $true 0 'Cdf Missing Zone'
        Set-RawConfig ([IO.File]::ReadAllBytes($broken));$null=Invoke-Probe $probe active 'time failure leaves locale active' de-DE en-US;Time-Check inactive
    }finally{Set-RawConfig $saved}
    foreach($text in @('{','{"schemaVersion":2,"time":{},"locale":{}}','{"schemaVersion":1,"enabled":true,"timeZoneId":"Pacific Standard Time","utcOffsetSeconds":9223372036854775807}')){
        try{Set-RawConfig ([Text.Encoding]::UTF8.GetBytes($text));$null=Invoke-Probe $probe inactive 'invalid JSON disables both groups';Time-Check inactive}finally{Set-RawConfig $saved}
    }
    try{
        if((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -cne $expectedConfigHash){throw 'External configuration change before missing-file test.'}
        [IO.File]::Delete($config);$expectedConfigHash=$null
        $value=Invoke-Probe $probe inactive 'missing configuration disables both groups'
        if($value.tls.errorStage -ne 1 -or $value.tls.errorCode -eq 0){throw 'Missing-file diagnostics absent.'}
        Time-Check inactive
    }finally{Set-RawConfig $saved}
    try{
        Set-RawConfig ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"enabled":true,"timeZoneId":"Pacific Standard Time","utcOffsetSeconds":0}'))
        $null=Invoke-Probe $probe inactive 'legacy JSON keeps locale inactive';Time-Check active
    }finally{Set-RawConfig $saved}
    $caught=$false
    try{$null=Invoke-Probe $probe active 'expected timeout while registered' en-US en-US 500 -WaitInput}catch{if($_.Exception.Message -notmatch 'timed out'){throw};$caught=$true}
    $r=$cases[$cases.Count-1];if(-not $caught -or -not $r.timedOut -or $null -eq $r.exitCode -or $r.stdout -notmatch '"ready":true'){throw 'Timeout diagnostics missing.'};$r.expectedFailure=$true;$r.passed=$true
    $caught=$false
    try{$null=Invoke-Probe (Join-Path $run 'MissingLocaleProbe.exe') active 'expected process creation failure'}catch{$caught=$true}
    $r=$cases[$cases.Count-1];if(-not $caught -or -not $r.error -or $null -ne $r.exitCode){throw 'Creation failure diagnostics missing.'};$r.expectedFailure=$true;$r.passed=$true
    foreach($image in $images){$null=Manager Uninstall $image;$null=$owned.Remove($image)}
    foreach($path in @($probe,$other)){$null=Invoke-Probe $path absent 'after uninstall baseline'}
    foreach($bad in @((New-Config en en-US),(New-Config en-US zz-ZZ))){
        $before=@((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash,(Get-FileHash -LiteralPath $deployment -Algorithm SHA256).Hash)
        $caught=$false;try{$null=Manager Install $images[0] $bad}catch{if($_.Exception.Message -notmatch 'Invalid time configuration'){throw};$caught=$true}
        if(-not $caught -or (Snapshot $images[0]) -ne 'null' -or $before[0] -cne (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -or $before[1] -cne (Get-FileHash -LiteralPath $deployment -Algorithm SHA256).Hash){throw 'Invalid v2 install mutated deployment.'}
        $cases.Add([pscustomobject]@{label='invalid v2 installation rejected before mutation';passed=$true})
    }
}catch{$failure=$_.Exception.Message}
finally{
    foreach($image in @($owned.ToArray())){try{$null=Manager Uninstall $image}catch{$cleanup.Add("${image}: $($_.Exception.Message)")}}
    foreach($image in $images){if($snapshots.ContainsKey($image) -and (Snapshot $image) -cne $snapshots[$image]){$cleanup.Add("Registry baseline differs: $image")}}
    if($usedDeployment){try{
        if((Get-FileHash -LiteralPath $deployment -Algorithm SHA256).Hash -cne $expectedDeploymentHash){throw 'External deployment-record change; recovery preserved.'}
        if($null -ne $originalConfig){Set-RawConfig $originalConfig}
        else{if((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -cne $expectedConfigHash){throw 'External configuration change.'};[IO.File]::Delete($config);$expectedConfigHash=$null}
        $record=Get-Content -LiteralPath $deployment -Raw|ConvertFrom-Json;$record.configSha256=$expectedConfigHash
        [IO.File]::WriteAllText($deployment,($record|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }catch{$cleanup.Add("Configuration restore: $($_.Exception.Message)")}}
    $ifeo.Dispose();$base.Dispose()
    $report=[pscustomobject]@{passed=($null -eq $failure -and $cleanup.Count -eq 0);failure=$failure;cleanupErrors=@($cleanup.ToArray());registryRestored=($cleanup.Count -eq 0);iterations=$Iterations;hostNlsVariations=@($hostVariations.ToArray());cases=@($cases.ToArray());runDirectory=$run}
    $reportPath=Join-Path $reports 'locale-integration.json';$report|ConvertTo-Json -Depth 32|Set-Content -LiteralPath $reportPath -Encoding utf8
}
if(-not $report.passed){throw "Locale integration failed: $failure; cleanup=$($cleanup -join '; '); report=$reportPath"}
[pscustomobject]@{passed=$true;cases=$cases.Count;registryRestored=$true;report=$reportPath}|ConvertTo-Json -Compress
