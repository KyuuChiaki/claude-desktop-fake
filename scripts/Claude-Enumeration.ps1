# Enumeration policy is consumed by the manager, never by the early provider.
Set-StrictMode -Version Latest
function Cdf-Enumeration($C,$Package) {
    if(-not $C.EnumerationConfigPath){
        return [pscustomobject]@{configurationPath=$null;sha256=$null;directories=@([pscustomobject]@{template='%CLAUDE_PACKAGE_ROOT%';path=$Package.root;exists=[IO.Directory]::Exists($Package.root)});legacy=$true}
    }
    $path=[IO.Path]::GetFullPath($C.EnumerationConfigPath)
    $bytes=[IO.File]::ReadAllBytes($path)
    if(-not $bytes.Length -or $bytes.Length -gt 16384){throw 'Enumeration configuration must be non-empty UTF-8 JSON of at most 16 KiB.'}
    $json=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xfeff)
    $settings=ConvertFrom-Json -InputObject $json
    if($null -eq $settings -or $settings -isnot [pscustomobject]){throw 'Enumeration configuration must be an object.'}
    # ConvertFrom-Json can accept repeated names on some PowerShell versions.
    # Inspect top-level property tokens separately before consuming their data.
    $tokens=[regex]::Matches($json,'"(?:\\.|[^"\\])*"|[{}\[\]:,]')
    $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $objects=0;$arrays=0
    for($i=0;$i -lt $tokens.Count;$i++){
        $token=$tokens[$i].Value
        if($token -eq '{'){$objects++}elseif($token -eq '}'){$objects--}elseif($token -eq '['){$arrays++}elseif($token -eq ']'){$arrays--}
        elseif($objects -eq 1 -and $arrays -eq 0 -and $token.StartsWith('"') -and $i+1 -lt $tokens.Count -and $tokens[$i+1].Value -eq ':'){
            $key=ConvertFrom-Json -InputObject $token
            if(-not $keys.Add([string]$key)){throw "Duplicate enumeration field: $key"}
        }
    }
    if($keys.Count -ne 2 -or -not $keys.Contains('schemaVersion') -or -not $keys.Contains('imageDirectories')){throw 'Enumeration configuration requires only schemaVersion and imageDirectories.'}
    if(($settings.schemaVersion -isnot [int] -and $settings.schemaVersion -isnot [long]) -or $settings.schemaVersion -ne 1){throw 'Unsupported enumeration schemaVersion.'}
    if($settings.imageDirectories -isnot [array] -or $settings.imageDirectories.Count -lt 1 -or $settings.imageDirectories.Count -gt 16){throw 'imageDirectories must be an array of 1 to 16 directory strings.'}
    $folders=@{
        CLAUDE_PACKAGE_ROOT=[IO.Path]::GetFullPath($Package.root)
        LOCALAPPDATA=[Environment]::GetFolderPath('LocalApplicationData')
        APPDATA=[Environment]::GetFolderPath('ApplicationData')
        USERPROFILE=[Environment]::GetFolderPath('UserProfile')
        PROGRAMDATA=[Environment]::GetFolderPath('CommonApplicationData')
    }
    $directories=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($template in $settings.imageDirectories){
        if($template -isnot [string] -or [string]::IsNullOrWhiteSpace($template)){throw 'imageDirectories entries must be non-empty strings.'}
        $expanded=[regex]::Replace($template,'%([A-Za-z_][A-Za-z0-9_]*)%',{
            param($match)
            $name=$match.Groups[1].Value
            if(-not $folders.ContainsKey($name) -or -not $folders[$name]){throw "Unknown or unavailable enumeration variable: $name"}
            return [string]$folders[$name]
        })
        if($expanded -notmatch '^[A-Za-z]:[\\/]' -or $expanded -match '[*?"<>|\x00-\x1f]'){throw "Enumeration requires a drive-absolute directory without wildcards: $template"}
        $full=[IO.Path]::GetFullPath($expanded).TrimEnd('\')
        if($full -ieq [IO.Path]::GetPathRoot($full).TrimEnd('\')){throw 'Enumeration of a drive root is not allowed.'}
        if([IO.File]::Exists($full)){throw "Enumeration entry is a file: $template"}
        if($seen.Add($full)){$directories+=[pscustomobject]@{template=$template;path=$full;exists=[IO.Directory]::Exists($full)}}
    }
    if(-not $seen.Contains([IO.Path]::GetFullPath($Package.root).TrimEnd('\'))){throw 'imageDirectories must include %CLAUDE_PACKAGE_ROOT%.'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
    [pscustomobject]@{configurationPath=$path;sha256=$hash;directories=$directories;legacy=$false}
}
function Cdf-EnumeratedFiles($Enumeration,$Package) {
    if($Enumeration.legacy){return [pscustomobject]@{files=@($Package.files);skipped=@()}}
    $files=[Collections.Generic.List[string]]::new();$skipped=[Collections.Generic.List[object]]::new()
    $visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($root in $Enumeration.directories){
        if(-not $root.exists){continue}
        $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($root.path)
        while($pending.Count){
            $directory=$pending.Pop()
            if(-not $visited.Add($directory)){continue}
            $item=Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){$skipped.Add([pscustomobject]@{path=$directory;status='NotChecked';signer='';reason='reparse-directory'});continue}
            foreach($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)){
                if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){
                    if($entry.PSIsContainer -or $entry.Extension -ieq '.exe'){$skipped.Add([pscustomobject]@{path=$entry.FullName;status='NotChecked';signer='';reason='reparse-entry'})}
                    continue
                }
                if($entry.PSIsContainer){$pending.Push($entry.FullName)}elseif($entry.Extension -ieq '.exe'){$files.Add($entry.FullName)}
            }
        }
    }
    [pscustomobject]@{files=@($files.ToArray()|Sort-Object -Unique);skipped=@($skipped.ToArray())}
}
function Cdf-PathInEnumeration([string]$Path,$Directories) {
    if(-not $Path){return $false}
    foreach($directory in $Directories){
        if($Path.StartsWith(($directory.path.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){return $true}
    }
    return $false
}
