Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
. (Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')
function Cdf-AutoRoot { Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude-auto' }
function Cdf-AutoReadJson([string]$Path){
    for($attempt=0;$attempt -lt 5;$attempt++){
        try{
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
            try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
            return ($text|ConvertFrom-Json)
        }catch [IO.IOException]{if($attempt -eq 4){throw};[Threading.Thread]::Sleep(50)}
    }
}
function Cdf-AutoDirectories($Context,$Package){
    $enumeration=Cdf-Enumeration $Context $Package
    $packages=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Packages'
    $windowsApps=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'
    if($Context.FolderOverrides){
        $packages=Join-Path $Context.FolderOverrides.LOCALAPPDATA 'Packages'
        $windowsApps=Join-Path $Context.FolderOverrides.PROGRAMFILES 'WindowsApps'
    }
    @($enumeration.directories|ForEach-Object{
        $pattern=Cdf-EnumerationFolderPattern $_
        # A broad user cache must not turn unrelated same-name programs into
        # fail-closed targets. Only Claude namespaces get admission protection.
        if(-not $pattern -and $_.path -in @($packages,$windowsApps)){$pattern=$Context.PackageName+'_*'}
        [pscustomobject]@{path=$_.path;exists=$_.exists;folderNamePattern=$pattern}
    })
}
function Cdf-AutoScopes($Directories){
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result=@(foreach($directory in $Directories){
        $scope=$directory.path.TrimEnd('\')+'\'
        if($directory.folderNamePattern){$scope+=$directory.folderNamePattern+'\'}
        if($scope.Length -ge 480){throw 'Automatic startup protection directory exceeds its ABI limit.'}
        if($seen.Add($scope)){$scope}
    })
    if(-not $result.Count -or $result.Count -gt 16){throw 'Automatic startup protection requires 1 to 16 directory scopes.'}
    ,([string[]]$result)
}
function Cdf-AutoDiscoverPackage($State){
    $contexts=@(('Registry::HKEY_USERS\'+$State.ownerSid+'\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'),
                ('Registry::HKEY_USERS\'+$State.ownerSid+'_Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'))
    $roots=@(foreach($path in $contexts){Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue|Where-Object {$_.PSChildName -like 'AnthropicPBC.Claude_*_x64__*'}|ForEach-Object{
        $entry=Get-ItemProperty -LiteralPath $_.PSPath
        if($entry.PackageRootFolder -and [IO.Directory]::Exists($entry.PackageRootFolder)){[pscustomobject]@{path=$entry.PackageRootFolder;version=[version]$_.PSChildName.Split('_')[1]}}
    }})
    if($roots.Count){$root=($roots|Sort-Object version -Descending|Select-Object -First 1).path}
    elseif([IO.Directory]::Exists($State.packageRoot)){$root=$State.packageRoot}
    else{
        $apps=Join-Path $State.folderOverrides.PROGRAMFILES 'WindowsApps'
        $roots=@((Cdf-ReadEnumerationDirectory $apps).entries|Where-Object {$_.PSIsContainer -and $_.Name -like 'AnthropicPBC.Claude_*_x64__*'}|ForEach-Object{[pscustomobject]@{path=$_.FullName.Replace('\\?\','');version=[version]$_.Name.Split('_')[1]}})
        if(-not $roots.Count){throw 'No Claude package is available for automatic refresh.'}
        $root=($roots|Sort-Object version -Descending|Select-Object -First 1).path
    }
    [xml]$xml=Get-Content -LiteralPath (Join-Path $root 'AppxManifest.xml') -Raw
    $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('m','http://schemas.microsoft.com/appx/manifest/foundation/windows10')
    $identity=$xml.SelectSingleNode('/m:Package/m:Identity',$ns);$app=$xml.SelectSingleNode('/m:Package/m:Applications/m:Application[@Id="Claude"]',$ns)
    if(-not $identity -or -not $app -or $identity.Name -cne 'AnthropicPBC.Claude' -or $identity.ProcessorArchitecture -cne 'x64' -or $app.Executable -ine 'app\Claude.exe'){throw 'Automatic refresh found an invalid Claude package manifest.'}
    [pscustomobject]@{root=$root;packageId=[IO.Path]::GetFileName($root);main=(Join-Path $root $app.Executable);services=@();files=@()}
}
function Cdf-AutoContext([string]$Project,$State=$null){
    $context=New-CdfClaudeContext -Root (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude') `
        -SourceDll (Join-Path $Project 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll') -DllName 'CdfClaudeTimeZone64.dll'
    $context.EnumerationConfigPath=Join-Path $Project 'config\claude-targets.json'
    $context.SkipProcessDiagnostics=$true
    if($State){
        $context.FolderOverrides=$State.folderOverrides
        $discoverFunction=${function:Cdf-AutoDiscoverPackage}
        $context.Discover={& $discoverFunction $State}.GetNewClosure()
        $discovered=Join-Path (Cdf-AutoRoot) 'discovered-images.json'
        if(Test-Path -LiteralPath $discovered){$context.AdditionalImagePaths=@((Cdf-AutoReadJson $discovered).paths)}
    }
    return $context
}
function Cdf-AutoVerifyRelease($State){
    foreach($file in $State.files){
        $path=Join-Path $State.release $file.path
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Automatic refresh release contains a reparse file.'}
        if((Cdf-Hash $path) -cne $file.sha256){throw "Automatic refresh deployment changed: $($file.path)"}
    }
}
function Cdf-AutoRefresh([string]$StateRoot){
    $statePath=Join-Path $StateRoot 'state.json';$state=Cdf-AutoReadJson $statePath
    if(-not $state.enabled){throw 'Automatic refresh has been disabled.'}
    if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -notin @($state.ownerSid,'S-1-5-18')){throw 'Automatic refresh must run as its owner or LocalSystem.'}
    Cdf-AutoVerifyRelease $state
    $context=Cdf-AutoContext $state.release $state;$package=Cdf-DiscoverPackage $context
    $directories=Cdf-AutoDirectories $context $package
    $context.StartupGuardScopes=Cdf-AutoScopes $directories
    $expectedRelease=$state.release;$readJsonFunction=${function:Cdf-AutoReadJson}
    $context.BeforeCommit={
        $current=& $readJsonFunction $statePath
        if(-not $current.enabled -or $current.release -cne $expectedRelease){throw 'Automatic refresh cancelled before commit.'}
    }.GetNewClosure()
    $result=Invoke-CdfClaudeManager $context Enable
    if(-not $result.enabled){throw ('Automatic refresh did not produce a valid registration: '+($result.issues -join '; '))}
    [pscustomobject]@{images=@($result.images).Count;skipped=@($result.skipped).Count;directories=$directories;packageRoot=$package.root;manifestHash=(Cdf-Hash $context.Manifest)}
}
function Cdf-AutoCheckProvider([string]$Path){
    # Inspect the PE export table without loading the provider in this process.
    $bytes=[IO.File]::ReadAllBytes($Path);$pe=[BitConverter]::ToInt32($bytes,60)
    if($pe -lt 64 -or $pe+264 -gt $bytes.Length -or [BitConverter]::ToUInt16($bytes,$pe+24) -ne 0x20b){throw 'An x64 provider build is required.'}
    $sections=[BitConverter]::ToUInt16($bytes,$pe+6);$table=$pe+24+[BitConverter]::ToUInt16($bytes,$pe+20)
    function Raw-Rva([uint32]$Rva){
        for($i=0;$i -lt $sections;$i++){
            $at=$table+40*$i;$va=[BitConverter]::ToUInt32($bytes,$at+12);$size=[BitConverter]::ToUInt32($bytes,$at+16)
            if($Rva -ge $va -and $Rva-$va -lt $size){return [int]([BitConverter]::ToUInt32($bytes,$at+20)+$Rva-$va)}
        };throw 'Provider export RVA is outside its sections.'
    }
    $directory=Raw-Rva ([BitConverter]::ToUInt32($bytes,$pe+136))
    $count=[BitConverter]::ToUInt32($bytes,$directory+24);$names=Raw-Rva ([BitConverter]::ToUInt32($bytes,$directory+32))
    if($count -gt 65536){throw 'Invalid provider export count.'}
    for($i=0;$i -lt $count;$i++){
        $start=Raw-Rva ([BitConverter]::ToUInt32($bytes,$names+4*$i));$end=$start
        while($end -lt $bytes.Length -and $end-$start -lt 256 -and $bytes[$end]){$end++}
        if([Text.Encoding]::ASCII.GetString($bytes,$start,$end-$start) -ceq 'CdfClaudeQueryStartupGuardStatus'){return}
    }
    throw 'Rebuild and upgrade the Claude provider before enabling automatic startup protection.'
}
function Cdf-AutoTaskService { $service=New-Object -ComObject Schedule.Service;$service.Connect();return $service }
function Cdf-AutoTask($Service,[string]$Name){try{return $Service.GetFolder('\').GetTask($Name)}catch{$exception=$_.Exception;while($exception){if(($exception.HResult -band 0xffff) -in @(2,3)){return $null};$exception=$exception.InnerException};throw}}
function Cdf-AutoAccountSid([string]$Account){
    if($Account -match '^S-1-'){return ([Security.Principal.SecurityIdentifier]::new($Account)).Value}
    return ([Security.Principal.NTAccount]::new($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
}
function Cdf-AutoOwnedProcesses([string]$StateRoot,$State){
    $observer=' '+$State.arguments;$helper=$null
    if($State.PSObject.Properties['release']){$helper=' -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $State.release 'scripts\Refresh-Claude.ps1')+'" -StateRoot "'+$StateRoot+'" -ResultPath "'+(Join-Path $StateRoot 'refresh-result.json')+'"'}
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'"|Where-Object {
        $_.CommandLine -and $_.ExecutablePath -ieq $State.shell -and
            ($_.CommandLine.EndsWith($observer,[StringComparison]::OrdinalIgnoreCase) -or ($helper -and $_.CommandLine.EndsWith($helper,[StringComparison]::OrdinalIgnoreCase)))
    })
}
function Cdf-AutoAssertTask($Task,$State){
    if(-not $Task){return}
    $definition=$Task.Definition
    if($definition.RegistrationInfo.Source -cne 'ClaudeDesktopFake.AutoRefresh.v1' -or $definition.Actions.Count -ne 1 -or
       $definition.Actions.Item(1).Path -ine $State.shell -or $definition.Actions.Item(1).Arguments -cne $State.arguments -or
        (Cdf-AutoAccountSid $definition.Principal.UserId) -cne 'S-1-5-18' -or $definition.Principal.LogonType -ne 5 -or
        $definition.Principal.RunLevel -ne 1 -or $definition.Settings.MultipleInstances -ne 2 -or
        $definition.Settings.ExecutionTimeLimit -cne 'PT0S' -or -not $definition.Settings.StartWhenAvailable -or
        $definition.Triggers.Count -ne 2){throw 'Automatic refresh task changed externally; recovery records retained.'}
    $boot=$definition.Triggers.Item(1);$logon=$definition.Triggers.Item(2)
    if($boot.Type -ne 8 -or -not $boot.Enabled -or $boot.Delay -cne 'PT5S' -or $logon.Type -ne 9 -or
        -not $logon.Enabled -or (Cdf-AutoAccountSid $logon.UserId) -cne $State.ownerSid){throw 'Automatic refresh triggers changed externally; recovery records retained.'}
}
function Cdf-AutoStop([string]$StateRoot){
    $path=Join-Path $StateRoot 'state.json';if(-not(Test-Path -LiteralPath $path)){return}
    $state=Cdf-AutoReadJson $path
    $service=Cdf-AutoTaskService;$task=Cdf-AutoTask $service $state.taskName;Cdf-AutoAssertTask $task $state
    $state.enabled=$false;Cdf-Save $path $state
    if($task){$task.Enabled=$false}
    # The task only observes events; all registry mutations are in its helper.
    # Stop the observer first, then let a cancelled helper finish/roll back.
    if($task){
        try{$task.Stop(0)}catch{
            $exception=$_.Exception;$notRunning=$false
            while($exception){if(($exception.HResult -band 0xffff) -eq 0x130b){$notRunning=$true};$exception=$exception.InnerException}
            if(-not $notRunning){throw}
        }
    }
    $mutex=$null;$owned=$false;$deadline=[DateTime]::UtcNow.AddSeconds(180)
    while(@(Cdf-AutoOwnedProcesses $StateRoot $state).Count){
        if([DateTime]::UtcNow -ge $deadline){throw 'Monitoring was cancelled, but its worker/helper has not exited; IFEO and recovery records were preserved. Retry Disable after it finishes.'}
        [Threading.Thread]::Sleep(250)
    }
    # Old releases may have created a SYSTEM-only mutex. Cancellation makes
    # their helper leave naturally; wait for its handle to close, then create
    # the explicitly shared Administrators/SYSTEM mutex.
    while(-not $mutex){
        try{$mutex=Cdf-NewRegistryMutex}catch{
            $exception=$_.Exception;$denied=$false
            while($exception){if($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 5){$denied=$true};$exception=$exception.InnerException}
            if(-not $denied -or [DateTime]::UtcNow -ge $deadline){throw}
            [Threading.Thread]::Sleep(200)
        }
    }
    try{
        try{$owned=$mutex.WaitOne([Math]::Max(0,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds))}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'A deployment is still running; automatic refresh is disabled but its worker was not interrupted.'}
        $healthPath=Join-Path $StateRoot 'health.json'
        if(Test-Path -LiteralPath $healthPath){$health=Cdf-AutoReadJson $healthPath;$health.state='stopped';$health.heartbeatUtc=[DateTime]::UtcNow.ToString('o');Cdf-Save $healthPath $health}
    }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
if(-not('CdfAutoWatchHub' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Threading;
public sealed class CdfAutoWatchHub : IDisposable {
  readonly List<FileSystemWatcher> items=new List<FileSystemWatcher>();
  readonly AutoResetEvent signal=new AutoResetEvent(false);
  long generation,changed;string lastPath="",lastError="";
  public long Generation { get {return Interlocked.Read(ref generation);} }
  public long ChangedTicks { get {return Interlocked.Read(ref changed);} }
  public string LastPath { get {return Volatile.Read(ref lastPath);} }
  public string LastError { get {return Volatile.Read(ref lastError);} }
  void Mark(string path) {Volatile.Write(ref lastPath,path.Length>2048?path.Substring(0,2048):path);Interlocked.Exchange(ref changed,DateTime.UtcNow.Ticks);Interlocked.Increment(ref generation);signal.Set();}
  public void Add(string path,string filter,bool recursive,bool directories) {
    var watcher=new FileSystemWatcher(path,filter);watcher.IncludeSubdirectories=recursive;watcher.InternalBufferSize=32768;
    watcher.NotifyFilter=directories?NotifyFilters.DirectoryName:NotifyFilters.FileName|NotifyFilters.LastWrite|NotifyFilters.Size;
    watcher.Created+=(s,e)=>Mark(e.FullPath);watcher.Changed+=(s,e)=>Mark(e.FullPath);watcher.Deleted+=(s,e)=>Mark(e.FullPath);
    watcher.Renamed+=(s,e)=>Mark(e.FullPath);watcher.Error+=(s,e)=>{Volatile.Write(ref lastError,e.GetException().Message);Mark(path);};
    items.Add(watcher);watcher.EnableRaisingEvents=true;
  }
  public bool Wait(int milliseconds) {return signal.WaitOne(milliseconds);}
  public void Dispose() {foreach(var item in items)item.Dispose();signal.Dispose();}
}
'@
}
function Cdf-AutoWatchers($Directories){
    $hub=[CdfAutoWatchHub]::new();$trees=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try{
        foreach($directory in $Directories){
            if(-not [IO.Directory]::Exists($directory.path)){
                $parent=$directory.path
                while($parent -and -not [IO.Directory]::Exists($parent)){$parent=[IO.Path]::GetDirectoryName($parent)}
                if($parent){$hub.Add($parent,'*',$false,$true)};continue
            }
            if($directory.folderNamePattern){
                $hub.Add($directory.path,$directory.folderNamePattern,$false,$true)
                $matcher=Cdf-EnumerationFolderMatcher $directory.folderNamePattern
                $entries=(Cdf-ReadEnumerationDirectory $directory.path).entries
                $targets=@($entries|Where-Object {$_.PSIsContainer -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $matcher.IsMatch($_.Name)}|ForEach-Object {$_.FullName.Replace('\\?\','')})
            }else{$targets=@($directory.path)}
            foreach($target in $targets){if($trees.Add($target)){$hub.Add($target,'*.exe',$true,$false);$hub.Add($target,'*',$true,$true)}}
        }
        return $hub
    }catch{$hub.Dispose();throw}
}
if(-not('CdfAutoImageProcess' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
public sealed class CdfAutoImageProcess : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct FT {public uint Low,High;}
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint id);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr h,uint flags,StringBuilder text,ref uint size);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern uint QueryDosDevice(string name,char[] target,uint size);
  [DllImport("kernel32.dll")] static extern uint GetLogicalDrives();
  [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h,out FT creation,out FT exit,out FT kernel,out FT user);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint milliseconds);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr h,uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  IntPtr handle;public uint Id;public string NativePath,Path;public long Created;
  public bool Alive {get{return handle!=IntPtr.Zero&&WaitForSingleObject(handle,0)==258;}}
  public static CdfAutoImageProcess Open(uint id){
    IntPtr h=OpenProcess(0x101001,false,id);if(h==IntPtr.Zero)return null;
    var item=new CdfAutoImageProcess();item.handle=h;item.Id=id;
    var text=new StringBuilder(32768);uint size=32768;FT c,e,k,u;
    if(!QueryFullProcessImageName(h,1,text,ref size)||!GetProcessTimes(h,out c,out e,out k,out u)){item.Dispose();return null;}
    item.NativePath=text.ToString();item.Created=(long)(((ulong)c.High<<32)|c.Low);
    uint drives=GetLogicalDrives();
    for(int i=0;i<26;i++)if((drives&(1u<<i))!=0){
      string drive=((char)('A'+i))+":";char[] target=new char[4096];if(QueryDosDevice(drive,target,(uint)target.Length)==0)continue;
      int end=Array.IndexOf(target,'\0');if(end<=0)continue;string prefix=new string(target,0,end);
      if(item.NativePath.StartsWith(prefix+"\\",StringComparison.OrdinalIgnoreCase)){item.Path=drive+item.NativePath.Substring(prefix.Length);break;}
    }
    if(item.Path==null){size=32768;text.Clear();if(QueryFullProcessImageName(h,0,text,ref size))item.Path=text.ToString();}
    return item;
  }
  public bool HasProvider(string name){try{using(var p=Process.GetProcessById((int)Id)){foreach(ProcessModule m in p.Modules)if(string.Equals(m.ModuleName,name,StringComparison.OrdinalIgnoreCase))return true;}}catch{}return false;}
  public bool Kill(){return Alive&&TerminateProcess(handle,0xE0CDF602);}
  public void Dispose(){if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;}}
}
'@
}
function Cdf-AutoInspectProcess([int]$ProcessId,$Images,$SignatureCache,[scriptblock]$Signature=$null,[string]$ProviderName='CdfClaudeTimeZone64.dll',[string]$DiagnosticDll){
    $process=[CdfAutoImageProcess]::Open([uint32]$ProcessId)
    if(-not $process){return [pscustomobject]@{action='unavailable';pid=$ProcessId}}
    try{
        if(-not $process.Path -or -not $process.Alive){return [pscustomobject]@{action='exited';pid=$ProcessId}}
        $identity=Get-CdfImageIdentity $process.Path
        $stamp=$identity.volumeSerial+'/'+$identity.fileId+'/'+$identity.size+'/'+$identity.lastWriteTimeUtcTicks
        $cached=$SignatureCache[$process.Path]
        if(-not $cached -or $cached.stamp -cne $stamp -or ([DateTime]::UtcNow-$cached.at).TotalSeconds -gt 30){
            if($Signature){$result=& $Signature $process.Path;$valid=$result.status -eq 'Valid';$signer=$result.signer}
            else{$result=Get-AuthenticodeSignature -LiteralPath $process.Path -ErrorAction Stop;$valid=$result.Status -eq 'Valid';$signer=if($result.SignerCertificate){$result.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)}else{''}}
            $after=Get-CdfImageIdentity $process.Path
            if($stamp -cne ($after.volumeSerial+'/'+$after.fileId+'/'+$after.size+'/'+$after.lastWriteTimeUtcTicks)){throw 'Process image changed during signature inspection.'}
            $cached=[pscustomobject]@{stamp=$stamp;at=[DateTime]::UtcNow;target=($valid -and [string]::Equals($signer,'Anthropic, PBC',[StringComparison]::OrdinalIgnoreCase))}
            if($SignatureCache.Count -gt 512){$SignatureCache.Clear()};$SignatureCache[$process.Path]=$cached
        }
        if(-not $cached.target){return [pscustomobject]@{action='not-target';pid=$ProcessId}}
        $entries=@($Images|Where-Object nativePath -ieq $process.NativePath);$registered=$false
        if($entries.Count -eq 1){
            $entry=$entries[0]
            $registered=$entry.volumeSerial -ceq $identity.volumeSerial -and $entry.fileId -ceq $identity.fileId -and $entry.size -eq $identity.size -and $entry.lastWriteTimeUtcTicks -eq $identity.lastWriteTimeUtcTicks
        }
        $provider=$registered -and $process.HasProvider($ProviderName)
        if($provider -and $DiagnosticDll){
            $diagnostic=Get-CdfClaudeProcessDiagnostic -ProcessId $ProcessId -DllPath $DiagnosticDll -MapPath ([IO.Path]::ChangeExtension($DiagnosticDll,'map'))
            if($diagnostic.identity){$provider=$diagnostic.identity.reasonCode -eq 1}
        }
        if($provider){return [pscustomobject]@{action='registered';pid=$ProcessId;path=$process.Path}}
        if($registered -and ([DateTime]::UtcNow.ToFileTimeUtc()-$process.Created) -lt 20000000L){return [pscustomobject]@{action='initializing';pid=$ProcessId;path=$process.Path}}
        $killed=$process.Kill()
        [pscustomobject]@{action=$(if($killed){'terminated'}elseif(-not $process.Alive){'exited'}else{'termination-failed'});pid=$ProcessId;created=$process.Created;path=$process.Path;reason=$(if($registered){'provider-not-loaded'}else{'unregistered-image'});signer='Anthropic, PBC';exitCode=[Convert]::ToUInt32('E0CDF602',16)}
    }catch{[pscustomobject]@{action='inspection-failed';pid=$ProcessId;error=$_.Exception.Message}}finally{$process.Dispose()}
}
function Cdf-AutoRememberImage([string]$StateRoot,[string]$Path){
    if($Path -notmatch '^[A-Za-z]:\\'){return}
    $file=Join-Path $StateRoot 'discovered-images.json';$paths=@()
    if(Test-Path -LiteralPath $file){$paths=@((Cdf-AutoReadJson $file).paths)}
    if($Path -notin $paths){
        if($paths.Count -ge 64){throw 'Automatic process discovery reached its 64-image input limit.'}
        $paths+=@($Path);Cdf-Save $file ([pscustomobject]@{schemaVersion=1;paths=$paths})
    }
}
