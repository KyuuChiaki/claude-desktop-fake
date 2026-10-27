[CmdletBinding()]
param(
    [string]$BuildDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),
    [ValidateRange(1, 100)][int]$Iterations = 10
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$manager = Join-Path $PSScriptRoot 'Manage-Verifier.ps1'
$probe = Join-Path $BuildDirectory 'bin\CdfProbe64.exe'
$bootstrap = Join-Path $BuildDirectory 'bin\CdfBootstrap64.dll'
$runtimeDirectory = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage1'
$expectedDll = Join-Path $env:SystemRoot 'System32\CdfBootstrap64.dll'
$reportDirectory = Join-Path $BuildDirectory 'test-results'
$null = New-Item -ItemType Directory -Path $reportDirectory -Force
$runDirectory = Join-Path $reportDirectory ('run-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $runDirectory
$otherProbe = Join-Path $runDirectory 'CdfProbeOther64.exe'
$images = @('CdfProbe64.exe', 'CdfProbeOther64.exe')
$owned = [Collections.Generic.List[string]]::new()
$cases = [Collections.Generic.List[object]]::new()
$cleanupErrors = [Collections.Generic.List[string]]::new()
$failure = $null
$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$ifeo = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options', $true)

function Get-Snapshot([string]$Image) {
    $key = $ifeo.OpenSubKey($Image, $false)
    try {
        if ($null -eq $key) { return 'null' }
        $values = @($key.GetValueNames() | Sort-Object | ForEach-Object {
            [pscustomobject]@{ name = $_; kind = $key.GetValueKind($_).ToString()
                data = $key.GetValue($_, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        })
        return ConvertTo-Json -InputObject ([pscustomobject]@{ values = $values; children = @($key.GetSubKeyNames() | Sort-Object) }) -Depth 10 -Compress
    } finally { if ($null -ne $key) { $key.Dispose() } }
}

function Invoke-Manager([string]$Operation, [string]$Image) {
    if ($Operation -eq 'Install') {
        return (& $manager -Action Install -ImageName $Image -BootstrapPath $bootstrap | ConvertFrom-Json)
    }
    return (& $manager -Action $Operation -ImageName $Image | ConvertFrom-Json)
}

function Invoke-Probe([string]$Path, [string]$Expectation, [string]$Label) {
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $Path
    $process.StartInfo.Arguments = '--expect ' + $Expectation
    if ($Expectation -eq 'loaded') { $process.StartInfo.Arguments += ' --expected-dll "' + $expectedDll + '"' }
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $record = [ordered]@{ label = $Label; imagePath = $Path; exitCode = $null; durationMs = 0; passed = $false; observation = $null; stdout = ''; stderr = ''; error = $null }
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if (-not $process.Start()) { throw 'Process creation returned false.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            $process.WaitForExit()
            $record.exitCode = $process.ExitCode
            $record.stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
            $record.stderr = $stderrTask.GetAwaiter().GetResult().Trim()
            throw 'Probe timed out after 10 seconds.'
        }
        $record.exitCode = $process.ExitCode
        $record.stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $record.stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        if ($record.stdout) { $record.observation = $record.stdout | ConvertFrom-Json }
        $record.passed = ($process.ExitCode -eq 0 -and $null -ne $record.observation -and $record.observation.matched)
        if (-not $record.passed) { throw "Probe failed: $Label, exit=$($record.exitCode), stdout=$($record.stdout), stderr=$($record.stderr)" }
    } catch {
        $record.error = $_.Exception.Message
        throw
    } finally {
        $timer.Stop()
        $record.durationMs = $timer.ElapsedMilliseconds
        $cases.Add([pscustomobject]$record)
        $process.Dispose()
    }
}

$originalSnapshots = @{}
try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Integration tests require elevation.' }
    foreach ($image in $images) {
        $originalSnapshots[$image] = Get-Snapshot $image
        $status = Invoke-Manager Status $image
        if ($originalSnapshots[$image] -ne 'null' -or $status.managed) { throw "Test target is already configured: $image" }
    }
    Copy-Item -LiteralPath $probe -Destination $otherProbe
    $executables = @($probe, $otherProbe)
    for ($imageIndex = 0; $imageIndex -lt $images.Count; ++$imageIndex) {
        $image = $images[$imageIndex]
        $executable = $executables[$imageIndex]
        Invoke-Probe $executable absent "$image baseline"
        $owned.Add($image)
        $installed = Invoke-Manager Install $image
        if (-not $installed.managed -or -not $installed.matchesInstalled) { throw 'Install status mismatch.' }
        $backupHash = (Get-FileHash -LiteralPath $installed.recoveryRecord -Algorithm SHA256).Hash
        $again = Invoke-Manager Install $image
        if (-not $again.matchesInstalled -or (Get-FileHash -LiteralPath $again.recoveryRecord -Algorithm SHA256).Hash -cne $backupHash) {
            throw 'Repeated installation changed the original recovery record.'
        }
        $cases.Add([pscustomobject]@{ label = "$image idempotent install"; passed = $true })
        for ($iteration = 1; $iteration -le $Iterations; ++$iteration) {
            Invoke-Probe $executable loaded "$image loaded $iteration/$Iterations"
        }
        $removed = Invoke-Manager Uninstall $image
        if ($removed.managed) { throw 'Uninstall retained a management record.' }
        $null = $owned.Remove($image)
        Invoke-Probe $executable absent "$image after uninstall"
        if ((Get-Snapshot $image) -cne $originalSnapshots[$image]) { throw "Registry baseline not restored: $image" }
        $cases.Add([pscustomobject]@{ label = "$image registry restored"; passed = $true })
    }
} catch { $failure = $_.Exception.Message }
finally {
    foreach ($image in @($owned.ToArray())) {
        try { $null = Invoke-Manager Uninstall $image }
        catch { $cleanupErrors.Add("${image}: $($_.Exception.Message)") }
    }
    foreach ($image in $images) {
        if ($originalSnapshots.ContainsKey($image) -and (Get-Snapshot $image) -cne $originalSnapshots[$image]) {
            $cleanupErrors.Add("Registry differs from baseline: $image")
        }
    }
    $ifeo.Dispose()
    $base.Dispose()
    $report = [pscustomobject]@{
        passed = ($null -eq $failure -and $cleanupErrors.Count -eq 0)
        windowsVersion = [Environment]::OSVersion.Version.ToString()
        iterationsPerImage = $Iterations; bootstrapPath = $expectedDll
        failure = $failure; cleanupErrors = @($cleanupErrors.ToArray()); cases = @($cases.ToArray())
        registryRestored = ($cleanupErrors.Count -eq 0)
    }
    $reportPath = Join-Path $reportDirectory 'verifier-load.json'
    $report | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $reportPath -Encoding utf8
}
if (-not $report.passed) { throw "Verifier integration failed: $failure; cleanup=$($cleanupErrors -join '; '); report=$reportPath" }
[pscustomobject]@{ passed = $true; cases = $cases.Count; report = $reportPath; registryRestored = $true } | ConvertTo-Json -Compress
