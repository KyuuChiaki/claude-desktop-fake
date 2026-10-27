[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Install', 'Status', 'Uninstall')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('(?i)^[^\\/:*?"<>|\x00-\x1f]+\.exe$')][string]$ImageName,
    [string]$DllPath,
    [string]$ConfigPath,
    [string]$ImagePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ImageName = $ImageName.ToLowerInvariant()
$runtimeDirectory = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2'
$deployedDll = Join-Path $env:SystemRoot 'System32\CdfTimeZone64.dll'
$deployedConfig = Join-Path $runtimeDirectory 'timezone.json'
$deploymentRecordPath = Join-Path $runtimeDirectory 'deployment.json'
$pendingDeploymentPath = Join-Path $runtimeDirectory 'deployment-pending.json'
$stateDirectory = Join-Path $runtimeDirectory 'state'
$statePath = Join-Path $stateDirectory ($ImageName + '.json')
$bindingDirectory=Join-Path $runtimeDirectory 'bindings'
$script:runtimeBindingPlan=$null
$ifeoPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$trackedNames = @('GlobalFlag', 'VerifierDlls', 'VerifierFlags')
$baseKey = $null
$script:ifeo = $null
$mutex = $null
$mutexOwned = $false

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Install and Uninstall require an elevated PowerShell session.'
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell for the AMD64 System32 provider.' }
}

function Get-RegistryValue([string]$Name) {
    $key = $script:ifeo.OpenSubKey($ImageName, $false)
    try {
        if ($null -eq $key -or $key.GetValueNames() -notcontains $Name) {
            return [pscustomobject]@{ name = $Name; exists = $false; kind = $null; data = $null }
        }
        return [pscustomobject]@{
            name = $Name; exists = $true; kind = $key.GetValueKind($Name).ToString()
            data = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } finally { if ($null -ne $key) { $key.Dispose() } }
}

function Test-ValueEqual($Left, $Right) {
    if ([bool]$Left.exists -ne [bool]$Right.exists) { return $false }
    if (-not $Left.exists) { return $true }
    return ($Left.kind -eq $Right.kind -and
        (ConvertTo-Json -InputObject $Left.data -Compress -Depth 8) -ceq
        (ConvertTo-Json -InputObject $Right.data -Compress -Depth 8))
}

function Assert-InstalledValues($State, [switch]$AllowPartial) {
    foreach ($expected in $State.installedValues) {
        $actual = Get-RegistryValue $expected.name
        if (Test-ValueEqual $actual $expected) { continue }
        $original = @($State.originalValues | Where-Object { $_.name -eq $expected.name })[0]
        if ($AllowPartial -and (Test-ValueEqual $actual $original)) { continue }
        throw "Configuration conflict for $ImageName/$($expected.name). No registry values were restored."
    }
}

function Set-RegistryValue($Value) {
    $key = $script:ifeo.OpenSubKey($ImageName, $true)
    if ($null -eq $key -and $Value.exists) { $key = $script:ifeo.CreateSubKey($ImageName) }
    try {
        if ($null -eq $key) { return }
        if (-not $Value.exists) {
            $key.DeleteValue($Value.name, $false)
        } else {
            $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind], $Value.kind)
            $data = $Value.data
            if ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { $data = [int]$data }
            try { $key.SetValue($Value.name, $data, $kind) }
            catch { throw "Cannot write $ImageName/$($Value.name) ($kind): $($_.Exception.Message)" }
        }
        $key.Flush()
    } finally { if ($null -ne $key) { $key.Dispose() } }
}

function Restore-OriginalValues($State, [switch]$AllowPartial) {
    Assert-InstalledValues $State -AllowPartial:$AllowPartial
    # Disable our verifier flag first, then restore the remaining values.
    foreach ($name in $trackedNames) {
        Set-RegistryValue (@($State.originalValues | Where-Object { $_.name -eq $name })[0])
    }
    if (-not $State.keyExisted) {
        $key = $script:ifeo.OpenSubKey($ImageName, $false)
        $empty = $false
        try { if ($null -ne $key) { $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) } }
        finally { if ($null -ne $key) { $key.Dispose() } }
        if ($empty) { $script:ifeo.DeleteSubKey($ImageName, $false) }
    }
    foreach ($original in $State.originalValues) {
        if (-not (Test-ValueEqual (Get-RegistryValue $original.name) $original)) {
            throw "Restore verification failed for $ImageName/$($original.name). Recovery record retained."
        }
    }
}

function Save-JsonAtomically($Content, [string]$Destination) {
    $temporary = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Content -Depth 12), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Destination)) {
            [IO.File]::Replace($temporary, $Destination, [Management.Automation.Language.NullString]::Value)
        }
        else { [IO.File]::Move($temporary, $Destination) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Save-State($State) { Save-JsonAtomically $State $statePath }

function Assert-OwnedDeployment {
    if (-not (Test-Path -LiteralPath $deploymentRecordPath)) {
        throw "An unowned file exists at $deployedDll. It will not be overwritten."
    }
    $deployment = Get-Content -LiteralPath $deploymentRecordPath -Raw | ConvertFrom-Json
    if ($deployment.schemaVersion -ne 1 -or $deployment.dllPath -cne $deployedDll -or
        $deployment.dllSha256 -cne (Get-FileHash -LiteralPath $deployedDll -Algorithm SHA256).Hash) {
        throw 'Deployment ownership/hash mismatch. The existing System32 file will not be overwritten.'
    }
}

function Assert-Config([string]$Path, [string]$SourceDll) {
    $validator = Join-Path (Split-Path -Parent $SourceDll) 'CdfTimeRules64.exe'
    if (-not (Test-Path -LiteralPath $validator)) { throw "Configuration validator is missing: $validator" }
    $result = & $validator --validate-config $Path
    if ($LASTEXITCODE -ne 0) { throw "Invalid time configuration: $result" }
    $validation = $result | ConvertFrom-Json
    if (-not $validation.valid) { throw 'Configuration validation failed.' }
}

function Assert-DeploymentPlan([string]$DllHash, [string]$ConfigHash) {
    if (Test-Path -LiteralPath $pendingDeploymentPath) {
        throw 'An interrupted deployment exists. Run Uninstall for the recorded image to recover it.'
    }
    $managed = @(Get-ChildItem -LiteralPath $stateDirectory -Filter '*.json')
    if (Test-Path -LiteralPath $deployedDll) {
        Assert-OwnedDeployment
        if ((Get-FileHash -LiteralPath $deployedDll -Algorithm SHA256).Hash -cne $DllHash -and $managed.Count -gt 0) {
            throw 'Other managed targets still use the deployed DLL. Uninstall them before changing it.'
        }
    } elseif ($managed.Count -gt 0) { throw 'The shared DLL is missing while managed images exist.' }
    if (Test-Path -LiteralPath $deployedConfig) {
        if (-not (Test-Path -LiteralPath $deploymentRecordPath)) { throw "Unowned configuration exists: $deployedConfig" }
        $deployment = Get-Content -LiteralPath $deploymentRecordPath -Raw | ConvertFrom-Json
        if (-not $deployment.PSObject.Properties['configSha256'] -or $deployment.configPath -cne $deployedConfig) {
            throw 'Configuration ownership record is missing or invalid.'
        }
        $actual = (Get-FileHash -LiteralPath $deployedConfig -Algorithm SHA256).Hash
        if ($actual -cne $deployment.configSha256) { throw 'Configuration changed outside this installation; refusing to overwrite it.' }
        if ($actual -cne $ConfigHash -and $managed.Count -gt 0) { throw 'Other managed images still use a different configuration. Uninstall them before replacing it.' }
    } elseif ($managed.Count -gt 0) { throw 'The shared configuration is missing while managed images exist.' }
}

function File-Hash([string]$Path) {
    if ([IO.File]::Exists($Path)) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    if (Test-Path -LiteralPath $Path) { throw "Expected a regular file: $Path" }
    return $null
}

function Copy-FileAtomically([string]$Source, [string]$Target, [string]$Hash) {
    $temporary = $Target + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -cne $Hash) { throw 'Source configuration changed during deployment.' }
        if ([IO.File]::Exists($Target)) { [IO.File]::Replace($temporary, $Target, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Target) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Read-DeploymentTransaction {
    $record = Get-Content -LiteralPath $pendingDeploymentPath -Raw | ConvertFrom-Json
    if ($record.schemaVersion -ne 1 -or $record.imageName -cne $ImageName -or
        $record.transactionId -notmatch '^[0-9a-f]{32}$' -or $record.phase -notin @('prepared','committed','restored') -or
        @($record.files).Count -notin @(3,5)) { throw 'Invalid deployment transaction or different owner image. Recovery files retained.' }
    $targets = @($deployedDll, $deployedConfig, $deploymentRecordPath)
    for ($i=0; $i -lt 3; ++$i) {
        if ($record.files[$i].target -cne $targets[$i]) { throw 'Invalid transaction target. Recovery files retained.' }
    }
    if(@($record.files).Count -eq 5){
        foreach($entry in @($record.files[3],$record.files[4])){
            if([IO.Path]::GetDirectoryName($entry.target) -ine $bindingDirectory -or [IO.Path]::GetFileName($entry.target) -cnotmatch '^[A-F0-9]{64}\.(bin|ref)$'){throw 'Invalid runtime binding transaction target.'}
        }
    }
    return $record
}

function Transaction-Directory($Record) { return Join-Path $runtimeDirectory ('deployment-recovery.'+$Record.transactionId) }

function Clear-DeploymentTransaction($Record) {
    $directory = Transaction-Directory $Record
    # Remove only this transaction's exact files; preserve unexpected material.
    foreach ($name in @('0.old','1.old','2.old','3.old','4.old','0.new','1.new','2.new','3.new','4.new')) {
        $path = Join-Path $directory $name
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $false) }
    [IO.File]::Delete($pendingDeploymentPath)
}

function Restore-DeploymentTransaction {
    if (-not (Test-Path -LiteralPath $pendingDeploymentPath)) { return }
    $record = Read-DeploymentTransaction
    $directory = Transaction-Directory $record
    # Validate every target and backup before restoring any target.
    for ($i=0; $i -lt @($record.files).Count; ++$i) {
        $file = $record.files[$i]; $actual = File-Hash $file.target
        if ($record.phase -eq 'restored') {
            if ($actual -cne $file.originalHash) { throw 'Restored deployment changed externally; recovery files retained.' }
        } elseif ($record.phase -eq 'committed') {
            if ($actual -cne $file.installedHash) { throw 'Committed deployment changed externally; recovery files retained.' }
        } else {
            if ($actual -cne $file.originalHash -and $actual -cne $file.installedHash) {
                throw "Deployment conflict at $($file.target); recovery files retained."
            }
            if ($null -ne $file.originalHash -and (File-Hash (Join-Path $directory "$i.old")) -cne $file.originalHash) {
                throw 'Deployment backup missing or changed; recovery files retained.'
            }
        }
    }
    if ($record.phase -eq 'prepared') {
        for ($i=0; $i -lt @($record.files).Count; ++$i) {
            $file = $record.files[$i]; $actual = File-Hash $file.target
            if ($actual -ceq $file.originalHash) { continue }
            if ($actual -cne $file.installedHash) { throw 'External deployment change during rollback; recovery files retained.' }
            if ($null -eq $file.originalHash) { [IO.File]::Delete($file.target) }
            else { Copy-FileAtomically (Join-Path $directory "$i.old") $file.target $file.originalHash }
        }
        $record.phase = 'restored'
        Save-JsonAtomically $record $pendingDeploymentPath
    }
    Clear-DeploymentTransaction $record
}

function Install-Deployment([string]$SourceDll, [string]$DllHash, [string]$SourceConfig, [string]$ConfigHash) {
    Assert-DeploymentPlan $DllHash $ConfigHash
    $record = [pscustomobject]@{schemaVersion=1;imageName=$ImageName;transactionId=[Guid]::NewGuid().ToString('N');phase='prepared';files=@()}
    $directory = Transaction-Directory $record
    $null = New-Item -ItemType Directory -Path $directory
    $hasJournal = $false
    try {
        [IO.File]::Copy($SourceDll, (Join-Path $directory '0.new'), $false)
        [IO.File]::Copy($SourceConfig, (Join-Path $directory '1.new'), $false)
        if ((File-Hash (Join-Path $directory '0.new')) -cne $DllHash -or (File-Hash (Join-Path $directory '1.new')) -cne $ConfigHash) {
            throw 'Source file changed during deployment preparation.'
        }
        $ownership=[pscustomobject]@{schemaVersion=1;dllPath=$deployedDll;dllSha256=$DllHash;configPath=$deployedConfig;configSha256=$ConfigHash;runtimeBindings=@()}
        if(Test-Path -LiteralPath $deploymentRecordPath){$previous=Get-Content -LiteralPath $deploymentRecordPath -Raw|ConvertFrom-Json;if($previous.PSObject.Properties['runtimeBindings']){$ownership.runtimeBindings=@($previous.runtimeBindings)}}
        $targets = @($deployedDll, $deployedConfig, $deploymentRecordPath)
        if($script:runtimeBindingPlan){
            $plan=$script:runtimeBindingPlan
            [void](New-Item -ItemType Directory -Path $bindingDirectory -Force)
            $descriptor=Join-Path $bindingDirectory ($plan.bindingSha256+'.bin');$reference=Join-Path $bindingDirectory ($plan.sha256+'.ref')
            if((Test-Path -LiteralPath $descriptor) -and (File-Hash $descriptor) -cne $plan.bindingSha256){throw 'Existing runtime binding hash conflict.'}
            if(Test-Path -LiteralPath $reference){
                $owned=@($ownership.runtimeBindings|Where-Object imageSha256 -ceq $plan.sha256)
                if($owned.Count -ne 1 -or (File-Hash $reference) -cne $owned[0].referenceSha256){throw 'Unowned or externally modified runtime binding reference.'}
            }
            [IO.File]::Copy($plan.bindingSource,(Join-Path $directory '3.new'))
            [IO.File]::WriteAllText((Join-Path $directory '4.new'),$plan.bindingSha256,[Text.UTF8Encoding]::new($false))
            $ownership.runtimeBindings=@($ownership.runtimeBindings|Where-Object imageSha256 -cne $plan.sha256)+@([pscustomobject]@{imageSha256=$plan.sha256;bindingSha256=$plan.bindingSha256;referenceSha256=(File-Hash (Join-Path $directory '4.new'))})
            $targets+=@($descriptor,$reference)
        }
        Save-JsonAtomically $ownership (Join-Path $directory '2.new')
        for ($i=0; $i -lt $targets.Count; ++$i) {
            $originalHash = File-Hash $targets[$i]
            if ($null -ne $originalHash) {
                [IO.File]::Copy($targets[$i], (Join-Path $directory "$i.old"), $false)
                if ((File-Hash (Join-Path $directory "$i.old")) -cne $originalHash) { throw 'Deployment changed while preparing backup.' }
            }
            $record.files += [pscustomobject]@{target=$targets[$i];originalHash=$originalHash;installedHash=(File-Hash (Join-Path $directory "$i.new"))}
        }
        # Both ownership checks must still hold after preparing the backups.
        Assert-DeploymentPlan $DllHash $ConfigHash
        Save-JsonAtomically $record $pendingDeploymentPath
        $hasJournal = $true
        for ($i=0; $i -lt $targets.Count; ++$i) {
            $file = $record.files[$i]
            if ((File-Hash $file.target) -cne $file.originalHash) { throw 'External deployment change before write.' }
            if ($file.originalHash -cne $file.installedHash) { Copy-FileAtomically (Join-Path $directory "$i.new") $file.target $file.installedHash }
        }
        $record.phase = 'committed'
        Save-JsonAtomically $record $pendingDeploymentPath
        Clear-DeploymentTransaction $record
    } catch {
        $deploymentError = $_
        if ($hasJournal -and (Test-Path -LiteralPath $pendingDeploymentPath)) {
            try { Restore-DeploymentTransaction }
            catch { throw "Deployment failed: $($deploymentError.Exception.Message); recovery stopped: $($_.Exception.Message). Record: $pendingDeploymentPath" }
        } elseif (-not $hasJournal) {
            foreach ($name in @('0.old','1.old','2.old','3.old','4.old','0.new','1.new','2.new','3.new','4.new')) {
                $path = Join-Path $directory $name
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            }
            [IO.Directory]::Delete($directory, $false)
        }
        throw $deploymentError
    }
}

function Read-State {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.schemaVersion -ne 1 -or $state.imageName -cne $ImageName -or
        $state.dllPath -cne $deployedDll -or $state.phase -notin @('prepared', 'installed', 'restoring')) {
        throw "Invalid recovery record: $statePath"
    }
    foreach ($name in $trackedNames) {
        if (@($state.originalValues | Where-Object { $_.name -eq $name }).Count -ne 1 -or
            @($state.installedValues | Where-Object { $_.name -eq $name }).Count -ne 1) {
            throw "Incomplete recovery record: $statePath"
        }
    }
    return $state
}

function Get-Status {
    $values = @{}
    foreach ($name in @('GlobalFlag', 'VerifierDlls', 'VerifierFlags', 'Debugger', 'UseFilter')) {
        $values[$name] = Get-RegistryValue $name
    }
    $owned = Test-Path -LiteralPath $statePath
    $phase = $null
    $matchesInstalled = $false
    if ($owned) {
        $state = Read-State
        $phase = $state.phase
        try { Assert-InstalledValues $state; $matchesInstalled = $true } catch { $matchesInstalled = $false }
    }
    $configuration = $null
    $configurationError = $null
    if (Test-Path -LiteralPath $deployedConfig) {
        try {
            $configured = Get-Content -LiteralPath $deployedConfig -Raw | ConvertFrom-Json
            if ($configured.schemaVersion -ge 2) {
                $configuration = [pscustomobject]@{ schemaVersion = $configured.schemaVersion; time = $configured.time; locale = $configured.locale; region = $(if($configured.schemaVersion -eq 3){$configured.region}else{$null}); runtime = $(if($configured.schemaVersion -eq 3){$configured.runtime}else{$null}) }
            } else { $configuration = [pscustomobject]@{ schemaVersion = $configured.schemaVersion; time = $configured; locale = $null } }
        } catch { $configurationError = $_.Exception.Message }
    }
    return [pscustomobject]@{
        configuration = $configuration; configurationError = $configurationError
        imageName = $ImageName; registryView = 'Registry64'; registryKey = "HKLM\$ifeoPath\$ImageName"
        managed = [bool]$owned; phase = $phase; matchesInstalled = $matchesInstalled
        dllPath = $deployedDll; deploymentRecord = $deploymentRecordPath
        recoveryRecord = $(if ($owned) { $statePath } else { $null })
        configPath = $deployedConfig
        deploymentRecovery = $(if (Test-Path -LiteralPath $pendingDeploymentPath) { $pendingDeploymentPath } else { $null })
        configSha256 = $(if (Test-Path -LiteralPath $deployedConfig) { (Get-FileHash -LiteralPath $deployedConfig -Algorithm SHA256).Hash } else { $null })
        values = $values
    }
}

function Ensure-RuntimeDirectory {
    foreach ($path in @((Split-Path -Parent $runtimeDirectory), $runtimeDirectory, $stateDirectory,$bindingDirectory)) {
        if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -ItemType Directory -Path $path }
        if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Runtime directories must not be reparse points: $path"
        }
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
            $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
            $rights = if ($sidText -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,
                [Security.AccessControl.FileSystemRights]$rights, $inheritance,
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
            $null = $acl.AddAccessRule($rule)
        }
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        Set-Acl -LiteralPath $path -AclObject $acl
    }
}

function Assert-Amd64Dll([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'Missing DOS signature.' }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 24) { throw 'Invalid PE header offset.' }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'Expected an AMD64 PE file.' }
        $stream.Position = $peOffset + 22
        if (($reader.ReadUInt16() -band 0x2000) -eq 0) { throw 'Expected a DLL.' }
        $stream.Position = $peOffset + 24
        if ($reader.ReadUInt16() -ne 0x20B) { throw 'Expected PE32+.' }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Convert-GlobalFlag($Value) {
    if (-not $Value.exists) { return [uint32]0 }
    if ($Value.kind -eq 'DWord') {
        return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Value.data), 0)
    }
    if ($Value.kind -eq 'String' -and [string]$Value.data -match '^(?:0[xX])?([0-9a-fA-F]{1,8})$') {
        return [Convert]::ToUInt32($matches[1], 16)
    }
    throw 'GlobalFlag must be a DWORD or a hexadecimal REG_SZ.'
}

try {
    if ($Action -ne 'Status') {
        Assert-Administrator
        $mutex = [Threading.Mutex]::new($false, 'Global\ClaudeDesktopFake.Stage1.Registry')
        try { $mutexOwned = $mutex.WaitOne(15000) }
        catch [Threading.AbandonedMutexException] { $mutexOwned = $true }
        if (-not $mutexOwned) { throw 'Timed out waiting for another configuration operation.' }
    }
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $script:ifeo = $baseKey.OpenSubKey($ifeoPath, ($Action -ne 'Status'))
    if ($null -eq $script:ifeo) { throw 'The 64-bit IFEO registry root is unavailable.' }

    if ($Action -eq 'Install') {
        if ([string]::IsNullOrWhiteSpace($DllPath)) { throw '-DllPath is required for Install.' }
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) { throw '-ConfigPath is required for Install.' }
        $sourceDll = (Resolve-Path -LiteralPath $DllPath).ProviderPath
        $sourceConfig = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
        $configHash = (Get-FileHash -LiteralPath $sourceConfig -Algorithm SHA256).Hash
        $sourceHash = (Get-FileHash -LiteralPath $sourceDll -Algorithm SHA256).Hash
        Assert-Config $sourceConfig $sourceDll
        Assert-Amd64Dll $sourceDll
        if($ImagePath){
            $resolvedImage=(Resolve-Path -LiteralPath $ImagePath).ProviderPath
            if([IO.Path]::GetFileName($resolvedImage) -ine $ImageName){throw '-ImagePath filename must match -ImageName.'}
            . (Join-Path $PSScriptRoot 'Runtime-Profiles.ps1')
            $sourceSettings=Get-Content -LiteralPath $sourceConfig -Raw|ConvertFrom-Json
            if($sourceSettings.schemaVersion -eq 3 -and $sourceSettings.runtime.enabled){
                $profile=Get-CdfRuntimeProfile -Path $resolvedImage -Capture ([bool]$sourceSettings.runtime.captureEnabled) -CreateBinding
                if(-not $profile.supported){throw "Unsupported runtime compatibility: $($profile.reason)"}
                if($profile.type -eq 'electron'){$script:runtimeBindingPlan=$profile}
            }
        }
        if ((Get-FileHash -LiteralPath $sourceConfig -Algorithm SHA256).Hash -cne $configHash -or
            (Get-FileHash -LiteralPath $sourceDll -Algorithm SHA256).Hash -cne $sourceHash) { throw 'Source files changed during validation.' }
        if (Test-Path -LiteralPath $statePath) {
            $state = Read-State
            if ($state.phase -ne 'installed') { throw 'An incomplete installation exists. Run Uninstall to recover it.' }
            Assert-InstalledValues $state
            Assert-OwnedDeployment
            if (-not (Test-Path -LiteralPath $deployedConfig) -or
                $state.configSha256 -cne $configHash -or (Get-FileHash -LiteralPath $deployedConfig -Algorithm SHA256).Hash -cne $configHash) {
                throw 'The shared configuration differs from this installation; refusing to overwrite it.'
            }
            if ($sourceHash -cne $state.dllSha256 -or -not (Test-Path -LiteralPath $deployedDll) -or
                (Get-FileHash -LiteralPath $deployedDll -Algorithm SHA256).Hash -cne $sourceHash) {
                throw 'The managed DLL differs or is missing. Uninstall the managed targets before replacing it.'
            }
            if($script:runtimeBindingPlan){Install-Deployment $sourceDll $sourceHash $sourceConfig $configHash}
        } else {
            $original = @($trackedNames | ForEach-Object { Get-RegistryValue $_ })
            $global = @($original | Where-Object { $_.name -eq 'GlobalFlag' })[0]
            $flag = Convert-GlobalFlag $global
            foreach ($name in @('Debugger', 'VerifierDlls', 'UseFilter')) {
                if ((Get-RegistryValue $name).exists) { throw "Existing $name configuration for $ImageName; refusing to overwrite it." }
            }
            $oldFlags = @($original | Where-Object { $_.name -eq 'VerifierFlags' })[0]
            if (($flag -band 0x100) -ne 0 -or ($oldFlags.exists -and
                ($oldFlags.kind -ne 'DWord' -or [int]$oldFlags.data -ne 0))) {
                throw "Existing verifier settings for $ImageName; refusing to overwrite them."
            }
            $key = $script:ifeo.OpenSubKey($ImageName, $false)
            $keyExisted = $null -ne $key
            try { if ($keyExisted -and $key.SubKeyCount -ne 0) { throw 'Existing IFEO filter subkeys; refusing to overwrite them.' } }
            finally { if ($null -ne $key) { $key.Dispose() } }
            Ensure-RuntimeDirectory
            Install-Deployment $sourceDll $sourceHash $sourceConfig $configHash
            $newFlag = [uint32]($flag -bor 0x100)
            $flagKind = if ($global.exists) { $global.kind } else { 'DWord' }
            $flagData = if ($flagKind -eq 'String') { '0x{0:x8}' -f $newFlag }
                else { [BitConverter]::ToInt32([BitConverter]::GetBytes($newFlag), 0) }
            $state = [pscustomobject]@{
                schemaVersion = 1; imageName = $ImageName; phase = 'prepared'; keyExisted = $keyExisted
                dllPath = $deployedDll; dllSha256 = $sourceHash; originalValues = $original
                configPath = $deployedConfig; configSha256 = $configHash
                installedValues = @(
                    # Zero falls back to legacy default checks (0x48004) on this Windows build.
                    # A custom-provider configuration uses the high bit with all check bits clear.
                    [pscustomobject]@{ name = 'VerifierFlags'; exists = $true; kind = 'DWord'; data = [int]::MinValue },
                    [pscustomobject]@{ name = 'VerifierDlls'; exists = $true; kind = 'String'; data = 'CdfTimeZone64.dll' },
                    [pscustomobject]@{ name = 'GlobalFlag'; exists = $true; kind = $flagKind; data = $flagData }
                )
            }
            Save-State $state
            try {
                foreach ($value in $state.installedValues) { Set-RegistryValue $value }
                Assert-InstalledValues $state
                $state.phase = 'installed'
                Save-State $state
            } catch {
                $installError = $_
                try { Restore-OriginalValues $state -AllowPartial; Remove-Item -LiteralPath $statePath }
                catch { throw "Install failed: $($installError.Exception.Message); rollback failed: $($_.Exception.Message). Recovery: $statePath" }
                throw $installError
            }
        }
    } elseif ($Action -eq 'Uninstall') {
        if (Test-Path -LiteralPath $statePath) {
            $state = Read-State
            Assert-InstalledValues $state -AllowPartial:($state.phase -ne 'installed')
            # Persist recovery intent before restoring anything so interrupted
            # uninstall operations can resume without treating our own writes
            # as an external configuration conflict.
            $state.phase = 'restoring'
            Save-State $state
            Restore-OriginalValues $state -AllowPartial
            Remove-Item -LiteralPath $statePath
        }
        Restore-DeploymentTransaction
    }
    Get-Status | ConvertTo-Json -Depth 12
} finally {
    if ($null -ne $script:ifeo) { $script:ifeo.Dispose() }
    if ($null -ne $baseKey) { $baseKey.Dispose() }
    if ($mutexOwned) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
