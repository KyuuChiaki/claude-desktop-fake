Set-StrictMode -Version Latest
function Get-CdfWebRTCPolicy([string]$NetworkRoot) {
    $path=Join-Path $NetworkRoot 'protection.json'
    if(-not [IO.File]::Exists($path)){return [pscustomobject]@{disabled=$true;valid=$true}}
    try{
        if((Get-Item -LiteralPath $path -Force).Length -gt 1024){throw 'Protection configuration is larger than expected.'}
        $config=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($config.schemaVersion -ne 1 -or $config.webRTCDisabled -isnot [bool]){throw 'Invalid protection configuration.'}
        return [pscustomobject]@{disabled=$config.webRTCDisabled;valid=$true}
    }catch{return [pscustomobject]@{disabled=$true;valid=$false}}
}

function Get-CdfNetworkModuleUsers([string]$Path) {
    if(-not [IO.File]::Exists($Path)){return}
    $name=[IO.Path]::GetFileName($Path)
    $inventory=& (Join-Path $env:SystemRoot 'System32\tasklist.exe') /m $name /fo csv /nh
    if($LASTEXITCODE){throw 'Unable to inspect the network component module inventory.'}
    foreach($entry in ($inventory|ConvertFrom-Csv -Header name,processId,modules)){
        $processId=0
        if(-not [int]::TryParse($entry.processId,[ref]$processId)){continue}
        $p=$null
        try{
            $p=[Diagnostics.Process]::GetProcessById($processId)
            if($Path -in @($p.Modules|ForEach-Object FileName)){
                [pscustomobject]@{name=$entry.name;pid=$processId;verified=$true}
            }
        }catch [ArgumentException]{
            # The process exited during inspection.
        }catch{
            [pscustomobject]@{name=$entry.name;pid=$processId;verified=$false}
        }finally{if($p){$p.Dispose()}}
    }
}

function Restore-CdfNetworkPending([string]$RuntimeDirectory){
    $recordPath=Join-Path $RuntimeDirectory 'transport-deployment.json';$pendingPath=$recordPath+'.pending.json'
    if(-not [IO.File]::Exists($pendingPath)){return}
    $pending=[IO.File]::ReadAllText($pendingPath)|ConvertFrom-Json
    if(-not $pending.PSObject.Properties['files']){throw "Legacy interrupted deployment requires manual review; retained: $pendingPath"}
    if(@($pending.files).Count -ne 3 -or @($pending.files|ForEach-Object index|Sort-Object -Unique).Count -ne 3){throw 'Invalid transport recovery file set.'}
    $allowed=@('CdfProxyTransport64.dll','active.dpapi','policy.bin')
    $hashes=@{}
    foreach($file in $pending.files){
        if($file.index -notin @(0,1,2)){throw 'Invalid transport recovery index.'}
        if($file.path -cne (Join-Path $RuntimeDirectory $allowed[$file.index]) -or $file.backup -cne ($file.path+'.network-backup')){throw 'Invalid transport recovery paths.'}
        $hash=if([IO.File]::Exists($file.path)){(Get-FileHash -LiteralPath $file.path).Hash}else{$null}
        $hashes[$file.index]=$hash
        if($hash -ne $file.beforeHash -and $hash -ne $file.afterHash){throw "External deployment conflict: $($file.path); recovery retained."}
        if($file.beforeHash -and (-not [IO.File]::Exists($file.backup) -or (Get-FileHash -LiteralPath $file.backup).Hash -ne $file.beforeHash)){throw 'Deployment backup is missing or changed.'}
    }
    $current=if([IO.File]::Exists($recordPath)){[IO.File]::ReadAllText($recordPath)}else{$null}
    $installed=$false
    if($current){$record=$current|ConvertFrom-Json;if($record.PSObject.Properties['policySha256'] -and $record.PSObject.Properties['transportSha256'] -and $record.PSObject.Properties['profileSha256']){$installed=($record.policySha256 -eq $pending.policySha256 -and $record.transportSha256 -eq $pending.transportSha256 -and $record.profileSha256 -eq $pending.profileSha256)}}
    if($installed){foreach($file in $pending.files){if(-not [IO.File]::Exists($file.path) -or (Get-FileHash -LiteralPath $file.path).Hash -ne $file.afterHash){throw 'Committed deployment no longer matches; recovery retained.'}}}
    else{
        if($current -cne $pending.previousRecord){throw 'External ownership-record modification; recovery retained.'}
        foreach($file in $pending.files){
            if($hashes[$file.index] -ceq $file.beforeHash){continue}
            if($file.beforeHash){Copy-Item -LiteralPath $file.backup -Destination $file.path -Force;Set-CdfNetworkFileAcl $file.path -Private:($file.index -eq 1)}
            elseif([IO.File]::Exists($file.path)){Remove-Item -LiteralPath $file.path}
        }
    }
    foreach($file in $pending.files){if([IO.File]::Exists($file.backup)){Remove-Item -LiteralPath $file.backup}}
    Remove-Item -LiteralPath $pendingPath
}
function Set-CdfNetworkFileAcl([string]$Path,[switch]$Private) {
    $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
    $reader=if($Private){[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}else{'S-1-5-32-545'}
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($reader),'ReadAndExecute','Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-CdfNetworkDeploymentStatus([string]$RuntimeDirectory){
    $recordPath=Join-Path $RuntimeDirectory 'transport-deployment.json'
    if(-not [IO.File]::Exists($recordPath)){return $null}
    $record=[IO.File]::ReadAllText($recordPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $ok=$true
    foreach($pair in @(@($record.transportPath,$record.transportSha256),@($record.profilePath,$record.profileSha256),@($record.policyPath,$record.policySha256))){if(-not [IO.File]::Exists($pair[0]) -or (Get-FileHash -LiteralPath $pair[0]).Hash -ne $pair[1]){$ok=$false}}
    [pscustomobject]@{owned=$true;hashesMatch=$ok;interfaceGuid=$record.interfaceGuid;transportPath=$record.transportPath;profilePath=$record.profilePath;policyPath=$record.policyPath;credentialScope='CurrentUser'}
}
function Initialize-CdfNetworkDeployment([string]$RuntimeDirectory,[string]$TransportPath,[string]$ProfilePath,[string]$InterfaceAlias){
    Restore-CdfNetworkPending $RuntimeDirectory
    if(-not $TransportPath -or -not $ProfilePath -or -not $InterfaceAlias){throw 'Install requires -TransportPath, -ProxyProfilePath and -InterfaceAlias.'}
    $transport=(Resolve-Path -LiteralPath $TransportPath).ProviderPath;$profile=(Resolve-Path -LiteralPath $ProfilePath).ProviderPath
    Assert-Amd64Dll $transport
    $adapter=Get-NetAdapter -Name $InterfaceAlias -ErrorAction Stop
    if($adapter.Status -ne 'Up' -or -not $adapter.HardwareInterface){throw 'Select an active physical network adapter.'}
    $guid=([Guid]$adapter.InterfaceGuid).ToString('B')
    Add-Type -AssemblyName System.Security
    $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($profile),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {$config=[Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
        if($config.type -ne 'vless' -or $config.network -ne 'tcp' -or $config.flow -ne 'xtls-rprx-vision' -or $config.'client-fingerprint' -ne 'chrome'){throw 'Unsupported private transport profile.'}
        $address=$null;if(-not [Net.IPAddress]::TryParse([string]$config.server,[ref]$address) -or $address.AddressFamily -ne 'InterNetwork'){throw 'The upstream requires a numeric IPv4 address.'}
        $route=@(Find-NetRoute -RemoteIPAddress $address.IPAddressToString -InterfaceIndex $adapter.InterfaceIndex | Where-Object {$_.CimClass.CimClassName -eq 'MSFT_NetRoute'})
        if($route.Count -ne 1 -or $route[0].InterfaceIndex -ne $adapter.InterfaceIndex){throw 'The upstream route does not use the selected physical adapter; no routing configuration was changed.'}
    } finally {[Array]::Clear($plain,0,$plain.Length);$config=$null}
    $null=New-Item -ItemType Directory -Force -Path $RuntimeDirectory
    $targetTransport=Join-Path $RuntimeDirectory 'CdfProxyTransport64.dll';$targetProfile=Join-Path $RuntimeDirectory 'active.dpapi';$targetPolicy=Join-Path $RuntimeDirectory 'policy.bin';$recordPath=Join-Path $RuntimeDirectory 'transport-deployment.json'
    $transportHash=(Get-FileHash -LiteralPath $transport).Hash;$profileHash=(Get-FileHash -LiteralPath $profile).Hash
    $old=$null
    if([IO.File]::Exists($recordPath)){
        $old=[IO.File]::ReadAllText($recordPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($old.schemaVersion -ne 1 -or $old.transportPath -cne $targetTransport -or $old.profilePath -cne $targetProfile -or $old.policyPath -cne $targetPolicy -or -not (Get-CdfNetworkDeploymentStatus $RuntimeDirectory).hashesMatch){throw 'External transport/configuration modification; recovery files retained.'}
        $managed=@(Get-ChildItem -LiteralPath (Join-Path $RuntimeDirectory 'state') -Filter '*.json' -ErrorAction SilentlyContinue)
        if($managed.Count -gt 0 -and ($old.transportSha256 -ne $transportHash -or $old.profileSha256 -ne $profileHash -or $old.interfaceGuid -ne $guid)){throw 'Managed test images still reference another transport or policy. Uninstall them before updating.'}
    }else{foreach($path in @($targetTransport,$targetProfile,$targetPolicy)){if([IO.File]::Exists($path)){throw "Refusing to replace an unowned network file: $path"}}}
    $stream=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($stream)
    try{
        $writer.Write([uint32]0x4e464443);$writer.Write([uint32]1);$writer.Write([uint32]2208);$writer.Write([uint32]0)
        foreach($entry in @(@($targetTransport,512),@($targetProfile,512),@($guid,40))){$bytes=[Text.Encoding]::Unicode.GetBytes([string]$entry[0]);if($bytes.Length -ge ([int]$entry[1]*2)){throw 'Network policy path is too long.'};$fixed=[byte[]]::new([int]$entry[1]*2);[Array]::Copy($bytes,$fixed,$bytes.Length);$writer.Write($fixed)}
        foreach($hash in @($transportHash,$profileHash)){for($i=0;$i -lt 64;$i+=2){$writer.Write([Convert]::ToByte($hash.Substring($i,2),16))}}
        $writer.Flush();$policyBytes=$stream.ToArray()
    } finally{$writer.Dispose();$stream.Dispose()}
    if($policyBytes.Length -ne 2208){throw 'Policy ABI mismatch.'}
    $sha=[Security.Cryptography.SHA256]::Create();try{$policyHash=([BitConverter]::ToString($sha.ComputeHash($policyBytes))).Replace('-','')}finally{$sha.Dispose()}
    if($old -and $old.policySha256 -ceq $policyHash){return Get-CdfNetworkDeploymentStatus $RuntimeDirectory}
    $files=@();$paths=@($targetTransport,$targetProfile,$targetPolicy);$hashes=@($transportHash,$profileHash,$policyHash)
    for($i=0;$i -lt 3;$i++){
        $backup=$paths[$i]+'.network-backup';if([IO.File]::Exists($backup)){throw "Unowned recovery backup exists: $backup"}
        $beforeHash=$null
        if([IO.File]::Exists($paths[$i])){$beforeHash=(Get-FileHash -LiteralPath $paths[$i]).Hash;Copy-Item -LiteralPath $paths[$i] -Destination $backup;Set-CdfNetworkFileAcl $backup -Private}
        $files+= [pscustomobject]@{index=$i;path=$paths[$i];backup=$backup;beforeHash=$beforeHash;afterHash=$hashes[$i]}
    }
    $previousRecord=if([IO.File]::Exists($recordPath)){[IO.File]::ReadAllText($recordPath)}else{$null}
    $pendingRecord=[pscustomobject]@{schemaVersion=1;phase='prepared';transportPath=$targetTransport;transportSha256=$transportHash;profilePath=$targetProfile;profileSha256=$profileHash;policyPath=$targetPolicy;policySha256=$policyHash;interfaceGuid=$guid;previousRecord=$previousRecord;files=$files}
    $pendingPath=$recordPath+'.pending.json'
    if([IO.File]::Exists($pendingPath)){throw "An interrupted transport deployment requires recovery: $pendingPath"}
    Save-JsonAtomically $pendingRecord $pendingPath
    try{
        if($transport -ine $targetTransport -and (-not [IO.File]::Exists($targetTransport) -or (Get-FileHash -LiteralPath $targetTransport).Hash -ne $transportHash)){Copy-Item -LiteralPath $transport -Destination $targetTransport -Force}
        if($profile -ine $targetProfile -and (-not [IO.File]::Exists($targetProfile) -or (Get-FileHash -LiteralPath $targetProfile).Hash -ne $profileHash)){Copy-Item -LiteralPath $profile -Destination $targetProfile -Force}
        [IO.File]::WriteAllBytes($targetPolicy,$policyBytes)
        Set-CdfNetworkFileAcl $targetTransport;Set-CdfNetworkFileAcl $targetProfile -Private;Set-CdfNetworkFileAcl $targetPolicy
        $pendingRecord.policySha256=(Get-FileHash -LiteralPath $targetPolicy).Hash;$pendingRecord.phase='installed'
        $committed=[pscustomobject]@{schemaVersion=1;phase='installed';transportPath=$targetTransport;transportSha256=$transportHash;profilePath=$targetProfile;profileSha256=$profileHash;policyPath=$targetPolicy;policySha256=$policyHash;interfaceGuid=$guid}
        Save-JsonAtomically $committed $recordPath
        Restore-CdfNetworkPending $RuntimeDirectory
    }catch{throw "Transport deployment failed; recovery materials retained at $pendingPath. $($_.Exception.Message)"}
    Get-CdfNetworkDeploymentStatus $RuntimeDirectory
}
