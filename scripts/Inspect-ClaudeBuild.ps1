[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$compiler=Get-ChildItem -Path (Join-Path $BuildDirectory 'CMakeFiles\*\CMakeCXXCompiler.cmake')|Select-Object -First 1
$tool=[regex]::Match((Get-Content -Raw -LiteralPath $compiler.FullName),'CMAKE_CXX_COMPILER "([^"]+)"').Groups[1].Value
$dump=Join-Path (Split-Path -Parent $tool) 'dumpbin.exe';$artifacts=@()
foreach($name in @('CdfClaudeTimeZone64','CdfClaudeTimeZoneTest64')){
    $file=Join-Path $BuildDirectory ('bin\'+$name+'.dll');$f=[IO.File]::OpenRead($file);$r=[IO.BinaryReader]::new($f)
    try{
        if($r.ReadUInt16() -ne 0x5a4d){throw 'Invalid DOS header.'};$f.Position=0x3c;$pe=$r.ReadUInt32();$f.Position=$pe
        if($r.ReadUInt32() -ne 0x4550 -or $r.ReadUInt16() -ne 0x8664){throw 'Provider is not AMD64.'}
        $f.Position=$pe+40;$entry=$r.ReadUInt32();$f.Position=$pe+48;$imageBase=$r.ReadUInt64();$f.Position=$pe+24+112+9*8;$tls=$r.ReadUInt32()
        if($entry -eq 0 -or $tls -ne 0){throw 'Invalid entry or unexpected provider TLS.'}
    }finally{$r.Dispose()}
    $imports=(& $dump /nologo /imports $file)-join "`n";if($LASTEXITCODE){throw 'Import inspection failed.'}
    $deps=@([regex]::Matches($imports,'(?im)^\s+([\w.-]+\.dll)\s*$')|ForEach-Object{$_.Groups[1].Value.ToLowerInvariant()}|Sort-Object -Unique)
    if($deps.Count -ne 1 -or $deps[0] -ne 'ntdll.dll'){throw "Unexpected dependency: $deps"}
    $exports=(& $dump /nologo /exports $file)-join "`n";if($LASTEXITCODE){throw 'Export inspection failed.'}
    foreach($export in @('CdfClaudeQueryIdentityStatus','CdfClaudeQueryStartupGuardStatus','CdfTimeZoneQueryStatus','CdfLocaleQueryStatus')){if($exports -notmatch ('\b'+$export+'\b')){throw "Missing export $export"}}
    $map=Get-Content -Raw -LiteralPath (Join-Path $BuildDirectory ('bin\'+$name+'.map'))
    $match=[regex]::Match($map,'(?m)^\s+[0-9a-f]+:[0-9a-f]+\s+CdfTimeZoneEntry\s+([0-9a-f]+)\s')
    if(-not $match.Success -or [Convert]::ToUInt64($match.Groups[1].Value,16) -ne $entry+$imageBase){throw 'Provider entry mismatch.'}
    $artifacts+=[pscustomobject]@{name=($name+'.dll');machine='AMD64';entryRva=$entry;dependencies=$deps;sha256=(Get-FileHash $file).Hash;bytes=(Get-Item $file).Length;exports=$exports}
}
$source=Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\claude_identity.cpp')
if($source -match '\b(VirtualProtect\w*|NtProtectVirtualMemory|WriteProcessMemory|NtWriteVirtualMemory|CreateThread|LoadLibrary\w*|LdrLoadDll|WinVerifyTrust)\s*\('){throw 'Unexpected early identity API.'}
$result=[pscustomobject]@{passed=$true;artifacts=$artifacts;identityAbiBytes=2280;nativeOnly=$true}
$dir=Join-Path $BuildDirectory 'test-results';[void](New-Item -ItemType Directory -Path $dir -Force)
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $dir 'claude-build-inspection.json') -Encoding utf8
$result|Select-Object passed,identityAbiBytes,nativeOnly|ConvertTo-Json -Compress
