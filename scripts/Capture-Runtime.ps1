[CmdletBinding()]
param([Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,[string]$OutputPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-ProcessDiagnostics.ps1')
$build=Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release\bin'
$process=[Diagnostics.Process]::GetProcessById($ProcessId)
try{
    $modules=@($process.Modules|Where-Object ModuleName -in @('CdfTimeZone64.dll','CdfClaudeTimeZone64.dll','CdfClaudeTimeZoneTest64.dll'))
    if($modules.Count -ne 1){throw 'Exactly one managed Stage 5 provider must be loaded.'}
    $module=$modules[0];$localPath=Join-Path $build $module.ModuleName;$mapPath=[IO.Path]::ChangeExtension($localPath,'map')
    if(-not(Test-Path -LiteralPath $mapPath) -or (Get-FileHash -LiteralPath $localPath).Hash -cne (Get-FileHash -LiteralPath $module.FileName).Hash){throw 'Matching provider binary and map are required.'}
    $bytes=[IO.File]::ReadAllBytes($localPath);$pe=[BitConverter]::ToInt32($bytes,60);$preferred=[BitConverter]::ToUInt64($bytes,$pe+48)
    $header=[CdfClaudeReadMemory]::Read($ProcessId,$module.BaseAddress.ToInt64(),$pe+256)
    foreach($offset in @(($pe+8),($pe+80))){if([BitConverter]::ToUInt32($header,$offset) -ne [BitConverter]::ToUInt32($bytes,$offset)){throw 'Mapped provider header differs from the diagnostic build.'}}
    $map=Get-Content -LiteralPath $mapPath -Raw
    function Read-Symbol([string]$Name,[string]$Object,[int]$Count){
        $pattern='(?m)^\s+[0-9a-f]+:[0-9a-f]+\s+\?'+[regex]::Escape($Name)+'@\S+\s+([0-9a-f]+)\s+'+[regex]::Escape($Object)+'\.cpp\.obj\s*$'
        $matches=[regex]::Matches($map,$pattern)
        if($matches.Count -ne 1){throw "Missing or ambiguous diagnostic symbol: $Object/$Name"}
        $rva=[Convert]::ToInt64($matches[0].Groups[1].Value,16)-[long]$preferred
        if($rva -lt 0 -or $rva+$Count -gt $module.ModuleMemorySize){throw 'Diagnostic data lies outside the mapped provider.'}
        ,([CdfClaudeReadMemory]::Read($ProcessId,$module.BaseAddress.ToInt64()+$rva,$Count))
    }
    function Text-At([byte[]]$Data,[int]$Offset,[int]$Chars){[Text.Encoding]::Unicode.GetString($Data,$Offset,$Chars*2).Split([char]0)[0]}
    $status=$null
    for($attempt=0;$attempt -lt 3;$attempt++){
        $before=[BitConverter]::ToUInt32((Read-Symbol runtime_sequence runtime_provider 4),0)
        $candidate=Read-Symbol runtime_status runtime_provider 816
        $after=[BitConverter]::ToUInt32((Read-Symbol runtime_sequence runtime_provider 4),0)
        if($before -eq $after -and -not($after -band 1)){$status=$candidate;break}
    }
    if(-not $status -or [BitConverter]::ToUInt32($status,0) -ne 816 -or [BitConverter]::ToUInt32($status,4) -ne 2){throw 'Runtime diagnostic ABI is unavailable, busy or incompatible.'}
    $buffer=Read-Symbol runtime_capture runtime_capture (24+32*8216)
    if([BitConverter]::ToUInt32($buffer,0) -ne $buffer.Length -or [BitConverter]::ToUInt32($buffer,4) -ne 1){throw 'Capture diagnostic ABI mismatch.'}
    $count=[BitConverter]::ToUInt32($buffer,8);if($count -gt 32){throw 'Capture count exceeds its bounded capacity.'}
    $contexts=@()
    for($i=0;$i -lt $count;$i++){
        $offset=24+$i*8216;$sequence=[BitConverter]::ToUInt32($buffer,$offset);$state=[BitConverter]::ToUInt32($buffer,$offset+4);$length=[BitConverter]::ToUInt32($buffer,$offset+12)
        $observation=$null;$error=$null
        if(($sequence -band 1) -or $state -eq 1){$error='sampling-in-progress'}
        elseif($state -eq 2 -and $length -lt 8192){try{$text=[Text.Encoding]::UTF8.GetString($buffer,$offset+24,$length).TrimEnd([char]0);$observation=$text|ConvertFrom-Json}catch{$error='invalid-sample-json'}}
        elseif($state -eq 4){$error='sample-truncated'}else{$error='sampling-failed'}
        $contexts+=[pscustomobject]@{index=$i;threadId=[BitConverter]::ToUInt32($buffer,$offset+8);context=('{0:x16}' -f [BitConverter]::ToUInt64($buffer,$offset+16));state=$state;error=$error;observation=$observation}
    }
    $enabled=[BitConverter]::ToUInt32($status,796) -ne 0
    $fingerprint=[BitConverter]::ToString($status,764,32).Replace('-','').ToLowerInvariant()
    $compat=Read-Symbol compatibility_status runtime_adapter 552
    if([BitConverter]::ToUInt32($compat,0) -notin @(0,552)){throw 'Compatibility diagnostic ABI mismatch.'}
    $compatibility=[pscustomobject]@{version=1;state=[BitConverter]::ToUInt32($compat,8);errorCode=[BitConverter]::ToUInt32($compat,12);failureCode=[BitConverter]::ToUInt32($compat,16);failedRole=[BitConverter]::ToUInt32($compat,20);match=[BitConverter]::ToUInt32($compat,24);catalogRevision=[BitConverter]::ToUInt32($compat,28);coreReady=[BitConverter]::ToUInt32($compat,32) -ne 0;captureReady=[BitConverter]::ToUInt32($compat,36) -ne 0;bindingLoaded=[BitConverter]::ToUInt32($compat,40) -ne 0;siteCount=[BitConverter]::ToUInt32($compat,44);imageSha256=[BitConverter]::ToString($compat,48,32).Replace('-','');engineSha256=[BitConverter]::ToString($compat,80,32).Replace('-','');bindingSha256=[BitConverter]::ToString($compat,112,32).Replace('-','');catalogSha256=[BitConverter]::ToString($compat,144,32).Replace('-','');abiId=(Text-At $compat 176 64);engineId=(Text-At $compat 304 96)}
    $patches=@()
    if([BitConverter]::ToUInt32($compat,496) -ne 0){
        $main=$process.MainModule
        $stream=[IO.File]::Open($main.FileName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete);$reader=[IO.BinaryReader]::new($stream)
        try{
        $stream.Position=60;$imagePe=$reader.ReadInt32();$stream.Position=$imagePe+6;$sectionCount=$reader.ReadUInt16();$stream.Position=$imagePe+20;$optionalSize=$reader.ReadUInt16()
        $sections=@(for($s=0;$s -lt $sectionCount;$s++){$stream.Position=$imagePe+24+$optionalSize+40*$s+12;[pscustomobject]@{rva=$reader.ReadUInt32();bytes=$reader.ReadUInt32();raw=$reader.ReadUInt32()}})
        foreach($index in 0,1){
            $rva=[BitConverter]::ToUInt32($compat,496+4*$index);$length=if($index -eq 0){14}else{20}
            if($rva+$length -gt $main.ModuleMemorySize){throw 'Adapter patch lies outside the executable.'}
            $section=@($sections|Where-Object {$rva -ge $_.rva -and $rva+$length -le $_.rva+$_.bytes})
            if($section.Count -ne 1){throw 'Adapter patch file mapping is ambiguous.'}
            $stream.Position=$section[0].raw+$rva-$section[0].rva;$expected=[BitConverter]::ToString($reader.ReadBytes($length)).Replace('-','')
            $actual=[CdfClaudeReadMemory]::Read($ProcessId,$main.BaseAddress.ToInt64()+$rva,$length)
            $hex=[BitConverter]::ToString($actual).Replace('-','');$kind='unexpected'
            if($hex -ieq $expected){$kind='original'}
            elseif($length -ge 14 -and [BitConverter]::ToString($actual,0,6) -ceq 'FF-25-00-00-00-00'){
                $destination=[BitConverter]::ToInt64($actual,6)
                if($destination -ge $module.BaseAddress.ToInt64() -and $destination -lt $module.BaseAddress.ToInt64()+$module.ModuleMemorySize){$kind='provider-tail-jump'}
            }
            $patches+=[pscustomobject]@{rva=$rva;bytes=$hex;state=$kind}
        }
        }finally{$reader.Dispose();$stream.Dispose()}
    }
    $report=[pscustomobject]@{
        schemaVersion=1;pid=$ProcessId;processName=$process.ProcessName;provider=$module.FileName;providerSha256=(Get-FileHash -LiteralPath $localPath).Hash;method='ReadProcessMemory only; no remote execution'
        runtime=[pscustomobject]@{version=2;state=[BitConverter]::ToUInt32($status,8);errorCode=[BitConverter]::ToUInt32($status,12);errorStage=[BitConverter]::ToUInt32($status,68);configVersion=[BitConverter]::ToUInt32($status,56);policy=$(if([BitConverter]::ToUInt32($status,60)){'passthrough'}else{'block'});compatibility=[BitConverter]::ToUInt32($status,64);patchCount=[BitConverter]::ToUInt32($status,72);homeRegion=(Text-At $status 96 4);formatLocale=(Text-At $status 104 85);uiLanguage=(Text-At $status 274 85);adapterId=(Text-At $status 444 96);runtimeVersion=(Text-At $status 636 64);fingerprint=[BitConverter]::ToString($status,764,32).Replace('-','').ToLowerInvariant()}
        adapterPatches=$patches
        compatibility=$compatibility
        sampling=[pscustomobject]@{enabled=$enabled;state=$(if(-not $enabled){'disabled'}elseif(-not $count){'not-sampled'}else{'observed'});count=$count;failures=[BitConverter]::ToUInt32($buffer,12);truncated=[BitConverter]::ToUInt32($buffer,16);contexts=$contexts}
    }
    $json=$report|ConvertTo-Json -Depth 32
    if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,[Text.UTF8Encoding]::new($false))}
    $json
}finally{$process.Dispose()}
