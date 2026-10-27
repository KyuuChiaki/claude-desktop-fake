[CmdletBinding()]
param([string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$manager = Join-Path $PSScriptRoot 'Manage-Verifier.ps1'
$bootstrap = Join-Path $BuildDirectory 'bin\CdfBootstrap64.dll'
$image = 'CdfConfigFixture_' + [Guid]::NewGuid().ToString('N') + '.exe'
$subkey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $image
$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$key = $null
$cases = [Collections.Generic.List[object]]::new()
$failure = $null
$cleanup = $false
try {
    $key = $base.CreateSubKey($subkey, $true)
    $key.SetValue('GlobalFlag', '0x08000000', [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('VerifierFlags', 16, [Microsoft.Win32.RegistryValueKind]::DWord)
    $key.SetValue('CdfPreservedValue', 'preserve this value', [Microsoft.Win32.RegistryValueKind]::String)
    $key.Flush()
    $blocked = $false
    try { $null = & $manager -Action Install -ImageName $image -BootstrapPath $bootstrap }
    catch { if ($_.Exception.Message -match 'Existing verifier settings') { $blocked = $true } else { throw } }
    if (-not $blocked) { throw 'Install did not reject pre-existing verifier settings.' }
    $cases.Add([pscustomobject]@{ label = 'pre-existing verifier settings rejected'; passed = $true })
    $null = & $manager -Action Uninstall -ImageName $image
    if ($key.GetValueNames().Count -ne 3 -or $key.GetValue('GlobalFlag') -cne '0x08000000' -or
        $key.GetValueKind('GlobalFlag') -ne [Microsoft.Win32.RegistryValueKind]::String -or
        $key.GetValue('VerifierFlags') -ne 16 -or
        $key.GetValueKind('VerifierFlags') -ne [Microsoft.Win32.RegistryValueKind]::DWord -or
        $key.GetValue('CdfPreservedValue') -cne 'preserve this value') {
        throw 'Unowned registry values or types were changed.'
    }
    $cases.Add([pscustomobject]@{ label = 'unowned configuration and value types preserved'; passed = $true })
    $status = & $manager -Action Status -ImageName $image | ConvertFrom-Json
    if ($status.managed -or $status.registryView -ne 'Registry64') { throw 'Status reported incorrect ownership or registry view.' }
    $cases.Add([pscustomobject]@{ label = 'read-only status reports Registry64 and no ownership'; passed = $true })
} catch { $failure = $_.Exception.Message }
finally {
    if ($null -ne $key) { $key.Dispose() }
    $base.DeleteSubKey($subkey, $false)
    $remaining = $base.OpenSubKey($subkey, $false)
    $cleanup = ($null -eq $remaining)
    if ($null -ne $remaining) { $remaining.Dispose() }
    $base.Dispose()
    $reportDirectory = Join-Path $BuildDirectory 'test-results'
    $null = New-Item -ItemType Directory -Path $reportDirectory -Force
    $report = [pscustomobject]@{ passed = ($null -eq $failure -and $cleanup); failure = $failure
        fixtureImage = $image; fixtureRemoved = $cleanup; cases = @($cases.ToArray()) }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDirectory 'configuration-safety.json') -Encoding utf8
}
if (-not $report.passed) { throw "Configuration safety checks failed: $failure" }
$report | ConvertTo-Json -Depth 8 -Compress
