[CmdletBinding(SupportsShouldProcess)]
param([string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\timezone.json'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Use 64-bit PowerShell on Windows.'}
$project=Split-Path -Parent $PSScriptRoot
$source=(Resolve-Path -LiteralPath $ConfigPath).ProviderPath
$validator=Join-Path $project 'out\build\x64-release\bin\CdfTimeRules64.exe'
if(-not(Test-Path -LiteralPath $validator)){throw 'Run scripts/Build.ps1 before preparing the configuration.'}
$expected=(Get-FileHash -LiteralPath $source).Hash
$validation=& $validator --validate-config $source
if($LASTEXITCODE -ne 0 -or -not (($validation -join "`n"|ConvertFrom-Json).valid)){throw 'Configuration validation failed.'}
$dataRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake'
$directory=Join-Path $dataRoot 'stage2';$destination=Join-Path $directory 'timezone.json'
if(Test-Path -LiteralPath $destination){
    if((Get-FileHash -LiteralPath $destination).Hash -ceq $expected){[pscustomobject]@{status='unchanged';path=$destination;sha256=$expected}|ConvertTo-Json;return}
    if($WhatIfPreference){[pscustomobject]@{status='would-refuse-overwrite';path=$destination}|ConvertTo-Json;return}
    throw 'An existing configuration differs. It was preserved. Back it up and edit it as described in docs/configuration.md.'
}
if($PSCmdlet.ShouldProcess($destination,'Create initial validated configuration')){
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Creating the deployed configuration requires an elevated PowerShell session.'}
    . (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
    Cdf-SecureDirectory $dataRoot;Cdf-SecureDirectory $directory
    $temporary=Join-Path $directory ([Guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::Copy($source,$temporary,$false)
        if((Get-FileHash -LiteralPath $temporary).Hash -cne $expected){throw 'Source configuration changed during validation.'}
        [IO.File]::Move($temporary,$destination)
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
    [pscustomobject]@{status='created';path=$destination;sha256=$expected}|ConvertTo-Json
}
