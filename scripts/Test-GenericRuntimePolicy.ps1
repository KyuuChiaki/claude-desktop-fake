[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$project=Split-Path -Parent $PSScriptRoot;$common=[Environment]::GetFolderPath('CommonApplicationData')
$root=Join-Path $common 'ClaudeDesktopFake\stage2';$config=Join-Path $root 'timezone.json';$deployment=Join-Path $root 'deployment.json'
$manager=Join-Path $PSScriptRoot 'Manage-TimeZone.ps1';$image='CdfRuntimeGeneric64.exe'
$source=Join-Path $project 'out\runtime-fixtures\electron-44.9.3\CdfElectronProbe64.exe'
$copy=Join-Path (Split-Path -Parent $source) $image;$marker=$copy+'.cdf-copy.json'
$dll=Join-Path $BuildDirectory 'bin\CdfTimeZone64.dll'
if((Get-FileHash -LiteralPath $dll).Hash -cne (Get-FileHash -LiteralPath (Join-Path $env:WINDIR 'System32\CdfTimeZone64.dll')).Hash){throw 'Run the ordinary generic provider regression first so the shared deployment already matches this build.'}
if((& $manager -Action Status -ImageName $image|ConvertFrom-Json).managed){throw 'Existing generic runtime policy registration; preserving it.'}
if(@(Get-ChildItem -LiteralPath (Join-Path $root 'state') -Filter '*.json').Count){throw 'Other registered generic tests still use the shared deployment.'}
$original=[IO.File]::ReadAllBytes($config);$oldDeployment=[IO.File]::ReadAllBytes($deployment)
$configHash=(Get-FileHash -LiteralPath $config).Hash;$deploymentHash=(Get-FileHash -LiteralPath $deployment).Hash
$expectedConfig=$configHash;$expectedDeployment=$deploymentHash
$run=Join-Path $BuildDirectory ('test-results\runtime-generic-policy-'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $run -Force)
[IO.File]::WriteAllBytes((Join-Path $run 'original-timezone.json'),$original)
[IO.File]::WriteAllBytes((Join-Path $run 'original-deployment.json'),$oldDeployment)
$checks=[Collections.Generic.List[string]]::new();$failure=$null;$cleanup=@();$installed=$false
function Check([bool]$Value,[string]$Label){if(-not $Value){throw "Assertion failed: $Label"};$checks.Add($Label)}
function Run([string]$Label){
    $output=Join-Path $run ($Label+'.json');$null=& (Join-Path $PSScriptRoot 'Invoke-RuntimeFixture.ps1') -ReportPath $output -ImageName $image
    $observation=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
    Check $observation.native.contracts.passed ($Label+' dynamic WinRT, Native resolver and process contracts')
    [pscustomobject]@{observation=$observation;reference=(Get-Content -LiteralPath ($output+'.controller.json') -Raw|ConvertFrom-Json)}
}
try{
    if(Test-Path -LiteralPath $copy){
        if(-not(Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json).sha256 -cne (Get-FileHash -LiteralPath $copy).Hash){throw 'Unowned generic runtime fixture copy.'}
    }
    Copy-Item -LiteralPath $source -Destination $copy -Force
    $file=[IO.File]::Open($copy,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite)
    try{$offset=0x53b6cc0-0x1000+0x600+16;$file.Position=$offset;$value=$file.ReadByte();$file.Position=$offset;$file.WriteByte($value -bxor 1)}finally{$file.Dispose()}
    @{sha256=(Get-FileHash -LiteralPath $copy).Hash;source=$source}|ConvertTo-Json|Set-Content -LiteralPath $marker -Encoding utf8
    $baseline=Run baseline
    $sourceConfig=Join-Path $run 'unknown-block.config.json'
    @{schemaVersion=3;time=@{enabled=$true;timeZoneId='Eastern Standard Time';utcOffsetSeconds=3600};locale=@{enabled=$true;formatLocale='de-DE';uiLanguage='ja-JP'};region=@{enabled=$true;homeRegion='DE'};runtime=@{enabled=$true;unknownVersionPolicy='block';captureEnabled=$false}}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $sourceConfig -Encoding utf8
    $null=& $manager -Action Install -ImageName $image -DllPath $dll -ConfigPath $sourceConfig
    $installed=$true;$expectedConfig=(Get-FileHash -LiteralPath $config).Hash;$expectedDeployment=(Get-FileHash -LiteralPath $deployment).Hash
    $sample=Run unknown-block-generic;$o=$sample.observation;$reference=$sample.reference
    Check ($o.native.runtime.state -eq 32 -and $o.native.runtime.patchCount -eq 0 -and $o.native.runtime.error -eq 1306) 'unknown generic runtime passes through even with requested block policy'
    Check ($o.main.now -ge $reference.utcStartMs -and $o.main.now -le $reference.utcEndMs) 'generic failure restores real UTC'
    Check ($o.main.intlDate.locale -ceq $baseline.observation.main.intlDate.locale -and $o.renderer.intlDate.locale -ceq $baseline.observation.renderer.intlDate.locale) 'generic failure restores main and renderer locale'
    Check ($o.native.geoName -ceq $baseline.observation.native.geoName -and $o.native.winrtHomeRegion -ceq $baseline.observation.native.winrtHomeRegion) 'generic failure restores Win32 and WinRT geography'
    $null=& $manager -Action Uninstall -ImageName $image;$installed=$false
    $restored=Run restored;Check (-not $restored.observation.native.PSObject.Properties['runtime']) 'generic IFEO removal restores the unloaded baseline'
}catch{$failure=$_.Exception.ToString()+"`n"+$_.ScriptStackTrace}finally{
    if($installed){try{$null=& $manager -Action Uninstall -ImageName $image;$installed=$false}catch{$cleanup+=$_.Exception.Message}}
    try{
        if($installed -or (Get-FileHash -LiteralPath $config).Hash -cne $expectedConfig -or (Get-FileHash -LiteralPath $deployment).Hash -cne $expectedDeployment){throw 'External deployment/configuration change or incomplete unregister; preserving recovery material.'}
        [IO.File]::WriteAllBytes($config,$original);[IO.File]::WriteAllBytes($deployment,$oldDeployment)
        if((Get-FileHash -LiteralPath $config).Hash -cne $configHash -or (Get-FileHash -LiteralPath $deployment).Hash -cne $deploymentHash){throw 'Generic policy configuration restoration mismatch.'}
    }catch{$cleanup+=$_.Exception.Message}
    $report=[pscustomobject]@{passed=($null -eq $failure -and -not $cleanup.Count);failure=$failure;cleanupErrors=$cleanup;cases=@($checks);caseCount=$checks.Count;runDirectory=$run;scope='Unknown official Electron copy under the generic test provider; proves startup blocking is exclusive to identity-gated providers'}
    $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $BuildDirectory 'test-results\runtime-generic-policy.json') -Encoding utf8
}
if(-not $report.passed){throw "Generic runtime policy failed: $failure; cleanup=$($cleanup -join '; '); evidence=$run"}
$report|Select-Object passed,caseCount,runDirectory|ConvertTo-Json
