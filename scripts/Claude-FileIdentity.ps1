Set-StrictMode -Version Latest
if (-not ('CdfClaudeFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class CdfClaudeFile {
  [StructLayout(LayoutKind.Sequential)] struct ID128 { [MarshalAs(UnmanagedType.ByValArray,SizeConst=16)] public byte[] Bytes; }
  [StructLayout(LayoutKind.Sequential)] struct IDINFO { public ulong Volume; public ID128 Id; }
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long Creation,Access,Write,Change; public uint Attributes; }
  public sealed class Identity { public string Path,NativePath,VolumeSerial,FileId; public ulong Size; public long LastWriteTimeUtcTicks; }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandleEx(SafeFileHandle file,int kind,IntPtr data,uint size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileSizeEx(SafeFileHandle file,out long size);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint QueryDosDevice(string drive,char[] target,uint size);
  public static string NativePath(string path) {
    path=System.IO.Path.GetFullPath(path);
    if(path.Length<3 || path[1]!=':' || path[2]!='\\') throw new ArgumentException("A drive-absolute path is required");
    char[] device=new char[4096];if(QueryDosDevice(path.Substring(0,2),device,(uint)device.Length)==0)throw new Win32Exception(Marshal.GetLastWin32Error());
    int end=Array.IndexOf(device,'\0');if(end<=0)throw new ArgumentException("Invalid DOS device path");
    return new string(device,0,end)+path.Substring(2);
  }
  public static Identity Get(string path) {
    path=System.IO.Path.GetFullPath(path);
    if(path.Length<3 || path[1]!=':' || path[2]!='\\') throw new ArgumentException("A drive-absolute path is required");
    char[] device=new char[4096]; if(QueryDosDevice(path.Substring(0,2),device,(uint)device.Length)==0) throw new Win32Exception(Marshal.GetLastWin32Error());
    int end=Array.IndexOf(device,'\0'); if(end<=0) throw new ArgumentException("Invalid DOS device path");
    using(var h=CreateFile(path,0x80,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)) {
      if(h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
      int n=Marshal.SizeOf<IDINFO>(),m=Marshal.SizeOf<BASIC>(); IntPtr p=Marshal.AllocHGlobal(n),q=Marshal.AllocHGlobal(m);
      try {
        if(!GetFileInformationByHandleEx(h,18,p,(uint)n) || !GetFileInformationByHandleEx(h,0,q,(uint)m)) throw new Win32Exception(Marshal.GetLastWin32Error());
        long size; if(!GetFileSizeEx(h,out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var id=Marshal.PtrToStructure<IDINFO>(p); var basic=Marshal.PtrToStructure<BASIC>(q);
        if((basic.Attributes & (0x400|0x10))!=0 || size<=0) throw new ArgumentException("Reparse point, directory or empty image is not supported");
        return new Identity { Path=path,NativePath=new string(device,0,end)+path.Substring(2),VolumeSerial=id.Volume.ToString("x16"),FileId=BitConverter.ToString(id.Id.Bytes).Replace("-", "").ToLowerInvariant(),Size=(ulong)size,LastWriteTimeUtcTicks=basic.Write };
      } finally { Marshal.FreeHGlobal(p); Marshal.FreeHGlobal(q); }
    }
  }
}
'@
}

function Get-CdfImageIdentity([string]$Path) {
    $i=[CdfClaudeFile]::Get($Path)
    [pscustomobject][ordered]@{name=[IO.Path]::GetFileName($i.Path);path=$i.Path;nativePath=$i.NativePath;volumeSerial=$i.VolumeSerial;fileId=$i.FileId;size=$i.Size;lastWriteTimeUtcTicks=$i.LastWriteTimeUtcTicks}
}
