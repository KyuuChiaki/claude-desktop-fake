[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
. (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
$results=Join-Path $BuildDirectory 'test-results';[void](New-Item -ItemType Directory -Path $results -Force)
$run=Join-Path $results ('claude-gate-中-'+[Guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $run)
$root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude-test'
$context=New-CdfClaudeContext -Root $root -SourceDll (Join-Path $BuildDirectory 'bin\CdfClaudeTimeZoneTest64.dll') -DllName 'CdfClaudeTimeZoneTest64.dll'
$context.Manifest=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude\images-test.json'
if(Test-Path -LiteralPath $context.State){throw 'Existing gate test registration; recover before running tests.'}
if(Test-Path -LiteralPath $context.Manifest){throw 'Existing test manifest; refusing to overwrite it.'}
$probe=Join-Path $run 'CdfClaudeGateProbe64.exe';Copy-Item -LiteralPath (Join-Path $BuildDirectory 'bin\CdfClaudeGateProbe64.exe') -Destination $probe
$second=Join-Path $run 'CdfClaudeGateOther64.exe';Copy-Item -LiteralPath $probe -Destination $second
$otherDir=Join-Path $run 'other';[void](New-Item -ItemType Directory -Path $otherDir);$other=Join-Path $otherDir 'CdfClaudeGateProbe64.exe';Copy-Item -LiteralPath $probe -Destination $other
$fake1=Join-Path $run 'CdfClaudeUnsigned64.exe';$fake2=Join-Path $run 'CdfClaudeWrongSigner64.exe';$fake3=Join-Path $run 'CdfClaudeSigError64.exe'
foreach($f in @($fake1,$fake2,$fake3)){Copy-Item -LiteralPath $probe -Destination $f}
$package=[pscustomobject]@{root=$run;packageId='fixture_1.0.0.0_x64__fnn82j28hfe8t';main=$probe;services=@();files=@($probe,$second,$fake1,$fake2,$fake3)}
$context.Discover={ $package }.GetNewClosure()
$context.Signature={param($path)
    switch([IO.Path]::GetFileName($path)){
        'CdfClaudeUnsigned64.exe'{return [pscustomobject]@{status='NotSigned';signer=''}}
        'CdfClaudeWrongSigner64.exe'{return [pscustomobject]@{status='Valid';signer='Other Publisher'}}
        'CdfClaudeSigError64.exe'{throw 'Simulated signature query error'}
        'CdfClaudeGateOther64.exe'{return [pscustomobject]@{status='Valid';signer='anthropic, pbc'}}
        default{return [pscustomobject]@{status='Valid';signer='Anthropic, PBC'}}
    }
}
$cases=[Collections.Generic.List[object]]::new();$failure=$null;$cleanup=@();$savedManifest=$null;$baselineRegistry=$null
$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
$ifeo=$base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',$true)
function Test-Registry([string]$name){$k=$ifeo.OpenSubKey($name,$false);try{if(-not $k){return 'null'};Cdf-Json @($k.GetValueNames()|Sort-Object|ForEach-Object{[pscustomobject]@{name=$_;kind=$k.GetValueKind($_).ToString();data=$k.GetValue($_,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}})}finally{if($k){$k.Dispose()}}}
function Test-SetRegistryValues([string]$name,$values){
    $key=$ifeo.OpenSubKey($name,$true)
    try{foreach($value in $values){
        if($value.exists){
            if(-not $key){$key=$ifeo.CreateSubKey($name)}
            $kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],$value.kind)
            $data=$value.data;if($kind -eq 'DWord'){$data=[int]$data};$key.SetValue($value.name,$data,$kind)
        }elseif($key){$key.DeleteValue($value.name,$false)}
    };if($key){$key.Flush()}}finally{if($key){$key.Dispose()}}
}
function Test-Reject([scriptblock]$body,[string]$pattern,[string]$label){$caught=$false;try{& $body|Out-Null}catch{if($_.Exception.Message -notlike $pattern){throw};$caught=$true};Test-Check $caught $label}
function Test-Check([bool]$condition,[string]$label){if(-not $condition){throw $label};$cases.Add([pscustomobject]@{label=$label;passed=$true})}
function Test-Probe([string]$path,[string]$expect,[string]$label,[string]$reason=''){
    $p=[Diagnostics.Process]::new();$p.StartInfo.FileName=$(if($path.Length -ge 260){'\\?\'+$path}else{$path});$p.StartInfo.Arguments='--expect '+$expect;$p.StartInfo.UseShellExecute=$false;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true;$p.StartInfo.CreateNoWindow=$true
    try{
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(10000)){$p.Kill();throw 'Gate probe timed out.'}
        $text=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$o=$text|ConvertFrom-Json
        $record=[pscustomobject]@{label=$label;passed=($p.ExitCode -eq 0 -and $o.matched);exitCode=$p.ExitCode;stdout=$text;stderr=$stderr;observation=$o};$cases.Add($record)
        if(-not $record.passed -or ($reason -and $o.tls.identityReason -ne $reason)){throw "Gate probe failed: $label $text $stderr"}
    }finally{$p.Dispose()}
}
try{
    $physical=Get-CdfImageIdentity $probe
    $alias=Join-Path $results 'reported-alias\claude.exe'
    $directories=@([pscustomobject]@{path=$run})
    $withoutProvider=[pscustomobject]@{identity=$null}
    $identity=[pscustomobject]@{currentImagePath=$physical.nativePath;matchedImagePath=$physical.path}
    $diagnostic=[pscustomobject]@{identity=$identity}
    $resolution=Cdf-ResolveRunningImage $probe $withoutProvider @($physical) $directories
    Test-Check ($resolution.listed -and $resolution.inEnumeration -and $resolution.resolvedPath -ceq $probe) 'Status keeps direct-path registration when provider is absent'
    $resolution=Cdf-ResolveRunningImage $alias $diagnostic @($physical) $directories
    Test-Check ($resolution.listed -and $resolution.inEnumeration -and $resolution.resolvedPath -ceq $probe) 'Status resolves Store-reported aliases using exact provider Native paths'
    $identity.matchedImagePath=''
    $resolution=Cdf-ResolveRunningImage $alias $diagnostic @($physical) $directories
    Test-Check ($resolution.listed -and $resolution.inEnumeration) 'Status recognizes a newly registered alias in an older rejected process snapshot'
    $identity.currentImagePath=$physical.nativePath+'-different'
    $resolution=Cdf-ResolveRunningImage $alias $diagnostic @($physical) $directories
    Test-Check (-not $resolution.listed -and -not $resolution.inEnumeration -and $resolution.resolvedPath -ceq $alias) 'Status does not infer identity from a similar Native path or image name'
    $identity.currentImagePath=$physical.nativePath;$identity.matchedImagePath=$physical.path
    $resolution=Cdf-ResolveRunningImage $alias $diagnostic @() $directories
    Test-Check (-not $resolution.listed -and $resolution.inEnumeration -and $resolution.resolvedPath -ceq $probe) 'Status does not relist a removed identity from an old matched snapshot'
    $unknown=Join-Path $run 'unknown.exe'
    $resolution=Cdf-ResolveRunningImage $unknown $withoutProvider @($physical) $directories
    Test-Check (-not $resolution.listed -and $resolution.inEnumeration) 'Status preserves unregistered candidates within configured roots'
    foreach($dir in @((Split-Path -Parent $root),$root,(Split-Path -Parent $context.Manifest))){Cdf-SecureDirectory $dir}
    Test-Probe $probe absent 'unregistered baseline'
    foreach($name in @('CdfClaudeGateProbe64.exe','CdfClaudeGateOther64.exe')){if((Test-Registry $name) -cne 'null'){throw "Preexisting test IFEO: $name"}}
    $key=$ifeo.CreateSubKey('CdfClaudeGateProbe64.exe');$key.SetValue('GlobalFlag','0x08000000',[Microsoft.Win32.RegistryValueKind]::String);$key.SetValue('VerifierFlags',0,[Microsoft.Win32.RegistryValueKind]::DWord);$key.SetValue('CdfFixture',[byte[]](1,2,3),[Microsoft.Win32.RegistryValueKind]::Binary);$key.Dispose()
    $baselineRegistry=Test-Registry 'CdfClaudeGateProbe64.exe'
    foreach($field in @('Debugger','VerifierDlls','UseFilter')){
        $key=$ifeo.OpenSubKey('CdfClaudeGateProbe64.exe',$true);$key.SetValue($field,'fixture',[Microsoft.Win32.RegistryValueKind]::String);$key.Dispose()
        try{Test-Reject {Invoke-CdfClaudeManager $context Enable} ('*Existing '+$field+'*') ('preflight refuses '+$field)}finally{$key=$ifeo.OpenSubKey('CdfClaudeGateProbe64.exe',$true);$key.DeleteValue($field);$key.Dispose()}
    }
    $signature=$context.Signature;$context.Signature={param($path)[pscustomobject]@{status='NotSigned';signer=''}}
    $denied=$false;try{Invoke-CdfClaudeManager $context Enable|Out-Null}catch{$denied=$_.Exception.Message -like '*main image validation failed*'}
    Test-Check $denied 'main signature mismatch rejects entire batch';$context.Signature=$signature
    $context.Signature=$null
    Test-Reject {Invoke-CdfClaudeManager $context Enable} '*main image validation failed*' 'real Authenticode rejects unsigned main fixture'
    $context.Signature=$signature
    $context.Fault={param($writes)if($writes -eq 4){throw 'Simulated interrupted batch'}}
    $rolledBack=$false;try{Invoke-CdfClaudeManager $context Enable|Out-Null}catch{$rolledBack=$_.Exception.Message -like '*rolled back*';if(-not $rolledBack){throw}}
    Test-Check $rolledBack 'failure midway through two-image batch rolls back all changes';$context.Fault=$null
    Test-Check (-not(Test-Path -LiteralPath $context.State) -and -not(Test-Path -LiteralPath $context.Pending)) 'rollback restores state and removes journal'
    Test-Check ((Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $baselineRegistry -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq 'null') 'batch rollback restores original types values and key existence'
    Test-Probe $probe absent 'baseline after rollback'
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\claude_transaction_worker.ps1') -Project (Split-Path -Parent $PSScriptRoot) -Root $root -Manifest $context.Manifest -SourceDll $context.SourceDll -Probe $probe -Second $second
    Test-Check ($LASTEXITCODE -eq 87 -and (Test-Path -LiteralPath $context.Pending)) 'abrupt manager termination leaves a recoverable journal'
    Invoke-CdfClaudeManager $context Disable|Out-Null
    Test-Check ((Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $baselineRegistry -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq 'null' -and -not(Test-Path -LiteralPath $context.Pending)) 'next Disable recovers an interrupted two-image transaction'
    $status=Invoke-CdfClaudeManager $context Enable
    Test-Check ($status.enabled -and $status.images.Count -eq 2 -and $status.skipped.Count -eq 3) 'valid signer included; unsigned wrong signer and query error skipped'
    $originalState=Cdf-Hash $context.State;$status=Invoke-CdfClaudeManager $context Enable
    Test-Check ((Cdf-Hash $context.State) -ceq $originalState) 'repeat enable preserves first restoration record'
    Test-Probe $probe match 'TLS and main ready after identity match' matched
    Test-Probe $second match 'second image TLS and main ready after identity match' matched
    Test-Probe $other deny 'same image name at another path passes through' image-not-listed
    $deniedIdentity=& (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\gate_denied_identity.ps1') -Image $other -OutputPath (Join-Path $run 'denied-identity.json')
    Test-Check $deniedIdentity.passed 'file identity query denied before TLS safely passes through'
    $savedManifest=[IO.File]::ReadAllBytes($context.Manifest)
    $m=Get-Content -Raw -LiteralPath $context.Manifest|ConvertFrom-Json;foreach($i in $m.images){$i.fileId='00000000000000000000000000000000'};Cdf-Save $context.Manifest $m
    Test-Probe $probe deny 'file ID mismatch passes through' file-identity-mismatch
    [IO.File]::WriteAllBytes($context.Manifest,$savedManifest)
    $m=Get-Content -Raw -LiteralPath $context.Manifest|ConvertFrom-Json;$m.images[0].volumeSerial='0000000000000000';Cdf-Save $context.Manifest $m
    Test-Probe $second deny 'volume mismatch passes through' file-identity-mismatch
    [IO.File]::WriteAllBytes($context.Manifest,$savedManifest)
    $m=Get-Content -Raw -LiteralPath $context.Manifest|ConvertFrom-Json;foreach($i in $m.images){$i.lastWriteTimeUtcTicks+=1};Cdf-Save $context.Manifest $m
    Test-Probe $probe deny 'write timestamp mismatch passes through' file-identity-mismatch
    [IO.File]::WriteAllBytes($context.Manifest,$savedManifest)
    $m=Get-Content -Raw -LiteralPath $context.Manifest|ConvertFrom-Json;foreach($i in $m.images){$i.size+=1};Cdf-Save $context.Manifest $m
    Test-Probe $probe deny 'size mismatch passes through' file-identity-mismatch
    [IO.File]::WriteAllBytes($context.Manifest,$savedManifest)
    [IO.File]::WriteAllText($context.Manifest,'{"schemaVersion":1,}',[Text.UTF8Encoding]::new($false))
    Test-Probe $probe deny 'damaged manifest passes through' manifest-invalid
    Test-Reject {Invoke-CdfClaudeManager $context Disable} '*Managed manifest/provider changed externally*' 'external manifest change blocks removal and preserves recovery'
    [IO.File]::Delete($context.Manifest)
    Test-Probe $probe deny 'missing manifest passes through' manifest-missing
    [IO.File]::WriteAllBytes($context.Manifest,$savedManifest)
    $validText=[Text.Encoding]::UTF8.GetString($savedManifest)
    foreach($bad in @($validText.Replace('"schemaVersion": 1','"schemaVersion": 1, "schemaVersion": 1'),$validText.Replace('"schemaVersion": 1','"schemaVersion": 01'),$validText.Replace('"schemaVersion": 1','"schemaVersion": 9223372036854775808'),($validText+'[]'),$validText.Replace('"signer": "Anthropic, PBC"','"signer": "Other Publisher"'))){
        [IO.File]::WriteAllText($context.Manifest,$bad,[Text.UTF8Encoding]::new($false));Test-Probe $probe deny 'strict manifest grammar rejects malformed identity' manifest-invalid
    }
    [IO.File]::WriteAllBytes($context.Manifest,$savedManifest)
    $savedManifest=$null
    for($i=0;$i -lt 10;++$i){Test-Probe $probe match ('repeat first name '+$i) matched;Test-Probe $second match ('repeat second name '+$i) matched}
    $key=$ifeo.OpenSubKey('CdfClaudeGateOther64.exe',$true);$key.SetValue('VerifierFlags',2,[Microsoft.Win32.RegistryValueKind]::DWord);$key.Dispose()
    try{
        Test-Reject {Invoke-CdfClaudeManager $context Disable} '*External IFEO conflict*' 'external change blocks entire disable batch'
        Test-Check ((Cdf-Hash $context.State) -ceq $originalState -and (Test-Registry 'CdfClaudeGateProbe64.exe') -like '*VerifierDlls*') 'conflict preserves all restoration records and other registrations'
    }finally{$key=$ifeo.OpenSubKey('CdfClaudeGateOther64.exe',$true);$key.SetValue('VerifierFlags',[int]::MinValue,[Microsoft.Win32.RegistryValueKind]::DWord);$key.Dispose()}
    $status=Invoke-CdfClaudeManager $context Status;Test-Check (-not $status.stale -and -not $status.issues.Count) 'status validates file IDs and registry'
    [IO.File]::Move($second,($second+'.previous'));[IO.File]::Copy($probe,$second)
    Test-Probe $second deny 'updated file at same path passes through before refresh' file-identity-mismatch
    $status=Invoke-CdfClaudeManager $context Status;Test-Check $status.stale 'status detects Store-style file replacement'
    Invoke-CdfClaudeManager $context Enable|Out-Null
    Test-Probe $second match 'repeat Enable revalidates and refreshes file identity' matched
    $package.files=@($probe,$fake1,$fake2,$fake3)
    Invoke-CdfClaudeManager $context Enable|Out-Null
    Test-Probe $second absent 'removed package image restores its IFEO immediately'
    Test-Check ((Test-Registry 'CdfClaudeGateOther64.exe') -ceq 'null') 'update deletes only its empty newly created IFEO key'
    Invoke-CdfClaudeManager $context Disable|Out-Null
    Test-Probe $probe absent 'disabled baseline'
    Test-Probe $second absent 'second name disabled baseline'
    Test-Check ((Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $baselineRegistry -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq 'null') 'disable restores exact original registry values and key existence'
    Invoke-CdfClaudeManager $context Disable|Out-Null
    Test-Check (-not(Test-Path -LiteralPath $context.State) -and -not(Test-Path -LiteralPath $context.Pending)) 'repeat disable is idempotent'

    # Reconcile values already returned to the recorded baseline without
    # accepting a third value, debugger, or path filter as a safe restoration.
    $package.files=@($probe,$second,$fake1,$fake2,$fake3)
    Invoke-CdfClaudeManager $context Enable|Out-Null
    $recovery=Get-Content -LiteralPath $context.State -Raw|ConvertFrom-Json
    $recoveryHash=Cdf-Hash $context.State
    foreach($image in $recovery.images){Test-SetRegistryValues $image.name $image.originalValues}
    $ifeo.DeleteSubKey('CdfClaudeGateOther64.exe',$false)
    Test-Reject {Invoke-CdfClaudeManager $context Enable} '*External IFEO conflict*' 'enable refuses externally removed registration until disable reconciles it'
    foreach($guard in @('Debugger','UseFilter')){
        $key=$ifeo.OpenSubKey('CdfClaudeGateProbe64.exe',$true)
        if($guard -eq 'Debugger'){$key.SetValue($guard,'fixture',[Microsoft.Win32.RegistryValueKind]::String)}else{$key.SetValue($guard,0,[Microsoft.Win32.RegistryValueKind]::DWord)}
        $key.Dispose()
        try{Test-Reject {Invoke-CdfClaudeManager $context Disable} '*External debugger/filter conflict*' ('baseline reconciliation still refuses '+$guard)}finally{$key=$ifeo.OpenSubKey('CdfClaudeGateProbe64.exe',$true);$key.DeleteValue($guard);$key.Dispose()}
    }
    $key=$ifeo.OpenSubKey('CdfClaudeGateProbe64.exe',$true);$child=$key.CreateSubKey('CdfFixtureFilter');$child.Dispose();$key.Dispose()
    try{Test-Reject {Invoke-CdfClaudeManager $context Disable} '*External debugger/filter conflict*' 'baseline reconciliation still refuses IFEO filter subkeys'}finally{$key=$ifeo.OpenSubKey('CdfClaudeGateProbe64.exe',$true);$key.DeleteSubKey('CdfFixtureFilter',$false);$key.Dispose()}
    Test-Check ((Cdf-Hash $context.State) -ceq $recoveryHash -and (Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $baselineRegistry -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq 'null') 'rejected reconciliation preserves all records and original registry types'
    Invoke-CdfClaudeManager $context Disable|Out-Null
    Test-Check (-not(Test-Path -LiteralPath $context.State) -and -not(Test-Path -LiteralPath $context.Pending) -and (Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $baselineRegistry -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq 'null') 'disable reconciles fully restored values and an already missing key'

    # A failed or interrupted disable must restore its actual mixed starting
    # values, including a missing VerifierFlags, rather than reinstalling them.
    Invoke-CdfClaudeManager $context Enable|Out-Null
    $recoveryHash=Cdf-Hash $context.State
    $key=$ifeo.OpenSubKey('CdfClaudeGateProbe64.exe',$true);$key.SetValue('GlobalFlag','0x08000000',[Microsoft.Win32.RegistryValueKind]::String);$key.Dispose()
    $key=$ifeo.OpenSubKey('CdfClaudeGateOther64.exe',$true);$key.DeleteValue('VerifierFlags');$key.Dispose()
    $mixedFirst=Test-Registry 'CdfClaudeGateProbe64.exe';$mixedSecond=Test-Registry 'CdfClaudeGateOther64.exe'
    $key=$ifeo.OpenSubKey('CdfClaudeGateOther64.exe',$true);$key.SetValue('VerifierFlags','0',[Microsoft.Win32.RegistryValueKind]::String);$key.Dispose()
    try{Test-Reject {Invoke-CdfClaudeManager $context Disable} '*External IFEO conflict*' 'partial restoration refuses an external value with a different registry type'}finally{$key=$ifeo.OpenSubKey('CdfClaudeGateOther64.exe',$true);$key.DeleteValue('VerifierFlags');$key.Dispose()}
    Test-Check ((Cdf-Hash $context.State) -ceq $recoveryHash -and (Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $mixedFirst -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq $mixedSecond) 'partial conflict causes no writes to the rest of the batch'
    $context.Fault={param($writes)if($writes -eq 2){throw 'Simulated partial disable failure'}}
    try{Test-Reject {Invoke-CdfClaudeManager $context Disable} '*Transaction rolled back: Simulated partial disable failure*' 'partial disable failure is rolled back'}finally{$context.Fault=$null}
    Test-Check ((Cdf-Hash $context.State) -ceq $recoveryHash -and -not(Test-Path -LiteralPath $context.Pending) -and (Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $mixedFirst -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq $mixedSecond) 'rollback restores the exact mixed snapshot without recreating missing values'
    $worker=Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\claude_transaction_worker.ps1'
    & (Get-Process -Id $PID).Path -NoProfile -File $worker -Project (Split-Path -Parent $PSScriptRoot) -Root $root -Manifest $context.Manifest -SourceDll $context.SourceDll -Probe $probe -Second $second -Action Disable
    Test-Check ($LASTEXITCODE -eq 87 -and (Test-Path -LiteralPath $context.Pending)) 'interrupted partial disable preserves its write-ahead journal'
    try{$context.Ifeo=$ifeo;Cdf-Recover $context}finally{$context.Ifeo=$null}
    Test-Check ((Cdf-Hash $context.State) -ceq $recoveryHash -and -not(Test-Path -LiteralPath $context.Pending) -and (Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $mixedFirst -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq $mixedSecond) 'interrupted recovery restores exact starting values and records'
    Invoke-CdfClaudeManager $context Disable|Out-Null
    Test-Check (-not(Test-Path -LiteralPath $context.State) -and -not(Test-Path -LiteralPath $context.Pending) -and (Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $baselineRegistry -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq 'null') 'partial restoration completes disable and preserves unrelated registry data'

    # Configurable roots must keep the Store main required and apply the same
    # signature, architecture, file identity, and shared-name IFEO rules.
    $enumStore=Join-Path $run 'enum-store';$enumCache=Join-Path $run 'another-user 中文\Claude-3p'
    $enumOutside=Join-Path $run 'enum-outside';$enumConfig=Join-Path $run 'claude-targets.json'
    foreach($directory in @($enumStore,$enumCache,$enumOutside,(Join-Path $enumCache 'claude-code\1.0'),(Join-Path $enumCache 'claude-code\2.0'))){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    $enumMain=Join-Path $enumStore 'CdfClaudeGateProbe64.exe';Copy-Item -LiteralPath $probe -Destination $enumMain
    $enumCode=Join-Path $enumCache 'claude-code\1.0\CdfClaudeGateProbe64.exe';Copy-Item -LiteralPath $probe -Destination $enumCode
    $enumNext=Join-Path $enumCache 'claude-code\2.0\CdfClaudeGateProbe64.exe';Copy-Item -LiteralPath $probe -Destination $enumNext
    $enumHelper=Join-Path $enumCache 'CdfClaudeGateOther64.exe';Copy-Item -LiteralPath $probe -Destination $enumHelper
    $outsideHelper=Join-Path $enumOutside 'CdfClaudeGateOther64.exe';Copy-Item -LiteralPath $probe -Destination $outsideHelper
    foreach($name in @('CdfClaudeUnsigned64.exe','CdfClaudeWrongSigner64.exe','CdfClaudeSigError64.exe')){Copy-Item -LiteralPath $probe -Destination (Join-Path $enumCache $name)}
    $enumPackage=[pscustomobject]@{root=$enumStore;packageId='fixture_1.0.0.0_x64__fnn82j28hfe8t';main=$enumMain;services=@();files=@($enumMain)}
    $context.Discover={$enumPackage}.GetNewClosure();$context.EnumerationConfigPath=$enumConfig
    Cdf-Save $enumConfig ([ordered]@{schemaVersion=1;imageDirectories=@('%CLAUDE_PACKAGE_ROOT%','%LOCALAPPDATA%\Claude-3p','%localappdata%\Claude-3p\')})
    $resolved=Cdf-Enumeration $context $enumPackage
    Test-Check ($resolved.directories.Count -eq 2 -and $resolved.directories[1].path -ieq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Claude-3p')) 'known-folder variables resolve the current user and duplicate roots are removed'
    Test-Check ((Cdf-PathInEnumeration (Join-Path $enumCache 'x.exe') @([pscustomobject]@{path=$enumCache})) -and -not(Cdf-PathInEnumeration ($enumCache+'-outside\x.exe') @([pscustomobject]@{path=$enumCache}))) 'directory matching respects path component boundaries'
    $programFiles=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'
    Cdf-Save $enumConfig ([ordered]@{schemaVersion=1;imageDirectories=@('%CLAUDE_PACKAGE_ROOT%','%ProgramFiles%\WindowsApps','%programfiles%\WindowsApps\')})
    $resolved=Cdf-Enumeration $context $enumPackage
    Test-Check ($resolved.directories.Count -eq 2 -and $resolved.directories[1].path -ieq $programFiles) 'ProgramFiles resolves the x64 known folder and ignores variable case and duplicate trailing separators'
    Cdf-Save $enumConfig ([ordered]@{schemaVersion=1;imageDirectories=@('%CLAUDE_PACKAGE_ROOT%','%ProgramFiles%\WindowsApps',$programFiles)})
    $resolved=Cdf-Enumeration $context $enumPackage
    Test-Check ($resolved.directories.Count -eq 2) 'ProgramFiles and the matching absolute WindowsApps path share one enumeration root'
    $savedProgramFiles=[Environment]::GetEnvironmentVariable('ProgramFiles','Process')
    try{
        [Environment]::SetEnvironmentVariable('ProgramFiles',(Join-Path $run 'spoofed-program-files'),'Process')
        $resolved=Cdf-Enumeration $context $enumPackage
        Test-Check ($resolved.directories[1].path -ieq $programFiles) 'ProgramFiles uses the Windows known folder rather than a process environment override'
    }finally{[Environment]::SetEnvironmentVariable('ProgramFiles',$savedProgramFiles,'Process')}
    foreach($invalid in @(
        '{"schemaVersion":1,"schemaVersion":1,"imageDirectories":["%CLAUDE_PACKAGE_ROOT%"]}',
        '{"schemaVersion":2,"imageDirectories":["%CLAUDE_PACKAGE_ROOT%"]}',
        '{"schemaVersion":1,"imageDirectories":["%CLAUDE_PACKAGE_ROOT%"],"unknown":true}',
        '{"schemaVersion":1,"imageDirectories":"%CLAUDE_PACKAGE_ROOT%"}',
        '{"schemaVersion":1,"imageDirectories":["%CLAUDE_PACKAGE_ROOT%","%UNKNOWN_FOLDER%"]}',
        '{"schemaVersion":1,"imageDirectories":["relative-folder"]}',
        '{"schemaVersion":1,"imageDirectories":["%CLAUDE_PACKAGE_ROOT%","C:\\"]}',
        '{"schemaVersion":1,"imageDirectories":["%CLAUDE_PACKAGE_ROOT%","C:\\wildcard*"]}',
        '{"schemaVersion":1,"imageDirectories":[]}',
        '{"schemaVersion":1,"imageDirectories":["%LOCALAPPDATA%\\Claude-3p"]}'
    )){
        [IO.File]::WriteAllText($enumConfig,$invalid,[Text.UTF8Encoding]::new($false))
        Test-Reject {Cdf-Enumeration $context $enumPackage} '*' 'invalid enumeration configuration is rejected before deployment'
    }
    $enumSettings=[ordered]@{schemaVersion=1;imageDirectories=@('%CLAUDE_PACKAGE_ROOT%',$enumCache,(Join-Path $run 'optional-missing'))}
    Cdf-Save $enumConfig $enumSettings
    $link=Join-Path $enumCache 'linked-outside';New-Item -ItemType Junction -Path $link -Target $enumOutside|Out-Null
    try{
        $found=Cdf-DiscoverImages $context
        Test-Check ($found.images.Count -eq 4 -and @($found.skipped|Where-Object reason -eq 'signature-mismatch').Count -eq 2 -and @($found.skipped|Where-Object reason -eq 'reparse-entry').Count -eq 1) 'configured roots recurse and enforce signatures while skipping junctions'
        Test-Check (@($found.enumeration.directories|Where-Object {-not $_.exists}).Count -eq 1) 'missing optional directories are reported without breaking discovery'
    }finally{[IO.Directory]::Delete($link,$false)}
    $status=Invoke-CdfClaudeManager $context Enable
    Test-Check ($status.enabled -and $status.images.Count -eq 4 -and $status.enumeration.directories.Count -eq 3 -and -not $status.enumeration.changed) 'configured package and cache images share a transactional identity manifest'
    $configState=Get-Content -LiteralPath $context.State -Raw|ConvertFrom-Json
    Test-Check ($configState.images.Count -eq 2 -and $configState.enumerationConfigSha256 -ceq (Cdf-Hash $enumConfig)) 'same executable names share IFEO records while each path has its own identity'
    Test-Probe $enumMain match 'configured Store root TLS and main ready' matched
    Test-Probe $enumCode match 'configured cache root TLS and main ready' matched
    Test-Probe $enumNext match 'second cached version TLS and main ready' matched
    Test-Probe $enumHelper match 'configured cache helper TLS and main ready' matched
    Test-Probe $outsideHelper deny 'same executable outside all configured roots stays transparent' image-not-listed
    $unchanged=Cdf-Hash $context.State;Invoke-CdfClaudeManager $context Enable|Out-Null
    Test-Check ((Cdf-Hash $context.State) -ceq $unchanged) 'configured repeat Enable preserves recovery records'
    Cdf-Save $enumConfig ([ordered]@{schemaVersion=1;imageDirectories=@('%CLAUDE_PACKAGE_ROOT%')})
    $status=Invoke-CdfClaudeManager $context Status
    Test-Check ($status.enabled -and $status.enumeration.changed -and $status.refreshRequired) 'Status distinguishes edited enumeration policy from active registration'
    Invoke-CdfClaudeManager $context Enable|Out-Null
    Test-Probe $enumCode deny 'removing cache root revokes its identity for new processes' image-not-listed
    Test-Probe $enumHelper absent 'removing unique helper name restores its IFEO registration'
    Invoke-CdfClaudeManager $context Disable|Out-Null
    Test-Check ((Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $baselineRegistry -and (Test-Registry 'CdfClaudeGateOther64.exe') -ceq 'null') 'configured disable restores exact pre-test registry values'
    $context.EnumerationConfigPath=$null;$context.Discover={$package}.GetNewClosure()
}catch{$failure=$_.Exception.ToString()+"`n"+$_.ScriptStackTrace}finally{
    if($savedManifest -and (Test-Path -LiteralPath $context.State)){try{[IO.File]::WriteAllBytes($context.Manifest,$savedManifest)}catch{$cleanup+=$_.Exception.Message}}
    try{Invoke-CdfClaudeManager $context Disable|Out-Null}catch{$cleanup+=$_.Exception.Message}
    if($baselineRegistry -and (Test-Registry 'CdfClaudeGateProbe64.exe') -ceq $baselineRegistry){$ifeo.DeleteSubKey('CdfClaudeGateProbe64.exe',$false)}
    $ifeo.Dispose();$base.Dispose()
    $report=[pscustomobject]@{passed=($null -eq $failure -and $cleanup.Count -eq 0);failure=$failure;cleanupErrors=$cleanup;runDirectory=$run;cases=@($cases)}
    $report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $results 'claude-gate-integration.json') -Encoding utf8
}
if(-not $report.passed){throw "Claude gate integration failed: $failure; cleanup=$($cleanup -join '; ')"}
[pscustomobject]@{passed=$true;cases=$cases.Count}|ConvertTo-Json -Compress
