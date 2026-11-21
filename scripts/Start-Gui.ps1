#requires -Version 7.5
[CmdletBinding()]
param(
    [ValidateRange(0,65535)][int]$Port=17862,
    [switch]$NoBrowser,
    [switch]$ReadOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(-not [Environment]::Is64BitProcess){throw '请使用 64 位 PowerShell 7。'}
$source=Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release\bin\CdfGui64.exe'
$exe=$source
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $ReadOnly){
    $gui=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\gui'
    $current=Join-Path $gui 'current.json'
    if($admin){
        $exe=& (Join-Path $PSScriptRoot 'Install-GuiManager.ps1')
    }elseif([IO.File]::Exists($current)){
        $state=Get-Content -LiteralPath $current -Raw|ConvertFrom-Json
        if($state.schemaVersion -ne 1 -or $state.release -cnotmatch '^[A-F0-9]{64}$'){throw '控制台安装记录无效。'}
        $exe=Join-Path (Join-Path $gui ('releases\'+$state.release)) 'out\build\x64-release\bin\CdfGui64.exe'
    }
}
if(-not [IO.File]::Exists($exe)){throw '请先运行 Build-Network.ps1 构建控制台。'}
$arguments=@('-port',[string]$Port)
if($NoBrowser){$arguments+='-no-browser'}
& $exe @arguments
if($LASTEXITCODE -ne 0){throw '控制台启动失败。'}
