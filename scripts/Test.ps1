[CmdletBinding()]
param([ValidateSet('Unit','Full')][string]$Suite='Unit',
      [string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$directory=[IO.Path]::GetFullPath($BuildDirectory)
$cache=Join-Path $directory 'CMakeCache.txt'
if(-not(Test-Path -LiteralPath $cache)){throw 'Run scripts/Build.ps1 first.'}
$entry=Get-Content -LiteralPath $cache|Where-Object {$_ -match '^CMAKE_CTEST_COMMAND:INTERNAL='}|Select-Object -First 1
if(-not $entry){throw 'CTest was not found in this build configuration.'}
$ctest=$entry.Substring($entry.IndexOf('=')+1)
$arguments=@('--test-dir',$directory,'--output-on-failure')
if($Suite -eq 'Unit'){
    $arguments+=@('-R','^(time_rules|time_config_preview|locale_rules|runtime_rules|build_inspection|timezone_build_inspection|locale_build_inspection|claude_gate_build_inspection|runtime_build_inspection)$')
}else{
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not [Environment]::Is64BitProcess -or -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Full tests require an elevated 64-bit session. Read docs/testing.md first.'}
}
& $ctest @arguments
if($LASTEXITCODE){throw "CTest failed ($LASTEXITCODE)."}
