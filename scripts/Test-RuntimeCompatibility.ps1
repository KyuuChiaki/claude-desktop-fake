[CmdletBinding()]
param([Parameter(Mandatory)][string]$ImagePath,[string]$SymbolsPath,[string]$OutputPath,[switch]$RequireCapture)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Runtime-Profiles.ps1')
$report=Get-CdfRuntimeProfile -Path $ImagePath -SymbolsPath $SymbolsPath -Capture ([bool]$RequireCapture)
$json=$report|ConvertTo-Json -Depth 12
if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,[Text.UTF8Encoding]::new($false))}
$json
if(-not $report.supported){exit 1}
