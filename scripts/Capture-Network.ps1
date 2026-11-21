[CmdletBinding()]
param([Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ProcessId,[string]$OutputPath,[string]$BuildDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'out\build\x64-release'),[ValidateSet('CdfNetwork64.dll','CdfClaudeNetwork64.dll')][string]$ProviderName='CdfNetwork64.dll')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Claude-ProcessDiagnostics.ps1')
$process=[Diagnostics.Process]::GetProcessById($ProcessId)
try{
    $modules=@($process.Modules|Where-Object ModuleName -eq $ProviderName)
    if($modules.Count -ne 1){throw 'The requested process does not contain exactly one network provider.'}
    $module=$modules[0];$local=Join-Path $BuildDirectory ('bin\'+$ProviderName);$mapPath=[IO.Path]::ChangeExtension($local,'map')
    if((Get-FileHash -LiteralPath $local).Hash -ne (Get-FileHash -LiteralPath $module.FileName).Hash){throw 'A matching provider binary and map are required.'}
    $image=[IO.File]::ReadAllBytes($local);$pe=[BitConverter]::ToInt32($image,60);$preferred=[BitConverter]::ToUInt64($image,$pe+48)
    $mapped=[CdfClaudeReadMemory]::Read($ProcessId,$module.BaseAddress.ToInt64(),$pe+256)
    foreach($offset in @(($pe+8),($pe+80))){if([BitConverter]::ToUInt32($mapped,$offset) -ne [BitConverter]::ToUInt32($image,$offset)){throw 'Mapped provider header does not match the diagnostic build.'}}
    $map=[IO.File]::ReadAllText($mapPath)
    $symbols=[regex]::Matches($map,'(?m)^\s+[0-9a-f]+:[0-9a-f]+\s+\?diagnostic@network@cdf@@\S+\s+([0-9a-f]+)\s+network_provider\.cpp\.obj\s*$')
    if($symbols.Count -ne 1){throw 'Missing or ambiguous network diagnostic symbol.'}
    $rva=[Convert]::ToInt64($symbols[0].Groups[1].Value,16)-[long]$preferred
    if($rva -lt 0 -or $rva+544 -gt $module.ModuleMemorySize){throw 'Diagnostic data is outside the provider.'}
    $data=[CdfClaudeReadMemory]::Read($ProcessId,$module.BaseAddress.ToInt64()+$rva,544)
    if([BitConverter]::ToUInt32($data,0) -ne 544 -or [BitConverter]::ToUInt32($data,4) -ne 1){throw 'Network diagnostic ABI does not match this build.'}
    $calls=@(for($i=0;$i -lt 32;$i++){[BitConverter]::ToUInt64($data,272+8*$i)})
    $state=[BitConverter]::ToUInt32($data,8)
    $report=[pscustomobject]@{schemaVersion=1;processId=$ProcessId;processName=$process.ProcessName;provider=$module.FileName;providerSha256=(Get-FileHash -LiteralPath $local).Hash;method='ReadProcessMemory only; no remote execution';snapshot='best-effort atomic counters';state=$state;policyReady=[bool]($state-band 4);hooksReady=[bool]($state-band 8);transportReady=[bool]($state-band 16);failed=[bool]($state-band [uint32]2147483648);errorStage=[BitConverter]::ToUInt32($data,12);errorCode=[BitConverter]::ToUInt32($data,16);installedHooks=[BitConverter]::ToUInt32($data,24);connectCalls=[BitConverter]::ToUInt64($data,32);proxiedConnections=[BitConverter]::ToUInt64($data,40);dnsQueries=[BitConverter]::ToUInt64($data,48);deniedCalls=[BitConverter]::ToUInt64($data,56);nativeDenials=[BitConverter]::ToUInt64($data,64);dynamicLookups=[BitConverter]::ToUInt64($data,72);apiCalls=$calls;lastApi=[BitConverter]::ToUInt32($data,528);arguments=@([BitConverter]::ToUInt32($data,532),[BitConverter]::ToUInt32($data,536),[BitConverter]::ToUInt32($data,540))}
    $report|Add-Member -NotePropertyName lastNativeIoctl -NotePropertyValue ([BitConverter]::ToUInt32($data,84))
    $report|Add-Member -NotePropertyName deniedIoctl -NotePropertyValue ([BitConverter]::ToUInt32($data,200))
    $report|Add-Member -NotePropertyName deniedInputSize -NotePropertyValue ([BitConverter]::ToUInt32($data,204))
    $report|Add-Member -NotePropertyName deniedMetadata -NotePropertyValue ([BitConverter]::ToString($data,208,32).Replace('-',''))
    $json=$report|ConvertTo-Json -Depth 8
    if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,[Text.UTF8Encoding]::new($false))}
    $json
}finally{$process.Dispose()}
