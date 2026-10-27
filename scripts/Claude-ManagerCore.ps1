# Internal implementation shared with isolated tests. The public entry point has
# only -Action; test discovery/signature providers are never script parameters.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-ProcessDiagnostics.ps1')
function New-CdfClaudeContext([string]$Root,[string]$SourceDll,[string]$DllName) {
    [pscustomobject]@{
        Root=$Root; SourceDll=$SourceDll; DllName=$DllName; TargetDll=(Join-Path $env:SystemRoot ('System32\'+$DllName))
        Manifest=(Join-Path $Root 'images.json'); State=(Join-Path $Root 'state.json'); Ownership=(Join-Path $Root 'deployment.json')
        Pending=(Join-Path $Root 'deployment-pending.json'); ImageStates=(Join-Path $Root 'state')
        PackageName='AnthropicPBC.Claude'; Family='AnthropicPBC.Claude_fnn82j28hfe8t'; Signer='Anthropic, PBC'
        Discover=$null; Signature=$null; Fault=$null; Base=$null; Ifeo=$null
    }
}
function Cdf-Hash([string]$Path) { if([IO.File]::Exists($Path)){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}; if(Test-Path -LiteralPath $Path){throw "Expected a regular file: $Path"};return $null }
function Cdf-Json($Value){ConvertTo-Json -InputObject $Value -Depth 24 -Compress}
function Cdf-Save([string]$Path,$Value) {
    $tmp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($tmp,(ConvertTo-Json -InputObject $Value -Depth 24),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($tmp,$Path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$Path)}
    } finally { if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)} }
}
function Cdf-CopyAtomic([string]$From,[string]$To,[string]$Hash) {
    $tmp=$To+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::Copy($From,$tmp,$false);if((Cdf-Hash $tmp) -cne $Hash){throw "Source changed before deployment: $From"}
        if([IO.File]::Exists($To)){[IO.File]::Replace($tmp,$To,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$To)}
    } finally { if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)} }
}
function Cdf-SecureDirectory([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path)){[void](New-Item -ItemType Directory -Path $Path)}
    $item=Get-Item -LiteralPath $Path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Management directory is a reparse point: $Path"}
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    foreach($id in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')) {
        $sid=[Security.Principal.SecurityIdentifier]::new($id);$rights=if($id -eq 'S-1-5-32-545'){'ReadAndExecute'}else{'FullControl'}
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,$rights,'ContainerInherit,ObjectInherit','None','Allow'))
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'));Set-Acl -LiteralPath $Path -AclObject $acl
}
function Cdf-RegistryValue($C,[string]$Image,[string]$Name) {
    $k=$C.Ifeo.OpenSubKey($Image,$false)
    try {
        if(-not $k -or $k.GetValueNames() -notcontains $Name){return [pscustomobject]@{name=$Name;exists=$false;kind=$null;data=$null}}
        [pscustomobject]@{name=$Name;exists=$true;kind=$k.GetValueKind($Name).ToString();data=$k.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
    } finally {if($k){$k.Dispose()}}
}
function Cdf-ValueEqual($A,$B) {if([bool]$A.exists -ne [bool]$B.exists){return $false};if(-not $A.exists){return $true};return $A.kind -ceq $B.kind -and (Cdf-Json $A.data) -ceq (Cdf-Json $B.data)}
function Cdf-SetValue($C,[string]$Image,$Value) {
    $k=$C.Ifeo.OpenSubKey($Image,$true);if(-not $k -and $Value.exists){$k=$C.Ifeo.CreateSubKey($Image)}
    try {
        if(-not $k){return}
        if(-not $Value.exists){$k.DeleteValue($Value.name,$false)}else{
            $kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],$Value.kind);$data=$Value.data
            if($kind -eq 'DWord'){$data=[int]$data};$k.SetValue($Value.name,$data,$kind)
        }
        $k.Flush()
    } finally {if($k){$k.Dispose()}}
}
function Cdf-AssertImage($C,$Item,[switch]$Partial) {
    foreach($expected in $Item.installedValues){
        $actual=Cdf-RegistryValue $C $Item.name $expected.name
        if(Cdf-ValueEqual $actual $expected){continue}
        $original=@($Item.originalValues|Where-Object name -eq $expected.name)[0]
        if($Partial -and (Cdf-ValueEqual $actual $original)){continue}
        throw "External IFEO conflict for $($Item.name)/$($expected.name); recovery records retained."
    }
    $k=$C.Ifeo.OpenSubKey($Item.name,$false)
    try { if($k -and ($k.SubKeyCount -gt 0 -or $k.GetValueNames() -contains 'Debugger' -or $k.GetValueNames() -contains 'UseFilter')){throw "External debugger/filter conflict for $($Item.name)."} }
    finally {if($k){$k.Dispose()}}
}
function Cdf-NewImageState($C,[string]$Name) {
    $Name=$Name.ToLowerInvariant();$k=$C.Ifeo.OpenSubKey($Name,$false);$exists=[bool]$k
    try {if($k -and $k.SubKeyCount){throw "Existing IFEO subkeys for $Name."}}finally{if($k){$k.Dispose()}}
    foreach($key in @('Debugger','UseFilter','VerifierDlls')){if((Cdf-RegistryValue $C $Name $key).exists){throw "Existing $key for $Name; refusing to overwrite."}}
    $original=@('GlobalFlag','VerifierDlls','VerifierFlags'|ForEach-Object{Cdf-RegistryValue $C $Name $_})
    $g=@($original|Where-Object name -eq 'GlobalFlag')[0];$v=@($original|Where-Object name -eq 'VerifierFlags')[0];$flag=[uint32]0
    if($g.exists){
        if($g.kind -eq 'DWord'){$flag=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$g.data),0)}
        elseif($g.kind -eq 'String' -and [string]$g.data -match '^(?:0[xX])?([0-9a-fA-F]{1,8})$'){$flag=[Convert]::ToUInt32($matches[1],16)}
        else{throw "Unsupported GlobalFlag for $Name."}
    }
    if(($flag -band 0x100) -or ($v.exists -and ($v.kind -ne 'DWord' -or [int]$v.data -ne 0))){throw "Existing Verifier settings for $Name."}
    $kind=if($g.exists){$g.kind}else{'DWord'};$new=[uint32]($flag -bor 0x100)
    $data=if($kind -eq 'String'){'0x{0:x8}' -f $new}else{[BitConverter]::ToInt32([BitConverter]::GetBytes($new),0)}
    [pscustomobject]@{schemaVersion=1;name=$Name;keyExisted=$exists;originalValues=$original;installedValues=@(
        [pscustomobject]@{name='VerifierFlags';exists=$true;kind='DWord';data=[int]::MinValue},
        [pscustomobject]@{name='VerifierDlls';exists=$true;kind='String';data=$C.DllName},
        [pscustomobject]@{name='GlobalFlag';exists=$true;kind=$kind;data=$data})}
}
function Cdf-RestoreImage($C,$Item) {
    foreach($name in @('GlobalFlag','VerifierDlls','VerifierFlags')){Cdf-SetValue $C $Item.name (@($Item.originalValues|Where-Object name -eq $name)[0])}
    if(-not $Item.keyExisted){$k=$C.Ifeo.OpenSubKey($Item.name,$false);$empty=$false;try{$empty=$k -and $k.SubKeyCount -eq 0 -and $k.ValueCount -eq 0}finally{if($k){$k.Dispose()}};if($empty){$C.Ifeo.DeleteSubKey($Item.name,$false)}}
}
function Cdf-ReadState($C) {
    if(-not(Test-Path -LiteralPath $C.State)){return $null}
    $s=Get-Content -Raw -LiteralPath $C.State|ConvertFrom-Json
    if($s.schemaVersion -ne 1 -or $s.dllPath -cne $C.TargetDll -or $s.manifestPath -cne $C.Manifest -or $s.phase -notin @('installed','restoring') -or @($s.images).Count -lt 1){throw 'Invalid Claude recovery state.'}
    foreach($i in $s.images){
        if($i.name -notmatch '^[^\\/:*?"<>|\x00-\x1f]+\.exe$' -or @($i.originalValues).Count -ne 3 -or @($i.installedValues).Count -ne 3){throw 'Invalid image recovery entry.'}
        $file=Join-Path $C.ImageStates ($i.name+'.json');if(-not(Test-Path -LiteralPath $file) -or (Cdf-Json (Get-Content -Raw -LiteralPath $file|ConvertFrom-Json)) -cne (Cdf-Json $i)){throw "Image recovery record mismatch: $file"}
    }
    return $s
}
function Cdf-DiscoverPackage($C) {
    if($C.Discover){return & $C.Discover}
    $registry='Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    $entries=@(Get-ChildItem -LiteralPath $registry -ErrorAction SilentlyContinue|Where-Object {$_.PSChildName -like ($C.PackageName+'_*_x64__fnn82j28hfe8t')})
    $candidates=@(foreach($k in $entries){
        $p=Get-ItemProperty -LiteralPath $k.PSPath
        if($p.PackageRootFolder -and (Test-Path -LiteralPath $p.PackageRootFolder)){
            $parts=$k.PSChildName.Split('_');[pscustomobject]@{root=$p.PackageRootFolder;packageId=$k.PSChildName;version=[version]$parts[1]}
        }
    })
    if(-not $candidates.Count){throw 'Claude Store package is not registered for this Windows user.'}
    $p=$candidates|Sort-Object version -Descending|Select-Object -First 1
    [xml]$xml=Get-Content -Raw -LiteralPath (Join-Path $p.root 'AppxManifest.xml')
    $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('m','http://schemas.microsoft.com/appx/manifest/foundation/windows10');$ns.AddNamespace('d','http://schemas.microsoft.com/appx/manifest/desktop/windows10/6')
    $identity=$xml.SelectSingleNode('/m:Package/m:Identity',$ns);$app=$xml.SelectSingleNode('/m:Package/m:Applications/m:Application[@Id="Claude"]',$ns)
    if(-not $identity -or -not $app -or $identity.Name -cne $C.PackageName -or $identity.ProcessorArchitecture -cne 'x64' -or $app.Executable -ine 'app\Claude.exe'){throw 'Claude manifest identity, architecture or entry point is invalid.'}
    $services=@($xml.SelectNodes('/m:Package/m:Applications/m:Application/m:Extensions/d:Extension[@Category="windows.service"]',$ns)|ForEach-Object{[string]$_.Executable})
    [pscustomobject]@{root=[IO.Path]::GetFullPath($p.root);packageId=$p.packageId;main=(Join-Path $p.root $app.Executable);services=$services;files=@(Get-ChildItem -LiteralPath $p.root -Filter '*.exe' -File -Recurse|ForEach-Object FullName)}
}
function Cdf-DiscoverImages($C) {
    $p=Cdf-DiscoverPackage $C;$verified=@();$skipped=@()
    foreach($path in @($p.files|Sort-Object -Unique)) {
        $required=$path -ieq $p.main;$reason=$null;$signer='';$signatureStatus='QueryFailed'
        try {
            $before=Get-CdfImageIdentity $path
            if($before.path.Length -ge 520 -or $before.nativePath.Length -ge 520 -or $before.name.Length -ge 128){throw 'Image path exceeds the provider ABI limit.'}
            if($C.Signature){$sig=& $C.Signature $path;$signatureStatus=[string]$sig.status;$signer=[string]$sig.signer}
            else{$sig=Get-AuthenticodeSignature -LiteralPath $path;$signatureStatus=[string]$sig.Status;if($sig.SignerCertificate){$signer=$sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)}}
            if($signatureStatus -ne 'Valid' -or -not [string]::Equals($signer,$C.Signer,[StringComparison]::OrdinalIgnoreCase)){$reason='signature-mismatch'}
            else{
                # Reading the PE machine does not load or execute the candidate.
                $stream=[IO.File]::OpenRead($path);$reader=[IO.BinaryReader]::new($stream)
                try{$stream.Position=0x3c;$offset=$reader.ReadUInt32();$stream.Position=$offset;if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664){$reason='not-amd64'}}finally{$reader.Dispose()}
                $after=Get-CdfImageIdentity $path;if((Cdf-Json $before) -cne (Cdf-Json $after)){throw 'Image changed during verification.'}
            }
        }catch{$reason=$_.Exception.Message}
        if($reason){
            if($required){throw "Claude main image validation failed: $path; $signatureStatus; $signer; $reason"}
            $skipped+=[pscustomobject]@{path=$path;status=$signatureStatus;signer=$signer;reason=$reason};continue
        }
        $verified+=$after
    }
    if(@($verified|Where-Object path -ieq $p.main).Count -ne 1){throw 'Claude main image was not found in the verified set.'}
    if($verified.Count -gt 64){throw 'Provider supports at most 64 verified images.'}
    [pscustomobject]@{package=$p;images=$verified;skipped=$skipped}
}
function Cdf-AssertDeployment($C,$State) {
    if(Test-Path -LiteralPath $C.TargetDll){
        if(-not(Test-Path -LiteralPath $C.Ownership)){throw "Unowned System32 provider: $($C.TargetDll)"}
        $d=Get-Content -Raw -LiteralPath $C.Ownership|ConvertFrom-Json
        if($d.schemaVersion -ne 1 -or $d.dllPath -cne $C.TargetDll -or $d.dllSha256 -cne (Cdf-Hash $C.TargetDll)){throw 'Provider ownership/hash conflict.'}
    }elseif($State){throw 'Managed Claude provider is missing.'}
    if($State -and ((Cdf-Hash $C.Manifest) -cne $State.manifestSha256 -or (Cdf-Hash $C.TargetDll) -cne $State.dllSha256)){throw 'Managed manifest/provider changed externally.'}
    if($State){
        $manifest=Get-Content -LiteralPath $C.Manifest -Raw|ConvertFrom-Json
        if($manifest.schemaVersion -eq 3){foreach($image in $manifest.images){
            if($image.runtimeBindingSha256 -ceq ('0'*64)){continue}
            $binding=Join-Path (Join-Path (Split-Path -Parent $C.Manifest) 'bindings') ($image.runtimeBindingSha256+'.bin')
            if((Cdf-Hash $binding) -cne $image.runtimeBindingSha256){throw 'Managed runtime binding changed externally; preserving all restoration material.'}
        }}
    }
    if(-not $State -and (Test-Path -LiteralPath $C.Manifest)){throw 'An unowned identity manifest exists.'}
}
function Cdf-ValidateConfig($C) {
    $file=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2\timezone.json'
    $validator=Join-Path (Split-Path -Parent $C.SourceDll) 'CdfTimeRules64.exe'
    if(-not(Test-Path -LiteralPath $file) -or -not(Test-Path -LiteralPath $validator)){throw 'Stage 2 configuration or configuration validator is missing.'}
    $result=& $validator --validate-config $file
    if($LASTEXITCODE -ne 0 -or -not(($result|ConvertFrom-Json).valid)){throw "Invalid Stage 2 configuration: $result"}
}

# A write-ahead journal contains exact old/new file hashes and old/new IFEO
# snapshots. Recovery preflights the entire journal before restoring anything.
function Cdf-Recover($C) {
    if(-not(Test-Path -LiteralPath $C.Pending)){return}
    $j=Get-Content -Raw -LiteralPath $C.Pending|ConvertFrom-Json
    if($j.schemaVersion -ne 1 -or $j.transactionId -notmatch '^[a-f0-9]{32}$' -or $j.phase -notin @('prepared','committed','restored')){throw 'Invalid Claude deployment journal.'}
    $dir=Join-Path $C.Root ('recovery.'+$j.transactionId)
    $allowed=@($C.TargetDll,$C.Manifest,$C.State,$C.Ownership)
    $seen=@{}
    foreach($f in $j.files){
        $target=[IO.Path]::GetFullPath($f.target)
        $imageRecord=([IO.Path]::GetDirectoryName($target) -ieq $C.ImageStates -and [IO.Path]::GetFileName($target) -match '^[^\\/:*?"<>|\x00-\x1f]+\.exe\.json$')
        $bindingRecord=([IO.Path]::GetDirectoryName($target) -ieq (Join-Path (Split-Path -Parent $C.Manifest) 'bindings') -and [IO.Path]::GetFileName($target) -cmatch '^[A-F0-9]{64}\.bin$')
        if(($target -notin $allowed -and -not $imageRecord -and -not $bindingRecord) -or $seen.ContainsKey($target) -or $f.oldFile -notmatch '^\d+\.old$' -or $f.newFile -notmatch '^\d+\.new$'){throw 'Invalid journal file target.'}
        foreach($hash in @($f.oldHash,$f.newHash)){if($hash -and $hash -cnotmatch '^[A-F0-9]{64}$'){throw 'Invalid journal hash.'}}
        $seen[$target]=$true
    }
    foreach($change in $j.registry){
        if($change.name -notmatch '^[^\\/:*?"<>|\x00-\x1f]+\.exe$'){throw 'Invalid journal image name.'}
        foreach($values in @(@{v=$change.old},@{v=$change.new})){
            if(@($values.v).Count -ne 3 -or (@($values.v.name|Sort-Object) -join ',') -cne 'GlobalFlag,VerifierDlls,VerifierFlags'){throw 'Invalid journal registry snapshot.'}
        }
        $key=$C.Ifeo.OpenSubKey($change.name,$false)
        try{if($key -and ($key.SubKeyCount -gt 0 -or $key.GetValueNames() -contains 'Debugger' -or $key.GetValueNames() -contains 'UseFilter')){throw 'Journal registry conflict; recovery retained.'}}finally{if($key){$key.Dispose()}}
    }
    if($j.phase -eq 'committed'){
        foreach($f in $j.files){if((Cdf-Hash $f.target) -cne $f.newHash){throw 'Committed deployment changed externally; recovery retained.'}}
        foreach($change in $j.registry){foreach($value in $change.new){if(-not(Cdf-ValueEqual (Cdf-RegistryValue $C $change.name $value.name) $value)){throw 'Committed IFEO changed externally; recovery retained.'}}}
        foreach($change in $j.registry){if($change.removeKeyIfEmpty){$key=$C.Ifeo.OpenSubKey($change.name,$false);$empty=$false;try{$empty=$key -and $key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0}finally{if($key){$key.Dispose()}};if($empty){$C.Ifeo.DeleteSubKey($change.name,$false)}}}
    }elseif($j.phase -eq 'prepared') {
        foreach($change in $j.registry){foreach($old in $change.old){$actual=Cdf-RegistryValue $C $change.name $old.name;$new=@($change.new|Where-Object name -eq $old.name)[0];if(-not(Cdf-ValueEqual $actual $old) -and -not(Cdf-ValueEqual $actual $new)){throw "Recovery conflict for $($change.name)/$($old.name)."}}}
        foreach($f in $j.files){$hash=Cdf-Hash $f.target;if($hash -cne $f.oldHash -and $hash -cne $f.newHash){throw "Recovery file conflict: $($f.target)"};if($f.oldHash -and (Cdf-Hash (Join-Path $dir $f.oldFile)) -cne $f.oldHash){throw 'Recovery backup changed.'}}
        foreach($change in $j.registry){foreach($old in $change.old){Cdf-SetValue $C $change.name $old};if(-not $change.keyExisted){$k=$C.Ifeo.OpenSubKey($change.name,$false);$empty=$false;try{$empty=$k -and $k.SubKeyCount -eq 0 -and $k.ValueCount -eq 0}finally{if($k){$k.Dispose()}};if($empty){$C.Ifeo.DeleteSubKey($change.name,$false)}}}
        foreach($f in $j.files){if((Cdf-Hash $f.target) -cne $f.oldHash){if($f.oldHash){Cdf-CopyAtomic (Join-Path $dir $f.oldFile) $f.target $f.oldHash}else{[IO.File]::Delete($f.target)}}}
        $j.phase='restored';Cdf-Save $C.Pending $j
    }
    # Delete only a journal directory whose name and parent were checked.
    foreach($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)){[IO.File]::Delete($f.FullName)}
    if(Test-Path -LiteralPath $dir){[IO.Directory]::Delete($dir,$false)};[IO.File]::Delete($C.Pending)
}
function Cdf-Transaction($C,$Registry,$Files) {
    $id=[Guid]::NewGuid().ToString('N');$dir=Join-Path $C.Root ('recovery.'+$id);[void](New-Item -ItemType Directory -Path $dir)
    $j=[pscustomobject]@{schemaVersion=1;transactionId=$id;phase='prepared';registry=@($Registry);files=@()};$n=0
    try{foreach($f in $Files){
        $old=Cdf-Hash $f.target;$oldFile="$n.old";$newFile="$n.new"
        if($old){[IO.File]::Copy($f.target,(Join-Path $dir $oldFile));if((Cdf-Hash (Join-Path $dir $oldFile)) -cne $old){throw 'File changed during backup.'}}
        if($f.source){[IO.File]::Copy($f.source,(Join-Path $dir $newFile))}elseif($null -ne $f.value){Cdf-Save (Join-Path $dir $newFile) $f.value}
        $new=if($f.source -or $null -ne $f.value){Cdf-Hash (Join-Path $dir $newFile)}else{$null}
        $j.files+=[pscustomobject]@{target=$f.target;oldHash=$old;newHash=$new;oldFile=$oldFile;newFile=$newFile};++$n
    }
    Cdf-Save $C.Pending $j
    }catch{foreach($file in @(Get-ChildItem -LiteralPath $dir -File)){[IO.File]::Delete($file.FullName)};[IO.Directory]::Delete($dir,$false);throw}
    try{
        foreach($f in $j.files){if((Cdf-Hash $f.target) -cne $f.oldHash){throw 'External change before deployment.'};if($f.newHash){Cdf-CopyAtomic (Join-Path $dir $f.newFile) $f.target $f.newHash}else{[IO.File]::Delete($f.target)}}
        $writes=0
        foreach($change in $j.registry){foreach($v in $change.new){$actual=Cdf-RegistryValue $C $change.name $v.name;$old=@($change.old|Where-Object name -eq $v.name)[0];if(-not(Cdf-ValueEqual $actual $old)){throw 'IFEO changed during transaction.'};Cdf-SetValue $C $change.name $v;++$writes;if($C.Fault){& $C.Fault $writes}}}
        $j.phase='committed';Cdf-Save $C.Pending $j;Cdf-Recover $C
    }catch{
        $errorText=$_.Exception.Message
        try{Cdf-Recover $C}catch{throw "Transaction failed: $errorText; recovery stopped: $($_.Exception.Message). Journal: $($C.Pending)"}
        throw "Transaction rolled back: $errorText"
    }
}
function Cdf-FileChange([string]$Target,$Value=$null,[string]$Source=$null){[pscustomobject]@{target=$Target;value=$Value;source=$Source}}
function Cdf-Enable($C) {
    if(Test-Path -LiteralPath $C.Pending){throw 'Interrupted Claude transaction exists; run Disable to recover.'}
    $old=Cdf-ReadState $C;if($old){foreach($i in $old.images){Cdf-AssertImage $C $i}}
    Cdf-AssertDeployment $C $old;Cdf-ValidateConfig $C
    if(-not(Test-Path -LiteralPath $C.SourceDll)){throw "Build the Claude provider first: $($C.SourceDll)"}
    $hash=Cdf-Hash $C.SourceDll
    if($old -and $old.dllSha256 -cne $hash){throw 'Disable Claude before replacing its provider version.'}
    $d=Cdf-DiscoverImages $C
    $manifest=[pscustomobject]@{schemaVersion=1;packageName=$C.PackageName;packageFamily=$C.Family;signer=$C.Signer;images=@($d.images)}
    $configuration=Get-Content -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2\timezone.json') -Raw|ConvertFrom-Json
    $bindings=@()
    if($configuration.schemaVersion -eq 3 -and $configuration.runtime.enabled){
        . (Join-Path $PSScriptRoot 'Runtime-Profiles.ps1')
        $manifest.schemaVersion=3
        foreach($image in $manifest.images){
            $profile=Get-CdfRuntimeProfile -Path $image.path -Capture ([bool]$configuration.runtime.captureEnabled) -CreateBinding
            if(-not $profile.supported -and $configuration.runtime.unknownVersionPolicy -eq 'block'){throw "Unsupported runtime fingerprint; Enable refused: $($image.path); $($profile.sha256); reason=$($profile.reason); role=$($profile.failedRole); candidates=$($profile.candidates)"}
            $image|Add-Member -NotePropertyMembers @{runtimeType=$profile.type;adapterId=$profile.adapterId;compatibilityPolicy=$configuration.runtime.unknownVersionPolicy}
            $bindingHash='0'*64
            if($profile.supported -and $profile.type -eq 'electron'){
                $bindingHash=$profile.bindingSha256
                $bindings+=([pscustomobject]@{sha256=$bindingHash;source=$profile.bindingSource})
            }
            $image|Add-Member -NotePropertyName runtimeBindingSha256 -NotePropertyValue $bindingHash
        }
    }
    $states=@();$changes=@()
    foreach($name in @($d.images.name|ForEach-Object{$_.ToLowerInvariant()}|Sort-Object -Unique)){
        $prior=@(if($old){$old.images|Where-Object name -eq $name})
        $item=if($prior.Count){$prior[0]}else{Cdf-NewImageState $C $name};$states+=$item
        if(-not $prior.Count){$changes+=[pscustomobject]@{name=$name;keyExisted=$item.keyExisted;old=$item.originalValues;new=$item.installedValues;removeKeyIfEmpty=$false}}
    }
    if($old){foreach($i in $old.images){if($i.name -notin $states.name){$changes+=[pscustomobject]@{name=$i.name;keyExisted=$true;old=$i.installedValues;new=$i.originalValues;removeKeyIfEmpty=(-not $i.keyExisted)}}}}
    # Hash the exact serialized bytes that Cdf-Save writes.
    $manifestBytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $manifest -Depth 24));if($manifestBytes.Length -gt 65536){throw 'Identity manifest exceeds 64 KiB.'};$sha=[Security.Cryptography.SHA256]::Create();try{$manifestHash=[BitConverter]::ToString($sha.ComputeHash($manifestBytes)).Replace('-','')}finally{$sha.Dispose()}
    $state=[pscustomobject]@{schemaVersion=1;phase='installed';dllPath=$C.TargetDll;dllSha256=$hash;manifestPath=$C.Manifest;manifestSha256=$manifestHash;packageRoot=$d.package.root;packageId=$d.package.packageId;updatedAtUtc=[DateTime]::UtcNow.ToString('o');skipped=@($d.skipped);images=$states}
    if($old -and $old.manifestSha256 -ceq $manifestHash -and -not $changes.Count){return}
    foreach($path in @((Split-Path -Parent $C.Root),$C.Root,$C.ImageStates)){Cdf-SecureDirectory $path}
    $bindingDirectory=Join-Path (Split-Path -Parent $C.Manifest) 'bindings'
    if($bindings.Count){Cdf-SecureDirectory $bindingDirectory}
    $ownership=[pscustomobject]@{schemaVersion=1;dllPath=$C.TargetDll;dllSha256=$hash;manifestPath=$C.Manifest}
    $files=@((Cdf-FileChange $C.Manifest $manifest),(Cdf-FileChange $C.Ownership $ownership),(Cdf-FileChange $C.State $state))
    foreach($binding in @($bindings|Sort-Object sha256 -Unique)){
        $target=Join-Path $bindingDirectory ($binding.sha256+'.bin')
        if(Test-Path -LiteralPath $target){if((Cdf-Hash $target) -cne $binding.sha256){throw 'Runtime binding hash conflict.'}}
        else{$files+=Cdf-FileChange $target -Source $binding.source}
    }
    if((Cdf-Hash $C.TargetDll) -cne $hash){$files=@((Cdf-FileChange $C.TargetDll -Source $C.SourceDll))+$files}
    foreach($i in $states){$files+=Cdf-FileChange (Join-Path $C.ImageStates ($i.name+'.json')) $i}
    if($old){foreach($i in $old.images){if($i.name -notin $states.name){$files+=Cdf-FileChange (Join-Path $C.ImageStates ($i.name+'.json'))}}}
    Cdf-Transaction $C $changes $files
}
function Cdf-Disable($C) {
    Cdf-Recover $C;$old=Cdf-ReadState $C;if(-not $old){return}
    foreach($i in $old.images){Cdf-AssertImage $C $i}
    Cdf-AssertDeployment $C $old
    $changes=@($old.images|ForEach-Object{[pscustomobject]@{name=$_.name;keyExisted=$true;old=$_.installedValues;new=$_.originalValues;removeKeyIfEmpty=(-not $_.keyExisted)}})
    $files=@((Cdf-FileChange $C.State),(Cdf-FileChange $C.Manifest))
    foreach($i in $old.images){$files+=Cdf-FileChange (Join-Path $C.ImageStates ($i.name+'.json'))}
    Cdf-Transaction $C $changes $files
    foreach($i in $old.images){if(-not $i.keyExisted){$k=$C.Ifeo.OpenSubKey($i.name,$false);$empty=$false;try{$empty=$k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0}finally{if($k){$k.Dispose()}};if($empty){$C.Ifeo.DeleteSubKey($i.name,$false)}}}
}
function Cdf-Status($C) {
    $state=$null;$issues=@();try{$state=Cdf-ReadState $C}catch{$issues+=$_.Exception.Message}
    $images=@();$skipped=@();$stale=$false
    if($state){
        foreach($i in $state.images){try{Cdf-AssertImage $C $i}catch{$issues+=$_.Exception.Message}}
        if((Cdf-Hash $C.TargetDll) -cne $state.dllSha256 -or (Cdf-Hash $C.Manifest) -cne $state.manifestSha256){$issues+='Deployment hash mismatch.'}
        try{Cdf-AssertDeployment $C $state}catch{$issues+=$_.Exception.Message}
        try{$m=Get-Content -Raw -LiteralPath $C.Manifest|ConvertFrom-Json;foreach($i in $m.images){$match=$false;try{$match=(Cdf-Json (Get-CdfImageIdentity $i.path)) -ceq (Cdf-Json ($i|Select-Object name,path,nativePath,volumeSerial,fileId,size,lastWriteTimeUtcTicks))}catch{};$images+=[pscustomobject]@{name=$i.name;path=$i.path;signer=$C.Signer;signatureStatus='VerifiedAtEnable';fileIdentityCurrent=$match};if(-not $match){$stale=$true}}}catch{$issues+=$_.Exception.Message}
        $skipped=@($state.skipped)
        try{$p=Cdf-DiscoverPackage $C;if($p.root -ine $state.packageRoot){$stale=$true}}catch{$issues+=$_.Exception.Message;$stale=$true}
    }else{
        try{$discovered=Cdf-DiscoverImages $C;$skipped=@($discovered.skipped);$images=@($discovered.images|ForEach-Object{[pscustomobject]@{name=$_.name;path=$_.path;signer=$C.Signer;signatureStatus='Valid';fileIdentityCurrent=$true}})}catch{$issues+=$_.Exception.Message}
    }
    $runtime=[ordered]@{enabled=$false;configurationVersion=$null;policy=$null;captureEnabled=$false;region=$null;profiles=@();error=$null}
    try{
        $configuration=Get-Content -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2\timezone.json') -Raw|ConvertFrom-Json
        $runtime.configurationVersion=$configuration.schemaVersion
        if($configuration.schemaVersion -eq 3){
            $runtime.enabled=[bool]$configuration.runtime.enabled;$runtime.policy=$configuration.runtime.unknownVersionPolicy;$runtime.captureEnabled=[bool]$configuration.runtime.captureEnabled;$runtime.region=$configuration.region
            if($runtime.enabled){
                . (Join-Path $PSScriptRoot 'Runtime-Profiles.ps1')
                foreach($image in $images){$profile=Get-CdfRuntimeProfile -Path $image.path -Capture ([bool]$configuration.runtime.captureEnabled);$runtime.profiles+=([pscustomobject]@{name=$image.name;path=$image.path;runtime=$profile})}
            }
        }
    }catch{$runtime.error=$_.Exception.Message}
    foreach($image in $images){
        if($state -and (Test-Path -LiteralPath $C.Manifest)){
            try{
                $installed=Get-Content -LiteralPath $C.Manifest -Raw|ConvertFrom-Json
                if($installed.schemaVersion -eq 3){
                    $entry=@($installed.images|Where-Object path -ceq $image.path)
                    if($entry.Count -eq 1 -and $entry[0].runtimeBindingSha256 -cne ('0'*64)){
                        $bindingPath=Join-Path (Join-Path (Split-Path -Parent $C.Manifest) 'bindings') ($entry[0].runtimeBindingSha256+'.bin')
                        $image|Add-Member -NotePropertyName runtimeBinding -NotePropertyValue ([pscustomobject]@{sha256=$entry[0].runtimeBindingSha256;path=$bindingPath;current=((Cdf-Hash $bindingPath) -ceq $entry[0].runtimeBindingSha256)})
                    }
                }
            }catch{$issues+=$_.Exception.Message}
        }
        $registration=[ordered]@{}
        foreach($name in @('GlobalFlag','VerifierDlls','VerifierFlags')){$registration[$name]=Cdf-RegistryValue $C $image.name $name}
        $image|Add-Member -NotePropertyName registration -NotePropertyValue ([pscustomobject]$registration)
    }
    $enabled=[bool]$state -and -not $issues.Count -and -not(Test-Path -LiteralPath $C.Pending)
    $running=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -and $_.ExecutablePath -match '\\WindowsApps\\AnthropicPBC\.Claude_[^\\]+\\'}|ForEach-Object{
        $diagnostic=Get-CdfClaudeProcessDiagnostic -ProcessId $_.ProcessId -DllPath $C.SourceDll -MapPath ([IO.Path]::ChangeExtension($C.SourceDll,'map'))
        $matched=$null -ne $diagnostic.identity -and $diagnostic.identity.reasonCode -eq 1
        [pscustomobject]@{pid=$_.ProcessId;parentPid=$_.ParentProcessId;name=$_.Name;path=$_.ExecutablePath;service=($_.Name -ieq 'cowork-svc.exe');requiresRestart=($(if($enabled){-not $matched}else{$diagnostic.providerLoaded -ne $false}));diagnostic=$diagnostic}
    })
    [pscustomobject]@{managed=[bool]$state;enabled=$enabled;images=$images;skipped=$skipped;stale=$stale;issues=$issues;running=$running;requiresRestart=(@($running|Where-Object requiresRestart).Count -gt 0);statePath=$C.State;manifestPath=$C.Manifest;pendingTransaction=(Test-Path -LiteralPath $C.Pending);providerPath=$C.TargetDll;providerSha256=(Cdf-Hash $C.TargetDll);configurationPath=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2\timezone.json');registryView='Registry64';runtime=[pscustomobject]$runtime}
}
function Invoke-CdfClaudeManager($Context,[ValidateSet('Enable','Status','Disable')][string]$Action) {
    $c=$Context;$mutex=$null;$owned=$false
    try{
        if($Action -ne 'Status'){
            $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
            if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or -not [Environment]::Is64BitProcess){throw 'Use elevated 64-bit PowerShell for Enable/Disable.'}
            $mutex=[Threading.Mutex]::new($false,'Global\ClaudeDesktopFake.Stage1.Registry');try{$owned=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$owned=$true};if(-not $owned){throw 'Another deployment operation is in progress.'}
        }
        $c.Base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
        $c.Ifeo=$c.Base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',($Action -ne 'Status'))
        if(-not $c.Ifeo){throw '64-bit IFEO registry root is unavailable.'}
        switch($Action){'Enable'{Cdf-Enable $c};'Disable'{Cdf-Disable $c}}
        Cdf-Status $c
    }finally{if($c.Ifeo){$c.Ifeo.Dispose();$c.Ifeo=$null};if($c.Base){$c.Base.Dispose();$c.Base=$null};if($owned){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
}
