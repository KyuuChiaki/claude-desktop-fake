#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProxyProfilePath,[Parameter(Mandatory)][string]$InterfaceAlias)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot;$bin=Join-Path $root 'out\build\x64-release\bin'
$image='CdfNetworkElectron64.exe';$exe=Join-Path $root ('out\runtime-fixtures\electron-44.9.3\'+$image)
$run=Join-Path $root ('out\build\x64-release\test-results\network-debug-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Force -Path $run
. (Join-Path $PSScriptRoot 'Claude-ProcessDiagnostics.ps1')
if(-not ('CdfNetworkDebugChild' -as [type])){Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public sealed class CdfNetworkDebugChild : IDisposable {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct SI {
  public int cb; public string reserved,desktop,title;public int x,y,xSize,ySize,xChars,yChars,fill,flags;public short show,reservedSize;public IntPtr reserved2,input,output,error;
 }
 [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr process,thread;public uint pid,tid; }
 [StructLayout(LayoutKind.Sequential)] struct SA{public int size;public IntPtr descriptor;[MarshalAs(UnmanagedType.Bool)]public bool inherit;}
 [StructLayout(LayoutKind.Explicit,Size=176)] public struct Event {
  [FieldOffset(0)]public uint code;[FieldOffset(4)]public uint pid;[FieldOffset(8)]public uint tid;
  [FieldOffset(16)]public uint exception;[FieldOffset(16)]public IntPtr file;
  [FieldOffset(24)]public IntPtr module;[FieldOffset(32)]public IntPtr address;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref SI startup,out PI process);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool WaitForDebugEvent(out Event e,uint milliseconds);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool ContinueDebugEvent(uint pid,uint tid,uint status);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h,uint code);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string path,uint access,uint share,ref SA security,uint disposition,uint attributes,IntPtr template);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern uint GetFinalPathNameByHandleW(IntPtr file,StringBuilder name,uint size,uint flags);
 PI process;public uint Id {get{return process.pid;}}public bool Exited;
 public CdfNetworkDebugChild(string executable,string arguments,string stdout,string stderr,string environment){var sa=new SA();sa.size=Marshal.SizeOf(typeof(SA));sa.inherit=true;var si=new SI();si.cb=Marshal.SizeOf(typeof(SI));si.flags=1|0x100;si.show=0;si.input=CreateFileW("NUL",0x80000000,3,ref sa,3,0x80,IntPtr.Zero);si.output=CreateFileW(stdout,0x40000000,3,ref sa,2,0x80,IntPtr.Zero);si.error=CreateFileW(stderr,0x40000000,3,ref sa,2,0x80,IntPtr.Zero);IntPtr block=Marshal.StringToHGlobalUni(environment);try{if(!CreateProcessW(executable,new StringBuilder("\""+executable+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,true,2|0x400|0x08000000,block,null,ref si,out process))throw new System.ComponentModel.Win32Exception();CloseHandle(process.thread);}finally{Marshal.FreeHGlobal(block);CloseHandle(si.input);CloseHandle(si.output);CloseHandle(si.error);}}
 public bool Next(out Event e){return WaitForDebugEvent(out e,100);}
 public void Continue(Event e){uint status=e.code==1 && e.exception!=0x80000003 ? 0x80010001u:0x10002u;if(!ContinueDebugEvent(e.pid,e.tid,status))throw new System.ComponentModel.Win32Exception();if(e.code==5)Exited=true;}
 public static string PathFor(Event e){if(e.code!=6)return "";var s=new StringBuilder(2048);GetFinalPathNameByHandleW(e.file,s,2048,0);return s.ToString();}
 public static void CloseEventFile(Event e){if((e.code==3||e.code==6)&&e.file!=IntPtr.Zero)CloseHandle(e.file);}
 public void Dispose(){if(!Exited)TerminateProcess(process.process,0xE0CDF7FE);CloseHandle(process.process);}
}
'@}
$bytes=[IO.File]::ReadAllBytes((Join-Path $bin 'CdfNetwork64.dll'));$pe=[BitConverter]::ToInt32($bytes,60);$preferred=[BitConverter]::ToInt64($bytes,$pe+48);$map=[IO.File]::ReadAllText((Join-Path $bin 'CdfNetwork64.map'))
function Symbol-Rva([string]$Name){$found=[regex]::Matches($map,('(?m)^\s+[0-9a-f]+:[0-9a-f]+\s+\?'+$Name+'@network@cdf@@\S+\s+([0-9a-f]+)\s+network_provider\.cpp\.obj\s*$'));if($found.Count -ne 1){throw "Missing map symbol: $Name"};[Convert]::ToInt64($found[0].Groups[1].Value,16)-$preferred}
$failureRva=Symbol-Rva 'import_failure';$statusRva=Symbol-Rva 'diagnostic';$manager=Join-Path $PSScriptRoot 'Manage-Network.ps1'
$before=& $manager -Action Status -ImageName $image|ConvertFrom-Json;if($before.managed){throw 'A pre-existing registration will not be borrowed.'}
$saved=@{};$child=$null;$moduleBase=0L;$evidence=[Collections.Generic.List[object]]::new();$debugEvents=[Collections.Generic.List[object]]::new()
try{
    foreach($name in @('CDF_NETWORK_REPORT','CDF_NETWORK_USER_DATA','CDF_NETWORK_ADDON','ELECTRON_RUN_AS_NODE','NODE_OPTIONS')){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    $env:CDF_NETWORK_REPORT=Join-Path $run 'electron.json';$env:CDF_NETWORK_USER_DATA=Join-Path $run 'userdata';$env:CDF_NETWORK_ADDON=Join-Path $bin 'CdfNetworkNative64.node';[Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE',$null,'Process');[Environment]::SetEnvironmentVariable('NODE_OPTIONS',$null,'Process')
    & $manager -Action Install -ImageName $image -ProviderPath (Join-Path $bin 'CdfNetwork64.dll') -TransportPath (Join-Path $bin 'CdfProxyTransport64.dll') -ProxyProfilePath $ProxyProfilePath -InterfaceAlias $InterfaceAlias|Out-Null
    $environmentBlock=(@([Environment]::GetEnvironmentVariables('Process').GetEnumerator()|Where-Object {$_.Key -notin @('ELECTRON_RUN_AS_NODE','NODE_OPTIONS')}|Sort-Object Key|ForEach-Object {"$($_.Key)=$($_.Value)"}) -join [char]0)+[char]0
    $child=[CdfNetworkDebugChild]::new($exe,('"'+(Join-Path $root 'tests\network_electron.cjs')+'"'),(Join-Path $run 'stdout.txt'),(Join-Path $run 'stderr.txt'),$environmentBlock);$watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not $child.Exited -and $watch.Elapsed.TotalSeconds -lt 45){
        $event=[CdfNetworkDebugChild+Event]::new();if(-not $child.Next([ref]$event)){continue}
        try{
            $debugEvents.Add([pscustomobject]@{code=$event.code;pid=$event.pid;exception=('{0:x8}' -f $event.exception);module=$(if($event.code -eq 6){[CdfNetworkDebugChild]::PathFor($event)}else{''});moduleBase=('{0:x16}' -f $event.module.ToInt64())})
            if($event.code -eq 1 -and -not $moduleBase){try{$module=@(([Diagnostics.Process]::GetProcessById([int]$child.Id)).Modules|Where-Object ModuleName -eq 'CdfNetwork64.dll');if($module.Count -eq 1){$moduleBase=$module[0].BaseAddress.ToInt64()}}catch{}}
            if($event.code -eq 6 -and [IO.Path]::GetFileName([CdfNetworkDebugChild]::PathFor($event)) -ieq 'CdfNetwork64.dll'){$moduleBase=$event.module.ToInt64()}
            if($event.code -eq 1 -and $event.exception -eq 2147483651 -and $moduleBase){
                $status=[CdfClaudeReadMemory]::Read([int]$child.Id,$moduleBase+$statusRva,544)
                if([BitConverter]::ToUInt32($status,8) -band [uint32]2147483648){$failure=[CdfClaudeReadMemory]::Read([int]$child.Id,$moduleBase+$failureRva,272);$evidence.Add([pscustomobject]@{pid=$child.Id;stage=[BitConverter]::ToUInt32($failure,0);ntstatus=('{0:x8}' -f [BitConverter]::ToUInt32($failure,4));address=('{0:x16}' -f [BitConverter]::ToUInt64($failure,8));module=[Text.Encoding]::Unicode.GetString($failure,16,256).Split([char]0)[0]})}
            }
        }finally{[CdfNetworkDebugChild]::CloseEventFile($event);$child.Continue($event)}
    }
    $evidence|ConvertTo-Json -Depth 5|Out-File (Join-Path $run 'failure.json') -Encoding utf8
    $debugEvents|ConvertTo-Json -Depth 5|Out-File (Join-Path $run 'debug-events.json') -Encoding utf8
    $evidence|ConvertTo-Json -Depth 5
}finally{
    if($child){$rootId=$child.Id;$child.Dispose();Get-CimInstance Win32_Process -Filter ("Name='"+$image+"'")|Where-Object ParentProcessId -eq $rootId|ForEach-Object{try{Stop-Process -Id $_.ProcessId -ErrorAction Stop}catch{}}}
    & $manager -Action Uninstall -ImageName $image|Out-File (Join-Path $run 'cleanup.json') -Encoding utf8
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
}
