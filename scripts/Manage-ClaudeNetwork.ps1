# Enable the signed network provider beside the already deployed time provider.
# Preserve the verified time binary; changing its version requires the normal
# Disable / upgrade workflow. This command never starts or stops Claude.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Enable','Status','Disable','Upgrade')][string]$Action,
    [string]$ProviderPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release\bin\CdfClaudeNetwork64.dll'),
    [switch]$SelectionOnly
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-AutoCore.ps1')
. (Join-Path $PSScriptRoot 'Network-Deployment.ps1')
$networkRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\network'
$policyPath=Join-Path $networkRoot 'claude.json';$ownershipPath=Join-Path $networkRoot 'claude-deployment.json'
$target=Join-Path $env:SystemRoot 'System32\CdfClaudeNetwork64.dll'
$autoPath=Join-Path (Cdf-AutoRoot) 'state.json'
function Get-NetworkIntegrationStatus {
    $policy=if([IO.File]::Exists($policyPath)){Cdf-AutoReadJson $policyPath}else{$null}
    $requested=[bool]($policy -and $policy.enabled)
    $statePath=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage3\claude\state.json'
    $images=@();$issues=@()
    if([IO.File]::Exists($statePath)){
        $state=Cdf-AutoReadJson $statePath
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64')
        try{
            foreach($image in $state.images){
                $key=$base.OpenSubKey(('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\'+$image.name))
                try{$actual=if($key){[string]$key.GetValue('VerifierDlls')}else{''}}finally{if($key){$key.Dispose()}}
                $expected=@($image.installedValues|Where-Object name -eq 'VerifierDlls')[0].data
                $networkEnabled=$actual -match '(?i)(?:^|\s)CdfClaudeNetwork64\.dll(?:$|\s)'
                if($actual -cne $expected){$issues+='IFEO conflict: '+$image.name}
                elseif($networkEnabled -ne ($requested -and $image.name -notin $policy.excludedImages)){$issues+='IFEO proxy selection mismatch: '+$image.name}
                $images+=[pscustomobject]@{name=$image.name;providers=$actual;matchesRecovery=($actual -ceq $expected);networkEnabled=$networkEnabled}
            }
        }finally{$base.Dispose()}
    }
    $hashMatches=$policy -and (Cdf-Hash $target) -ceq $policy.dllSha256
    $deployment=$null
    try{$deployment=Get-CdfNetworkDeploymentStatus $networkRoot}
    catch{if($requested){$issues+='Unable to read network transport deployment.'}}
    if($requested -and -not $hashMatches){$issues+='Network provider hash mismatch.'}
    if($requested -and (-not $deployment -or -not $deployment.hashesMatch)){$issues+='Network transport hash mismatch.'}
    $enabled=$requested -and $hashMatches -and -not $issues.Count -and @($images|Where-Object networkEnabled).Count -gt 0
    [pscustomobject]@{schemaVersion=1;enabled=[bool]$enabled;requested=$requested;policyPath=$policyPath;providerPath=$target;providerSha256=(Cdf-Hash $target);transport=$deployment;images=$images;issues=$issues;serviceNetworkEnabled=$false;alreadyRunningProcesses='Changes apply only after the process exits and starts again.'}
}
function Test-NetworkAwareRelease($State) {
    # Only reuse an installed monitor whose verified core selects providers in
    # the same way. Older releases still use the original migration path.
    $relative='scripts\Claude-ManagerCore.ps1'
    if(@($State.files|Where-Object path -ieq $relative).Count -ne 1){return $false}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $State.release $relative),[ref]$tokens,[ref]$errors)
    if($errors.Count){return $false}
    $selector=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Cdf-ProviderNames'},$false)
    $local=${function:Cdf-ProviderNames}.Ast
    if($local -is [Management.Automation.Language.FunctionDefinitionAst]){$local=$local.Body}
    $body=$local.EndBlock.Extent.Text
    return $null -ne $selector -and
        $selector.Body.EndBlock.Extent.Text.Replace("`r`n","`n") -ceq $body.Replace("`r`n","`n")
}
if($Action -eq 'Status'){
    . (Join-Path $PSScriptRoot 'Network-Children.ps1')
    $status=Get-NetworkIntegrationStatus
    $manifestPath=Join-Path (Split-Path -Parent (Cdf-AutoRoot)) 'claude\images.json'
    $manifest=$null
    $readError=$null
    try{if([IO.File]::Exists($manifestPath)){$manifest=Cdf-AutoReadJson $manifestPath}}catch{$readError=$_.Exception.Message}
    $children=Get-CdfNetworkChildTargets $manifest
    if($readError){$children.inspection='unavailable';$children.error=$readError}
    $status|Add-Member -NotePropertyName networkChildTargets -NotePropertyValue $children
    $status|ConvertTo-Json -Depth 10
    return
}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not [Environment]::Is64BitProcess -or -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Use elevated 64-bit PowerShell.'}
if(-not [IO.File]::Exists($autoPath)){throw 'Enable the managed Claude time/locale deployment before adding its network provider.'}
$autoHash=Cdf-Hash $autoPath
$automatic=Cdf-AutoReadJson $autoPath;Cdf-AutoVerifyRelease $automatic
if($automatic.ownerSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'The automatic refresh deployment belongs to another user.'}
if($Action -eq 'Upgrade'){
    $source=(Resolve-Path -LiteralPath $ProviderPath).ProviderPath
    Cdf-AutoCheckProvider $source
    $newHash=Cdf-Hash $source
    $mutex=Cdf-NewRegistryMutex;$held=$false
    $context=New-CdfClaudeContext (Join-Path (Split-Path -Parent (Cdf-AutoRoot)) 'claude') '' 'CdfClaudeTimeZone64.dll'
    try{
        try{$held=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Automatic refresh is committing another registration. Retry the upgrade.'}
        if((Cdf-Hash $autoPath) -cne $autoHash){throw 'Automatic refresh deployment changed. Retry the upgrade.'}
        $context.Base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64')
        $context.Ifeo=$context.Base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',$true)
        if(-not $context.Ifeo){throw '64-bit IFEO registry root is unavailable.'}
        if([IO.File]::Exists($context.Pending)){
            $journal=Cdf-AutoReadJson $context.Pending
            if($policyPath -notin @($journal.files|ForEach-Object target)){throw 'Interrupted project deployment requires recovery.'}
            Cdf-Recover $context
        }
        $state=Cdf-ReadState $context
        if($state){foreach($image in $state.images){Cdf-AssertImage $context $image}}
        $oldPolicy=Cdf-AutoReadJson $policyPath
        $owned=Cdf-AutoReadJson $ownershipPath
        $oldHash=Cdf-Hash $target
        if(-not $oldHash -or $oldPolicy.schemaVersion -ne 1 -or $oldPolicy.dllPath -ine $target -or
           $owned.schemaVersion -ne 1 -or $owned.phase -ne 'installed' -or $owned.dllPath -ine $target -or
           $oldPolicy.dllSha256 -cne $oldHash -or $owned.dllSha256 -cne $oldHash){
            throw 'Network provider or ownership changed externally. Recovery records retained.'
        }
        if($newHash -cne $oldHash){
            $users=@(Get-CdfNetworkModuleUsers $target)
            if($users.Count){throw ('Exit the processes using the installed network provider: '+(($users|ForEach-Object {"$($_.name) ($($_.pid))"}) -join ', '))}
            $owned.dllSha256=$newHash
            $oldPolicy.dllSha256=$newHash
            Cdf-Transaction $context @() @(
                (Cdf-FileChange $target -Source $source),
                (Cdf-FileChange $ownershipPath $owned),
                (Cdf-FileChange $policyPath $oldPolicy)
            )
        }
        Get-NetworkIntegrationStatus|ConvertTo-Json -Depth 10
    }finally{
        if($context.Ifeo){$context.Ifeo.Dispose()}
        if($context.Base){$context.Base.Dispose()}
        if($held){$mutex.ReleaseMutex()}
        $mutex.Dispose()
    }
    return
}
if($Action -eq 'Enable'){
    $deployment=Get-CdfNetworkDeploymentStatus $networkRoot
    if(-not $deployment -or -not $deployment.hashesMatch){throw 'Install and validate the private network transport before enabling it for Claude.'}
    $adapter=Get-NetAdapter|Where-Object {([Guid]$_.InterfaceGuid) -eq ([Guid]$deployment.interfaceGuid)}
    if(@($adapter).Count -ne 1 -or -not $adapter.HardwareInterface -or $adapter.Status -ne 'Up'){throw 'The selected physical adapter is not available.'}
    Add-Type -AssemblyName System.Security
    $plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($deployment.profilePath),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try{
        $profile=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json;$address=$null
        if(-not [Net.IPAddress]::TryParse([string]$profile.server,[ref]$address) -or $address.AddressFamily -ne 'InterNetwork'){throw 'The private upstream must be a numeric IPv4 address.'}
        $routes=@(Find-NetRoute -RemoteIPAddress $address.IPAddressToString -InterfaceIndex $adapter.InterfaceIndex|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_NetRoute'})
        if($routes.Count -ne 1 -or $routes[0].InterfaceIndex -ne $adapter.InterfaceIndex){throw 'The private upstream is not reachable through the selected physical adapter.'}
    }finally{[Array]::Clear($plain,0,$plain.Length);$profile=$null}
    $source=(Resolve-Path -LiteralPath $ProviderPath).ProviderPath
    # Require the signed-provider gate export, without loading the DLL here.
    Cdf-AutoCheckProvider $source
    $hash=Cdf-Hash $source
    $owned=$null
    if([IO.File]::Exists($ownershipPath)){
        $owned=Cdf-AutoReadJson $ownershipPath
        if($owned.schemaVersion -ne 1 -or $owned.dllPath -ine $target -or $owned.dllSha256 -cne $hash){throw 'Disable the network integration before changing its provider build; ownership record retained.'}
        if([IO.File]::Exists($target) -and (Cdf-Hash $target) -cne $hash){throw 'External network provider modification; recovery retained.'}
    }elseif([IO.File]::Exists($target)){throw 'An unowned signed network provider already exists.'}
    if(-not $owned -or $owned.phase -ne 'installed' -or -not [IO.File]::Exists($target)){
        Cdf-SecureDirectory $networkRoot
        Cdf-Save $ownershipPath ([pscustomobject]@{schemaVersion=1;phase='prepared';dllPath=$target;dllSha256=$hash})
        if(-not [IO.File]::Exists($target)){Cdf-CopyAtomic $source $target $hash}
        Set-CdfNetworkFileAcl $target
        Cdf-Save $ownershipPath ([pscustomobject]@{schemaVersion=1;phase='installed';dllPath=$target;dllSha256=$hash})
    }
}else{
    if(-not [IO.File]::Exists($policyPath)){Get-NetworkIntegrationStatus|ConvertTo-Json -Depth 10;return}
    $hash=(Cdf-AutoReadJson $policyPath).dllSha256
}
$policy=[pscustomobject]@{schemaVersion=1;enabled=($Action -eq 'Enable');dllPath=$target;dllSha256=$hash;excludedImages=@('cowork-svc.exe')}
if($SelectionOnly -and (Test-NetworkAwareRelease $automatic)){
    $mutex=Cdf-NewRegistryMutex;$held=$false
    $context=New-CdfClaudeContext (Join-Path (Split-Path -Parent (Cdf-AutoRoot)) 'claude') '' 'CdfClaudeTimeZone64.dll'
    try{
        try{$held=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw '自动刷新正在更新登记，本次未切换。请稍后重试。'}
        if((Cdf-Hash $autoPath) -cne $autoHash){throw '自动刷新部署刚刚变更，本次未切换。请稍后重试。'}
        $context.Base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64')
        $context.Ifeo=$context.Base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',$true)
        if(-not $context.Ifeo){throw '64-bit IFEO registry root is unavailable.'}
        Cdf-SwitchNetworkSelection $context $policy
        Get-NetworkIntegrationStatus|ConvertTo-Json -Depth 10
    }finally{
        if($context.Ifeo){$context.Ifeo.Dispose()}
        if($context.Base){$context.Base.Dispose()}
        if($held){$mutex.ReleaseMutex()}
        $mutex.Dispose()
    }
    return
}
# Stage an immutable manager release from the *deployed* time version. Never
# upgrade its DLL or mutate the hash-verified observer release in place.
$sources=Join-Path $networkRoot 'claude-manager-sources';Cdf-SecureDirectory $sources
$staging=Join-Path $sources ([Guid]::NewGuid().ToString('N'));Cdf-SecureDirectory $staging
foreach($file in $automatic.files){
    $from=Join-Path $automatic.release $file.path;$to=Join-Path $staging $file.path
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
    Cdf-CopyAtomic $from $to $file.sha256
}
foreach($name in @('Claude-ManagerCore.ps1','Claude-AutoCore.ps1','Manage-ClaudeAuto.ps1','Watch-Claude.ps1',
        'Claude-FileIdentity.ps1','Startup-Observation.ps1','StartupFileEvents.cs')){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $staging ('scripts\'+$name)) -Force
}
$before=if([IO.File]::Exists($policyPath)){[IO.File]::ReadAllText($policyPath)}else{$null}
Cdf-Save $policyPath $policy
try{
    & (Join-Path $staging 'scripts\Manage-ClaudeAuto.ps1') -Action Enable|Out-Null
    if(-not $?){throw 'Automatic refresh installation failed.'}
}catch{
    $failure=$_.Exception.Message
    # Core registry changes use its existing complete-batch transaction. Keep
    # both old and new release/materials for review if recovery cannot commit.
    $actual=Cdf-AutoReadJson $policyPath
    if((Cdf-Json $actual) -ceq (Cdf-Json $policy)){
        if($before){[IO.File]::WriteAllText($policyPath,$before,[Text.UTF8Encoding]::new($false))}else{$policy.enabled=$false;Cdf-Save $policyPath $policy}
        try{& (Join-Path $staging 'scripts\Manage-ClaudeAuto.ps1') -Action Enable|Out-Null}catch{throw ('Network integration failed: '+$failure+'; recovery also stopped: '+$_.Exception.Message+'; materials: '+$staging)}
    }
    throw ('Network integration failed and previous provider selection was restored: '+$failure)
}
Get-NetworkIntegrationStatus|ConvertTo-Json -Depth 10
