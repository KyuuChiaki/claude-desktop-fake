[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))

# Registration-only acceptance against the actual signed Store package. Never
# launch, stop or restart Claude or a service from this script.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$project=Split-Path -Parent $PSScriptRoot
$config=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2\timezone.json'
$status=& (Join-Path $PSScriptRoot 'Manage-Claude.ps1') -Action Status|ConvertFrom-Json
if($status.managed -or $status.pendingTransaction -or $status.issues.Count){throw 'Existing Claude management state; preserving it.'}
$state=Join-Path (Split-Path -Parent $config) 'state'
if(@(Get-ChildItem -LiteralPath $state -Filter '*.json' -ErrorAction SilentlyContinue).Count){throw 'Managed generic test images still use the shared configuration.'}
$run=Join-Path $BuildDirectory ('test-results\claude-runtime-registration-'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $run -Force)
$original=[IO.File]::ReadAllBytes($config);$originalHash=(Get-FileHash -LiteralPath $config).Hash
[IO.File]::WriteAllBytes((Join-Path $run 'original-timezone.json'),$original)
$source=Join-Path $project 'config\timezone.json'
$validation=& (Join-Path $BuildDirectory 'bin\CdfTimeRules64.exe') --validate-config $source
if($LASTEXITCODE -ne 0){throw 'Stage 5 registration configuration is invalid.'}
$expected=$originalHash;$failure=$null;$cleanup=@();$acceptance=$null
try{
    if((Get-FileHash -LiteralPath $config).Hash -cne $expected){throw 'External shared configuration change.'}
    [IO.File]::WriteAllBytes($config,[IO.File]::ReadAllBytes($source));$expected=(Get-FileHash -LiteralPath $config).Hash
    $null=& (Join-Path $PSScriptRoot 'Test-ClaudeRegistration.ps1') -BuildDirectory $BuildDirectory
    $acceptance=Get-Content -LiteralPath (Join-Path $BuildDirectory 'test-results\claude-registration.json') -Raw|ConvertFrom-Json
    if(-not $acceptance.passed){throw 'Public Stage 5 registration acceptance failed.'}
}catch{$failure=$_.Exception.ToString()+"`n"+$_.ScriptStackTrace}finally{
    try{
        $finalStatus=& (Join-Path $PSScriptRoot 'Manage-Claude.ps1') -Action Status|ConvertFrom-Json
        if($finalStatus.managed -or $finalStatus.pendingTransaction -or $finalStatus.issues.Count){throw 'Claude registration did not restore cleanly; preserving the temporary configuration and recovery material.'}
        if((Get-FileHash -LiteralPath $config).Hash -cne $expected){throw 'External shared configuration change; retaining restoration materials.'}
        [IO.File]::WriteAllBytes($config,$original)
        if((Get-FileHash -LiteralPath $config).Hash -cne $originalHash){throw 'Original configuration restoration failed.'}
    }catch{$cleanup+=$_.Exception.Message}
    $report=[pscustomobject]@{passed=($null -eq $failure -and -not $cleanup.Count);failure=$failure;cleanupErrors=$cleanup;configurationRestored=($cleanup.Count -eq 0);originalConfigurationHash=$originalHash;acceptance=$acceptance;runDirectory=$run;scope='Actual Store package registration only; no application or service lifecycle operations'}
    $report|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $BuildDirectory 'test-results\claude-runtime-registration.json') -Encoding utf8
}
if(-not $report.passed){throw "Stage 5 Claude registration failed: $failure; cleanup=$($cleanup -join '; '); evidence=$run"}
$report|Select-Object passed,configurationRestored,runDirectory|ConvertTo-Json
