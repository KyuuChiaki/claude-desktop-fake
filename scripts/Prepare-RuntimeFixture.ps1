[CmdletBinding()]
param([string]$Version='44.9.3')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid Electron version.'}
$projectRoot=Split-Path -Parent $PSScriptRoot
$cache=Join-Path $projectRoot 'out\dependencies';[void](New-Item -ItemType Directory -Path $cache -Force)
$name="electron-v$Version-win32-x64.zip";$archive=Join-Path $cache $name
$base="https://github.com/electron/electron/releases/download/v$Version"
$checksums=(Invoke-WebRequest -Uri "$base/SHASUMS256.txt" -TimeoutSec 40).Content
if($checksums -is [byte[]]){$checksums=[Text.Encoding]::UTF8.GetString($checksums)}
$pattern='(?m)^([a-fA-F0-9]{64})\s+\*?'+[regex]::Escape($name)+'\s*$'
$m=[regex]::Match([string]$checksums,$pattern)
if(-not $m.Success){throw 'Release SHA-256 was not found.'}
$expected=$m.Groups[1].Value
if(-not(Test-Path -LiteralPath $archive)){
    $partial=$archive+'.partial'
    try{Invoke-WebRequest -Uri "$base/$name" -OutFile $partial -TimeoutSec 300;if((Get-FileHash -LiteralPath $partial).Hash -ine $expected){throw 'Electron archive hash mismatch.'};[IO.File]::Move($partial,$archive)}finally{if(Test-Path -LiteralPath $partial){[IO.File]::Delete($partial)}}
}
if((Get-FileHash -LiteralPath $archive).Hash -ine $expected){throw 'Cached Electron archive hash mismatch.'}
$destination=Join-Path $projectRoot "out\runtime-fixtures\electron-$Version"
if(-not(Test-Path -LiteralPath $destination)){
    [IO.Compression.ZipFile]::ExtractToDirectory($archive,$destination)
    [IO.File]::Move((Join-Path $destination 'electron.exe'),(Join-Path $destination 'CdfElectronProbe64.exe'))
}
$record=[ordered]@{version=$Version;source="$base/$name";checksumSource="$base/SHASUMS256.txt";archiveSha256=$expected;fixture=$destination;scope='Official matching-version Electron isolated fixture; not a Claude application runtime acceptance'}
$record|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $destination 'cdf-fixture.json') -Encoding utf8
$record|ConvertTo-Json
