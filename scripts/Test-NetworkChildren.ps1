[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-FileIdentity.ps1')
. (Join-Path $PSScriptRoot 'Network-Children.ps1')

$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Name){
    if(-not $Condition){throw "Network child scope: $Name"}
    $checks.Add($Name)
}
function New-Row([int]$Id,[int]$Parent,[string]$Name,$Seconds,[string]$Path=''){
    $creation=if($null -ne $Seconds){$start.AddSeconds($Seconds)}else{$null}
    [pscustomobject]@{Name=$Name;ProcessId=$Id;ParentProcessId=$Parent;CreationDate=$creation;ExecutablePath=$Path}
}
# The two alias cases exercise the same diagnostic shape as a Store process.
# Synthetic process IDs are never inspected on the live system.
function Get-CdfClaudeProcessDiagnostic([int]$ProcessId,[string]$DllPath,[string]$MapPath,[switch]$IdentityOnly){
    if(-not $IdentityOnly){throw 'Child scope must request only the identity diagnostic.'}
    if($ProcessId -in @(80,83)){
        $matchedPath=if($ProcessId -eq 80){$fixtureImage.path}else{$otherPath}
        $identity=[pscustomobject]@{reasonCode=1;matchedImagePath=$matchedPath;currentImagePath=$fixtureImage.nativePath
            fileId=$fixtureImage.fileId;volumeSerial=$fixtureImage.volumeSerial;size=$fixtureImage.size
            lastWriteTimeUtcTicks=$fixtureImage.lastWriteTimeUtcTicks}
        return [pscustomobject]@{identity=$identity;inspectionError=$null}
    }
    [pscustomobject]@{identity=$null;inspectionError=$null}
}

$dir=[IO.Directory]::CreateDirectory((Join-Path ([IO.Path]::GetTempPath()) ('CdfNetworkChildren-'+[guid]::NewGuid().ToString('N'))))
$imageFile=Join-Path $dir.FullName 'claude.exe'
$configFile=Join-Path $dir.FullName 'names.json'
try{
    $names=@(Read-CdfNetworkChildNames (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\claude-network-children.json'))
    Check (($names -join ',') -ceq 'ssh.exe,node.exe') 'Shipped list contains the two shared tools'
    $utf8=[Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($configFile,'{"schemaVersion":1,"imageNames":["SSH.EXE","custom-tool.exe"]}',$utf8)
    Check ((@(Read-CdfNetworkChildNames $configFile) -join ',') -ceq 'ssh.exe,custom-tool.exe') 'Normalizes valid configurable names'
    [IO.File]::WriteAllText($configFile,'{"schemaVersion":1,"imageNames":[]}',$utf8)
    Check (@(Read-CdfNetworkChildNames $configFile).Count -eq 0) 'An empty configured list is supported'
    $invalid=@(
        '{"schemaVersion":2,"imageNames":[]}',
        '{"schemaVersion":1,"imageNames":"ssh.exe"}',
        '{"schemaVersion":1,"imageNames":["ssh.exe","SSH.EXE"]}',
        '{"schemaVersion":1,"imageNames":["../node.exe"]}',
        '{"schemaVersion":1,"imageNames":["*.exe"]}',
        '{"schemaVersion":1,"imageNames":[],"allProcesses":true}'
    )
    foreach($candidate in $invalid){
        [IO.File]::WriteAllText($configFile,$candidate,$utf8)
        $rejected=$false
        try{$null=@(Read-CdfNetworkChildNames $configFile)}catch{$rejected=$true}
        Check $rejected ("Rejects invalid configuration "+$candidate)
    }

    # Only file identity is needed. The placeholder is never executed.
    [IO.File]::WriteAllBytes($imageFile,[byte[]](7,8,9))
    $fixtureImage=Get-CdfImageIdentity $imageFile
    $otherPath=Join-Path $dir.FullName 'unregistered\claude.exe'
    $start=[datetime]::UtcNow.Date
    $rows=@(
        (New-Row 10 1 'Claude.exe' 1 $imageFile)
        (New-Row 11 10 'SSH.EXE' 2)
        (New-Row 12 10 'cmd.exe' 3)
        (New-Row 13 12 'node.exe' 4)
        (New-Row 14 10 'node-helper.exe' 5)
        (New-Row 20 1 'pwsh.exe' 1)
        (New-Row 21 20 'ssh.exe' 2)
        (New-Row 22 20 'node.exe' 2)
        (New-Row 30 1 'claude.exe' 1 $otherPath)
        (New-Row 31 30 'ssh.exe' 3)
        (New-Row 40 45678 'node.exe' 4)
        (New-Row 50 10 'shell.exe' 10)
        (New-Row 51 50 'ssh.exe' 9)
        (New-Row 52 50 'ssh.exe' 10)
        (New-Row 53 10 'node.exe' $null)
        (New-Row 60 61 'shell.exe' 4)
        (New-Row 61 60 'node.exe' 5)
        (New-Row 80 1 'claude.exe' 1 'store-alias')
        (New-Row 81 80 'node.exe' 3)
        (New-Row 83 1 'claude.exe' 1 'stale-store-alias')
        (New-Row 84 83 'node.exe' 4)
    )
    $result=Find-CdfNetworkChildren @($fixtureImage) $names $rows
    $byId=@{}
    foreach($row in $result.running){$byId[$row.pid]=$row}
    Check ($byId.Count -eq 3) 'Reports only the three confirmed child identities'
    Check ($byId[11].claudePid -eq 10 -and $byId[11].depth -eq 1) 'Attributes direct SSH to its registered Claude parent'
    Check ($byId[13].parentPid -eq 12 -and $byId[13].claudePid -eq 10 -and $byId[13].depth -eq 2) 'Attributes Node through an intermediate shell'
    Check ($byId[81].claudePid -eq 80 -and $result.verifiedRoots -eq 2) 'Accepts the Store alias when its full registered identity matches'
    Check ($result.unverifiedRoots -eq 1 -and -not $byId.ContainsKey(84)) 'A stale alias cannot establish a root'
    Check (-not $byId.ContainsKey(21) -and -not $byId.ContainsKey(22)) 'Other terminal SSH and Node are outside scope'
    Check (-not $byId.ContainsKey(31)) 'An unregistered same-name Claude does not establish ancestry'
    Check (-not $byId.ContainsKey(40)) 'An exited intermediate cannot establish ancestry'
    Check (-not $byId.ContainsKey(51) -and -not $byId.ContainsKey(52)) 'Reused parent PID and equal creation timestamps are rejected'
    Check (-not $byId.ContainsKey(53) -and -not $byId.ContainsKey(61)) 'Missing timestamps and malformed cycles cannot establish ancestry'
    Check (-not $byId.ContainsKey(14)) 'Matches complete executable names'
    $changed=$fixtureImage.PSObject.Copy()
    $changed.fileId='different'
    $stale=Find-CdfNetworkChildren @($changed) $names $rows
    Check ($stale.running.Count -eq 0 -and $stale.unverifiedRoots -ge 2) 'A changed file identity invalidates ordinary and diagnostic roots'
    $empty=Find-CdfNetworkChildren @() $names $rows
    Check ($empty.running.Count -eq 0) 'An empty manifest cannot classify children'
    $status=Get-CdfNetworkChildTargets $null
    Check (($status.imageNames -join ',') -ceq ($names -join ',') -and $status.inspection -eq 'no-manifest') 'Missing manifest remains visible in status'
    Check ($status.enforcement -eq 'not-configured' -and $status.firstConnectionEnforced -eq $false) 'Observation never advertises first-connection enforcement'
    [pscustomobject]@{passed=$true;count=$checks.Count;checks=$checks.ToArray()} | ConvertTo-Json -Depth 3
}finally{
    [IO.File]::Delete($configFile)
    [IO.File]::Delete($imageFile)
    [IO.Directory]::Delete($dir.FullName,$false)
}
