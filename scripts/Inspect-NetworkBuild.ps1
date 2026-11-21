[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$cache=Get-Content -LiteralPath (Join-Path $BuildDirectory 'CMakeCache.txt')
$linker=@($cache|Where-Object {$_ -match '^CMAKE_LINKER:FILEPATH='})
if($linker.Count -ne 1){throw 'The CMake linker path is unavailable.'}
$dumpbin=Join-Path (Split-Path -Parent ($linker[0] -replace '^[^=]+=','')) 'dumpbin.exe'
$reports=@()
foreach($name in @('CdfNetwork64','CdfClaudeNetwork64','CdfProxyTransport64')){
    $path=Join-Path $BuildDirectory ('bin\'+$name+'.dll')
    $headers=& $dumpbin /nologo /headers $path
    if($LASTEXITCODE -ne 0 -or -not ($headers -match '8664')){throw "Expected an AMD64 DLL: $name"}
    $imports=& $dumpbin /nologo /imports $path
    if($LASTEXITCODE -ne 0){throw "Import inspection failed: $name"}
    $dependencies=@($imports|ForEach-Object {if($_ -match '^\s+([\w.-]+\.dll)\s*$'){$matches[1]}}|Sort-Object -Unique)
    $provider=$name -ne 'CdfProxyTransport64'
    if($provider -and ($dependencies.Count -ne 1 -or $dependencies[0] -ine 'ntdll.dll')){throw 'The bootstrap provider must depend only on ntdll.dll.'}
    $exports=(& $dumpbin /nologo /exports $path)-join "`n"
    $required=@(if($provider){'CdfNetworkQueryStatus'}else{'CdfTransportStart','CdfTransportOpen','CdfTransportDns','CdfTransportRelease','CdfTransportStop'})
    if($name -eq 'CdfClaudeNetwork64'){$required+='CdfClaudeQueryIdentityStatus';$required+='CdfClaudeQueryStartupGuardStatus'}
    foreach($symbol in $required){if($exports -notmatch ('\b'+[regex]::Escape($symbol)+'\b')){throw "Missing export: $name/$symbol"}}
    if($provider){$map=[IO.File]::ReadAllText([IO.Path]::ChangeExtension($path,'map'));if($map -notmatch '\bCdfNetworkEntry\b'){throw 'Provider entry is absent from the map.'}}
    $reports+=[pscustomobject]@{name=$name;machine='AMD64';sha256=(Get-FileHash -LiteralPath $path).Hash;dependencies=$dependencies;exports=$required}
}
[pscustomobject]@{passed=$true;providerStatusSize=544;policySize=2208;providers=$reports}|ConvertTo-Json -Depth 6
