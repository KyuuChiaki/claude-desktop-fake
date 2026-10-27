[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot;$bin=Join-Path $BuildDirectory 'bin'
$compiler=Get-ChildItem -Path (Join-Path $BuildDirectory 'CMakeFiles\*\CMakeCXXCompiler.cmake')|Select-Object -First 1
$tool=[regex]::Match((Get-Content -LiteralPath $compiler.FullName -Raw),'CMAKE_CXX_COMPILER "([^"]+)"').Groups[1].Value
$dump=Join-Path (Split-Path -Parent $tool) 'dumpbin.exe';$artifacts=@()
foreach($name in @('CdfTimeZone64','CdfClaudeTimeZone64','CdfClaudeTimeZoneTest64')){
    $file=Join-Path $bin ($name+'.dll');$bytes=[IO.File]::ReadAllBytes($file);$pe=[BitConverter]::ToInt32($bytes,60)
    if([BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x8664){throw 'Runtime provider must be AMD64 PE.'}
    $binaryText=[Text.Encoding]::Unicode.GetString($bytes)
    $containsFault=$binaryText.Contains('CDF_RUNTIME_TEST_FAULT') -or $binaryText.Contains('runtime-test-fault.txt')
    if($name -eq 'CdfClaudeTimeZoneTest64'){
        if(-not $containsFault){throw 'The isolated test provider is missing its rollback fault fixture.'}
    }elseif($containsFault){throw 'Production provider contains a test-only fault control.'}
    $imports=(& $dump /nologo /imports $file)-join "`n";if($LASTEXITCODE){throw 'Runtime import inspection failed.'}
    $deps=@([regex]::Matches($imports,'(?im)^\s+([\w.-]+\.dll)\s*$')|ForEach-Object{$_.Groups[1].Value.ToLowerInvariant()}|Sort-Object -Unique)
    if($deps.Count -ne 1 -or $deps[0] -cne 'ntdll.dll'){throw "Unexpected runtime provider dependencies: $deps"}
    $exports=(& $dump /nologo /exports $file)-join "`n";if($LASTEXITCODE){throw 'Runtime exports inspection failed.'}
    foreach($export in @('CdfTimeZoneQueryStatus','CdfLocaleQueryStatus','CdfRuntimeQueryStatus','CdfRuntimeQueryCompatibilityStatus')){if($exports -notmatch ('\b'+$export+'\b')){throw "Missing diagnostic $export"}}
    $map=Get-Content -LiteralPath (Join-Path $bin ($name+'.map')) -Raw
    $entry=[regex]::Match($map,'(?m)^\s+[0-9a-f]+:[0-9a-f]+\s+CdfTimeZoneEntry\s+([0-9a-f]+)\s')
    if(-not $entry.Success -or [Convert]::ToUInt64($entry.Groups[1].Value,16) -ne ([BitConverter]::ToUInt64($bytes,$pe+48)+[BitConverter]::ToUInt32($bytes,$pe+40))){throw 'Runtime provider entry mismatch.'}
    foreach($symbol in @('runtime_sequence','runtime_status','runtime_capture')){if($map -notmatch ('\?'+$symbol+'@')){throw "Missing read-only capture layout symbol $symbol"}}
    $artifacts+=[pscustomobject]@{name=$name+'.dll';machine='AMD64';dependencies=$deps;sha256=(Get-FileHash -LiteralPath $file).Hash;bytes=$bytes.Length;entry='CdfTimeZoneEntry';diagnosticVersion=2;diagnosticBytes=816}
}
$adapter=Get-Content -LiteralPath (Join-Path $root 'src\runtime_adapter.cpp') -Raw
$catalog=Get-Content -LiteralPath (Join-Path $root 'profiles\runtime-adapters.json') -Raw|ConvertFrom-Json
if($catalog.schemaVersion -ne 2 -or $catalog.images.Count -lt 2 -or $catalog.builds.Count -lt 1 -or $catalog.windowsBuild -ne 19045){throw 'Runtime catalogue mismatch.'}
$capture=Get-Content -LiteralPath (Join-Path $root 'src\runtime_capture.cpp') -Raw
$winrt=Get-Content -LiteralPath (Join-Path $root 'src\runtime_winrt.cpp') -Raw
foreach($source in @($adapter,$capture,$winrt)){
    $code=[regex]::Replace($source,'(?m)//[^\r\n]*','')
    if($code -match '\b(std::|LoadLibrary\w*\s*\(|LdrLoadDll\s*\(|CreateThread\s*\(|NtCreateThreadEx\s*\(|NtWriteFile\s*\(|NtWriteVirtualMemory\s*\(|WriteProcessMemory\s*\()'){throw 'Unexpected runtime dependency or external side effect.'}
}
$cmake=Get-Content -LiteralPath (Join-Path $root 'CMakeLists.txt') -Raw
if($cmake -match 'CDF_EXPERIMENTAL_RUNTIME' -or $cmake -notmatch 'VERSION 0\.6\.0'){throw 'Runtime must be part of the normal 0.6.0 build.'}
if($adapter -match '0x(?:2dbee20|53b6cc0|1e0b1f0|3c253ec)' -or $capture -match 'image\+0x'){throw 'Runtime bridge still contains fixed target RVAs.'}
$report=[pscustomobject]@{passed=$true;artifacts=$artifacts;profiles=@($catalog.images|Select-Object id,sha256);catalogRevision=$catalog.revision;abiFamilies=$catalog.abis.Count;runtimeAbiBytes=816;compatibilityAbiBytes=552;timeAbiBytes=528;identityAbiBytes=2280;readOnlyCapture=$true;patches='two verified leaf tail jumps; generated role-address bindings';staticDependencies=@('ntdll.dll')}
$dir=Join-Path $BuildDirectory 'test-results';[void](New-Item -ItemType Directory -Path $dir -Force)
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $dir 'runtime-build-inspection.json') -Encoding utf8
[pscustomobject]@{passed=$true;providers=$artifacts.Count;profiles=$catalog.images.Count;runtimeAbiBytes=816;dependencies=@('ntdll.dll')}|ConvertTo-Json -Compress
