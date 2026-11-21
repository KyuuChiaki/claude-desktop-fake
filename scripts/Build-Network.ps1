[CmdletBinding()]
param(
    [string]$CacheDirectory=(Join-Path $env:LOCALAPPDATA 'ClaudeDesktopFake\network-tools'),
    [ValidateRange(1,128)][int]$Parallel=16,
    [string]$DownloadProxy,
    [string]$CMakePath,[string]$NinjaPath,[string]$VisualStudioPath,[string]$VcvarsPath,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$WindowsSdkVersion
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$tools=& (Join-Path $PSScriptRoot 'Initialize-NetworkTools.ps1') -CacheDirectory $CacheDirectory -DownloadProxy $DownloadProxy
Push-Location -LiteralPath $root
$saved=@{}
try {
    foreach($name in @('GOMODCACHE','GOCACHE','GOTOOLCHAIN','CGO_ENABLED','CC','PATH')) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
    $env:GOMODCACHE=Join-Path $tools.cacheDirectory 'gomod'
    $env:GOCACHE=Join-Path $tools.cacheDirectory 'gobuild'
    $env:GOTOOLCHAIN='local';$env:CGO_ENABLED='1';$env:CC=$tools.compiler
    $env:PATH=(Split-Path -Parent $tools.compiler)+';'+$env:PATH
    & python (Join-Path $PSScriptRoot 'Prepare-NetworkXray.py') --source $tools.xray --destination (Join-Path $root 'out\network-dependencies\xray')
    if($LASTEXITCODE -ne 0){throw 'Xray patch validation failed.'}
    $bin=Join-Path $root 'out\build\x64-release\bin'
    $null=New-Item -ItemType Directory -Force -Path $bin
    & $tools.go -C transport build -mod=readonly -p $Parallel -buildmode=c-shared -trimpath -o (Join-Path $bin 'CdfProxyTransport64.dll') .
    if($LASTEXITCODE -ne 0){throw 'Transport build failed.'}
    & $tools.go -C transport mod verify
    if($LASTEXITCODE -ne 0){throw 'Go module checksum verification failed.'}
    $env:CGO_ENABLED='0'
    & $tools.go -C transport build -mod=readonly -p $Parallel -trimpath -o (Join-Path $bin 'CdfGui64.exe') ./cmd/cdfgui
    if($LASTEXITCODE -ne 0){throw 'GUI build failed.'}
    $nativeBuild=@{Parallel=$Parallel}
    foreach($option in 'CMakePath','NinjaPath','VisualStudioPath','VcvarsPath','WindowsSdkVersion'){
        if($PSBoundParameters.ContainsKey($option)){$nativeBuild[$option]=$PSBoundParameters[$option]}
    }
    & (Join-Path $PSScriptRoot 'Build.ps1') @nativeBuild
} finally {
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
    Pop-Location
}
