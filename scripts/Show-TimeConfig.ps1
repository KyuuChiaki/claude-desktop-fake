[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$ReferenceUtc,
    [string]$BuildDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$project=Split-Path -Parent $PSScriptRoot
if(-not $ConfigPath){$ConfigPath=Join-Path $project 'config\timezone.json'}
if(-not $BuildDirectory){$BuildDirectory=Join-Path $project 'out\build\x64-release'}
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess){
    throw 'Use 64-bit PowerShell on Windows.'
}
$source=(Resolve-Path -LiteralPath $ConfigPath).ProviderPath
$validator=Join-Path ([IO.Path]::GetFullPath($BuildDirectory)) 'bin\CdfTimeRules64.exe'
if(-not(Test-Path -LiteralPath $validator -PathType Leaf)){throw 'Run scripts/Build.ps1 before previewing the configuration.'}
$before=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
$arguments=@('--preview-config',$source)
if($PSBoundParameters.ContainsKey('ReferenceUtc')){
    if([string]::IsNullOrEmpty($ReferenceUtc)){throw 'ReferenceUtc must be an explicit UTC timestamp ending in Z.'}
    $arguments+=@('--reference-utc',$ReferenceUtc)
}
$raw=& $validator @arguments
$code=$LASTEXITCODE
$rawJson=($raw -join "`n").Trim()
try{$result=$rawJson|ConvertFrom-Json}catch{throw 'The configuration validator does not support previews. Rebuild this checkout.'}
if($code -ne 0 -or -not $result.valid){throw "Configuration preview failed: $($raw -join ' ')"}
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $before){throw 'Configuration changed during preview; retry with a stable file.'}
# Preserve the provider's ISO timestamp strings verbatim. Some PowerShell
# versions deserialize them as DateTime and reserialize them in the host zone.
$metadata=[ordered]@{configPath=$source;configSha256=$before}|ConvertTo-Json -Compress
$rawJson.Substring(0,$rawJson.Length-1)+','+$metadata.Substring(1)
