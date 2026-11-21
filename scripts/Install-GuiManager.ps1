# Installs only the local console and its fixed, hash-bound management tools.
[CmdletBinding()]
param([switch]$StageOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw '请使用管理员 PowerShell 安装管理组件。'
}
$source=Split-Path -Parent $PSScriptRoot
$shared=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake'
$gui=Join-Path $shared 'gui'
$releaseRoot=Join-Path $gui 'releases'
$allowed=@(
    'scripts\Invoke-GuiAction.ps1','scripts\Claude-GuiCore.ps1','scripts\Manage-TimeZone.ps1',
    'scripts\Manage-ClaudeNetwork.ps1','scripts\Manage-ClaudeAuto.ps1','scripts\Manage-Claude.ps1',
    'scripts\Claude-AutoCore.ps1','scripts\Claude-ManagerCore.ps1','scripts\Claude-FileIdentity.ps1',
    'scripts\Claude-Enumeration.ps1','scripts\Claude-ProcessDiagnostics.ps1','scripts\Watch-Claude.ps1',
    'scripts\Startup-Observation.ps1','scripts\StartupFileEvents.cs','scripts\Measure-StartupObservation.ps1',
    'scripts\Refresh-Claude.ps1','scripts\Capture-Runtime.ps1','scripts\Capture-Network.ps1',
    'scripts\Show-TimeConfig.ps1','scripts\Runtime-Profiles.ps1','scripts\Toolchain.ps1',
    'scripts\Network-Deployment.ps1','scripts\Network-Children.ps1','config\claude-network-children.json',
    'config\claude-targets.json','include\locale_hooks.inc',
    'profiles\runtime-adapters.json'
)
$bin='out\build\x64-release\bin'
foreach($name in @('CdfGui64.exe','CdfProxyCheck64.exe','CdfProxyTransport64.dll','CdfTimeRules64.exe',
        'CdfTimeZone64.dll','CdfRuntimeResolve64.exe','CdfClaudeTimeZone64.dll','CdfClaudeTimeZone64.map',
        'CdfClaudeNetwork64.dll','CdfClaudeNetwork64.map')){
    $allowed+=Join-Path $bin $name
}
$records=@(foreach($relative in $allowed){
    $path=Join-Path $source $relative
    if(-not [IO.File]::Exists($path)){throw "构建产物缺失，请先运行 Build-Network.ps1：$relative"}
    [ordered]@{path=$relative;sha256=(Cdf-Hash $path)}
})
$manifest=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $records -Compress))
$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifest))
if(-not [IO.Directory]::Exists($shared)){Cdf-SecureDirectory $shared}
if((Get-Item -LiteralPath $shared -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '部署根目录不可为重解析点。'}
$rootAcl=Get-Acl -LiteralPath $shared
$trusted=@('S-1-5-18','S-1-5-32-544')
$owner=$rootAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
if($owner -notin $trusted){throw '部署根目录所有者须为管理员组或 SYSTEM。'}
$canChange=[Security.AccessControl.FileSystemRights]'Write,Delete,ChangePermissions,TakeOwnership,DeleteSubdirectoriesAndFiles'
foreach($rule in $rootAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
    if($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $canChange) -and $rule.IdentityReference.Value -notin $trusted){
        throw '部署根目录允许其他用户修改，请先修复其权限。'
    }
}
foreach($path in @($gui,$releaseRoot)){Cdf-SecureDirectory $path}
$release=Join-Path $releaseRoot $hash
Cdf-SecureDirectory $release
foreach($record in $records){
    $path=Join-Path $release $record.path
    $parents=[Collections.Generic.Stack[string]]::new()
    $directory=Split-Path -Parent $path
    while($directory.Length -gt $release.Length){$parents.Push($directory);$directory=Split-Path -Parent $directory}
    while($parents.Count){Cdf-SecureDirectory ($parents.Pop())}
    if([IO.File]::Exists($path)){
        if(((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Cdf-Hash $path) -cne $record.sha256){
            throw '控制台安装文件已变化，保留原文件。'
        }
    }else{
        Cdf-CopyAtomic (Join-Path $source $record.path) $path $record.sha256
    }
}
$manifestPath=Join-Path $release 'gui-release.json'
if([IO.File]::Exists($manifestPath)){
    if((Cdf-Hash $manifestPath) -cne $hash){throw '控制台安装清单已变化。'}
}else{
    [IO.File]::WriteAllBytes($manifestPath,$manifest)
}
# An observation session can run from a protected release while the user
# continues using the current dashboard and its in-memory connection history.
if(-not $StageOnly){Cdf-Save (Join-Path $gui 'current.json') ([ordered]@{schemaVersion=1;release=$hash})}
Join-Path $release (Join-Path $bin 'CdfGui64.exe')
