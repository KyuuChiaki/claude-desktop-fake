param([Parameter(Mandatory)][string]$Project,[Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ExpectedFile)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $Project 'scripts\Claude-Enumeration.ps1')
$enumeration=[pscustomobject]@{legacy=$false;directories=@([pscustomobject]@{path=$Root;exists=$true})}
$result=Cdf-EnumeratedFiles $enumeration ([pscustomobject]@{})
$passed=@($result.files).Count -eq 1 -and $result.files[0] -ceq $ExpectedFile -and -not $result.files[0].StartsWith('\\?\')
[pscustomobject]@{passed=$passed;powerShell=$PSVersionTable.PSVersion.ToString();pathLength=$ExpectedFile.Length;files=$result.files;skipped=$result.skipped}|ConvertTo-Json -Depth 5
if(-not $passed){exit 1}
