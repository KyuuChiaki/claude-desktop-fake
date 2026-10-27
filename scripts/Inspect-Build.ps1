[CmdletBinding()]
param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PeInfo([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid DOS signature: $Path" }
        $stream.Position = 0x3C
        $pe = $reader.ReadUInt32()
        $stream.Position = $pe
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $Path" }
        $machine = $reader.ReadUInt16()
        $stream.Position = $pe + 22
        $characteristics = $reader.ReadUInt16()
        $optional = $pe + 24
        $stream.Position = $optional
        $magic = $reader.ReadUInt16()
        $stream.Position = $optional + 16
        $entry = $reader.ReadUInt32()
        $stream.Position = $optional + 112 + 8
        $importRva = $reader.ReadUInt32()
        $importSize = $reader.ReadUInt32()
        $stream.Position = $optional + 112 + 8 * 9
        $tlsRva = $reader.ReadUInt32()
        $tlsSize = $reader.ReadUInt32()
        $stream.Position = $optional + 112 + 8 * 13
        $delayImportRva = $reader.ReadUInt32()
        return [pscustomobject]@{
            path = $Path; machine = ('0x{0:X4}' -f $machine); pe32Plus = ($magic -eq 0x20B)
            isDll = (($characteristics -band 0x2000) -ne 0); entryRva = $entry
            importRva = $importRva; importSize = $importSize; delayImportRva = $delayImportRva
            tlsRva = $tlsRva; tlsSize = $tlsSize; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

$dll = Get-PeInfo (Join-Path $BuildDirectory 'bin\CdfBootstrap64.dll')
$probe = Get-PeInfo (Join-Path $BuildDirectory 'bin\CdfProbe64.exe')
if ($dll.machine -ne '0x8664' -or $probe.machine -ne '0x8664' -or -not $dll.pe32Plus -or -not $probe.pe32Plus) {
    throw 'Both artifacts must be AMD64 PE32+.'
}
if (-not $dll.isDll -or $probe.isDll -or $dll.entryRva -eq 0 -or $dll.importRva -ne 0 -or
    $dll.importSize -ne 0 -or $dll.delayImportRva -ne 0) {
    throw 'Bootstrap must be a DLL with a custom entry point and no imports or delayed imports.'
}
if ($probe.tlsRva -eq 0 -or $probe.tlsSize -eq 0) { throw 'The Probe TLS directory is missing.' }
$compilerRecord = Get-ChildItem -Path (Join-Path $BuildDirectory 'CMakeFiles\*\CMakeCXXCompiler.cmake') |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -eq $compilerRecord) { throw 'CMake compiler metadata is missing.' }
$compilerMatch = [regex]::Match((Get-Content -LiteralPath $compilerRecord.FullName -Raw),
    '(?m)^set\(CMAKE_CXX_COMPILER "([^"]+)"\)')
if (-not $compilerMatch.Success) { throw 'The resolved MSVC compiler path is missing from CMake metadata.' }
$dumpbin = Join-Path (Split-Path -Parent $compilerMatch.Groups[1].Value.Trim()) 'dumpbin.exe'
$exports = & $dumpbin /nologo /exports $dll.path
if ($LASTEXITCODE -ne 0 -or ($exports -join "`n") -notmatch '\bCdfBootstrapQueryState\b') { throw 'Diagnostic export is missing.' }
if (($exports -join "`n") -notmatch '\bCdfBootstrapQueryVerifierFlags\b') { throw 'Verifier flags diagnostic export is missing.' }
$map = Get-Content -LiteralPath (Join-Path $BuildDirectory 'bin\CdfBootstrap64.map') -Raw
if ($map -notmatch '\bCdfBootstrapEntry\b') { throw 'Custom DLL entry point is missing from the linker map.' }
$report = [pscustomobject]@{ passed = $true; bootstrap = $dll; probe = $probe }
$reportDirectory = Join-Path $BuildDirectory 'test-results'
$null = New-Item -ItemType Directory -Path $reportDirectory -Force
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDirectory 'build-inspection.json') -Encoding utf8
$report | ConvertTo-Json -Depth 8 -Compress
