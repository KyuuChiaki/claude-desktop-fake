[CmdletBinding()]
param([string]$BuildDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(-not $BuildDirectory){$BuildDirectory=Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'}
. (Join-Path $PSScriptRoot 'Claude-AutoCore.ps1')
$results=Join-Path $BuildDirectory 'test-results';[IO.Directory]::CreateDirectory($results)|Out-Null
$run=Join-Path $results ('auto-monitor-'+[Guid]::NewGuid().ToString('N'));Cdf-SecureDirectory $run
$checks=[Collections.Generic.List[object]]::new();$children=[Collections.Generic.List[Diagnostics.Process]]::new()
$hub=$null;$task=$null;$service=$null;$taskName=$null;$failure=$null;$cleanup=@()
function Check([bool]$Condition,[string]$Name){$checks.Add([pscustomobject]@{name=$Name;passed=$Condition});if(-not $Condition){throw $Name}}
function Child {
    $p=[Diagnostics.Process]::new();$p.StartInfo.FileName=Join-Path $BuildDirectory 'bin\CdfAutoProbe64.exe'
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true;$p.StartInfo.RedirectStandardOutput=$true
    [void]$p.Start();$children.Add($p);return $p
}
function Wait-Change($Watcher,[long]$Before){$end=[DateTime]::UtcNow.AddSeconds(8);while($Watcher.Generation -le $Before -and [DateTime]::UtcNow -lt $end){[void]$Watcher.Wait(100)};return $Watcher.Generation -gt $Before}
try{
    $sharedJson=Join-Path $run 'shared-json.json';Cdf-Save $sharedJson ([pscustomobject]@{value=1})
    $jsonHandle=[IO.File]::Open($sharedJson,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{Cdf-Save $sharedJson ([pscustomobject]@{value=2});Check ((Cdf-AutoReadJson $sharedJson).value -eq 2) 'shared JSON snapshots tolerate atomic replacement without blocking the writer'}finally{$jsonHandle.Dispose()}
    $watchRoot=Join-Path $run 'watch';[IO.Directory]::CreateDirectory($watchRoot)|Out-Null
    $hub=Cdf-AutoWatchers @([pscustomobject]@{path=$watchRoot;folderNamePattern='AnthropicPBC.Claude_*'})
    $before=$hub.Generation;$version=Join-Path $watchRoot 'AnthropicPBC.Claude_9.0.0_arm64__different';[IO.Directory]::CreateDirectory($version)|Out-Null
    Check (Wait-Change $hub $before) 'new package directory triggers refresh without a fixed publisher suffix'
    $hub.Dispose();$hub=Cdf-AutoWatchers @([pscustomobject]@{path=$watchRoot;folderNamePattern='AnthropicPBC.Claude_*'})
    $before=$hub.Generation;[IO.File]::WriteAllText((Join-Path $version 'any-new-name.exe'),'fixture')
    Check (Wait-Change $hub $before) 'new executable filename triggers file monitoring'
    $before=$hub.Generation;[IO.File]::WriteAllText((Join-Path $version 'any-new-name.exe'),'changed-fixture')
    Check (Wait-Change $hub $before) 'executable replacement triggers file monitoring'
    $foreign=Join-Path $watchRoot 'OtherApplication';[IO.Directory]::CreateDirectory($foreign)|Out-Null
    [Threading.Thread]::Sleep(150);$before=$hub.Generation;[IO.File]::WriteAllText((Join-Path $foreign 'ignored.exe'),'fixture');[void]$hub.Wait(150)
    Check ($hub.Generation -eq $before) 'wildcard root does not recursively monitor unrelated packages'
    $valid={param($Path)[pscustomobject]@{status='Valid';signer='Anthropic, PBC'}}
    $p=Child;$result=Cdf-AutoInspectProcess $p.Id @() @{}
    Check ($result.action -eq 'not-target' -and -not $p.HasExited) 'unsigned executable is not terminated by production signature verification'
    $p.Kill();[void]$p.WaitForExit(3000)
    $p=Child;$result=Cdf-AutoInspectProcess $p.Id @() @{} {param($Path)[pscustomobject]@{status='Valid';signer='Other Publisher'}}
    Check ($result.action -eq 'not-target' -and -not $p.HasExited) 'valid unrelated signer is not terminated'
    $p.Kill();[void]$p.WaitForExit(3000)
    $p=Child;$result=Cdf-AutoInspectProcess $p.Id @() @{} {param($Path)[pscustomobject]@{status='HashMismatch';signer='Anthropic, PBC'}}
    Check ($result.action -eq 'not-target' -and -not $p.HasExited) 'invalid Anthropic signature is not treated as a verified target'
    $p.Kill();[void]$p.WaitForExit(3000)
    $p=Child;$result=Cdf-AutoInspectProcess $p.Id @() @{} {param($Path)throw 'signature-fixture-error'}
    Check ($result.action -eq 'inspection-failed' -and -not $p.HasExited) 'signature inspection failure preserves unrelated or uncertain processes'
    $p.Kill();[void]$p.WaitForExit(3000)
    $p=Child;$result=Cdf-AutoInspectProcess $p.Id @() @{} $valid
    [void]$p.WaitForExit(3000)
    Check ($result.action -eq 'terminated' -and $result.reason -eq 'unregistered-image' -and [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$p.ExitCode),0) -eq [Convert]::ToUInt32('E0CDF602',16)) 'verified unregistered fixture is terminated using its retained process handle'
    $identity=Get-CdfImageIdentity (Join-Path $BuildDirectory 'bin\CdfAutoProbe64.exe')
    $p=Child;$result=Cdf-AutoInspectProcess $p.Id @($identity) @{} $valid 'ntdll.dll'
    Check ($result.action -eq 'registered' -and -not $p.HasExited) 'registered fixture with its expected provider remains running'
    $p.Kill();[void]$p.WaitForExit(3000)
    $p=Child;[Threading.Thread]::Sleep(2100);$result=Cdf-AutoInspectProcess $p.Id @($identity) @{} $valid 'CdfMissingFixture.dll'
    [void]$p.WaitForExit(3000)
    Check ($result.action -eq 'terminated' -and $result.reason -eq 'provider-not-loaded') 'verified registered fixture without its provider is terminated after startup grace'
    Cdf-AutoRememberImage $run $identity.path;Cdf-AutoRememberImage $run $identity.path
    Check (@((Get-Content (Join-Path $run 'discovered-images.json') -Raw|ConvertFrom-Json).paths).Count -eq 1) 'process discoveries are deduplicated for later signature-checked registration'
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Scheduled task lifecycle test needs elevated PowerShell.'}
    $service=Cdf-AutoTaskService;$taskName='CdfAutoTest-'+[Guid]::NewGuid().ToString('N')
    $marker=Join-Path $run 'system-task.json';$script=Join-Path $run 'task-fixture.ps1'
    [IO.File]::WriteAllText($script,'param($Output,$Core); . $Core; $held=Cdf-NewRegistryMutex; try { @{pid=$PID;sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}|ConvertTo-Json|Set-Content -LiteralPath $Output; Start-Sleep -Seconds 60 } finally {$held.Dispose()}')
    $shell=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$script+'" -Output "'+$marker+'" -Core "'+(Join-Path $PSScriptRoot 'Claude-ManagerCore.ps1')+'"'
    $state=[pscustomobject]@{enabled=$true;ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;taskName=$taskName;shell=$shell;arguments=$arguments}
    Cdf-Save (Join-Path $run 'state.json') $state
    $definition=$service.NewTask(0);$definition.RegistrationInfo.Source='ClaudeDesktopFake.AutoRefresh.v1'
    $definition.Principal.UserId='S-1-5-18';$definition.Principal.LogonType=5;$definition.Principal.RunLevel=1
    $definition.Settings.StartWhenAvailable=$true;$definition.Settings.MultipleInstances=2;$definition.Settings.ExecutionTimeLimit='PT0S';$definition.Settings.Hidden=$true
    $boot=$definition.Triggers.Create(8);$boot.Enabled=$true;$boot.Delay='PT5S';$logon=$definition.Triggers.Create(9);$logon.Enabled=$true;$logon.UserId=$state.ownerSid
    $action=$definition.Actions.Create(0);$action.Path=$shell;$action.Arguments=$arguments
    $task=$service.GetFolder('\').RegisterTaskDefinition($taskName,$definition,6,'SYSTEM',$null,5,'D:P(A;;FA;;;SY)(A;;FA;;;BA)')
    Cdf-AutoAssertTask $task $state
    Check ($task.Definition.Triggers.Count -eq 2) 'owned task persists with boot and owner-logon triggers'
    [void]$task.Run($null);$until=[DateTime]::UtcNow.AddSeconds(20)
    while(-not(Test-Path -LiteralPath $marker) -and [DateTime]::UtcNow -lt $until){[Threading.Thread]::Sleep(150)}
    $record=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
    Check ($record.sid -ceq 'S-1-5-18') 'scheduled worker executes as LocalSystem without an interactive window'
    $shared=Cdf-NewRegistryMutex;$acquired=$false
    try{$acquired=$shared.WaitOne(1000);Check $acquired 'administrator can open and acquire a registry mutex created by LocalSystem'}finally{if($acquired){$shared.ReleaseMutex()};$shared.Dispose()}
    $stopStarted=[DateTime]::UtcNow;Cdf-AutoStop $run
    Check (([DateTime]::UtcNow-$stopStarted).TotalSeconds -lt 10) 'Disable stops the task without waiting for its idle timer to expire'
    Check (-not (Get-Content (Join-Path $run 'state.json') -Raw|ConvertFrom-Json).enabled) 'Disable first cancels refresh admission'
    $service.GetFolder('\').DeleteTask($taskName,0);$task=$null
    Check (-not(Cdf-AutoTask $service $taskName)) 'Disable removes the exact owned startup task'
    Check (-not(Get-Process -Id $record.pid -ErrorAction SilentlyContinue)) 'Disable stops the owned worker process'
}catch{$failure=$_.Exception.Message+"`n"+$_.ScriptStackTrace}finally{
    if($hub){$hub.Dispose()}
    if($task -and $service){try{$task.Stop(0);$service.GetFolder('\').DeleteTask($taskName,0)}catch{$cleanup+=$_.Exception.Message}}
    foreach($child in $children){try{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)};$child.Dispose()}catch{$cleanup+=$_.Exception.Message}}
    $report=[pscustomobject]@{passed=($null -eq $failure -and $cleanup.Count -eq 0);failure=$failure;cleanupErrors=$cleanup;runDirectory=$run;cases=$checks.ToArray();signatureMockUsedOnlyForOwnedFixtures=$true}
    Cdf-Save (Join-Path $results 'claude-auto-monitor.json') $report
}
if(-not $report.passed){throw ('Automatic monitor test failed: '+$failure+'; cleanup='+($cleanup -join '; '))}
[pscustomobject]@{passed=$true;cases=$checks.Count}|ConvertTo-Json -Compress
