# Read-only process inspection. No remote calls, threads or process writes.
Set-StrictMode -Version Latest
if(-not ('CdfClaudeReadMemory' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class CdfClaudeReadMemory {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint id);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] data, UIntPtr size, out UIntPtr read);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static byte[] Read(uint id, long address, int count) {
    IntPtr h=OpenProcess(0x410,false,id);
    if(h==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    try { byte[] data=new byte[count]; UIntPtr got;
      if(!ReadProcessMemory(h,new IntPtr(address),data,(UIntPtr)count,out got) || got.ToUInt64()!=(ulong)count) throw new Win32Exception(Marshal.GetLastWin32Error());
      return data;
    } finally { CloseHandle(h); }
  }
}
'@
}
function Get-CdfClaudeProcessDiagnostic([int]$ProcessId,[string]$DllPath,[string]$MapPath){
    $result=[ordered]@{pid=$ProcessId;providerLoaded=$null;identity=$null;time=$null;locale=$null;runtime=$null;inspectionError=$null;method='ReadProcessMemory; no remote execution'}
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById($ProcessId)
        $module=@($process.Modules|Where-Object ModuleName -ieq ([IO.Path]::GetFileName($DllPath)))
        $result.providerLoaded=$module.Count -gt 0
        if(-not $result.providerLoaded){return [pscustomobject]$result}
        if(-not [IO.File]::Exists($MapPath)){throw 'Matching build map is unavailable.'}
        $module=$module[0];$map=Get-Content -Raw -LiteralPath $MapPath
        if((Get-FileHash -LiteralPath $module.FileName).Hash -cne (Get-FileHash -LiteralPath $DllPath).Hash){throw 'Running provider differs from the diagnostic build.'}
        $local=[IO.File]::ReadAllBytes($DllPath);$pe=[BitConverter]::ToInt32($local,60)
        $header=[CdfClaudeReadMemory]::Read($ProcessId,$module.BaseAddress.ToInt64(),$pe+256)
        foreach($o in @(($pe+8),($pe+80))){if([BitConverter]::ToUInt32($header,$o) -ne [BitConverter]::ToUInt32($local,$o)){throw 'Mapped provider header differs from the diagnostic build.'}}
        $preferred=[BitConverter]::ToUInt64($local,$pe+48);$remote=$module.BaseAddress.ToInt64()
        function Read-Symbol([string]$Name,[string]$Object,[int]$Count){
            $pattern='(?m)^\s+[0-9a-f]+:[0-9a-f]+\s+\?'+[regex]::Escape($Name)+'@\S+\s+([0-9a-f]+)\s+'+[regex]::Escape($Object)+'\.cpp\.obj\s*$'
            $m=[regex]::Matches($map,$pattern)
            if($m.Count -ne 1){throw "Ambiguous or missing diagnostic symbol: $Object/$Name"}
            $rva=[Convert]::ToInt64($m[0].Groups[1].Value,16)-[long]$preferred
            if($rva -lt 0 -or $rva+$Count -gt $module.ModuleMemorySize){throw 'Diagnostic symbol outside module.'}
            ,([CdfClaudeReadMemory]::Read($ProcessId,$remote+$rva,$Count))
        }
        function Text-At([byte[]]$Bytes,[int]$Offset,[int]$Chars){[Text.Encoding]::Unicode.GetString($Bytes,$Offset,$Chars*2).Split([char]0)[0]}
        $data=Read-Symbol identity_status claude_identity 2280
        if([BitConverter]::ToUInt32($data,0) -ne 2280 -or [BitConverter]::ToUInt32($data,4) -ne 1){throw 'Identity diagnostic ABI mismatch.'}
        $reasons=@('not-checked','matched','manifest-missing','manifest-invalid','process-image-unavailable','image-file-unavailable','image-not-listed','file-identity-mismatch')
        $reason=[BitConverter]::ToUInt32($data,12)
        $result.identity=[pscustomobject]@{version=1;state=[BitConverter]::ToUInt32($data,8);reason=$reasons[[Math]::Min([int]$reason,7)];reasonCode=$reason;errorCode=[BitConverter]::ToUInt32($data,16);imageCount=[BitConverter]::ToUInt32($data,20);nativeStatus=[BitConverter]::ToInt32($data,24);volumeSerial=('{0:x16}' -f [BitConverter]::ToUInt64($data,32));fileId=([BitConverter]::ToString($data,40,16).Replace('-','').ToLowerInvariant());size=[BitConverter]::ToUInt64($data,56);lastWriteTimeUtcTicks=[BitConverter]::ToInt64($data,64);signer=(Text-At $data 72 64);currentImagePath=(Text-At $data 200 520);matchedImagePath=(Text-At $data 1240 520)}
        $timeCounts=Read-Symbol counters time_provider (23*8)
        $localeCount=@(Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'include\locale_hooks.inc')|Where-Object {$_ -match '^CDF_LOCALE_HOOK\('}).Count
        $localeCounts=Read-Symbol counters locale_provider ($localeCount*8)
        $sumTime=[UInt64]0;$sumLocale=[UInt64]0
        for($i=0;$i -lt 23;$i++){$sumTime+=[BitConverter]::ToUInt64($timeCounts,$i*8)}
        for($i=0;$i -lt $localeCount;$i++){$sumLocale+=[BitConverter]::ToUInt64($localeCounts,$i*8)}
        $result.time=[pscustomobject]@{initializationState=[BitConverter]::ToUInt32((Read-Symbol state time_provider 4),0);active=(Read-Symbol active time_provider 1)[0] -ne 0;errorStage=[BitConverter]::ToUInt32((Read-Symbol error_stage time_provider 4),0);errorCode=[BitConverter]::ToUInt32((Read-Symbol error_code time_provider 4),0);observedCalls=$sumTime}
        $result.locale=[pscustomobject]@{initializationState=[BitConverter]::ToUInt32((Read-Symbol state locale_provider 4),0);prepared=(Read-Symbol prepared locale_provider 1)[0] -ne 0;errorStage=[BitConverter]::ToUInt32((Read-Symbol error_stage locale_provider 4),0);errorCode=[BitConverter]::ToUInt32((Read-Symbol error_code locale_provider 4),0);observedCalls=$sumLocale}
        $native=Read-Symbol native_thunks time_provider (11*24);$base=Read-Symbol base_thunks time_provider (16*24);$kernel=Read-Symbol kernel_thunks time_provider 24
        $timeResolved=0;$bridgesResolved=0
        if($result.time.active){
            for($i=0;$i -lt 8;$i++){if([BitConverter]::ToUInt64($native,$i*24+8)){$timeResolved++}}
            for($i=0;$i -lt 15;$i++){if([BitConverter]::ToUInt64($base,$i*24+8)){$timeResolved++}}
            for($i=8;$i -lt 11;$i++){if([BitConverter]::ToUInt64($native,$i*24+8)){$bridgesResolved++}}
            if([BitConverter]::ToUInt64($base,15*24+8)){$bridgesResolved++};if([BitConverter]::ToUInt64($kernel,8)){$bridgesResolved++}
        }
        $result.time|Add-Member -NotePropertyMembers @{resolvedHooks=$timeResolved;resolvedBridges=$bridgesResolved;state=($result.time.initializationState -bor $(if($timeResolved -eq 23 -and $bridgesResolved -eq 5){16}else{0}))}
        $bindings=Read-Symbol bindings locale_provider ($localeCount*24);$definitions=Read-Symbol definitions locale_provider ($localeCount*24)
        $localeResolved=0;$aliasResolved=0;$requiredAliases=0
        for($i=0;$i -lt $localeCount;$i++){
            $resolved=$result.locale.prepared;$mask=[BitConverter]::ToUInt32($definitions,$i*24+8)
            for($j=0;$j -lt 3;$j++){
                if(-not($mask -band (1 -shl $j))){continue};$requiredAliases++
                $pointer=[BitConverter]::ToInt64($bindings,$i*24+$j*8)
                if($pointer -eq 0){$resolved=$false;continue}
                if($pointer -lt $remote -or $pointer+24 -gt $remote+$module.ModuleMemorySize){throw 'Locale binding outside provider.'}
                $descriptor=[CdfClaudeReadMemory]::Read($ProcessId,$pointer,24)
                if([BitConverter]::ToUInt64($descriptor,8)){$aliasResolved++}else{$resolved=$false}
            }
            if($resolved){$localeResolved++}
        }
        $result.locale|Add-Member -NotePropertyMembers @{resolvedHooks=$localeResolved;resolvedAliases=$aliasResolved;requiredAliases=$requiredAliases;state=($result.locale.initializationState -bor $(if($localeResolved -eq $localeCount){16}else{0}))}
        if($map -match '\?runtime_status@'){
            try{$result.runtime=(& (Join-Path $PSScriptRoot 'Capture-Runtime.ps1') -ProcessId $ProcessId|ConvertFrom-Json)}catch{$result.runtime=[pscustomobject]@{inspectionError=$_.Exception.Message}}
        }
    }catch{$result.inspectionError=$_.Exception.Message}finally{if($process){$process.Dispose()}}
    [pscustomobject]$result
}
