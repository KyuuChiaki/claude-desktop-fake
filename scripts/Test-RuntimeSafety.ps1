[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
. (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
$project=Split-Path -Parent $PSScriptRoot;$common=[Environment]::GetFolderPath('CommonApplicationData')
$results=Join-Path $BuildDirectory 'test-results';$run=Join-Path $results ('runtime-safety-'+[Guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $run -Force)
$root=Join-Path $common 'ClaudeDesktopFake\stage3\claude-test'
$context=New-CdfClaudeContext -Root $root -SourceDll (Join-Path $BuildDirectory 'bin\CdfClaudeTimeZoneTest64.dll') -DllName 'CdfClaudeTimeZoneTest64.dll'
$context.Manifest=Join-Path $common 'ClaudeDesktopFake\stage3\claude\images-test.json'
$faultFile=Join-Path $common 'ClaudeDesktopFake\stage3\claude\runtime-test-fault.txt'
if(Test-Path -LiteralPath $faultFile){throw 'Existing runtime fault marker; refusing to overwrite it.'}
if((Test-Path -LiteralPath $context.State) -or (Test-Path -LiteralPath $context.Manifest)){throw 'Existing isolated gate registration; refusing to overwrite recovery materials.'}
$fixture=Join-Path $project 'out\runtime-fixtures\electron-44.9.3';$source=Join-Path $fixture 'CdfElectronProbe64.exe'
$image='CdfRuntimePolicy64.exe';$path=Join-Path $fixture $image;$marker=$path+'.cdf-copy.json'
if(Test-Path -LiteralPath $path){if(-not(Test-Path -LiteralPath $marker) -or (Get-Content -Raw -LiteralPath $marker|ConvertFrom-Json).sha256 -cne (Cdf-Hash $path)){throw 'Unowned runtime policy fixture.'}}
$package=[pscustomobject]@{root=$fixture;packageId='runtime_fixture_x64';main=$path;services=@();files=@($path)}
$context.Discover={$package}.GetNewClosure()
$context.Signature={param($file)[pscustomobject]@{status='Valid';signer='Anthropic, PBC'}} # Test fixture only; production always uses Authenticode.
$config=Join-Path $common 'ClaudeDesktopFake\stage2\timezone.json';$deployment=Join-Path $common 'ClaudeDesktopFake\stage2\deployment.json'
$original=[IO.File]::ReadAllBytes($config);$originalHash=Cdf-Hash $config;$expectedConfig=$originalHash;$originalDeployment=Cdf-Hash $deployment
[IO.File]::WriteAllBytes((Join-Path $run 'original-timezone.json'),$original)
$checks=[Collections.Generic.List[string]]::new();$failure=$null;$cleanup=@()
function Check([bool]$Condition,[string]$Label){if(-not $Condition){throw "Assertion failed: $Label"};$checks.Add($Label)}
function Configuration([string]$Policy='block',[bool]$Time=$true,[bool]$Locale=$true,[bool]$Region=$true,[bool]$Runtime=$true){
    [pscustomobject]@{schemaVersion=3;time=@{enabled=$Time;timeZoneId='Eastern Standard Time';utcOffsetSeconds=3600};locale=@{enabled=$Locale;formatLocale='de-DE';uiLanguage='ja-JP'};region=@{enabled=$Region;homeRegion='DE'};runtime=@{enabled=$Runtime;unknownVersionPolicy=$Policy;captureEnabled=$false}}
}
function Set-Configuration($Value){
    if((Cdf-Hash $config) -cne $script:expectedConfig){throw 'External configuration change; preserving recovery.'}
    if($Value -is [string]){[IO.File]::WriteAllText($config,$Value,[Text.UTF8Encoding]::new($false))}else{Cdf-Save $config $Value}
    $script:expectedConfig=Cdf-Hash $config
}
function Copy-Image([bool]$Unknown,[bool]$Repack=$false){
    if(Test-Path -LiteralPath $path){if((Cdf-Hash $path) -cne (Get-Content -Raw -LiteralPath $marker|ConvertFrom-Json).sha256){throw 'External test executable change.'}}
    $temporary=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $inputFile=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{$outputFile=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
            try{$inputFile.CopyTo($outputFile)
    if($Unknown -or $Repack){
        # Change an actual ABI field offset, rather than an irrelevant DOS
        # reserved byte that same-engine compatibility now correctly accepts.
        $offset=if($Repack){28}else{0x53b6cc0-0x1000+0x600+16}
        $outputFile.Position=$offset;$v=$outputFile.ReadByte();$outputFile.Position=$offset;$outputFile.WriteByte($v -bxor 1)
    }
            }finally{$outputFile.Dispose()}
        }finally{$inputFile.Dispose()}
        # Image sections and security scanners may briefly retain read handles
        # after an ACG crash. Never edit that mapped file in place.
        for($attempt=0;;$attempt++){
            if(Test-Path -LiteralPath $path){if((Cdf-Hash $path) -cne (Get-Content -Raw -LiteralPath $marker|ConvertFrom-Json).sha256){throw 'External test image replacement.'}}
            try{[IO.File]::Move($temporary,$path,$true);break}catch [IO.IOException]{if($attempt -ge 19){throw};Start-Sleep -Milliseconds 100}
        }
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
    Cdf-Save $marker @{sha256=(Cdf-Hash $path);source=$source;scope='owned isolated runtime compatibility fixture'}
}
function Fixture([string]$Label,[long]$Exit=0,[string]$Fault='',[bool]$Capture=$false,[string]$ExplicitLang=''){
    $output=Join-Path $run ($Label+'.json')
    $null=& (Join-Path $PSScriptRoot 'Invoke-RuntimeFixture.ps1') -ReportPath $output -ImageName $image -ExpectedExitCode $Exit -TestFault $Fault -Capture:$Capture -ExplicitLang $ExplicitLang
    $reference=Get-Content -LiteralPath ($output+'.controller.json') -Raw|ConvertFrom-Json
    Check ($reference.unsignedExitCode -eq $Exit) "$Label preserves expected exit code"
    if($Exit){Check (-not(Test-Path -LiteralPath $output)) "$Label stops before application code writes a report";return $null}
    $o=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
    Check $o.native.contracts.passed "$Label native contracts"
    [pscustomobject]@{observation=$o;reference=$reference;path=$output}
}
function PolicyFixture([string]$Label,[long]$Exit=0){
    $output=Join-Path $run ($Label+'.json')
    $p=[Diagnostics.Process]::new();$p.StartInfo.FileName=Join-Path $BuildDirectory 'bin\CdfRuntimePolicyLaunch64.exe'
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    foreach($argument in @($path,(Join-Path $project 'tests\runtime_electron.cjs'),'--js-flags=--jitless')){$p.StartInfo.ArgumentList.Add($argument)}
    $p.StartInfo.Environment['CDF_RUNTIME_REPORT']=$output;$p.StartInfo.Environment['CDF_RUNTIME_USER_DATA']=$output+'.userdata'
    $p.StartInfo.Environment['CDF_RUNTIME_NATIVE']=Join-Path $BuildDirectory 'bin\CdfRuntimeNative64.node'
    $p.StartInfo.Environment['CDF_RUNTIME_TEST_TZ']='1'
    foreach($name in @('ELECTRON_RUN_AS_NODE','NODE_OPTIONS','TZ','CDF_RUNTIME_TEST_FAULT','CDF_RUNTIME_HOLD')){[void]$p.StartInfo.Environment.Remove($name)}
    $start=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try{
        [void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(70000)){$p.Kill($true);$p.WaitForExit();throw 'Protected runtime fixture launcher timed out.'}
        $text=$stdout.GetAwaiter().GetResult();$errors=$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText(($output+'.launcher.log'),$text+"`n"+$errors,[Text.UTF8Encoding]::new($false))
        Check ($p.ExitCode -eq 0) "$Label launcher exits normally"
        $launch=$text|ConvertFrom-Json
        Check ($launch.created -and -not $launch.timedOut -and $launch.prohibitDynamicCode -and ($Exit -eq -1 -or $launch.exitCode -eq $Exit)) "$Label real Windows dynamic-code policy and expected child exit"
        $reference=[pscustomobject]@{utcStartMs=$start;utcEndMs=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();realCreationFileTime=$launch.realCreationFileTime;exitCode=$launch.exitCode;policy='PROCESS_CREATION_MITIGATION_POLICY_PROHIBIT_DYNAMIC_CODE_ALWAYS_ON'}
        Cdf-Save ($output+'.controller.json') $reference
        if($launch.exitCode){
            Check (-not(Test-Path -LiteralPath $output)) "$Label no application report on early native exit"
            return [pscustomobject]@{observation=$null;reference=$reference;path=$output}
        }
        $o=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
        Check (-not $o.PSObject.Properties['error'] -and $o.native.contracts.passed) "$Label native and WinRT contracts under actual protection policy"
        [pscustomobject]@{observation=$o;reference=$reference;path=$output}
    }finally{$p.Dispose()}
}
function Passthrough($Observed,$Baseline,[string]$Label){
    $o=$Observed.observation;$r=$Observed.reference
    Check ($o.native.runtime.state -eq 32 -and $o.native.runtime.patchCount -eq 0) "$Label no partial Windows/runtime virtualization"
    Check ($o.main.now -ge $r.utcStartMs -and $o.main.now -le $r.utcEndMs) "$Label real UTC"
    Check ($o.main.intlDate.locale -ceq $Baseline.main.intlDate.locale -and $o.renderer.intlDate.locale -ceq $Baseline.renderer.intlDate.locale -and $o.main.intlDate.timeZone -ceq $Baseline.main.intlDate.timeZone) "$Label real runtime locale and time zone"
    Check ($o.native.geoName -ceq $Baseline.native.geoName -and $o.native.winrtHomeRegion -ceq $Baseline.native.winrtHomeRegion) "$Label real Win32 and WinRT geography"
    Check ([Math]::Abs([decimal]$o.native.processTimes.creation-[decimal]$r.realCreationFileTime) -le 32) "$Label real creation time"
}
try{
    Copy-Image $true
    $baseline=(Fixture baseline).observation
    $explicitLanguageBaseline=(Fixture baseline-explicit-language 0 '' $false 'fr-CA').observation
    # Some Electron builds fail natively under ACG even with --jitless. Keep an
    # unregistered control so passthrough must preserve that exact native exit,
    # while block must produce our distinct pre-application failure code.
    Copy-Image $false;$mitigationBaseline=PolicyFixture protection-baseline -1
    # An owned DOS packaging change must get a new complete-image binding,
    # while preserving the normalized runtime build and its behavior.
    Copy-Image $false $true
    Set-Configuration (Configuration);$repackedStatus=Invoke-CdfClaudeManager $context Enable
    Check ($repackedStatus.runtime.profiles[0].runtime.match -ceq 'same-engine') 'repack resolves automatically using the normalized runtime fingerprint'
    $repacked=Fixture same-engine-repack 0 '' $true
    Check ($repacked.observation.main.intlDate.locale -ceq 'de-DE' -and $repacked.observation.renderer.intlDate.locale -ceq 'de-DE' -and $repacked.observation.native.runtime.patchCount -eq 2) 'same-engine repack applies the complete behavior before application initialization'
    $repackCaptures=@(Get-ChildItem -LiteralPath $run -Filter 'same-engine-repack.json.capture.*.json')
    Check ($repackCaptures.Count -ge 1) 'same-engine repack has live startup binding evidence'
    foreach($capture in $repackCaptures){$c=Get-Content -LiteralPath $capture.FullName -Raw|ConvertFrom-Json
        Check ($c.compatibility.match -eq 2 -and $c.compatibility.bindingLoaded -and $c.compatibility.coreReady) 'startup rechecks and consumes the repack binding'
    }
    Invoke-CdfClaudeManager $context Disable|Out-Null
    Copy-Image $true
    Set-Configuration (Configuration)
    $rejected=$false;try{Invoke-CdfClaudeManager $context Enable|Out-Null}catch{$rejected=$_.Exception.Message -like '*Unsupported runtime fingerprint*';if(-not $rejected){throw}}
    Check $rejected 'Enable rejects unknown runtime fingerprint before registration'
    Check (-not(Test-Path -LiteralPath $context.State) -and -not(Test-Path -LiteralPath $context.Manifest)) 'preflight refusal leaves no batch state or identity manifest'
    Set-Configuration (Configuration passthrough);Invoke-CdfClaudeManager $context Enable|Out-Null
    $pass=Fixture unknown-passthrough;Passthrough $pass $baseline 'unknown fingerprint passthrough'
    Check ($pass.observation.native.runtime.error -eq 1306 -and $pass.observation.native.runtime.stage -eq 10) 'unknown fingerprint diagnostic classification'
    Set-Configuration (Configuration block);$null=Fixture unknown-block 3771593985
    # Replacing only this owned fixture makes its identity stale. Identity denial
    # wins over the runtime block policy, exactly as with an unrefreshed Store update.
    Copy-Image $false;$denied=Fixture stale-identity
    Check ($denied.observation.native.runtime.state -eq 0 -and $denied.observation.native.runtime.patchCount -eq 0) 'stale file identity always passes through before runtime preflight'
    Invoke-CdfClaudeManager $context Disable|Out-Null
    Set-Configuration (Configuration passthrough);Invoke-CdfClaudeManager $context Enable|Out-Null
    $active=Fixture known-active
    Check ($active.observation.main.intlDate.locale -ceq 'de-DE' -and $active.observation.renderer.intlDate.locale -ceq 'de-DE' -and $active.observation.native.runtime.patchCount -eq 2) 'known runtime installs complete patch group'
    $identity=Get-Content -LiteralPath $context.Manifest -Raw|ConvertFrom-Json
    $bound=@($identity.images|Where-Object name -ieq $image)[0]
    $bindingPath=Join-Path (Join-Path (Split-Path -Parent $context.Manifest) 'bindings') ($bound.runtimeBindingSha256+'.bin')
    $bindingBytes=[IO.File]::ReadAllBytes($bindingPath)
    $changed=[byte[]]$bindingBytes.Clone();$changed[0]=$changed[0] -bxor 1
    try{
        [IO.File]::WriteAllBytes($bindingPath,$changed)
        $bad=Fixture binding-tampered-passthrough
        Passthrough $bad $baseline 'tampered content-addressed binding'
        Check ($bad.observation.native.runtime.stage -eq 15) 'tampered binding is classified before internal patching'
        $refused=$false;try{Invoke-CdfClaudeManager $context Disable|Out-Null}catch{$refused=$_.Exception.Message -like '*runtime binding changed externally*';if(-not $refused){throw}}
        Check $refused 'Disable detects external binding changes before restoring any registration'
        Set-Configuration (Configuration block);$null=Fixture binding-tampered-block 3771593985
    }finally{
        if([Convert]::ToBase64String([IO.File]::ReadAllBytes($bindingPath)) -cne [Convert]::ToBase64String($changed)){throw 'External binding change during controlled restoration.'}
        [IO.File]::WriteAllBytes($bindingPath,$bindingBytes)
    }
    try{
        [IO.File]::Delete($bindingPath);$null=Fixture binding-missing-block 3771593985
        Set-Configuration (Configuration passthrough);$missing=Fixture binding-missing-passthrough
        Passthrough $missing $baseline 'missing runtime binding'
    }finally{
        if(Test-Path -LiteralPath $bindingPath){throw 'External binding replacement; preserving recovery.'}
        [IO.File]::WriteAllBytes($bindingPath,$bindingBytes)
    }
    $explicitLanguage=(Fixture known-active-explicit-language 0 '' $false 'fr-CA').observation
    Check ($explicitLanguage.renderer.navigator.language -ceq $explicitLanguageBaseline.renderer.navigator.language -and $explicitLanguage.renderer.intlDate.locale -ceq 'de-DE') 'explicit Electron app language takes priority while Intl keeps configured format locale'
    foreach($field in @('networkDefault','networkElectron','networkPartition')){
        Check ($explicitLanguage.$field.acceptLanguage -ceq $explicitLanguageBaseline.$field.acceptLanguage) ('explicit app language preserves native loopback '+$field)
    }
    $timeoutPath=Join-Path $run 'intentional-timeout.json';$timeoutReported=$false
    try{$null=& (Join-Path $PSScriptRoot 'Invoke-RuntimeFixture.ps1') -ReportPath $timeoutPath -ImageName $image -TestHang -TimeoutSeconds 2}catch{$timeoutReported=$_.Exception.Message -like '*timed out*';if(-not $timeoutReported){throw}}
    Check $timeoutReported 'owned test runtime timeout is reported as a failure'
    $timeout=Get-Content -LiteralPath ($timeoutPath+'.controller.json') -Raw|ConvertFrom-Json
    Check ($timeout.started -and $timeout.timedOut -and $null -ne $timeout.exitCode -and $timeout.PSObject.Properties['stderr'] -and -not(Test-Path -LiteralPath $timeoutPath)) 'timeout preserves exit code and diagnostics without a false application observation'
    $missingPath=Join-Path $run 'intentional-start-failure.json';$startFailed=$false
    try{$null=& (Join-Path $PSScriptRoot 'Invoke-RuntimeFixture.ps1') -ReportPath $missingPath -ImageName ('CdfMissing-'+[Guid]::NewGuid().ToString('N')+'.exe') -TimeoutSeconds 2}catch{$startFailed=$true}
    Check $startFailed 'missing owned test runtime reports process creation failure'
    $missing=Get-Content -LiteralPath ($missingPath+'.controller.json') -Raw|ConvertFrom-Json
    Check (-not $missing.started -and -not $missing.timedOut -and $null -eq $missing.exitCode -and $missing.failure) 'process creation failure retains controller diagnostics'
    $protected=PolicyFixture protection-passthrough $mitigationBaseline.reference.exitCode
    if($mitigationBaseline.reference.exitCode -eq 0){
        Passthrough $protected $baseline 'Windows dynamic-code policy refusal'
        Check ($protected.observation.native.runtime.stage -eq 14 -and $protected.observation.native.runtime.error -eq 1260) 'actual protection policy diagnosed before any patch write'
    }else{Check ($protected.reference.exitCode -eq $mitigationBaseline.reference.exitCode) 'protection passthrough preserves native Electron mitigation failure without claiming JS coverage'}
    Set-Configuration (Configuration block);$null=PolicyFixture protection-block 3771593985
    Set-Configuration (Configuration passthrough)
    [IO.File]::WriteAllText($faultFile,'after-first-patch',[Text.UTF8Encoding]::new($false))
    $rollback=Fixture partial-install-passthrough 0 after-first-patch $true
    Passthrough $rollback $baseline 'failed second patch installation'
    Check ($rollback.observation.native.runtime.error -eq 29 -and $rollback.observation.native.runtime.stage -eq 12) 'partial installation failure is diagnosed'
    $captures=@(Get-ChildItem -LiteralPath $run -Filter 'partial-install-passthrough.json.capture.*.json');$verified=0
    foreach($capture in $captures){$c=Get-Content -Raw -LiteralPath $capture.FullName|ConvertFrom-Json
        Check ($c.adapterPatches.Count -eq 2 -and @($c.adapterPatches|Where-Object state -cne 'original').Count -eq 0) 'ReadProcessMemory confirms both original patch sites after rollback';$verified++}
    Check ($verified -ge 1) 'rollback verified in a live process'
    Set-Configuration (Configuration block);$null=Fixture partial-install-block 3771593985 after-first-patch
    if([IO.File]::ReadAllText($faultFile) -cne 'after-first-patch'){throw 'Runtime fault marker changed externally.'};[IO.File]::Delete($faultFile)
    Invoke-CdfClaudeManager $context Disable|Out-Null
    foreach($fault in @('deny-first-protect','deny-second-protect')){
        Set-Configuration (Configuration passthrough);Invoke-CdfClaudeManager $context Enable|Out-Null
        [IO.File]::WriteAllText($faultFile,$fault,[Text.UTF8Encoding]::new($false))
        $refusal=Fixture $fault 0 $fault $true
        Passthrough $refusal $baseline ($fault+' preserves passthrough after a protection call fails')
        Check ($refusal.observation.native.runtime.error -eq 5 -and $refusal.observation.native.runtime.stage -eq 12) ($fault+' retains the original protection failure diagnostic')
        $captures=@(Get-ChildItem -LiteralPath $run -Filter ($fault+'.json.capture.*.json'))
        Check ($captures.Count -ge 1) ($fault+' has live rollback evidence')
        foreach($capture in $captures){$c=Get-Content -LiteralPath $capture.FullName -Raw|ConvertFrom-Json
            Check ($c.adapterPatches.Count -eq 2 -and @($c.adapterPatches|Where-Object state -cne 'original').Count -eq 0) ($fault+' confirms both original instruction sites without rewriting the denied site')
        }
        Set-Configuration (Configuration block);$null=Fixture ($fault+'-block') 3771593985 $fault
        if([IO.File]::ReadAllText($faultFile) -cne $fault){throw 'External protection fault marker change.'};[IO.File]::Delete($faultFile)
        Invoke-CdfClaudeManager $context Disable|Out-Null
    }
    # Switches are independent; old schema behavior is covered again with the
    # same runtime process rather than inferred from parser-only tests.
    foreach($case in @(
        @{label='runtime-off';value=(Configuration block $true $true $true $false);time=$true;locale=$true;region=$true;patches=0},
        @{label='region-only';value=(Configuration block $false $false $true $false);time=$false;locale=$false;region=$true;patches=0},
        @{label='runtime-locale';value=(Configuration block $false $true $false $true);time=$false;locale=$true;region=$false;patches=2},
        @{label='runtime-time';value=(Configuration block $true $false $false $true);time=$true;locale=$false;region=$false;patches=0},
        @{label='all-off';value=(Configuration block $false $false $false $false);time=$false;locale=$false;region=$false;patches=0},
        @{label='schema2';value=@{schemaVersion=2;time=@{enabled=$true;timeZoneId='Eastern Standard Time';utcOffsetSeconds=3600};locale=@{enabled=$true;formatLocale='de-DE';uiLanguage='ja-JP'}};time=$true;locale=$true;region=$false;patches=0},
        @{label='schema1';value=@{schemaVersion=1;enabled=$true;timeZoneId='Eastern Standard Time';utcOffsetSeconds=3600};time=$true;locale=$false;region=$false;patches=0}
    )){
        Set-Configuration $case.value;Invoke-CdfClaudeManager $context Enable|Out-Null;$sample=Fixture $case.label;$o=$sample.observation;$ref=$sample.reference
        Check ($o.native.runtime.patchCount -eq $case.patches) ($case.label+' patch scope')
        $delta=if($case.time){3600000}else{0};Check ($o.main.now -ge $ref.utcStartMs+$delta -and $o.main.now -le $ref.utcEndMs+$delta) ($case.label+' independent clock')
        if($case.locale){Check ($o.native.winrtFormatLocale -ceq 'de-DE') ($case.label+' configured Windows locale still applies')}
        Check ($o.native.geoName -ceq $(if($case.region){'DE'}else{$baseline.native.geoName})) ($case.label+' independent home region')
        Invoke-CdfClaudeManager $context Disable|Out-Null
    }
    Set-Configuration (Configuration);Invoke-CdfClaudeManager $context Enable|Out-Null
    Set-Configuration '{';$damaged=Fixture damaged-json
    Check ($damaged.observation.native.runtime.state -eq 0 -and $damaged.observation.main.intlDate.locale -ceq $baseline.main.intlDate.locale) 'damaged JSON leaves all groups original'
    Set-Configuration (Configuration);Invoke-CdfClaudeManager $context Disable|Out-Null
    $restored=Fixture restored
    Check (-not $restored.observation.native.PSObject.Properties['runtime']) 'Disable restores unregistered runtime baseline'
}catch{$failure=$_.Exception.ToString()+"`n"+$_.ScriptStackTrace}finally{
    if(Test-Path -LiteralPath $faultFile){try{if([IO.File]::ReadAllText($faultFile) -cnotin @('after-first-patch','deny-first-protect','deny-second-protect')){throw 'External runtime fault marker change; preserving evidence.'};[IO.File]::Delete($faultFile)}catch{$cleanup+=$_.Exception.Message}}
    try{Invoke-CdfClaudeManager $context Disable|Out-Null}catch{$cleanup+=$_.Exception.Message}
    try{
        if((Cdf-Hash $config) -cne $expectedConfig -or (Cdf-Hash $deployment) -cne $originalDeployment){throw 'External shared configuration/deployment change; retaining recovery.'}
        [IO.File]::WriteAllBytes($config,$original)
        if((Cdf-Hash $config) -cne $originalHash){throw 'Original configuration restore failed.'}
    }catch{$cleanup+=$_.Exception.Message}
    $report=[pscustomobject]@{passed=($null -eq $failure -and -not $cleanup.Count);scope='isolated identity-gated provider; mocked fixture signer; no Claude process started';failure=$failure;cleanupErrors=$cleanup;cases=@($checks);caseCount=$checks.Count;runDirectory=$run}
    $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $results 'runtime-safety.json') -Encoding utf8
}
if(-not $report.passed){throw "Runtime safety failed: $failure; cleanup=$($cleanup -join '; '); recovery=$run"}
[pscustomobject]@{passed=$true;cases=$checks.Count;runDirectory=$run}|ConvertTo-Json -Compress
