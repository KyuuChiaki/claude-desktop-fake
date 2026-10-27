[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$bin=Join-Path $BuildDirectory 'bin'
$compilerRecord=Get-ChildItem -Path (Join-Path $BuildDirectory 'CMakeFiles\*\CMakeCXXCompiler.cmake')|Sort-Object LastWriteTime -Descending|Select-Object -First 1
$compiler=[regex]::Match((Get-Content -LiteralPath $compilerRecord.FullName -Raw),'(?m)^set\(CMAKE_CXX_COMPILER "([^"]+)"\)')
if(-not $compiler.Success){throw 'MSVC compiler record missing.'}
$dumpbin=Join-Path (Split-Path -Parent $compiler.Groups[1].Value) 'dumpbin.exe'
$artifacts=@('CdfTimeZone64.dll','CdfLocaleProbe64.exe','CdfLocaleRules64.exe','CdfLocaleEarly64.dll','CdfLocaleLate64.dll')|ForEach-Object{
    $path=Join-Path $bin $_;$stream=[IO.File]::OpenRead($path);$reader=[IO.BinaryReader]::new($stream)
    try{
        if($reader.ReadUInt16() -ne 0x5a4d){throw 'Invalid DOS signature.'}
        $stream.Position=0x3c;$pe=$reader.ReadUInt32();$stream.Position=$pe
        if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664){throw "Not AMD64: $_"}
        $stream.Position=$pe+24;if($reader.ReadUInt16() -ne 0x20b){throw 'Not PE32+.'}
        $stream.Position=$pe+40;$entry=$reader.ReadUInt32()
        $stream.Position=$pe+48;$imageBase=$reader.ReadUInt64()
        $stream.Position=$pe+24+112+9*8;$tls=$reader.ReadUInt32()
        $stream.Position=$pe+24+112+13*8;$delay=$reader.ReadUInt32()
        [pscustomobject]@{name=$_;machine='AMD64';size=$stream.Length;entryRva=$entry;imageBase=$imageBase;tlsRva=$tls;delayImportRva=$delay;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    }finally{$reader.Dispose();$stream.Dispose()}
}
$dll=$artifacts[0]
if($dll.entryRva -eq 0 -or $dll.tlsRva -ne 0 -or $dll.delayImportRva -ne 0 -or $artifacts[1].tlsRva -eq 0){throw 'Unexpected provider/Probe PE metadata.'}
$imports=(& $dumpbin /nologo /imports (Join-Path $bin $dll.name)) -join "`n"
if($LASTEXITCODE -ne 0){throw 'dumpbin imports failed.'}
$dependencies=@([regex]::Matches($imports,'(?im)^\s+([\w.-]+\.dll)\s*$')|ForEach-Object{$_.Groups[1].Value.ToLowerInvariant()}|Sort-Object -Unique)
if($dependencies.Count -ne 1 -or $dependencies[0] -ne 'ntdll.dll' -or $imports -notmatch '\b__chkstk\b'){throw 'Provider must use ntdll only, including native stack probing.'}
$exports=(& $dumpbin /nologo /exports (Join-Path $bin $dll.name)) -join "`n"
if($LASTEXITCODE -ne 0 -or $exports -notmatch '\bCdfLocaleQueryStatus\b' -or $exports -notmatch '\bCdfTimeZoneQueryStatus\b'){throw 'Diagnostics missing.'}
$map=Get-Content -LiteralPath (Join-Path $bin 'CdfTimeZone64.map') -Raw
$entry=[regex]::Match($map,'(?m)^\s+[0-9a-f]+:[0-9a-f]+\s+CdfTimeZoneEntry\s+([0-9a-f]+)\s')
if(-not $entry.Success -or [Convert]::ToUInt64($entry.Groups[1].Value,16) -ne $dll.imageBase+$dll.entryRva){throw 'Provider entry mismatch.'}
$manifest=Get-Content -LiteralPath (Join-Path $root 'include\locale_hooks.inc') -Raw
$hooks=@([regex]::Matches($manifest,'(?m)^CDF_LOCALE_HOOK\((\w+),\s*(\d+)\)')|ForEach-Object{[pscustomobject]@{name=$_.Groups[1].Value;mask=[int]$_.Groups[2].Value}})
$aliases=0;foreach($hook in $hooks){foreach($bit in @(1,2,4)){if($hook.mask -band $bit){++$aliases}}}
if($hooks.Count -ne 53 -or $aliases -ne 90 -or @($hooks.name|Sort-Object -Unique).Count -ne 53){throw 'Locale manifest mismatch.'}
$production=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -File|Where-Object{$_.Name -match '^(time_|locale_)' -and $_.Extension -in @('.cpp','.inc')})|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw}
$forbidden='\b(VirtualProtect\w*|NtProtectVirtualMemory|WriteProcessMemory|NtWriteVirtualMemory|CreateThread|NtCreateThreadEx|LoadLibrary\w*|LdrLoadDll|SetSystemTime|SetLocalTime|SetTimeZoneInformation|SetDynamicTimeZoneInformation|NtSetSystemTime|NtSetValueKey|NtWriteFile|SetUserGeoID|SetLocaleInfo\w*)\s*\('
if(($production -join "`n") -match $forbidden){throw "Unexpected production API: $($matches[1])"}
$report=[pscustomobject]@{passed=$true;artifacts=@($artifacts);dependencies=$dependencies;localeHooks=$hooks;requiredHooks=53;requiredAliases=90;imports=$imports;exports=$exports;providerEntry='CdfTimeZoneEntry';stackProbe='ntdll!__chkstk';timeDiagnosticAbi=528}
$directory=Join-Path $BuildDirectory 'test-results';$null=New-Item -ItemType Directory -Path $directory -Force
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $directory 'locale-build-inspection.json') -Encoding utf8
[pscustomobject]@{passed=$true;localeHooks=53;localeAliases=90;dependencies=$dependencies}|ConvertTo-Json -Compress
