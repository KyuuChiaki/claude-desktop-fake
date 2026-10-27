[CmdletBinding()]
param(
    [ValidateRange(1,128)][int]$Parallel=16,[switch]$Test,
    [string]$CMakePath=$env:CDF_CMAKE,[string]$NinjaPath=$env:CDF_NINJA,
    [string]$VisualStudioPath=$env:CDF_VS_INSTALLATION,[string]$VcvarsPath=$env:CDF_VCVARS64,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$WindowsSdkVersion='10.0.26100.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if(-not $IsWindows -or -not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -lt 7){throw 'Use 64-bit PowerShell 7 on Windows.'}
. (Join-Path $PSScriptRoot 'Toolchain.ps1')
$projectRoot = Split-Path -Parent $PSScriptRoot
$vs=if($VcvarsPath -and -not $VisualStudioPath){[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $VcvarsPath) '..\..\..'))}else{Find-CdfVisualStudio $VisualStudioPath}
$vcvars=if($VcvarsPath){(Resolve-Path -LiteralPath $VcvarsPath).ProviderPath}else{Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'}
$cmake=Find-CdfExecutable $CMakePath 'cmake.exe' @((Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'))
$ninja=Find-CdfExecutable $NinjaPath 'ninja.exe' @((Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'))

# Import the developer environment without interpolating paths into shell code.
$previousVcvars = [Environment]::GetEnvironmentVariable('CDF_BUILD_VCVARS', 'Process')
$previousSdk = [Environment]::GetEnvironmentVariable('CDF_BUILD_SDK', 'Process')
try {
    $env:CDF_BUILD_VCVARS = $vcvars
    $env:CDF_BUILD_SDK = $WindowsSdkVersion
    $developerEnvironment = & $env:ComSpec /d /c 'call "%CDF_BUILD_VCVARS%" %CDF_BUILD_SDK% >nul && set'
    if ($LASTEXITCODE -ne 0) { throw 'vcvars64.bat failed.' }
    foreach ($line in $developerEnvironment) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable('CDF_BUILD_VCVARS', $previousVcvars, 'Process')
    [Environment]::SetEnvironmentVariable('CDF_BUILD_SDK', $previousSdk, 'Process')
}
$env:VSLANG = '1033'

Push-Location -LiteralPath $projectRoot
try {
    & $cmake --preset x64-release "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_SYSTEM_VERSION=$WindowsSdkVersion" "-DCDF_VS_ROOT=$vs"
    if ($LASTEXITCODE -ne 0) { throw "CMake configuration failed ($LASTEXITCODE)." }
    & $cmake --build --preset x64-release --parallel $Parallel
    if ($LASTEXITCODE -ne 0) { throw "Build failed ($LASTEXITCODE)." }
    if ($Test) {
        $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Full integration tests require elevation. See docs/testing.md for read-only tests.'}
        $ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'
        & $ctest --preset x64-release
        if ($LASTEXITCODE -ne 0) { throw "CTest failed ($LASTEXITCODE)." }
    }
} finally {
    Pop-Location
}
