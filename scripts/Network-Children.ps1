# Read-only scope for external network tools. Shared executables must never be
# added to the signed image manifest or to machine-wide IFEO by this list.
function Read-CdfNetworkChildNames([string]$Path) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length -gt 16384){throw 'The network child list exceeds 16 KiB.'}
    $json=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xfeff)
    $config=ConvertFrom-Json -InputObject $json -ErrorAction Stop
    if($config -isnot [pscustomobject]){throw 'Expected a network child list object.'}
    $fields=@($config.PSObject.Properties.Name)
    if($fields.Count -ne 2 -or 'schemaVersion' -cnotin $fields -or 'imageNames' -cnotin $fields){
        throw 'Expected schemaVersion and imageNames in the network child list.'
    }
    if(($config.schemaVersion -isnot [int] -and $config.schemaVersion -isnot [long]) -or
        $config.schemaVersion -ne 1 -or $config.imageNames -isnot [array] -or $config.imageNames.Count -gt 64){
        throw 'Expected network child list version 1 with at most 64 executable names.'
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($name in $config.imageNames){
        if($name -isnot [string] -or $name.Length -gt 128 -or $name -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\.exe\z' -or -not $seen.Add($name)){
            throw 'Network child names must be distinct executable basenames.'
        }
        $name.ToLowerInvariant()
    }
}

function Find-CdfNetworkChildren([object[]]$Images,[string[]]$ImageNames,[object[]]$Processes) {
    $registered=@{}
    foreach($image in $Images){
        if($image.name -ieq 'claude.exe'){$registered[$image.path]=$image}
    }
    $byPid=@{}
    $roots=@{}
    $unverified=0
    foreach($process in $Processes){
        $id=[int]$process.ProcessId
        $byPid[$id]=$process
        if($process.Name -ine 'claude.exe'){continue}
        $path=$process.ExecutablePath
        if($path -and $registered.ContainsKey($path)){
            $expected=$registered[$path]
            try{$actual=Get-CdfImageIdentity $path}catch{$unverified++;continue}
            $nativePath=$actual.nativePath
        }else{
            # CIM can report a Store alias. Reuse the running provider's verified
            # identity, and require its match to still be in the current manifest.
            $provider=Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll'
            $diagnostic=Get-CdfClaudeProcessDiagnostic $id $provider ([IO.Path]::ChangeExtension($provider,'map')) -IdentityOnly
            $actual=$diagnostic.identity
            if(-not $actual -or $actual.reasonCode -ne 1 -or -not $actual.matchedImagePath -or -not $registered.ContainsKey($actual.matchedImagePath)){
                if(-not $path -or $diagnostic.inspectionError -or ($actual -and $actual.reasonCode -eq 1)){$unverified++}
                continue
            }
            $expected=$registered[$actual.matchedImagePath]
            $nativePath=$actual.currentImagePath
        }
        if($nativePath -ieq $expected.nativePath -and $actual.volumeSerial -ieq $expected.volumeSerial -and
            $actual.fileId -ieq $expected.fileId -and $actual.size -eq $expected.size -and
            $actual.lastWriteTimeUtcTicks -eq $expected.lastWriteTimeUtcTicks -and $process.CreationDate -is [datetime]){
            $roots[$id]=$true
        }else{$unverified++}
    }
    $running=@(foreach($process in $Processes){
        if($process.Name -notin $ImageNames){continue}
        $current=$process
        $depth=0
        while($current.CreationDate -is [datetime]){
            $parent=$byPid[[int]$current.ParentProcessId]
            # A recycled PID or ambiguous timestamp is not evidence of ancestry.
            # Strictly decreasing dates also bound traversal in a malformed graph.
            if(-not $parent -or $parent.CreationDate -isnot [datetime] -or $parent.CreationDate -ge $current.CreationDate){break}
            $depth++
            if($roots.ContainsKey([int]$parent.ProcessId)){
                [pscustomobject]@{name=$process.Name;pid=[int]$process.ProcessId;parentPid=[int]$process.ParentProcessId
                    claudePid=[int]$parent.ProcessId;depth=$depth;createdUtc=$process.CreationDate.ToUniversalTime().ToString('o')}
                break
            }
            $current=$parent
        }
    })
    [pscustomobject]@{running=$running;verifiedRoots=$roots.Count;unverifiedRoots=$unverified}
}

function Get-CdfNetworkChildTargets($Manifest) {
    $path=Join-Path (Split-Path -Parent $PSScriptRoot) 'config\claude-network-children.json'
    $result=[ordered]@{scope='registered-claude-descendants';imageNames=@();running=@();inspection='complete'
        verifiedRoots=0;unverifiedRoots=0;enforcement='not-configured';firstConnectionEnforced=$false;error=$null}
    try{
        $result.imageNames=@(Read-CdfNetworkChildNames $path)
        if(-not $Manifest){
            $result.inspection='no-manifest'
        }elseif($result.imageNames.Count){
            $processes=@(Get-CimInstance Win32_Process -Property Name,ProcessId,ParentProcessId,CreationDate,ExecutablePath -ErrorAction Stop)
            $found=Find-CdfNetworkChildren @($Manifest.images) $result.imageNames $processes
            $result.running=$found.running
            $result.verifiedRoots=$found.verifiedRoots
            $result.unverifiedRoots=$found.unverifiedRoots
            if($found.unverifiedRoots){$result.inspection='partial'}
        }
    }catch{$result.inspection='unavailable';$result.error=$_.Exception.Message}
    [pscustomobject]$result
}
