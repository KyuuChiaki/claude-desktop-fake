[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Runtime-Profiles.ps1')
$project=Split-Path -Parent $PSScriptRoot;$source=Join-Path $project 'profiles\runtime-adapters.json'
$image=Join-Path $project 'out\runtime-fixtures\electron-44.9.3\CdfElectronProbe64.exe'
$originalHash=(Get-FileHash -LiteralPath $source).Hash
$run=Join-Path $BuildDirectory ('test-results\runtime-profile-preflight-'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $run -Force)
$cases=[Collections.Generic.List[object]]::new()
$known=Get-CdfRuntimeProfile $image
if(-not $known.supported){throw 'Known official runtime profile did not pass preflight.'}
$cases.Add([pscustomobject]@{label='known fingerprint and complete expected-instruction set';passed=$true;profile=$known})
foreach($fault in @('instructions','windows-build')){
    $catalog=Get-Content -LiteralPath $source -Raw|ConvertFrom-Json
    if($fault -eq 'instructions'){
        $catalog.abis[0].sites[0].bytes='00'+$catalog.abis[0].sites[0].bytes.Substring(2)
        $reason='catalogue-build-mismatch'
    }else{$catalog.windowsBuild=1;$reason='catalogue-build-mismatch'}
    $temporary=Join-Path $run ($fault+'.catalog.json')
    $catalog|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $temporary -Encoding utf8
    $result=Get-CdfRuntimeProfile -Path $image -CatalogPath $temporary
    if($result.supported -or $result.reason -cne $reason){throw "Preflight accepted incompatible $fault profile."}
    $cases.Add([pscustomobject]@{label=$fault;passed=$true;reason=$result.reason;profile=$result})
}
if((Get-FileHash -LiteralPath $source).Hash -cne $originalHash){throw 'Source profile catalogue changed unexpectedly.'}
$cases.Add([pscustomobject]@{label='original catalogue and vendor executable preserved';passed=$true})
$report=[pscustomobject]@{passed=$true;scope='Read-only runtime preflight with isolated negative catalogues; no registry or process lifecycle operations';cases=@($cases);caseCount=$cases.Count;runDirectory=$run}
$report|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $BuildDirectory 'test-results\runtime-profile-preflight.json') -Encoding utf8
$report|Select-Object passed,caseCount,runDirectory|ConvertTo-Json
