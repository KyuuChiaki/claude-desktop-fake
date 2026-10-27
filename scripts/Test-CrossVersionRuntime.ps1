[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),[ValidateRange(1,20)][int]$Iterations=10)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Runtime-Profiles.ps1')
$project=Split-Path -Parent $PSScriptRoot;$cases=@();$failure=$null
try{
    foreach($version in @('44.9.2','44.8.0')){
        $image=Join-Path $project ('out\runtime-fixtures\electron-'+$version+'\CdfElectronProbe64.exe')
        $profile=Get-CdfRuntimeProfile -Path $image
        if(-not $profile.supported){throw "Runtime $version is incompatible: $($profile.reason)"}
        $null=& (Join-Path $PSScriptRoot 'Test-Runtime.ps1') -BuildDirectory $BuildDirectory -FixtureVersion $version -Iterations $Iterations -Capture:([bool]$profile.captureReady)
        $evidence=Join-Path $BuildDirectory ('test-results\runtime-integration-'+$version+'.json')
        $result=Get-Content -LiteralPath $evidence -Raw|ConvertFrom-Json
        if(-not $result.passed -or $result.cases.Count -ne 6){throw "Runtime $version did not complete the six-case matrix."}
        $cases+=[pscustomobject]@{version=$version;profile=$profile;passed=$result.passed;assertions=$result.assertions;capture=$result.capture;runDirectory=$result.runDirectory;report=$evidence}
    }
}catch{$failure=$_.Exception.ToString()+"`n"+$_.ScriptStackTrace}finally{
    $report=[pscustomobject]@{passed=($null -eq $failure -and $cases.Count -eq 2);failure=$failure;cases=$cases;scope='Two additional official Electron versions; serial IFEO/shared configuration tests; no real Claude lifecycle actions'}
    $report|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $BuildDirectory 'test-results\runtime-cross-version.json') -Encoding utf8
}
if(-not $report.passed){throw "Cross-version runtime acceptance failed: $failure"}
$report|Select-Object passed,@{n='versions';e={$_.cases.version}},@{n='assertions';e={($_.cases|Measure-Object assertions -Sum).Sum}}|ConvertTo-Json
