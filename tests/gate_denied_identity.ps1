param([string]$Image,[string]$OutputPath)
$ErrorActionPreference='Stop'
if(-not ('CdfGateSuspended' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public sealed class CdfGateSuspended : IDisposable {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct SI {
  public uint cb; public string reserved,desktop,title; public uint x,y,cx,cy,xc,yc,fill,flags; public ushort show,reserved2; public IntPtr reservedPtr,input,output,error;
 }
 [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr process,thread; public uint pid,tid; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr a,IntPtr b,bool inherit,uint flags,IntPtr env,string cwd,ref SI si,out PI pi);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr handle);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint ms);
 [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
 [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr handle,uint code);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 PI pi;
 public static CdfGateSuspended Start(string image,IntPtr output) {
  if(!SetHandleInformation(output,1,1)) throw new Win32Exception(Marshal.GetLastWin32Error());
  SI si=new SI {cb=(uint)Marshal.SizeOf<SI>(),flags=0x100,output=output,error=output}; PI p;
  try { if(!CreateProcess(image,new StringBuilder("\""+image+"\" --expect deny"),IntPtr.Zero,IntPtr.Zero,true,0x08000004,IntPtr.Zero,null,ref si,out p)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
  finally { SetHandleInformation(output,1,0); }
  return new CdfGateSuspended { pi=p };
 }
 public uint Run() {
  if(ResumeThread(pi.thread)==0xffffffff) throw new Win32Exception(Marshal.GetLastWin32Error());
  if(WaitForSingleObject(pi.process,10000)!=0) throw new TimeoutException("Denied-identity fixture timed out");
  uint code; if(!GetExitCodeProcess(pi.process,out code)) throw new Win32Exception(Marshal.GetLastWin32Error()); return code;
 }
 public void Dispose() { if(pi.process!=IntPtr.Zero) { if(WaitForSingleObject(pi.process,0)!=0) TerminateProcess(pi.process,1460); CloseHandle(pi.thread); CloseHandle(pi.process); pi.process=IntPtr.Zero; } }
}
'@
}
$acl=Get-Acl -LiteralPath $Image
$file=[IO.File]::Open($OutputPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
$process=$null
try{
    $process=[CdfGateSuspended]::Start($Image,$file.SafeFileHandle.DangerousGetHandle())
    # The image is already mapped, but its loader/TLS have not run. Deny access
    # to this fixture only, so the provider's Native metadata open must fail.
    $denied=Get-Acl -LiteralPath $Image
    $denied.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Deny))
    Set-Acl -LiteralPath $Image -AclObject $denied
    $code=$process.Run()
}finally{
    Set-Acl -LiteralPath $Image -AclObject $acl
    if($process){$process.Dispose()};$file.Dispose()
}
$text=[IO.File]::ReadAllText($OutputPath);$observed=$text|ConvertFrom-Json
if($code -ne 0 -or $observed.tls.identityReason -ne 'image-file-unavailable' -or -not $observed.matched){throw "Denied-identity fixture failed: exit=$code $text"}
[pscustomobject]@{passed=$true;exitCode=$code;observation=$observed}
