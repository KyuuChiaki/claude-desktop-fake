[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Enable','Status','Disable')][string]$Action)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-AutoCore.ps1')
$project=Split-Path -Parent $PSScriptRoot;$root=Cdf-AutoRoot;$statePath=Join-Path $root 'state.json';$pending=Join-Path $root 'install-pending.json'
$service=Cdf-AutoTaskService
function Read-AutoStatus {
    $state=if(Test-Path -LiteralPath $statePath){Cdf-AutoReadJson $statePath}else{$null}
    $healthPath=Join-Path $root 'health.json';$health=if(Test-Path -LiteralPath $healthPath){Cdf-AutoReadJson $healthPath}else{$null}
    $task=$null;$errorText=$null
    if($state){try{$task=Cdf-AutoTask $service $state.taskName;Cdf-AutoAssertTask $task $state;Cdf-AutoVerifyRelease $state}catch{$errorText=$_.Exception.Message}}
    # PowerShell 7 may already deserialize ISO timestamps as UTC DateTime;
    # converting that object to a culture-specific string loses its time zone.
    $fresh=$health -and $health.heartbeatUtc -and ([DateTime]::UtcNow-([DateTime]$health.heartbeatUtc).ToUniversalTime()).TotalSeconds -lt 30
    $running=$task -and $task.State -eq 4 -and $fresh -and $health.state -in @('starting','watching','refreshing','retrying')
    if($running){$running=@(Cdf-AutoOwnedProcesses $root $state|Where-Object ProcessId -eq $health.pid).Count -eq 1}
    [pscustomobject]@{configured=($null -ne $state);enabled=($state -and $state.enabled -and $task -and $task.Enabled -and -not $errorText);monitorRunning=[bool]$running;taskName=$(if($state){$state.taskName}else{$null});taskPresent=($null -ne $task);taskState=$(if($task){$task.State}else{$null});lastTaskResult=$(if($task){$task.LastTaskResult}else{$null});principal='LocalSystem';startsAtBoot=([bool]($task -and $task.Enabled -and -not $errorText));pending=(Test-Path -LiteralPath $pending);error=$errorText;health=$health;root=$root}
}
if($Action -eq 'Status'){Read-AutoStatus|ConvertTo-Json -Depth 12;return}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not [Environment]::Is64BitProcess -or -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Use elevated 64-bit PowerShell for automatic refresh management.'}
# An interrupted installer only stops/removes a task whose action and owner
# match its recorded old or new definition. Its immutable release is retained.
if(Test-Path -LiteralPath $pending){
    $journal=Cdf-AutoReadJson $pending
    if($journal.schemaVersion -ne 1 -or $journal.next.ownerSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Invalid automatic refresh installation journal.'}
    $task=Cdf-AutoTask $service $journal.next.taskName;$accepted=$null
    foreach($candidate in @($journal.previous,$journal.next)){
        if(-not $candidate){continue}
        try{Cdf-AutoAssertTask $task $candidate;$accepted=$candidate;break}catch{}
    }
    if($task -and -not $accepted){throw 'Interrupted automatic refresh task changed externally; journal retained.'}
    $recovered=if($accepted){$accepted}else{$journal.next};$recovered.enabled=$false;Cdf-Save $statePath $recovered
    Cdf-AutoStop $root
    if($task){$service.GetFolder('\').DeleteTask($journal.next.taskName,0)}
    [IO.File]::Delete($pending)
}
if($Action -eq 'Disable'){
    if(Test-Path -LiteralPath $statePath){
        $state=Cdf-AutoReadJson $statePath
        Cdf-AutoStop $root
        $task=Cdf-AutoTask $service $state.taskName;Cdf-AutoAssertTask $task $state
        if($task){$service.GetFolder('\').DeleteTask($state.taskName,0)}
    }
    Read-AutoStatus|ConvertTo-Json -Depth 12;return
}
$sourceDll=Join-Path $project 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll'
Cdf-AutoCheckProvider $sourceDll
$old=if(Test-Path -LiteralPath $statePath){Cdf-AutoReadJson $statePath}else{$null}
$owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($old -and $old.ownerSid -cne $owner){throw 'Automatic refresh belongs to another Windows user.'}
$taskName='ClaudeDesktopFake-AutoRefresh-'+$owner
$existing=Cdf-AutoTask $service $taskName
if($existing -and -not $old){throw 'An unowned automatic refresh task exists; refusing to replace it.'}
if($old){Cdf-AutoAssertTask $existing $old}
$context=Cdf-AutoContext $project;$package=Cdf-DiscoverPackage $context
$managedState=Cdf-ReadState $context
if($managedState -and $managedState.dllSha256 -cne (Cdf-Hash $sourceDll)){throw 'Disable Claude with the previous deployment before upgrading its provider, then run Enable again.'}
$relative=@(
    'scripts\Claude-AutoCore.ps1','scripts\Watch-Claude.ps1','scripts\Refresh-Claude.ps1',
    'scripts\Claude-FileIdentity.ps1','scripts\Claude-ManagerCore.ps1','scripts\Claude-Enumeration.ps1',
    'scripts\Claude-ProcessDiagnostics.ps1','scripts\Capture-Runtime.ps1','scripts\Runtime-Profiles.ps1','scripts\Toolchain.ps1',
    'config\claude-targets.json','include\locale_hooks.inc','profiles\runtime-adapters.json',
    'out\build\x64-release\bin\CdfClaudeTimeZone64.dll','out\build\x64-release\bin\CdfClaudeTimeZone64.map',
    'out\build\x64-release\bin\CdfTimeRules64.exe','out\build\x64-release\bin\CdfRuntimeResolve64.exe')
$files=@($relative|ForEach-Object{[pscustomobject]@{path=$_;sha256=(Cdf-Hash (Join-Path $project $_))}})
if(@($files|Where-Object {-not $_.sha256}).Count){throw 'Build the project before installing automatic refresh.'}
$sha=[Security.Cryptography.SHA256]::Create()
try{$releaseId=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Cdf-Json $files)))).Replace('-','')}finally{$sha.Dispose()}
foreach($directory in @((Split-Path -Parent $root),$root,(Join-Path $root 'releases'))){Cdf-SecureDirectory $directory}
$release=Join-Path (Join-Path $root 'releases') $releaseId;Cdf-SecureDirectory $release
foreach($file in $files){
    $destination=Join-Path $release $file.path;$directory=Split-Path -Parent $destination
    $chain=[Collections.Generic.Stack[string]]::new();$at=$directory
    while($at.Length -gt $release.Length){$chain.Push($at);$at=Split-Path -Parent $at}
    while($chain.Count){Cdf-SecureDirectory ($chain.Pop())}
    if(Test-Path -LiteralPath $destination){if((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Cdf-Hash $destination) -cne $file.sha256){throw 'Immutable automatic refresh release changed externally.'}}
    else{Cdf-CopyAtomic (Join-Path $project $file.path) $destination $file.sha256}
}
if($old){Cdf-AutoStop $root}
$shell=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $release 'scripts\Watch-Claude.ps1')+'" -StateRoot "'+$root+'"'
$state=[pscustomobject]@{schemaVersion=1;enabled=$true;ownerSid=$owner;taskName=$taskName;shell=$shell;arguments=$arguments;release=$release;files=$files;packageRoot=$package.root;installedAtUtc=[DateTime]::UtcNow.ToString('o');folderOverrides=[pscustomobject]@{LOCALAPPDATA=[Environment]::GetFolderPath('LocalApplicationData');APPDATA=[Environment]::GetFolderPath('ApplicationData');USERPROFILE=[Environment]::GetFolderPath('UserProfile');PROGRAMFILES=[Environment]::GetFolderPath('ProgramFiles');PROGRAMDATA=[Environment]::GetFolderPath('CommonApplicationData')}}
Cdf-Save $pending ([pscustomobject]@{schemaVersion=1;previous=$old;next=$state})
try{
    Cdf-Save $statePath $state
    $refresh=Cdf-AutoRefresh $root
    $definition=$service.NewTask(0);$definition.RegistrationInfo.Description='Refresh verified Claude images and terminate unregistered valid Anthropic targets.';$definition.RegistrationInfo.Source='ClaudeDesktopFake.AutoRefresh.v1'
    $definition.Principal.UserId='S-1-5-18';$definition.Principal.LogonType=5;$definition.Principal.RunLevel=1
    $definition.Settings.Enabled=$true;$definition.Settings.Hidden=$true;$definition.Settings.StartWhenAvailable=$true
    $definition.Settings.DisallowStartIfOnBatteries=$false;$definition.Settings.StopIfGoingOnBatteries=$false
    $definition.Settings.ExecutionTimeLimit='PT0S';$definition.Settings.MultipleInstances=2
    $definition.Settings.RestartCount=3;$definition.Settings.RestartInterval='PT1M'
    $boot=$definition.Triggers.Create(8);$boot.Enabled=$true;$boot.Delay='PT5S'
    $logon=$definition.Triggers.Create(9);$logon.Enabled=$true;$logon.UserId=$owner
    $taskAction=$definition.Actions.Create(0);$taskAction.Path=$shell;$taskAction.Arguments=$arguments
    $task=$service.GetFolder('\').RegisterTaskDefinition($taskName,$definition,6,'SYSTEM',$null,5,'D:P(A;;FA;;;SY)(A;;FA;;;BA)')
    [IO.File]::Delete($pending)
    [void]$task.Run($null)
}catch{
    $state.enabled=$false;Cdf-Save $statePath $state
    throw ('Automatic refresh installation stopped; startup protection is retained. Retry Enable or use Disable. '+$_.Exception.Message)
}
Read-AutoStatus|ConvertTo-Json -Depth 12
