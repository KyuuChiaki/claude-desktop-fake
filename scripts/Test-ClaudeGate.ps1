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
