#requires -Version 7.5
[CmdletBinding()]
param([switch]$Online,[switch]$ReadOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$bin=Join-Path $root 'out\build\x64-release\bin'
$shared=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake'
$config=Join-Path $shared 'stage2\timezone.json'
$record=Join-Path $shared 'network\transport-deployment.json'
$before=@{}
foreach($path in @($config,$record,(Join-Path $shared 'network\policy.bin'),(Join-Path $shared 'network\active.dpapi'),
    (Join-Path $shared 'network\protection.json'))){
    $before[$path]=if([IO.File]::Exists($path)){(Get-FileHash -LiteralPath $path).Hash}else{$null}
}
$passed=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Name){
    if(-not $Condition){throw $Name}
    $passed.Add($Name)
}
function Test-WebRTCSetting {
    . (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
    . (Join-Path $PSScriptRoot 'Claude-GuiCore.ps1')
    . (Join-Path $PSScriptRoot 'Network-Deployment.ps1')
    $networkRoot=Join-Path ([IO.Path]::GetTempPath()) ('CdfWebRTC-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($networkRoot)
    $setting=Join-Path $networkRoot 'protection.json'
    try{
        Check (Get-CdfWebRTCPolicy $networkRoot).disabled 'WebRTC defaults to disabled with no saved preference'
        $off=Invoke-GuiWebRTCSwitch @{enabled=$false;revision='missing'}
        Check (-not (Get-CdfWebRTCPolicy $networkRoot).disabled -and -not $off.webRTCDisabled) 'WebRTC policy can be switched off'
        $on=Invoke-GuiWebRTCSwitch @{enabled=$true;revision=$off.webRTCRevision}
        Check ((Get-CdfWebRTCPolicy $networkRoot).disabled -and $on.webRTCDisabled) 'WebRTC policy can be switched on again'
    }finally{
        [IO.File]::Delete($setting)
        [IO.Directory]::Delete($networkRoot,$false)
    }
}
function Test-ProxySelection {
    . (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
    $tag='CdfGuiToggle-'+[Guid]::NewGuid().ToString('N')
    $directory=Join-Path ([IO.Path]::GetTempPath()) $tag
    $registry='Software\'+$tag
    $context=New-CdfClaudeContext $directory '' 'CdfClaudeTimeZone64.dll'
    $context.TargetDll=Join-Path $directory $context.DllName
    $context.NetworkPolicy=Join-Path $directory 'claude.json'
    [void][IO.Directory]::CreateDirectory($context.ImageStates)
    $context.Ifeo=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registry)
    try{
        [IO.File]::WriteAllText($context.TargetDll,'fixture')
        $dllHash=Cdf-Hash $context.TargetDll
        Cdf-Save $context.Ownership @{schemaVersion=1;dllPath=$context.TargetDll;dllSha256=$dllHash}
        Cdf-Save $context.Manifest @{schemaVersion=1;images=@()}
        $manifestHash=Cdf-Hash $context.Manifest
        $state=[pscustomobject]@{
            schemaVersion=1;phase='installed';dllPath=$context.TargetDll;dllSha256=$dllHash
            manifestPath=$context.Manifest;manifestSha256=$manifestHash;updatedAtUtc=[DateTime]::UtcNow.ToString('o')
            images=@(foreach($name in @('cdfguitoggle64.exe','cdfguitoggleother64.exe','cowork-svc.exe')){
                $item=Cdf-NewImageState $context $name
                foreach($value in $item.installedValues){Cdf-SetValue $context $name $value}
                Cdf-Save (Join-Path $context.ImageStates ($name+'.json')) $item
                $item
            })
        }
        Cdf-Save $context.State $state
        $originals=Cdf-Json @($state.images|ForEach-Object {,$_.originalValues})
        $timeOnly=$context.DllName
        $combined=$timeOnly+' CdfClaudeNetwork64.dll'
        $policy=[pscustomobject]@{enabled=$true;excludedImages=@('cowork-svc.exe')}
        Cdf-SwitchNetworkSelection $context $policy
        $updated=Cdf-ReadState $context
        foreach($image in $updated.images){Cdf-AssertImage $context $image}
        Check ((Cdf-RegistryValue $context 'cdfguitoggle64.exe' 'VerifierDlls').data -ceq $combined) 'Proxy switch updates registered images'
        Check ((Cdf-RegistryValue $context 'cowork-svc.exe' 'VerifierDlls').data -ceq $timeOnly) 'Proxy switch preserves service exclusion'
        Check ((Cdf-Json @($updated.images|ForEach-Object {,$_.originalValues})) -ceq $originals -and
            (Cdf-Hash $context.Manifest) -ceq $manifestHash) 'Proxy switch preserves restoration values and identity manifest'
        $beforePolicy=Cdf-Hash $context.NetworkPolicy
        $beforeState=Cdf-Hash $context.State
        Cdf-SwitchNetworkSelection $context $policy
        Check ((Cdf-Hash $context.NetworkPolicy) -ceq $beforePolicy -and (Cdf-Hash $context.State) -ceq $beforeState) 'Repeated proxy selection leaves persisted records unchanged'
        $policy.enabled=$false
        $context.Fault={param($writes) if($writes -eq 1){throw 'Simulated proxy commit failure'}}
        $failure=$null
        try{Cdf-SwitchNetworkSelection $context $policy}catch{$failure=$_.Exception.Message}
        finally{$context.Fault=$null}
        Check ($failure -like '*rolled back*Simulated proxy commit failure*' -and
            (Cdf-Hash $context.NetworkPolicy) -ceq $beforePolicy -and (Cdf-Hash $context.State) -ceq $beforeState -and
            -not [IO.File]::Exists($context.Pending)) 'Failed proxy switch restores policy and state'
        foreach($image in (Cdf-ReadState $context).images){Cdf-AssertImage $context $image}
        Cdf-SwitchNetworkSelection $context $policy
        $updated=Cdf-ReadState $context
        foreach($image in $updated.images){Cdf-AssertImage $context $image}
        Check (@($updated.images.installedValues|Where-Object {$_.name -eq 'VerifierDlls' -and $_.data -cne $timeOnly}).Count -eq 0) 'Disabling proxy retains time providers'
    }finally{
        $context.Ifeo.Dispose()
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registry,$false)
        if(-not [IO.File]::Exists($context.Pending)){
            foreach($folder in @($context.ImageStates,$directory)){
                foreach($file in @(Get-ChildItem -LiteralPath $folder -File)){[IO.File]::Delete($file.FullName)}
                [IO.Directory]::Delete($folder,$false)
            }
        }
    }
}
function Get-Optional($Object,[string]$Name){
    if($Object -and $Object.PSObject.Properties[$Name]){return $Object.$Name}
}
function Wait-GuiJob($Job) {
    $end=[DateTime]::UtcNow.AddSeconds(50)
    while($Job.state -eq 'running' -and [DateTime]::UtcNow -lt $end){
        Start-Sleep -Milliseconds 300
        $Job=Invoke-RestMethod -Uri ($origin+'/api/jobs/'+$Job.id) -Headers $headers
    }
    if($Job.state -eq 'running'){throw 'GUI job timed out.'}
    return $Job
}
function Send-Gui([string]$Path,$Value) {
    Invoke-RestMethod -Uri ($origin+$Path) -Method Post -Headers $headers -ContentType 'application/json' -Body (ConvertTo-Json -InputObject $Value -Depth 9 -Compress)
}
Test-ProxySelection
Test-WebRTCSetting
if($Online -and -not ('CdfGuiFixturePipe' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

public static class CdfGuiFixturePipe {
    [StructLayout(LayoutKind.Sequential)] struct Entry { public IntPtr Sid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetTokenInformation(SafeAccessTokenHandle token,uint cls,IntPtr data,int size,out int used);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe,out uint pid);

    public static string LogonSid(SafeAccessTokenHandle token) {
        int used;
        GetTokenInformation(token,2,IntPtr.Zero,0,out used);
        if (used<16 || used>65536) throw new InvalidOperationException("Token group size");
        var data=Marshal.AllocHGlobal(used);
        try {
            if (!GetTokenInformation(token,2,data,used,out used)) throw new Win32Exception();
            int count=Marshal.ReadInt32(data), step=Marshal.SizeOf<Entry>();
            if (count<1 || count>(used-IntPtr.Size)/step) throw new InvalidOperationException("Token groups");
            for(int i=0;i<count;i++){
                var e=Marshal.PtrToStructure<Entry>(IntPtr.Add(data,IntPtr.Size+i*step));
                if ((e.Attributes&0xc0000000)==0xc0000000) return new SecurityIdentifier(e.Sid).Value;
            }
            throw new InvalidOperationException("Logon group missing");
        } finally { Marshal.FreeHGlobal(data); }
    }
    public static bool Matches(SafePipeHandle pipe,uint expected){
        uint pid;
        return GetNamedPipeServerProcessId(pipe,out pid) && pid==expected;
    }
}
'@
}
function Read-TransportSnapshot([int]$ProcessId,[long]$Since) {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $logon=[CdfGuiFixturePipe]::LogonSid($identity.AccessToken)
    $name="ClaudeDesktopFake.$logon.connections.$ProcessId"
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut,
        [IO.Pipes.PipeOptions]::Asynchronous,[Security.Principal.TokenImpersonationLevel]::Identification)
    $timeout=[Threading.CancellationTokenSource]::new(3500)
    try{
        [void]$pipe.ConnectAsync($timeout.Token).GetAwaiter().GetResult()
        if(-not [CdfGuiFixturePipe]::Matches($pipe.SafePipeHandle,[uint32]$ProcessId)){throw 'Unrelated pipe server.'}
        $request=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{version=1;since=$Since;dnsSince=0} -Compress))
        $data=[byte[]]([BitConverter]::GetBytes([int]$request.Length)+$request)
        [void]$pipe.WriteAsync($data,0,$data.Length,$timeout.Token).GetAwaiter().GetResult()
        $header=[byte[]]::new(4)
        [void]$pipe.ReadExactlyAsync([Memory[byte]]::new($header),$timeout.Token).AsTask().GetAwaiter().GetResult()
        $size=[BitConverter]::ToInt32($header,0)
        if($size -lt 1 -or $size -gt 2MB){throw 'Invalid fixture telemetry frame.'}
        $payload=[byte[]]::new($size)
        [void]$pipe.ReadExactlyAsync([Memory[byte]]::new($payload),$timeout.Token).AsTask().GetAwaiter().GetResult()
        $ack=[byte[]]@(1,0,0,0,1)
        [void]$pipe.WriteAsync($ack,0,$ack.Length,$timeout.Token).GetAwaiter().GetResult()
        return [Text.Encoding]::UTF8.GetString($payload)|ConvertFrom-Json
    }finally{$timeout.Dispose();$pipe.Dispose();$identity.Dispose()}
}
function Test-LiveTransport($Proxy) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $bin 'CdfNetworkConnectionProbe64.exe'
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true
    $info.RedirectStandardOutput=$true
    $info.ArgumentList.Add((Join-Path $shared 'network\active.dpapi'))
    $info.ArgumentList.Add([string]$Proxy.interfaceGuid)
    $info.ArgumentList.Add('--dns')
    $probe=[Diagnostics.Process]::Start($info)
    try{
        $phase=$probe.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(32)).GetAwaiter().GetResult()
        Check ($phase -eq 'connected') ('Isolated proxy relay started: '+$phase)
        $active=$null
        for($n=0;$n -lt 10;$n++){
            $active=Read-TransportSnapshot $probe.Id 0
            if(@($active.active|Where-Object state -eq 'active').Count){break}
            Start-Sleep -Milliseconds 100
        }
        Check ($active.pid -eq $probe.Id -and $active.active.Count -eq 1 -and $active.active[0].state -eq 'active') 'Actual proxy relay appears active in pipe snapshot'
        $dns=@($active.dns.queries|Where-Object name -eq 'api.ipify.org')
        Check (@($dns|Where-Object {$_.type -eq 'A' -and $_.status -eq 'ok' -and $_.addresses.Count}).Count -eq 1) 'Actual proxied DNS query publishes its IPv4 answers'
        Check (@($dns|Where-Object {$_.type -eq 'AAAA' -and $_.status -eq 'blocked-ipv6'}).Count -eq 1) 'AAAA query is recorded as blocked locally'
        $probe.StandardInput.WriteLine('close')
        $probe.StandardInput.Flush()
        Check ($probe.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(7)).GetAwaiter().GetResult() -eq 'closed') 'Isolated socket closed'
        $closed=Read-TransportSnapshot $probe.Id $active.cursor
        Check ($closed.active.Count -eq 0 -and $closed.closed.Count -eq 1 -and $closed.closed[0].id -eq $active.active[0].id) 'Same relay appears once in closed history'
        $probe.StandardInput.WriteLine('exit')
        $probe.StandardInput.Flush()
        Check ($probe.WaitForExit(4500) -and $probe.ExitCode -eq 0) 'Isolated proxy relay fixture exited'
    }finally{if(-not $probe.HasExited){$probe.Kill();[void]$probe.WaitForExit(4500)};$probe.Dispose()}
}

if(Get-Process -Name CdfGui64 -ErrorAction SilentlyContinue){throw 'Stop the existing GUI before invoking this isolated test.'}
$reserved=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$reserved.Start()
$origin=$null
$headers=$null
try{
    $port=$reserved.LocalEndpoint.Port
    $start=& (Join-Path $PSScriptRoot 'Start-Gui.ps1') -Port $port -NoBrowser -ReadOnly:$ReadOnly|ConvertFrom-Json
    $origin=$start.origin
    $headers=@{Origin=$origin}
    $ticket=([Uri]$start.ticketUrl).Fragment.Substring(8)
    $session=Send-Gui '/api/session' @{ticket=$ticket}
    $headers.Authorization='Bearer '+$session.session
    Check ($start.fallback -and ([Uri]$origin).Port -ne $port) 'Occupied port uses another loopback port'
    $second=& (Join-Path $PSScriptRoot 'Start-Gui.ps1') -Port 0 -NoBrowser -ReadOnly:$ReadOnly|ConvertFrom-Json
    Check ($second.origin -eq $origin -and $second.ticketUrl -ne $start.ticketUrl) 'Repeated launch reopens the singleton with a fresh ticket'
    $duplicate=Invoke-WebRequest -Uri ($origin+'/api/session') -Method Post -ContentType 'application/json' -Headers $headers -Body (@{ticket=$ticket}|ConvertTo-Json -Compress) -SkipHttpErrorCheck
    Check ($duplicate.StatusCode -eq 401) 'Opening ticket cannot be replayed'
    $noToken=Invoke-WebRequest -Uri ($origin+'/api/status') -SkipHttpErrorCheck
    Check ($noToken.StatusCode -eq 401) 'Unauthenticated status is denied'
    $cross=Invoke-WebRequest -Uri ($origin+'/api/actions') -Method Post -ContentType 'application/json' -Headers @{Origin='http://localhost.invalid';Authorization=$headers.Authorization} -Body '{"action":"check"}' -SkipHttpErrorCheck
    Check ($cross.StatusCode -eq 403) 'Requests from another origin are denied'
    $status=$null
    for($attempt=0;$attempt -lt 30;$attempt++){
        $status=Invoke-RestMethod -Uri ($origin+'/api/status') -Headers $headers
        if($status.data -or (Get-Optional $status 'error')){break}
        Start-Sleep -Milliseconds 500
    }
    $statusError=Get-Optional $status 'error'
    Check ([bool]$status.data -and -not $statusError) ('Reads deployed configuration and live process status: '+$statusError)
    Check ($status.canManage -ne [bool]$ReadOnly) 'Privilege controls reflect setup'
    Check ($status.data.webRTCDisabled -is [bool] -and [bool]$status.data.webRTCRevision) 'Reads the WebRTC policy and its revision'
    $childScope=$status.data.networkChildTargets
    $configuredNames=(Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\claude-network-children.json') -Raw | ConvertFrom-Json).imageNames
    Check ($childScope.scope -ceq 'registered-claude-descendants' -and ($childScope.imageNames -join ',') -ieq ($configuredNames -join ',')) 'Reports the configured Claude descendant names'
    Check ($childScope.enforcement -ceq 'not-configured' -and $childScope.firstConnectionEnforced -eq $false) 'GUI distinguishes descendant observation from network enforcement'
    $check=Wait-GuiJob (Send-Gui '/api/actions' @{action='check'})
    Check ($check.state -eq 'done' -and $check.result.checks.Count -ge 3) ('Local check: '+(Get-Optional $check 'message'))
    $time=@{enabled=$true;timeZoneId='Eastern Standard Time';utcOffsetSeconds=-3600}
    $locale=@{enabled=$true;formatLocale='de-DE';uiLanguage='ja-JP'}
    $preview=Wait-GuiJob (Send-Gui '/api/actions' @{action='time.preview';time=$time;locale=$locale})
    Check ($preview.state -eq 'done' -and $preview.result.preview.utcClockShiftSeconds -eq -3600 -and $preview.result.preview.locale.uiLanguage -eq 'ja-JP') ('Preview uses independent locale and UTC offset: '+(Get-Optional $preview 'message'))
    if(-not $ReadOnly){
        $stale=Wait-GuiJob (Send-Gui '/api/actions' @{action='time.save';revision=('0'*64);time=$time;locale=$locale})
        Check ($stale.state -eq 'failed' -and $stale.message -match '配置已被其他操作修改') 'Privileged broker rejects a stale edit'
        $staleWebRTC=Wait-GuiJob (Send-Gui '/api/actions' @{action='webrtc.switch';enabled=$false;revision=('0'*64)})
        Check ($staleWebRTC.state -eq 'failed' -and $staleWebRTC.message -match 'WebRTC 配置已被其他操作修改') 'WebRTC switch rejects a stale edit'
    }
    $rows=Invoke-RestMethod -Uri ($origin+'/api/connections') -Headers $headers
    Check ($null -ne $rows.active -and $null -ne $rows.closed) 'Connections endpoint returns separate collections'
    Check ((Send-Gui '/api/connections/clear' @{}).cleared) 'Clear closed history leaves the service active'
    Check ($null -ne $rows.dns -and (Send-Gui '/api/dns/clear' @{}).cleared) 'DNS events have their own history and clear action'
    if($Online){
        $proxy=@{interfaceGuid=$status.data.proxy.interfaceGuid;reuse=$true}
        $exit=Wait-GuiJob (Send-Gui '/api/actions' @{action='proxy.test';proxy=$proxy})
        Check ($exit.state -eq 'done' -and [bool]$exit.result.ip) ('Private proxy HTTPS test: '+(Get-Optional $exit 'message'))
        Test-LiveTransport $proxy
    }
}finally{
    if($origin -and $headers -and $headers.ContainsKey('Authorization')){Send-Gui '/api/stop' @{}|Out-Null}
    $reserved.Stop()
    foreach($path in $before.Keys){
        $actual=if([IO.File]::Exists($path)){(Get-FileHash -LiteralPath $path).Hash}else{$null}
        Check ($actual -ceq $before[$path]) ('Deployment unchanged: '+[IO.Path]::GetFileName($path))
    }
}
[pscustomobject]@{passed=$true;checks=$passed.Count;online=[bool]$Online;results=@($passed)}|ConvertTo-Json -Depth 6
