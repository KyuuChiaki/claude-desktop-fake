# Launch the current Store desktop through its normal activation path, after
# verifying the signed network integration and existing time registration.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$status=& (Join-Path $PSScriptRoot 'Manage-ClaudeNetwork.ps1') -Action Status|ConvertFrom-Json
if(-not $status.enabled -or -not $status.transport.hashesMatch){throw 'Enable and verify Manage-ClaudeNetwork before launching Claude.'}
if(@(Get-CimInstance Win32_Process -Filter "Name='Claude.exe'"|Where-Object {$_.ExecutablePath -like '*\WindowsApps\AnthropicPBC.Claude_*\app\Claude.exe'}).Count){throw 'Claude Desktop is already running. Exit it yourself before applying a new startup policy.'}
$automaticPath=Join-Path $env:ProgramData 'ClaudeDesktopFake\stage3\claude-auto\state.json'
$automatic=Get-Content -LiteralPath $automaticPath -Raw -Encoding UTF8|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Claude-AutoCore.ps1')
Cdf-AutoVerifyRelease $automatic
$context=Cdf-AutoContext $automatic.release $automatic
$package=Cdf-DiscoverPackage $context
$manifest=Get-Content -LiteralPath $context.Manifest -Raw -Encoding UTF8|ConvertFrom-Json
$entry=@($manifest.images|Where-Object path -ieq $package.main)
if($entry.Count -ne 1){throw 'The current Claude package has not been verified and registered.'}
$current=Get-CdfImageIdentity $package.main
if($current.nativePath -ine $entry[0].nativePath){throw 'The registered Claude image path is stale.'}
foreach($field in @('volumeSerial','fileId','size','lastWriteTimeUtcTicks')){if($current.$field -cne $entry[0].$field){throw ('The registered Claude image is stale: '+$field)}}
$adapter=@(Get-NetAdapter|Where-Object {([Guid]$_.InterfaceGuid) -eq ([Guid]$status.transport.interfaceGuid)})
if($adapter.Count -ne 1 -or -not $adapter[0].HardwareInterface -or $adapter[0].Status -ne 'Up'){throw 'The selected physical adapter is unavailable.'}
Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList 'shell:AppsFolder\AnthropicPBC.Claude_fnn82j28hfe8t!Claude'
[pscustomobject]@{requested=$true;package=$package.packageId;image=$package.main;physicalInterface=$adapter[0].Name;interfaceGuid=$status.transport.interfaceGuid;mode='In-process private proxy over selected physical adapter';lifecycle='Activated desktop only; existing SYSTEM service left running.'}|ConvertTo-Json
