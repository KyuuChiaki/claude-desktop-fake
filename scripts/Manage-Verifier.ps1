[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Install', 'Status', 'Uninstall')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('(?i)^[^\\/:*?"<>|\x00-\x1f]+\.exe$')][string]$ImageName,
    [string]$BootstrapPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ImageName = $ImageName.ToLowerInvariant()
$runtimeDirectory = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage1'
$deployedDll = Join-Path $env:SystemRoot 'System32\CdfBootstrap64.dll'
$deploymentRecordPath = Join-Path $runtimeDirectory 'deployment.json'
$stateDirectory = Join-Path $runtimeDirectory 'state'
$statePath = Join-Path $stateDirectory ($ImageName + '.json')
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
    return [pscustomobject]@{
        imageName = $ImageName; registryView = 'Registry64'; registryKey = "HKLM\$ifeoPath\$ImageName"
        managed = [bool]$owned; phase = $phase; matchesInstalled = $matchesInstalled
        dllPath = $deployedDll; deploymentRecord = $deploymentRecordPath
        recoveryRecord = $(if ($owned) { $statePath } else { $null })
        values = $values
    }
}

function Ensure-RuntimeDirectory {
    foreach ($path in @((Split-Path -Parent $runtimeDirectory), $runtimeDirectory, $stateDirectory)) {
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
        if ([string]::IsNullOrWhiteSpace($BootstrapPath)) { throw '-BootstrapPath is required for Install.' }
        $sourceDll = (Resolve-Path -LiteralPath $BootstrapPath).ProviderPath
        Assert-Amd64Dll $sourceDll
        $sourceHash = (Get-FileHash -LiteralPath $sourceDll -Algorithm SHA256).Hash
        if (Test-Path -LiteralPath $statePath) {
            $state = Read-State
            if ($state.phase -ne 'installed') { throw 'An incomplete installation exists. Run Uninstall to recover it.' }
            Assert-InstalledValues $state
            Assert-OwnedDeployment
            if ($sourceHash -cne $state.dllSha256 -or -not (Test-Path -LiteralPath $deployedDll) -or
                (Get-FileHash -LiteralPath $deployedDll -Algorithm SHA256).Hash -cne $sourceHash) {
                throw 'The managed DLL differs or is missing. Uninstall the managed targets before replacing it.'
            }
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
            if (Test-Path -LiteralPath $deployedDll) {
                Assert-OwnedDeployment
                $deployedHash = (Get-FileHash -LiteralPath $deployedDll -Algorithm SHA256).Hash
                if ($deployedHash -cne $sourceHash -and @(Get-ChildItem -LiteralPath $stateDirectory -Filter '*.json').Count -gt 0) {
                    throw 'Other managed targets still use the deployed DLL. Uninstall them before changing it.'
                }
                if ($deployedHash -cne $sourceHash) { Copy-Item -LiteralPath $sourceDll -Destination $deployedDll -Force }
            } else { [IO.File]::Copy($sourceDll, $deployedDll, $false) }
            # The provider is loaded by basename from the Windows system search path.
            if ((Get-FileHash -LiteralPath $deployedDll -Algorithm SHA256).Hash -cne $sourceHash) { throw 'DLL deployment hash mismatch.' }
            Save-JsonAtomically ([pscustomobject]@{
                schemaVersion = 1; dllPath = $deployedDll; dllSha256 = $sourceHash
            }) $deploymentRecordPath
            $newFlag = [uint32]($flag -bor 0x100)
            $flagKind = if ($global.exists) { $global.kind } else { 'DWord' }
            $flagData = if ($flagKind -eq 'String') { '0x{0:x8}' -f $newFlag }
                else { [BitConverter]::ToInt32([BitConverter]::GetBytes($newFlag), 0) }
            $state = [pscustomobject]@{
                schemaVersion = 1; imageName = $ImageName; phase = 'prepared'; keyExisted = $keyExisted
                dllPath = $deployedDll; dllSha256 = $sourceHash; originalValues = $original
                installedValues = @(
                    # Zero falls back to legacy default checks (0x48004) on this Windows build.
                    # A custom-provider configuration uses the high bit with all check bits clear.
                    [pscustomobject]@{ name = 'VerifierFlags'; exists = $true; kind = 'DWord'; data = [int]::MinValue },
                    [pscustomobject]@{ name = 'VerifierDlls'; exists = $true; kind = 'String'; data = 'CdfBootstrap64.dll' },
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
    }
    Get-Status | ConvertTo-Json -Depth 12
} finally {
    if ($null -ne $script:ifeo) { $script:ifeo.Dispose() }
    if ($null -ne $baseKey) { $baseKey.Dispose() }
    if ($mutexOwned) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
