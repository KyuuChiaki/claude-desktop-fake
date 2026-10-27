[CmdletBinding()]
param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $BuildDirectory 'bin'
$compilerRecord = Get-ChildItem -Path (Join-Path $BuildDirectory 'CMakeFiles\*\CMakeCXXCompiler.cmake') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$compiler = [regex]::Match((Get-Content -LiteralPath $compilerRecord.FullName -Raw), '(?m)^set\(CMAKE_CXX_COMPILER "([^"]+)"\)')
if (-not $compiler.Success) { throw 'MSVC compiler record missing.' }
$dumpbin = Join-Path (Split-Path -Parent $compiler.Groups[1].Value) 'dumpbin.exe'
function Pe([string]$Name) {
    $path = Join-Path $bin $Name
    $stream = [IO.File]::OpenRead($path); $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'Invalid DOS signature.' }
        $stream.Position = 0x3C; $pe = $reader.ReadUInt32(); $stream.Position = $pe
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw "Not AMD64: $Name" }
        $stream.Position = $pe+24
        if ($reader.ReadUInt16() -ne 0x20B) { throw 'Not PE32+.' }
        $stream.Position = $pe+40; $entry = $reader.ReadUInt32()
        $stream.Position = $pe+48; $imageBase = $reader.ReadUInt64()
        $stream.Position = $pe+24+112+9*8; $tls = $reader.ReadUInt32()
        $stream.Position = $pe+24+112+13*8; $delay = $reader.ReadUInt32()
        return [pscustomobject]@{name=$Name;machine='AMD64';size=$stream.Length;entryRva=$entry;imageBase=$imageBase;tlsRva=$tls;delayImportRva=$delay;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    } finally { $reader.Dispose(); $stream.Dispose() }
}
$artifacts = @('CdfTimeZone64.dll','CdfTimeProbe64.exe','CdfTimeRules64.exe','CdfTimeEarly64.dll','CdfTimeLate64.dll') | ForEach-Object { Pe $_ }
$dll = $artifacts[0]
if ($dll.entryRva -eq 0 -or $dll.tlsRva -ne 0 -or $dll.delayImportRva -ne 0 -or $artifacts[1].tlsRva -eq 0) { throw 'Unexpected provider entry/TLS/import metadata.' }
$imports = (& $dumpbin /nologo /imports (Join-Path $bin $dll.name)) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'dumpbin imports failed.' }
$dependencies = @([regex]::Matches($imports,'(?im)^\s+([\w.-]+\.dll)\s*$') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
if ($dependencies.Count -ne 1 -or $dependencies[0] -ne 'ntdll.dll') { throw "Provider dependencies must be ntdll.dll only: $dependencies" }
$exports = (& $dumpbin /nologo /exports (Join-Path $bin $dll.name)) -join "`n"
if ($LASTEXITCODE -ne 0 -or $exports -notmatch '\bCdfTimeZoneQueryStatus\b') { throw 'Diagnostic export missing.' }
$map = Get-Content -LiteralPath (Join-Path $bin 'CdfTimeZone64.map') -Raw
$entry = [regex]::Match($map,'(?m)^\s+[0-9a-f]+:[0-9a-f]+\s+CdfTimeZoneEntry\s+([0-9a-f]+)\s')
if (-not $entry.Success -or [Convert]::ToUInt64($entry.Groups[1].Value,16) -ne $dll.imageBase+$dll.entryRva) { throw 'PE entry does not match CdfTimeZoneEntry.' }
$expectedTime = @('GetLocalTime','GetSystemTime','GetSystemTimeAsFileTime','GetSystemTimePreciseAsFileTime','GetTimeZoneInformation','GetDynamicTimeZoneInformation','GetTimeZoneInformationForYear','NtQuerySystemTime','RtlGetSystemTimePrecise','RtlTimeToTimeFields','RtlQueryTimeZoneInformation','RtlQueryDynamicTimeZoneInformation','NtQuerySystemInformation','RtlSystemTimeToLocalTime','RtlLocalTimeToSystemTime','SystemTimeToTzSpecificLocalTime','TzSpecificLocalTimeToSystemTime','SystemTimeToTzSpecificLocalTimeEx','TzSpecificLocalTimeToSystemTimeEx','FileTimeToLocalFileTime','LocalFileTimeToFileTime','LocalFileTimeToLocalSystemTime','LocalSystemTimeToLocalFileTime')
$bridges = @('GetProcAddress','LdrGetProcedureAddress','LdrGetProcedureAddressEx','LdrGetProcedureAddressForCaller')
$provider = Get-Content -LiteralPath (Join-Path $root 'src\time_provider.cpp') -Raw
$tableSource = [regex]::Replace($provider,'(?m)^#define THUNK[^\r\n]*','')
$actual = @([regex]::Matches($tableSource,'THUNK\((\w+)\)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
if (($actual -join ',') -cne (($expectedTime+$bridges | Sort-Object) -join ',')) { throw 'Unexpected thunk descriptor entries.' }
if ($provider -notmatch 'HookKernelGetProcAddress') { throw 'kernel32 resolver bridge missing.' }
$production = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter 'time_*.cpp') | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
$forbidden = '\b(VirtualProtect\w*|NtProtectVirtualMemory|WriteProcessMemory|NtWriteVirtualMemory|CreateThread|NtCreateThreadEx|LoadLibrary\w*|LdrLoadDll|QueryPerformanceCounter|GetTickCount(?:64)?|timeGetTime|GetLocaleInfo\w*|GetUserDefaultLocaleName|SetSystemTime|SetLocalTime|SetTimeZoneInformation|SetDynamicTimeZoneInformation|NtSetSystemTime|NtSetValueKey|NtWriteFile)\s*\('
if (($production -join "`n") -match $forbidden) { throw "Unexpected implementation API: $($matches[1])" }
$jsmnHash = (Get-FileHash -LiteralPath (Join-Path $root 'third_party\jsmn\jsmn.h') -Algorithm SHA256).Hash
if ($jsmnHash -cne '1ED6154DEDF009212A08A397E9C4ED50A0CE31D5A8301BB294E137AE3188C13B' -or
    (Get-Content -LiteralPath (Join-Path $root 'src\time_core.cpp') -Raw) -notmatch '#define JSMN_STRICT') { throw 'jsmn pin/strict mode mismatch.' }
$report = [pscustomobject]@{passed=$true;artifacts=@($artifacts);dependencies=$dependencies;timeHooks=$expectedTime;resolverBridges=@('kernelbase!GetProcAddress','kernel32!GetProcAddress','ntdll!LdrGetProcedureAddress','ntdll!LdrGetProcedureAddressEx','ntdll!LdrGetProcedureAddressForCaller');jsmnVersion='1.1.0';jsmnSha256=$jsmnHash;imports=$imports;exports=$exports}
$directory = Join-Path $BuildDirectory 'test-results'; $null = New-Item -ItemType Directory -Path $directory -Force
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $directory 'timezone-build-inspection.json') -Encoding utf8
[pscustomobject]@{passed=$true;timeHooks=23;resolverBridges=5;dependencies=$dependencies} | ConvertTo-Json -Compress
