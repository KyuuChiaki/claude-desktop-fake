[CmdletBinding()]
param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$manager = Join-Path $PSScriptRoot 'Manage-TimeZone.ps1'
$bin = Join-Path $BuildDirectory 'bin'
$dll = Join-Path $bin 'CdfTimeZone64.dll'
$runtime = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2'
$targets = @((Join-Path $env:SystemRoot 'System32\CdfTimeZone64.dll'),(Join-Path $runtime 'timezone.json'),(Join-Path $runtime 'deployment.json'))
$pending = Join-Path $runtime 'deployment-pending.json'
$images = @(('CdfTimeSafety_'+[Guid]::NewGuid().ToString('N')+'.exe'),('CdfTimeSafety_'+[Guid]::NewGuid().ToString('N')+'.exe'))
$statePaths = @($images | ForEach-Object { Join-Path $runtime ('state\'+$_.ToLowerInvariant()+'.json') })
$reportDirectory = Join-Path $BuildDirectory 'test-results'
$run = Join-Path $reportDirectory ('time-safety-'+[Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $run -Force
$cases = [Collections.Generic.List[object]]::new(); $cleanupErrors = [Collections.Generic.List[string]]::new()
$failure = $null; $expected = @{}; $original = @{}; $seed = @{}
$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
$ifeo = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',$true)
function Hash([string]$Path) { if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }; return $null }
function Json-File($Value,[string]$Path) { [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 12),[Text.UTF8Encoding]::new($false)) }
function Snapshot([string]$Image) {
    $key=$ifeo.OpenSubKey($Image,$false)
    try {
        if ($null -eq $key) { return 'null' }
        return ConvertTo-Json -InputObject ([pscustomobject]@{values=@($key.GetValueNames() | Sort-Object | ForEach-Object { [pscustomobject]@{name=$_;kind=$key.GetValueKind($_).ToString();data=$key.GetValue($_,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)} });children=@($key.GetSubKeyNames() | Sort-Object)}) -Depth 10 -Compress
    } finally { if ($null -ne $key) { $key.Dispose() } }
}
function Manager([string]$Action,[int]$Image=0,[string]$Source=$script:config,[string]$SourceDll=$dll) {
    if ($Action -eq 'Install') { return (& $manager -Action $Action -ImageName $images[$Image] -DllPath $SourceDll -ConfigPath $Source | ConvertFrom-Json) }
    return (& $manager -Action $Action -ImageName $images[$Image] | ConvertFrom-Json)
}
function Pass([string]$Label) { $cases.Add([pscustomobject]@{label=$Label;passed=$true}) }
function Reject([scriptblock]$Operation,[string]$Pattern,[string]$Label) {
    $caught=$false
    try { $null=& $Operation } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; $caught=$true }
    if (-not $caught) { throw "Expected rejection: $Label" }; Pass $Label
}
function Remember { foreach ($path in $targets) { $expected[$path]=Hash $path } }
function Assert-Unchanged {
    foreach ($path in $targets) { if ((Hash $path) -cne $expected[$path]) { throw "Unexpected deployment mutation: $path" } }
    if (Test-Path -LiteralPath $pending) { throw 'Unexpected deployment journal remained.' }
}
function Set-File([string]$Path,[byte[]]$Bytes) {
    if ((Hash $Path) -cne $expected[$Path]) { throw "External change: $Path" }
    [IO.File]::WriteAllBytes($Path,$Bytes); $expected[$Path]=Hash $Path
}
function Fixture-Value([string]$Name,$Value,[Microsoft.Win32.RegistryValueKind]$Kind,[scriptblock]$Test) {
    $key=$ifeo.OpenSubKey($images[0],$true)
    try { $key.SetValue($Name,$Value,$Kind); $key.Flush(); & $Test }
    finally { $key.DeleteValue($Name,$false); $key.Dispose() }
}
try {
    if (Test-Path -LiteralPath $pending) { throw 'A pending deployment exists; resolve it before safety tests.' }
    foreach ($image in $images) { if ((Snapshot $image) -ne 'null') { throw 'Fixture unexpectedly exists.' } }
    for ($i=0;$i -lt $targets.Count;++$i) {
        $path=$targets[$i]; $original[$path]=if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllBytes($path) } else { $null }
        if ($null -ne $original[$path]) { [IO.File]::WriteAllBytes((Join-Path $run "$i.original"),$original[$path]) }
    }
    Remember
    $config=Join-Path $run 'valid.json'; $otherConfig=Join-Path $run 'new-york.json'
    Json-File ([ordered]@{schemaVersion=1;enabled=$true;timeZoneId='Pacific Standard Time';utcOffsetSeconds=0}) $config
    Json-File ([ordered]@{schemaVersion=1;enabled=$true;timeZoneId='Eastern Standard Time';utcOffsetSeconds=3600}) $otherConfig
    $key=$ifeo.CreateSubKey($images[0]); $key.SetValue('CdfPreservedValue',[byte[]](1,2,3),[Microsoft.Win32.RegistryValueKind]::Binary); $key.Dispose()
    $seed[0]=Snapshot $images[0]; $seed[1]='null'
    foreach ($text in @('{','{"schemaVersion":1,"schemaVersion":1,"timeZoneId":"UTC","utcOffsetSeconds":0}',
        '{"schemaVersion":1,"enabled":1,"timeZoneId":"UTC","utcOffsetSeconds":0}',
        '{"schemaVersion":1,"enabled":true,"timeZoneId":"Cdf Missing Zone","utcOffsetSeconds":0}',
        '{"schemaVersion":1,"enabled":true,"timeZoneId":"UTC","utcOffsetSeconds":9223372036854775807}',
        '{"schemaVersion":1,"enabled":true,"timeZoneId":"UTC","utcOffsetSeconds":-200000000000}')) {
        $bad=Join-Path $run ([Guid]::NewGuid().ToString('N')+'.json'); [IO.File]::WriteAllText($bad,$text)
        Reject { Manager Install 0 $bad } 'Invalid time configuration' 'invalid config rejected before mutation'
        Assert-Unchanged
        if ((Snapshot $images[0]) -cne $seed[0] -or (Test-Path -LiteralPath $statePaths[0])) { throw 'Invalid config changed IFEO.' }
    }
    foreach ($name in @('Debugger','VerifierDlls','UseFilter')) {
        Fixture-Value $name 'fixture' String { Reject { Manager Install } "Existing $name" "$name conflict rejected"; Assert-Unchanged }
    }
    Fixture-Value 'VerifierFlags' 16 DWord { Reject { Manager Install } 'Existing verifier settings' 'existing Verifier checks rejected'; Assert-Unchanged }
    Fixture-Value 'GlobalFlag' 256 DWord { Reject { Manager Install } 'Existing verifier settings' 'existing application verifier flag rejected'; Assert-Unchanged }
    Fixture-Value 'GlobalFlag' ([byte[]](1,2)) Binary { Reject { Manager Install } 'GlobalFlag must' 'unsupported registry type rejected'; Assert-Unchanged }
    $key=$ifeo.CreateSubKey($images[0]+'\fixture-filter'); $key.Dispose()
    try { Reject { Manager Install } 'filter subkeys' 'path filter subkey rejected'; Assert-Unchanged }
    finally { $ifeo.DeleteSubKey($images[0]+'\fixture-filter',$false) }
    $key=$ifeo.OpenSubKey($images[0],$true)
    $key.SetValue('GlobalFlag','0x08000000',[Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('VerifierFlags',0,[Microsoft.Win32.RegistryValueKind]::DWord); $key.Dispose(); $seed[0]=Snapshot $images[0]
    $installed=Manager Install; Remember
    if (-not $installed.managed -or -not $installed.matchesInstalled -or $installed.registryView -ne 'Registry64' -or
        $installed.values.GlobalFlag.kind -ne 'String' -or $installed.values.GlobalFlag.data -cne '0x08000100') { throw 'Installed registry view/type/flag incorrect.' }
    Pass '64-bit registration preserves GlobalFlag type and unrelated bits'
    $recordHash=Hash $statePaths[0]; $null=Manager Install
    if ((Hash $statePaths[0]) -cne $recordHash) { throw 'Idempotent install changed recovery record.' }; Pass 'idempotent install retains first recovery record'
    Reject { Manager Install 1 $otherConfig } 'different configuration' 'shared config replacement rejected with another managed image'; Assert-Unchanged
    $key=$ifeo.OpenSubKey($images[0],$true); $key.SetValue('VerifierFlags',2,[Microsoft.Win32.RegistryValueKind]::DWord); $key.Flush()
    try {
        $conflict=Snapshot $images[0]
        Reject { Manager Uninstall } 'Configuration conflict' 'external registry change blocks restoration'
        if ((Snapshot $images[0]) -cne $conflict -or (Hash $statePaths[0]) -cne $recordHash) { throw 'Conflict overwrote registry/recovery.' }
    } finally { $key.SetValue('VerifierFlags',[int]::MinValue,[Microsoft.Win32.RegistryValueKind]::DWord); $key.Dispose() }
    $record=Get-Content -LiteralPath $statePaths[0] -Raw | ConvertFrom-Json; $record.phase='prepared'; Json-File $record $statePaths[0]
    $key=$ifeo.OpenSubKey($images[0],$true); $key.DeleteValue('VerifierDlls'); $key.Dispose()
    $null=Manager Uninstall
    if ((Snapshot $images[0]) -cne $seed[0]) { throw 'Partial install not restored.' }; Pass 'prepared partial installation recovers original values and types'
    $null=Manager Install; Remember
    $record=Get-Content -LiteralPath $statePaths[0] -Raw | ConvertFrom-Json; $record.phase='restoring'; Json-File $record $statePaths[0]
    $key=$ifeo.OpenSubKey($images[0],$true); $key.SetValue('GlobalFlag','0x08000000',[Microsoft.Win32.RegistryValueKind]::String); $key.Dispose()
    $null=Manager Uninstall
    if ((Snapshot $images[0]) -cne $seed[0]) { throw 'Partial uninstall not restored.' }; Pass 'interrupted uninstall resumes restoration'
    $null=Manager Install 1; Remember
    $key=$ifeo.OpenSubKey($images[1],$true); $key.SetValue('CdfExternalValue','preserved'); $key.Dispose()
    $null=Manager Uninstall 1
    $key=$ifeo.OpenSubKey($images[1],$true)
    if ($null -eq $key -or $key.ValueCount -ne 1 -or $key.GetValue('CdfExternalValue') -cne 'preserved') { throw 'Nonempty created key was deleted.' }
    $key.DeleteValue('CdfExternalValue'); $key.Dispose(); $ifeo.DeleteSubKey($images[1],$false); Pass 'uninstall preserves newly added unrelated value and nonempty key'
    $null=Manager Install 1; Remember; $null=Manager Uninstall 1
    if ((Snapshot $images[1]) -ne 'null') { throw 'Empty owned key remained.' }; Pass 'only an empty tool-created key is deleted'
    $null=Manager Install; Remember
    $saved=[IO.File]::ReadAllBytes($targets[1]); Set-File $targets[1] ([IO.File]::ReadAllBytes($otherConfig))
    try {
        Reject { Manager Install } 'configuration differs' 'external JSON change blocks reinstall'; Assert-Unchanged
        $null=Manager Uninstall
        if ((Snapshot $images[0]) -cne $seed[0]) { throw 'Config change prevented IFEO restore.' }; Pass 'uninstall restores IFEO despite invalidated config ownership'
    } finally { Set-File $targets[1] $saved }
    $recordBytes=[IO.File]::ReadAllBytes($targets[2]); [IO.File]::Delete($targets[2]); $expected[$targets[2]]=$null
    try { Reject { Manager Install 0 $otherConfig } 'unowned file' 'unowned System32 DLL rejected before config mutation'; Assert-Unchanged }
    finally { Set-File $targets[2] $recordBytes }
    $record=Get-Content -LiteralPath $targets[2] -Raw | ConvertFrom-Json; $record.configSha256='not-owned'
    Set-File $targets[2] ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $record)))
    try { Reject { Manager Install } 'Configuration changed outside' 'external configuration ownership mismatch rejected'; Assert-Unchanged }
    finally { Set-File $targets[2] $recordBytes }
    $alternative=Join-Path $run 'CdfTimeZone64.dll'
    [IO.File]::WriteAllBytes($alternative,([IO.File]::ReadAllBytes($dll)+[byte[]](0)))
    Copy-Item -LiteralPath (Join-Path $bin 'CdfTimeRules64.exe') -Destination $run
    $locked=[IO.File]::Open($targets[1],[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { Reject { Manager Install 0 $otherConfig $alternative } 'being used|used by another|process|sharing|进程|使用|拒绝|access' 'locked configuration triggers atomic deployment rollback' }
    finally { $locked.Dispose() }
    Assert-Unchanged; Pass 'failed deployment restores DLL, JSON, ownership record and removes journal'
    # Simulate a process interruption between the first and second deployment write.
    $id=[Guid]::NewGuid().ToString('N'); $directory=Join-Path $runtime ('deployment-recovery.'+$id); $null=New-Item -ItemType Directory -Path $directory
    $transaction=[pscustomobject]@{schemaVersion=1;imageName=$images[0].ToLowerInvariant();transactionId=$id;phase='prepared';files=@()}
    for ($i=0;$i -lt 3;++$i) {
        [IO.File]::Copy($targets[$i],(Join-Path $directory "$i.old"),$false)
        $transaction.files += [pscustomobject]@{target=$targets[$i];originalHash=(Hash $targets[$i]);installedHash=$(if ($i -eq 0) { Hash $alternative } else { Hash $targets[$i] })}
    }
    Json-File $transaction $pending
    Set-File $targets[0] ([IO.File]::ReadAllBytes($alternative))
    $changed=[IO.File]::ReadAllBytes($alternative)+[byte[]](1); Set-File $targets[0] $changed
    Reject { Manager Uninstall } 'Deployment conflict' 'external deployment change retains interruption recovery material'
    if (-not (Test-Path -LiteralPath $pending) -or (Hash $targets[0]) -cne $expected[$targets[0]]) { throw 'Conflict damaged recovery material.' }
    Set-File $targets[0] ([IO.File]::ReadAllBytes($alternative))
    $null=Manager Uninstall; Remember
    for ($i=0;$i -lt 3;++$i) {
        if ((Hash $targets[$i]) -cne $transaction.files[$i].originalHash) { throw 'Interrupted deployment restore mismatch.' }
    }
    if ((Test-Path -LiteralPath $pending) -or (Test-Path -LiteralPath $directory)) { throw 'Recovered transaction material remained.' }
    Pass 'prepared deployment interruption restores all original files'
} catch { $failure=$_.Exception.Message+' '+$_.ScriptStackTrace }
finally {
    for ($i=0;$i -lt $images.Count;++$i) {
        try {
            if (Test-Path -LiteralPath $statePaths[$i]) { $null=Manager Uninstall $i }
            if ($seed.ContainsKey($i)) {
                $current=Snapshot $images[$i]
                if ($current -cne $seed[$i]) { throw 'Fixture changed; preserving it for inspection.' }
                if ($current -ne 'null') {
                    $key=$ifeo.OpenSubKey($images[$i],$true)
                    foreach ($name in @($key.GetValueNames())) { $key.DeleteValue($name) }
                    $key.Dispose(); $ifeo.DeleteSubKey($images[$i],$false)
                }
            }
        } catch { $cleanupErrors.Add("$($images[$i]): $($_.Exception.Message)") }
    }
    try {
        if (Test-Path -LiteralPath $pending) { throw 'Interrupted/conflicting deployment retained for recovery.' }
        foreach ($path in $targets) { if ((Hash $path) -cne $expected[$path]) { throw "External deployment change; preserving files: $path" } }
        foreach ($path in $targets) {
            if ($null -eq $original[$path]) { [IO.File]::Delete($path) }
            elseif ((Hash $path) -cne (Hash (Join-Path $run (([Array]::IndexOf($targets,$path)).ToString()+'.original')))) { [IO.File]::WriteAllBytes($path,$original[$path]) }
        }
    } catch { $cleanupErrors.Add($_.Exception.Message) }
    $ifeo.Dispose(); $base.Dispose()
    $report=[pscustomobject]@{passed=($null -eq $failure -and $cleanupErrors.Count -eq 0);failure=$failure;cleanupErrors=@($cleanupErrors.ToArray());fixtureImages=$images;cases=@($cases.ToArray());recoveryMaterials=$run}
    $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $reportDirectory 'timezone-configuration-safety.json') -Encoding utf8
}
if (-not $report.passed) { throw "Time-zone safety tests failed: $failure; cleanup=$($cleanupErrors -join '; ')" }
[pscustomobject]@{passed=$true;cases=$cases.Count;fixturesRemoved=$true} | ConvertTo-Json -Compress
