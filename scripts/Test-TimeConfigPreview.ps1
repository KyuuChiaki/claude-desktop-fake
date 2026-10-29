[CmdletBinding()]
param([string]$BuildDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$project=Split-Path -Parent $PSScriptRoot
if(-not $BuildDirectory){$BuildDirectory=Join-Path $project 'out\build\x64-release'}
$directory=[IO.Path]::GetFullPath($BuildDirectory)
$validator=Join-Path $directory 'bin\CdfTimeRules64.exe'
$results=Join-Path $directory 'test-results'
[IO.Directory]::CreateDirectory($results)|Out-Null
$temporary=Join-Path $results ('time-preview-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary)|Out-Null
$source=Join-Path $temporary 'timezone.json'
$script:checks=0;$script:failures=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Label){$script:checks++;if(-not $Condition){$script:failures.Add($Label)}}
function Read-Preview([string]$Json){
    $value=$Json|ConvertFrom-Json
    foreach($match in [regex]::Matches($Json,'"(referenceUtc|virtualUtc|virtualLocalTime)"\s*:\s*"([^"]*)"')){
        $value.($match.Groups[1].Value)=$match.Groups[2].Value
    }
    return $value
}
function Write-Config([string]$Zone,[long]$Shift,[int]$Version=3,[bool]$Enabled=$true){
    $time=[ordered]@{enabled=$Enabled;timeZoneId=$Zone;utcOffsetSeconds=$Shift}
    $value=if($Version -eq 1){[ordered]@{schemaVersion=1;enabled=$Enabled;timeZoneId=$Zone;utcOffsetSeconds=$Shift}}else{
        $configuration=[ordered]@{schemaVersion=$Version;time=$time;locale=@{enabled=$true;formatLocale='en-US';uiLanguage='en-US'}}
        if($Version -eq 3){$configuration.region=@{enabled=$true;homeRegion='US'};$configuration.runtime=@{enabled=$true;unknownVersionPolicy='block';captureEnabled=$false}}
        $configuration
    }
    [IO.File]::WriteAllText($source,($value|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
}
try{
    $cases=@(
        @('Pacific Standard Time',0,'2026-10-29T12:00:00Z','2026-10-29T05:00:00.000-07:00',-25200,$true),
        @('Pacific Standard Time',0,'2026-01-15T12:00:00Z','2026-01-15T04:00:00.000-08:00',-28800,$false),
        @('Pacific Standard Time',0,'2026-03-08T09:59:59Z','2026-03-08T01:59:59.000-08:00',-28800,$false),
        @('Pacific Standard Time',0,'2026-03-08T10:00:00Z','2026-03-08T03:00:00.000-07:00',-25200,$true),
        @('Pacific Standard Time',0,'2026-11-01T08:59:59Z','2026-11-01T01:59:59.000-07:00',-25200,$true),
        @('Pacific Standard Time',0,'2026-11-01T09:00:00Z','2026-11-01T01:00:00.000-08:00',-28800,$false),
        @('Pacific Standard Time',3600,'2026-11-01T08:30:00Z','2026-11-01T01:30:00.000-08:00',-28800,$false),
        @('Pacific Standard Time',-3600,'2026-11-01T09:30:00Z','2026-11-01T01:30:00.000-07:00',-25200,$true),
        @('Eastern Standard Time',3600,'2026-10-29T12:00:00Z','2026-10-29T09:00:00.000-04:00',-14400,$true),
        @('India Standard Time',93600,'2024-02-28T22:00:00Z','2024-03-01T05:30:00.000+05:30',19800,$false),
        @('UTC',0,'2024-02-29T12:34:56.789Z','2024-02-29T12:34:56.789+00:00',0,$false),
        @('Pacific Standard Time',-25200,'2026-10-29T12:00:00Z','2026-10-28T22:00:00.000-07:00',-25200,$true)
    )
    $index=0
    foreach($case in $cases){
        Write-Config $case[0] $case[1] (1+$index%3)
        $before=(Get-FileHash -LiteralPath $source).Hash
        $preview=Read-Preview (& (Join-Path $project 'scripts\Show-TimeConfig.ps1') -BuildDirectory $directory -ConfigPath $source -ReferenceUtc $case[2])
        $reference=[DateTimeOffset]::ParseExact($case[2],[string[]]@('yyyy-MM-ddTHH:mm:ssZ','yyyy-MM-ddTHH:mm:ss.fffZ'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $expectedUtc=$reference.AddSeconds($case[1]).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ',[Globalization.CultureInfo]::InvariantCulture)
        Check ($preview.valid -and $preview.previewOnly -and $preview.timeEnabled) "case $index preview valid"
        Check ($preview.utcClockShiftSeconds -eq $case[1] -and $preview.virtualUtc -ceq $expectedUtc) "case $index applies clock shift exactly once"
        Check ($preview.virtualLocalTime -ceq $case[3] -and $preview.timeZoneOffsetSeconds -eq $case[4]) "case $index independent time-zone offset"
        Check ($preview.daylightSavingTime -eq $case[5]) "case $index DST determined by virtual UTC"
        Check ($preview.configVersion -eq (1+$index%3) -and $preview.configSha256 -ceq $before -and (Get-FileHash -LiteralPath $source).Hash -ceq $before) "case $index schema and read-only contract"
        $index++
    }
    Write-Config 'Pacific Standard Time' 0
    $now=Read-Preview (& $validator --preview-config $source)
    Check ($LASTEXITCODE -eq 0 -and $now.virtualUtc -ceq $now.referenceUtc -and $now.timeZoneOffsetSeconds -in @(-25200,-28800)) 'live zero shift retains UTC and computes Pacific bias'
    Write-Config 'Pacific Standard Time' 3600 3 $false
    $disabled=(& $validator --preview-config $source --reference-utc '2026-10-29T12:00:00Z')|ConvertFrom-Json
    Check ($LASTEXITCODE -eq 0 -and -not $disabled.timeEnabled -and $disabled.utcClockShiftSeconds -eq 3600 -and $null -eq $disabled.virtualUtc -and $null -eq $disabled.virtualLocalTime -and $null -eq $disabled.timeZoneOffsetSeconds -and $null -eq $disabled.daylightSavingTime) 'disabled feature does not report a virtual result'
    Write-Config 'UTC' 0
    foreach($invalid in @('2026-10-29T12:00:00','2026-10-29T12:00:00+00:00','2025-02-29T12:00:00Z','2026-13-01T00:00:00Z','2026-01-01T24:00:00Z','2026-01-01T00:00:60Z','2026-01-01T00:00:00z','not-a-date')){
        $raw=& $validator --preview-config $source --reference-utc $invalid
        $code=$LASTEXITCODE;$errorResult=$raw|ConvertFrom-Json
        Check ($code -ne 0 -and -not $errorResult.valid -and $errorResult.error -eq 87 -and $errorResult.errorStage -eq 'referenceUtc') "reject reference $invalid"
    }
    [IO.File]::WriteAllText($source,'{"schemaVersion":1,"enabled":true,"timeZoneId":"UTC"}')
    $raw=& $validator --preview-config $source
    $code=$LASTEXITCODE;$errorResult=$raw|ConvertFrom-Json
    Check ($code -ne 0 -and -not $errorResult.valid -and $errorResult.errorStage -eq 'configuration') 'clock shift is required, not an auto-offset placeholder'
    Write-Config 'America/Los_Angeles' 0
    $raw=& $validator --preview-config $source
    $code=$LASTEXITCODE;$errorResult=$raw|ConvertFrom-Json
    Check ($code -ne 0 -and -not $errorResult.valid) 'Windows time-zone ID remains required'
}catch{$script:failures.Add($_.ToString())}finally{
    if(Test-Path -LiteralPath $source){Remove-Item -LiteralPath $source}
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}
}
$report=[ordered]@{passed=($script:failures.Count -eq 0);checks=$script:checks;failures=@($script:failures)}
$json=$report|ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $results 'time-config-preview.json'),$json,[Text.UTF8Encoding]::new($false))
$json
if(-not $report.passed){throw 'Time configuration preview tests failed.'}
