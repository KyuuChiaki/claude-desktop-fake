#requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$WarningPreference='SilentlyContinue'
Set-StrictMode -Version Latest
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)

$root=Split-Path -Parent $PSScriptRoot
$bin=Join-Path $root 'out\build\x64-release\bin'
$dataRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake'
$guiRoot=Join-Path $dataRoot 'gui'
$claudeRoot=Join-Path $dataRoot 'stage3\claude'
$autoRoot=Join-Path $dataRoot 'stage3\claude-auto'
$networkRoot=Join-Path $dataRoot 'network'
$transportRecord=Join-Path $networkRoot 'transport-deployment.json'
$proxyProfilePath=Join-Path $networkRoot 'active.dpapi'
$configPath=Join-Path $dataRoot 'stage2\timezone.json'

try{
    $body=[Console]::In.ReadToEnd()
    if($body.Length -gt 8192){throw '管理请求超过长度限制。'}
    $request=ConvertFrom-Json -InputObject $body -AsHashtable -DateKind String
    $body=$null
    . (Join-Path $PSScriptRoot 'Claude-AutoCore.ps1')
    . (Join-Path $PSScriptRoot 'Network-Deployment.ps1')
    . (Join-Path $PSScriptRoot 'Network-Children.ps1')
    . (Join-Path $PSScriptRoot 'Claude-GuiCore.ps1')
    function Save-JsonAtomically($Value,[string]$Destination){Cdf-Save $Destination $Value}
    function Assert-Amd64Dll([string]$Path){
        $bytes=[IO.File]::ReadAllBytes($Path)
        if($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes,0) -ne 0x5a4d){throw '传输 DLL 格式无效。'}
        $pe=[BitConverter]::ToInt32($bytes,60)
        if($pe -lt 64 -or $pe -gt $bytes.Length-26 -or [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or
            [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x8664 -or -not ([BitConverter]::ToUInt16($bytes,$pe+22) -band 0x2000) -or
            [BitConverter]::ToUInt16($bytes,$pe+24) -ne 0x20b){throw '传输文件必须为 Windows x64 DLL。'}
    }
    $elevated=$request.action -in @('project.switch','proxy.switch','webrtc.switch','time.save','proxy.save')
    if($elevated){
        $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw '本次操作需要管理员权限。'}
    }
    $result=switch -CaseSensitive ($request.action){
        'status' {Get-GuiSnapshot $false;break}
        'check' {Get-GuiSnapshot $true;break}
        'project.switch' {
            if($request.enabled -isnot [bool]){throw '开关值无效。'}
            Invoke-GuiProjectSwitch $request.enabled;break
        }
        'proxy.switch' {
            if($request.enabled -isnot [bool]){throw '开关值无效。'}
            Invoke-GuiProxySwitch $request.enabled;break
        }
        'proxy.save' {Invoke-GuiNetworkSave $request;break}
        'webrtc.switch' {
            if($request.enabled -isnot [bool]){throw '开关值无效。'}
            Invoke-GuiWebRTCSwitch $request;break
        }
        'proxy.test' {Invoke-GuiProxyTest $request;break}
        {$_ -in @('time.save','time.preview')} {
            if($elevated -and $request.revision -ine (Get-GuiRevision $configPath)){throw '时区配置已被其他操作修改，请刷新。'}
            $settings=New-GuiTimeDraft $request (Read-GuiTimeConfig)
            $work=New-GuiWorkDirectory $elevated
            try{
                $candidate=Join-Path $work 'candidate.json'
                Cdf-Save $candidate $settings
                $preview=Get-GuiTimePreview $candidate $settings
                if($elevated){
                    $commit=& (Join-Path $PSScriptRoot 'Manage-TimeZone.ps1') -Action Configure -DllPath (Join-Path $bin 'CdfTimeZone64.dll') -ConfigPath $candidate -ExpectedConfigSha256 $request.revision | ConvertFrom-Json
                    @{ok=$true;preview=$preview;timeRevision=$commit.configSha256;message='时区和语言已保存，下次启动生效。'}
                }else{
                    @{ok=$true;preview=$preview;message='预览已更新。'}
                }
            }finally{[IO.File]::Delete((Join-Path $work 'candidate.json'));[IO.Directory]::Delete($work,$false)}
            break
        }
        default {throw '未知控制台操作。'}
    }
    [Console]::WriteLine((ConvertTo-Json -InputObject $result -Compress -Depth 22))
}catch{
    [Console]::WriteLine((ConvertTo-Json -InputObject @{ok=$false;message=$_.Exception.Message} -Compress))
}
