[CmdletBinding()]
param(
    [string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),
    [ValidateRange(1,20)][int]$Iterations=10,[switch]$Exploratory,[switch]$Capture,
    [ValidateSet('44.9.3','44.9.2','44.8.0')][string]$FixtureVersion='44.9.3'
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Runtime-ProcessFailure.ps1')
$projectRoot=Split-Path -Parent $PSScriptRoot
$runtime=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2'
$config=Join-Path $runtime 'timezone.json';$deployment=Join-Path $runtime 'deployment.json'
$original=if(Test-Path -LiteralPath $config){[IO.File]::ReadAllBytes($config)}else{$null}
$expectedConfig=if($original){(Get-FileHash -LiteralPath $config).Hash}else{$null}
$expectedDeployment=if(Test-Path -LiteralPath $deployment){(Get-FileHash -LiteralPath $deployment).Hash}else{$null}
$results=Join-Path $BuildDirectory 'test-results';$run=Join-Path $results ('runtime-'+[Guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $run -Force)
if($original){[IO.File]::WriteAllBytes((Join-Path $run 'original-timezone.json'),$original)}
$owned=[Collections.Generic.List[string]]::new();$records=[Collections.Generic.List[object]]::new();$checks=[Collections.Generic.List[string]]::new()
$failure=$null;$cleanup=@();$used=$false
$manager=Join-Path $PSScriptRoot 'Manage-TimeZone.ps1';$bin=Join-Path $BuildDirectory 'bin';$dll=Join-Path $bin 'CdfTimeZone64.dll'
$fixture=Join-Path $projectRoot ('out\runtime-fixtures\electron-'+$FixtureVersion)
$nativeImages=@('CdfRuntimeProbe64.exe','CdfRuntimeOther64.exe');$electronImages=@('CdfElectronProbe64.exe','CdfElectronOther64.exe')
$images=$nativeImages+$electronImages
foreach($pair in @(@((Join-Path $bin $nativeImages[0]),(Join-Path $bin $nativeImages[1])),@((Join-Path $fixture $electronImages[0]),(Join-Path $fixture $electronImages[1])))){
    if(-not(Test-Path -LiteralPath $pair[0])){throw "Missing runtime fixture: $($pair[0]); run Prepare-RuntimeFixture.ps1 first."}
    $sourceHash=(Get-FileHash -LiteralPath $pair[0]).Hash;$marker=$pair[1]+'.cdf-copy.json'
    if(Test-Path -LiteralPath $pair[1]){
        $existingHash=(Get-FileHash -LiteralPath $pair[1]).Hash
        if($existingHash -cne $sourceHash){
            if(-not(Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json).sha256 -cne $existingHash){throw "Unowned fixture copy differs: $($pair[1])"}
            Copy-Item -LiteralPath $pair[0] -Destination $pair[1] -Force
        }
    }else{Copy-Item -LiteralPath $pair[0] -Destination $pair[1]}
    @{source=$pair[0];sha256=$sourceHash}|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding utf8
}
function Assert([bool]$Condition,[string]$Label){if(-not $Condition){throw "Assertion failed: $Label"};$checks.Add($Label)}
function Json($Object){ConvertTo-Json -InputObject $Object -Depth 50 -Compress}
function Manager([string]$Action,[string]$Image,[string]$Source=''){
    if($Action -eq 'Install'){
        $parameters=@{Action=$Action;ImageName=$Image;DllPath=$dll;ConfigPath=$Source}
        if($Image -in $electronImages){$parameters.ImagePath=Join-Path $fixture $Image}
        $r=& $manager @parameters|ConvertFrom-Json
        $script:expectedConfig=(Get-FileHash -LiteralPath $config).Hash;$script:expectedDeployment=(Get-FileHash -LiteralPath $deployment).Hash;$script:used=$true
    }else{$r=& $manager -Action $Action -ImageName $Image|ConvertFrom-Json};return $r
}
function Register([string]$Image,[string]$Source){$null=Manager Install $Image $Source;if(-not $owned.Contains($Image)){$owned.Add($Image)}}
function Remove-Registrations(){foreach($image in @($owned.ToArray())){$null=Manager Uninstall $image;[void]$owned.Remove($image)}}
function Native([string]$Image,[string]$Label){
    $p=[Diagnostics.Process]::new();$p.StartInfo.FileName=Join-Path $bin $Image;$p.StartInfo.UseShellExecute=$false
    $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true;$p.StartInfo.CreateNoWindow=$true
    $start=[DateTime]::UtcNow.ToFileTimeUtc();$started=$false;$timedOut=$false;$creation=$null;$stdout=$null;$stderr=$null
    try{
        [void]$p.Start();$started=$true;$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();$creation=$p.StartTime.ToUniversalTime().ToFileTimeUtc()
        if(-not $p.WaitForExit(15000)){$timedOut=$true;$p.Kill($true);$p.WaitForExit();throw "Native runtime probe timed out: $Image"}
        $reference=[pscustomobject]@{start=$start;end=[DateTime]::UtcNow.ToFileTimeUtc();creation=$creation;exitCode=$p.ExitCode;stderr=$stderr.GetAwaiter().GetResult()}
        $text=$stdout.GetAwaiter().GetResult();[IO.File]::WriteAllText((Join-Path $run ($Label+'.native.json')),$text)
        $reference|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $run ($Label+'.native.controller.json')) -Encoding utf8
        Assert ($p.ExitCode -eq 0) "$Label native exits normally"
        $observation=$text|ConvertFrom-Json;Assert $observation.contracts.passed "$Label native COM, buffer and process contracts: $(Json $observation.contracts)"
        [pscustomobject]@{observation=$observation;reference=$reference}
    }catch{
        $controller=Join-Path $run ($Label+'.native.controller.json')
        if(-not(Test-Path -LiteralPath $controller)){Save-CdfRuntimeProcessFailure $p $started $stdout $stderr $controller ([DateTime]::FromFileTimeUtc($start).Subtract([DateTime]::UnixEpoch).TotalMilliseconds) $creation $_ $timedOut}
        throw
    }finally{$p.Dispose()}
}
function Electron([string]$Image,[string]$Label,[string]$Lang='',[string]$TZ='',[bool]$Sample=$false){
    $path=Join-Path $run ($Label+'.electron.json')
    $null=& (Join-Path $PSScriptRoot 'Invoke-RuntimeFixture.ps1') -ReportPath $path -FixtureDirectory $fixture -ImageName $Image -ExplicitLang $Lang -StartupTZ $TZ -Capture:$Sample
    $o=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json;$reference=Get-Content -LiteralPath ($path+'.controller.json') -Raw|ConvertFrom-Json
    Assert $o.native.contracts.passed "$Label Electron native contracts: $(Json $o.native.contracts)"
    [pscustomobject]@{observation=$o;reference=$reference;path=$path}
}
function Check-Native($N,$Reference,$Case,[string]$Label,$Oracle){
    Assert ($N.runtime.error -eq 0 -and ($N.runtime.state -band 79) -eq 79) "$Label native runtime ready"
    foreach($phase in @('early','tls')){
        Assert ($N.$phase.loaded -eq 1 -and $N.$phase.error -eq 0 -and ($N.$phase.state -band 79) -eq 79 -and $N.$phase.geo -ceq $Case.region) "$Label $phase ready before application"
        Assert ([decimal]$N.$phase.creation -eq ([decimal]$Reference.creation+[decimal]$Case.offset*10000000)) "$Label $phase creation shifted exactly once"
    }
    Assert ([decimal]$N.processTimes.creation -eq ([decimal]$Reference.creation+[decimal]$Case.offset*10000000)) "$Label main creation shifted exactly once"
    Assert ($N.geoName -ceq $Case.region -and $N.winrtHomeRegion -ceq $Case.region -and $N.winrtGeo -ceq $Case.region) "$Label independent Win32 and WinRT geography"
    Assert ($N.explicitJapan -ceq 'JP') "$Label explicit geographic query preserved"
    Assert ($N.winrtLanguages[0] -ceq $Case.ui -and $N.winrtAppLanguages[0] -ceq $Case.ui) "$Label WinRT UI languages"
    Assert ($N.winrtFormatLocale -ceq $Oracle.dateLocale -and $N.winrtNumberLocale -ceq $Oracle.numberLocale -and $N.winrtFormatRegion -ceq $Case.region) "$Label WinRT native resolved format language and independent region"
    $date=$N.winrtDate -replace '[\u200e\u200f]','';$tokyo=$N.winrtDateExplicitTokyo -replace '[\u200e\u200f]',''
    Assert ($date -ceq $Oracle.standardDate -and $tokyo -ceq $Oracle.standardTokyo) "$Label fixed WinRT dates use standard NLS without user overrides or UTC offset"
    Assert ((Json $N.winrtNumbers) -ceq (Json $Oracle.numbers)) "$Label WinRT decimal percent permille currency explicit-context oracle"
}
function Check-JS($S,$Reference,$Case,$Baseline,[string]$Label){
    foreach($kind in @('DateTimeFormat','NumberFormat','Collator','PluralRules','RelativeTimeFormat','ListFormat','DisplayNames','Segmenter')){Assert ($S.intlAll.$kind.locale -ceq $Case.format) "$Label Intl.$kind default format locale"}
    Assert ($S.intlDate.timeZone -ceq $Case.iana) "$Label default ICU zone"
    $low=[double]$Reference.utcStartMs+$Case.offset*1000;$high=[double]$Reference.utcEndMs+$Case.offset*1000
    Assert ($S.now -ge $low -and $S.now -le $high -and $S.newDate -ge $low -and $S.newDate -le $high) "$Label virtual UTC in controller window"
    Assert ([Math]::Abs($S.now-$S.performance.absolute) -lt 1000) "$Label performance origin and Date are consistent"
    Assert ($S.explicitUTC -eq 1705320000000 -and $S.explicitParse -eq 1705320000000) "$Label fixed timestamps never shifted"
    $explicitOracle=(Json $Baseline.explicitIntl)|ConvertFrom-Json
    foreach($locale in $explicitOracle.PSObject.Properties){$locale.Value.all.DateTimeFormat.timeZone=$Case.iana}
    Assert ((Json $S.explicitIntl) -ceq (Json $explicitOracle) -and $S.explicitCurrency -ceq $Baseline.explicitCurrency) "$Label explicit Intl locale currency precision collation preserved"
    Assert ($S.numberFormatted -ceq $Baseline.explicitIntl.($Case.format).number) "$Label Number.toLocaleString default locale"
    Assert ((Json $S.defaultFormatting) -ceq (Json $S.explicitFormatting.($Case.format))) "$Label default Date.toLocale date time combined and localeCompare"
    for($i=0;$i -lt $S.fixed.Count;$i++){
        $fixed=$S.fixed[$i];$oracle=$S.fixedOracles.($Case.iana)[$i]
        $offset=if($oracle.offsetName -eq 'GMT'){0}else{$m=[regex]::Match($oracle.offsetName,'^GMT([+-])(\d+)(?::(\d+))?$');if(-not $m.Success){throw 'Invalid ICU offset oracle'};$v=60*[int]$m.Groups[2].Value+[int]$(if($m.Groups[3].Success){$m.Groups[3].Value}else{0});if($m.Groups[1].Value -eq '+'){-$v}else{$v}}
        Assert ($fixed.hours -eq $oracle.hours -and $fixed.offset -eq $offset -and $fixed.ms -eq $Baseline.fixed[$i].ms) "$Label fixed date $i DST history leap future oracle"
    }
}
try{
    foreach($image in $images){Assert (-not(Manager Status $image).managed) "no preexisting managed runtime fixture $image"}
    $baseline=Native $nativeImages[0] 'baseline';Assert ($baseline.observation.early.loaded -eq 0 -and $baseline.observation.tls.loaded -eq 0) 'native unregistered baseline'
    $baseElectron=Electron $electronImages[0] 'baseline'
    $matrix=@(
        @{label='los-angeles-zero-en-us';zone='Pacific Standard Time';iana='America/Los_Angeles';offset=0;format='en-US';ui='en-US';region='US'},
        @{label='new-york-plus1h-german-japanese';zone='Eastern Standard Time';iana='America/New_York';offset=3600;format='de-DE';ui='ja-JP';region='DE'},
        @{label='utc-minus1h-french-british';zone='UTC';iana='UTC';offset=-3600;format='fr-FR';ui='en-GB';region='JP'},
        @{label='india-plus26h-japanese-american';zone='India Standard Time';iana='Asia/Calcutta';offset=93600;format='ja-JP';ui='en-US';region='IN'},
        @{label='los-angeles-minus26h-british-chinese';zone='Pacific Standard Time';iana='America/Los_Angeles';offset=-93600;format='en-GB';ui='zh-CN';region='GB'},
        @{label='new-york-zero-chinese-french';zone='Eastern Standard Time';iana='America/New_York';offset=0;format='zh-CN';ui='fr-FR';region='US'}
    )
    foreach($case in $matrix){
        $languageOracle=Electron $electronImages[0] ($case.label+'.language-oracle') $case.ui
        $source=Join-Path $run ($case.label+'.config.json')
        [ordered]@{schemaVersion=3;time=@{enabled=$true;timeZoneId=$case.zone;utcOffsetSeconds=$case.offset};locale=@{enabled=$true;formatLocale=$case.format;uiLanguage=$case.ui};region=@{enabled=$true;homeRegion=$case.region};runtime=@{enabled=$true;unknownVersionPolicy='block';captureEnabled=[bool]$Capture}}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $source -Encoding utf8
        foreach($image in $images){Register $image $source}
        $n=Native $nativeImages[0] $case.label
        $oracle=@($baseline.observation.winrtOracles|Where-Object {$_.locale -ceq $case.format -and $_.region -ceq $case.region})[0]
        Check-Native $n.observation $n.reference $case $case.label $oracle
        $electron=Electron $electronImages[0] $case.label '' '' ([bool]$Capture);$e=$electron.observation;$ref=$electron.reference
        $contexts=@{beforeReady=$e.beforeReady;main=$e.main;renderer=$e.renderer;webWorker=$e.webWorker;nodeWorker=$e.nodeWorker.initial;utility=$e.nodeUtility.initial}
        foreach($entry in $contexts.GetEnumerator()){Check-JS $entry.Value $ref $case $baseElectron.observation.main ($case.label+'/'+$entry.Key)}
        foreach($context in @($e.beforeReady,$e.main,$e.nodeWorker.initial,$e.nodeUtility.initial)){Assert ($context.navigator.language -ceq $case.ui) ($case.label+' Node navigator uses UI language')}
        $expectedLanguages=@(@($languageOracle.observation.renderer.navigator.language,$case.ui)|Select-Object -Unique)
        foreach($context in @($e.renderer,$e.webWorker)){Assert ((Json $context.navigator.languages) -ceq (Json $expectedLanguages)) ($case.label+' browser navigator native primary plus configured fallback')}
        foreach($field in @('networkDefault','networkElectron','networkPartition','networkPartitionExplicit','networkHeader','networkRedirect','networkExplicit','nodeFetch','nodeHttp')){Assert ((Json $e.$field) -ceq (Json $languageOracle.observation.$field)) ($case.label+' loopback '+$field)}
        # The native addon report crosses JSON.parse in JavaScript; FILETIME is
        # larger than 2^53, so allow its IEEE-754 rounding (at most 32 x 100 ns).
        Assert ([Math]::Abs([decimal]$e.native.processTimes.creation-([decimal]$ref.realCreationFileTime+[decimal]$case.offset*10000000)) -le 32) ($case.label+' Electron GetProcessTimes single offset')
        $unixCreation=([double]$ref.realCreationFileTime/10000-11644473600000)+$case.offset*1000
        Assert ([Math]::Abs($e.main.process.creationTime-$unixCreation) -lt 2) ($case.label+' Node creation time single offset')
        $elapsed=$e.elapsed.end.now-$e.elapsed.start.now;$performance=$e.elapsed.end.performance.now-$e.elapsed.start.performance.now
        $hr=([decimal]$e.elapsed.end.process.hrtime-[decimal]$e.elapsed.start.process.hrtime)/1000000;$uptime=1000*($e.elapsed.end.process.uptime-$e.elapsed.start.process.uptime)
        Assert ($elapsed -ge 150 -and $elapsed -lt 10000 -and [Math]::Abs($elapsed-$performance) -lt 100 -and [Math]::Abs($hr-$performance) -lt 100 -and [Math]::Abs($uptime-$performance) -lt 100) ($case.label+' Date performance hrtime and uptime rate')
        $cleared=if($baseElectron.observation.mainClearedTZ.intlDate.timeZone -ceq $baseElectron.observation.main.intlDate.timeZone){$case.iana}else{$baseElectron.observation.mainClearedTZ.intlDate.timeZone}
        Assert ($e.mainExplicitTZ.intlDate.timeZone -ceq $baseElectron.observation.mainExplicitTZ.intlDate.timeZone -and $e.mainClearedTZ.intlDate.timeZone -ceq $cleared) ($case.label+' explicit Node TZ and clear follow native cache')
        if($Capture){
            $captures=@(Get-ChildItem -LiteralPath $run -Filter ($case.label+'.electron.json.capture.*.json'));$observed=0
            foreach($file in $captures){$captureObservation=Get-Content -Raw -LiteralPath $file.FullName|ConvertFrom-Json
                Assert ($captureObservation.sampling.failures -eq 0 -and $captureObservation.sampling.truncated -eq 0) ($case.label+' bounded read-only capture '+$captureObservation.pid)
                if($captureObservation.sampling.state -eq 'not-sampled'){continue}
                foreach($context in $captureObservation.sampling.contexts){Assert ($context.state -eq 2 -and $null -eq $context.error) ($case.label+' capture context complete');foreach($kind in $context.observation.intl.PSObject.Properties){Assert ($kind.Value.locale -ceq $case.format) ($case.label+' captured '+$kind.Name)};$observed++}
            }
            Assert ($observed -ge 2) ($case.label+' sampled renderer and worker contexts; missing data is not a pass')
        }
        $repeats=if($case.label -in @('los-angeles-zero-en-us','new-york-plus1h-german-japanese')){$Iterations}else{1}
        for($i=0;$i -lt $repeats;$i++){foreach($index in 0,1){
            if($i -eq 0 -and $index -eq 0){continue}
            $label=$case.label+'.repeat.'+$index+'.'+$i
            $repeat=Native $nativeImages[$index] $label;Check-Native $repeat.observation $repeat.reference $case $label $oracle
            $repeatElectron=Electron $electronImages[$index] $label;Check-JS $repeatElectron.observation.main $repeatElectron.reference $case $baseElectron.observation.main $label
            Assert ($repeatElectron.observation.renderer.intlDate.locale -ceq $case.format -and $repeatElectron.observation.webWorker.intlDate.locale -ceq $case.format) ($label+' renderer and worker startup stability')
        }}
        $records.Add([pscustomobject]@{case=$case;nativeReport=(Join-Path $run ($case.label+'.native.json'));electronReport=$electron.path;languageOracle=$languageOracle.path;repeatsPerName=$repeats})
        Remove-Registrations
    }
    foreach($image in $nativeImages){$n=Native $image ('restored.'+$image);Assert ($n.observation.tls.loaded -eq 0) ('unregistered native restored '+$image)}
    foreach($image in $electronImages){$e=Electron $image ('restored.'+$image);Assert (-not $e.observation.native.PSObject.Properties['runtime']) ('unregistered Electron restored '+$image)}
}catch{$failure=$_.Exception.ToString()+"`n"+$_.ScriptStackTrace}finally{
    foreach($image in @($owned.ToArray())){try{$null=Manager Uninstall $image;[void]$owned.Remove($image)}catch{$cleanup+=$_.Exception.Message}}
    if($used){try{
        if((Get-FileHash -LiteralPath $config).Hash -cne $expectedConfig -or (Get-FileHash -LiteralPath $deployment).Hash -cne $expectedDeployment){throw 'External config/deployment change; preserving runtime recovery.'}
        if($original){[IO.File]::WriteAllBytes($config,$original);$expectedConfig=(Get-FileHash -LiteralPath $config).Hash}else{[IO.File]::Delete($config);$expectedConfig=$null}
        $d=Get-Content -Raw -LiteralPath $deployment|ConvertFrom-Json;$d.configSha256=$expectedConfig;[IO.File]::WriteAllText($deployment,(ConvertTo-Json -InputObject $d -Depth 10),[Text.UTF8Encoding]::new($false))
    }catch{$cleanup+=$_.Exception.Message}}
    $report=[pscustomobject]@{passed=($null -eq $failure -and $cleanup.Count -eq 0);scope=('official Electron '+$FixtureVersion+' isolated fixture; does not certify the Claude application');fixtureVersion=$FixtureVersion;failure=$failure;cleanupErrors=$cleanup;runDirectory=$run;capture=[bool]$Capture;assertions=$checks.Count;checks=@($checks);cases=@($records)}
    $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $results ('runtime-integration-'+$FixtureVersion+'.json')) -Encoding utf8
    if($FixtureVersion -eq '44.9.3'){$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $results 'runtime-integration.json') -Encoding utf8}
}
if(-not $report.passed){throw "Runtime integration failed: $failure; cleanup=$($cleanup -join '; '); recovery=$run"}
[pscustomobject]@{passed=$true;cases=$records.Count;assertions=$checks.Count;runDirectory=$run}|ConvertTo-Json -Compress
