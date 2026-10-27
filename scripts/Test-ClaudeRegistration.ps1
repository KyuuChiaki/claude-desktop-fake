[CmdletBinding()]
param([string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'))

# Exercise the public commands against the current Store registration without
# starting, stopping, or restarting any Claude process or service.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$project=Split-Path -Parent $PSScriptRoot
$manager=Join-Path $PSScriptRoot 'Manage-Claude.ps1'
$results=Join-Path $BuildDirectory 'test-results'
[void](New-Item -ItemType Directory -Path $results -Force)
$evidence=Join-Path $results ('claude-registration-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
[void](New-Item -ItemType Directory -Path $evidence)
$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
$ifeo=$base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',$false)

function Read-Registration([string[]]$Images) {
    @(foreach($name in ($Images|Sort-Object -Unique)) {
        $key=$ifeo.OpenSubKey($name,$false)
        try {
            [pscustomobject]@{
                name=$name;exists=[bool]$key
                subkeys=@(if($key){$key.GetSubKeyNames()|Sort-Object})
                values=@(if($key){foreach($v in ($key.GetValueNames()|Sort-Object)){
                    [pscustomobject]@{name=$v;kind=$key.GetValueKind($v).ToString();data=$key.GetValue($v,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
                }})
            }
        } finally { if($key){$key.Dispose()} }
    })
}
function Save-Evidence([string]$Name,$Value) {
    [IO.File]::WriteAllText((Join-Path $evidence $Name),(ConvertTo-Json -InputObject $Value -Depth 24),[Text.UTF8Encoding]::new($false))
}
function Public-Command([string]$Action) {
    (& $manager -Action $Action)|ConvertFrom-Json
}

$attempted=$false;$failure=$null;$cleanupErrors=@();$checks=[ordered]@{}
$before=$null;$after=$null;$enabled=$null;$baseline=$null;$restored=$null
$serviceBefore=Get-CimInstance Win32_Service -Filter "Name='CoworkVMServiceStore'"|Select-Object Name,State,ProcessId,StartName
try {
    $before=Public-Command Status
    if($before.managed -or $before.pendingTransaction -or $before.issues.Count){throw 'Existing management state or issue; refusing to change real Claude registration.'}
    if(-not $before.images.Count){throw 'No signed Claude Store images were discovered.'}
    Save-Evidence 'status-before.json' $before
    $baseline=Read-Registration @($before.images.name)
    Save-Evidence 'ifeo-before.json' $baseline
    $configHash=(Get-FileHash -LiteralPath $before.configurationPath -Algorithm SHA256).Hash
    $attempted=$true
    $enabled=Public-Command Enable
    Save-Evidence 'status-enabled.json' $enabled
    if(-not $enabled.enabled -or $enabled.stale -or $enabled.issues.Count){throw 'Enable did not produce consistent registration.'}
    $checks.allDiscoveredImagesRegistered=$enabled.images.Count -eq $before.images.Count
    $checks.claudeRegistered=@($enabled.images|Where-Object name -ieq 'claude.exe').Count -eq 1
    $checks.serviceRegistered=@($enabled.images|Where-Object name -ieq 'cowork-svc.exe').Count -eq 1
    $records=Join-Path (Split-Path -Parent $enabled.statePath) 'state'
    $checks.independentRecoveryRecords=@(foreach($image in $enabled.images){Test-Path -LiteralPath (Join-Path $records ($image.name.ToLowerInvariant()+'.json'))}) -notcontains $false
    $manifest=Get-Content -Raw -LiteralPath $enabled.manifestPath|ConvertFrom-Json
    Save-Evidence 'identity-manifest.json' $manifest
    $configuration=Get-Content -Raw -LiteralPath $enabled.configurationPath|ConvertFrom-Json
    if($configuration.schemaVersion -eq 3 -and $configuration.runtime.enabled){
        $checks.runtimeManifestVersion=$manifest.schemaVersion -eq 3
        $checks.runtimeProfilesListed=$enabled.runtime.enabled -and $enabled.runtime.profiles.Count -eq $enabled.images.Count
        $checks.runtimeManifestBindings=@(foreach($image in $manifest.images){
            $profile=@($enabled.runtime.profiles|Where-Object path -ceq $image.path)
            $profile.Count -eq 1 -and $profile[0].runtime.supported -and
                $image.runtimeType -ceq $profile[0].runtime.type -and
                $image.adapterId -ceq $profile[0].runtime.adapterId -and
                $image.compatibilityPolicy -ceq $configuration.runtime.unknownVersionPolicy
        }) -notcontains $false
        $checks.runtimeBindingHashes=@(foreach($image in $manifest.images){
            if($image.runtimeBindingSha256 -ceq ('0'*64)){$image.runtimeType -ceq 'native';continue}
            $descriptor=Join-Path (Join-Path (Split-Path -Parent $enabled.manifestPath) 'bindings') ($image.runtimeBindingSha256+'.bin')
            (Test-Path -LiteralPath $descriptor) -and (Get-FileHash -LiteralPath $descriptor).Hash -ceq $image.runtimeBindingSha256
        }) -notcontains $false
    }
    Save-Evidence 'installed-state.json' (Get-Content -Raw -LiteralPath $enabled.statePath|ConvertFrom-Json)
    $stateHash=(Get-FileHash -LiteralPath $enabled.statePath).Hash
    $repeat=Public-Command Enable
    $checks.enableIdempotent=$repeat.enabled -and (Get-FileHash -LiteralPath $enabled.statePath).Hash -ceq $stateHash
    if($checks.Values -contains $false){throw 'One or more registration checks failed.'}
} catch {
    $failure=$_.Exception.ToString()+"`n"+$_.ScriptStackTrace
} finally {
    if($attempted){try{$after=Public-Command Disable;Save-Evidence 'status-disabled.json' $after}catch{$cleanupErrors+=$_.Exception.ToString()}}
    if($baseline){
        $restored=Read-Registration @($baseline.name)
        Save-Evidence 'ifeo-after.json' $restored
        $checks.registryRestored=(ConvertTo-Json -InputObject $baseline -Depth 16 -Compress) -ceq (ConvertTo-Json -InputObject $restored -Depth 16 -Compress)
    }
    if($after){
        $checks.disabled=-not $after.managed -and -not $after.enabled -and -not $after.pendingTransaction -and -not $after.issues.Count
        $checks.configurationUnchanged=(Get-FileHash -LiteralPath $after.configurationPath -Algorithm SHA256).Hash -ceq $configHash
        $checks.sourceAndDeployedProviderMatch=(Get-FileHash -LiteralPath (Join-Path $project 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll')).Hash -ceq $after.providerSha256
    }
    $serviceAfter=Get-CimInstance Win32_Service -Filter "Name='CoworkVMServiceStore'"|Select-Object Name,State,ProcessId,StartName
    $checks.serviceUnchanged=(ConvertTo-Json -InputObject $serviceBefore -Compress) -ceq (ConvertTo-Json -InputObject $serviceAfter -Compress)
    $ifeo.Dispose();$base.Dispose()
    $report=[pscustomobject]@{
        passed=($null -eq $failure -and $cleanupErrors.Count -eq 0 -and $checks.Values -notcontains $false)
        failure=$failure;cleanupErrors=$cleanupErrors;checks=[pscustomobject]$checks;evidenceDirectory=$evidence
        verifiedImages=@(if($before){$before.images|Select-Object name,path,signer,signatureStatus})
        serviceBefore=$serviceBefore;serviceAfter=$serviceAfter
        finalEnabled=$(if($after){$after.enabled}else{$null})
        finalRequiresRestart=$(if($after){$after.requiresRestart}else{$null})
        scope='Public Enable/Status/Disable and exact IFEO restoration only; no target process or service lifecycle actions'
    }
    Save-Evidence 'report.json' $report
    Save-Evidence '..\claude-registration.json' $report
}
if(-not $report.passed){throw "Claude registration acceptance failed; evidence: $evidence; $failure; cleanup: $($cleanupErrors -join '; ')"}
$report|Select-Object passed,checks,serviceAfter,finalEnabled,finalRequiresRestart,evidenceDirectory|ConvertTo-Json -Depth 5
