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
        PROGRAMFILES=[Environment]::GetFolderPath('ProgramFiles')
    }
    if($C.PSObject.Properties['FolderOverrides'] -and $C.FolderOverrides){
        foreach($key in @('LOCALAPPDATA','APPDATA','USERPROFILE','PROGRAMDATA','PROGRAMFILES')){
            if($C.FolderOverrides.PSObject.Properties[$key]){$folders[$key]=[IO.Path]::GetFullPath([string]$C.FolderOverrides.$key)}
        }
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
        if($expanded -notmatch '^[A-Za-z]:[\\/]' -or $expanded -match '["<>|\x00-\x1f]'){throw "Enumeration requires a drive-absolute directory: $template"}
        $expanded=$expanded.Replace('/','\');if($expanded.Length -gt 3){$expanded=$expanded.TrimEnd('\')};$folderPattern=$null
        if($expanded -match '[*?]'){
            $separator=$expanded.LastIndexOf('\')
            $folderPattern=$expanded.Substring($separator+1)
            $parent=$expanded.Substring(0,$separator+1)
            if($parent -match '[*?]' -or $folderPattern -match '[\[\]`]'){
                throw "Directory wildcards are limited to * and ? in the final folder name: $template"
            }
            $full=[IO.Path]::GetFullPath($parent).TrimEnd('\')
        }else{$full=[IO.Path]::GetFullPath($expanded).TrimEnd('\')}
        if($full -ieq [IO.Path]::GetPathRoot($full).TrimEnd('\')){throw 'Enumeration of a drive root is not allowed.'}
        if([IO.File]::Exists($full)){throw "Enumeration entry is a file: $template"}
        $key=if($folderPattern){$full+'\'+$folderPattern}else{$full}
        if($seen.Add($key)){$directories+=[pscustomobject]@{template=$template;path=$full;exists=[IO.Directory]::Exists($full);folderNamePattern=$folderPattern}}
    }
    if(-not $seen.Contains([IO.Path]::GetFullPath($Package.root).TrimEnd('\'))){throw 'imageDirectories must include %CLAUDE_PACKAGE_ROOT%.'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
    [pscustomobject]@{configurationPath=$path;sha256=$hash;directories=$directories;legacy=$false}
}
function Cdf-ReadEnumerationDirectory([string]$Path) {
    # Windows PowerShell 5.1 can report an existing path over MAX_PATH as
    # missing. Use extended paths for filesystem access, then return ordinary
    # DOS paths to signature verification and the provider identity manifest.
    $literal=if($Path.StartsWith('\\?\',[StringComparison]::Ordinal)){$Path}else{'\\?\'+$Path}
    $item=Get-Item -LiteralPath $literal -Force -ErrorAction Stop
    if(-not $item.PSIsContainer){throw [IO.DirectoryNotFoundException]::new('Enumeration directory no longer exists: '+$Path)}
    $entries=@()
    if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
        $entries=@(Get-ChildItem -LiteralPath $literal -Force -ErrorAction Stop)
    }
    [pscustomobject]@{attributes=$item.Attributes;entries=$entries}
}
function Cdf-IsMissingEnumerationDirectory($ErrorRecord) {
    $exception=$ErrorRecord.Exception
    while($exception){
        if($exception -is [Management.Automation.ItemNotFoundException] -or
           $exception -is [IO.DirectoryNotFoundException] -or $exception -is [IO.FileNotFoundException]){return $true}
        if($exception -is [ComponentModel.Win32Exception]){return $exception.NativeErrorCode -in @(2,3)}
        $exception=$exception.InnerException
    }
    return $false
}
function Cdf-EnumerationFolderPattern($Directory) {
    if($Directory.PSObject.Properties['folderNamePattern']){return $Directory.folderNamePattern}
    return $null
}
function Cdf-EnumerationFolderMatcher([string]$Pattern) {
    [Management.Automation.WildcardPattern]::new($Pattern,([Management.Automation.WildcardOptions]::IgnoreCase -bor [Management.Automation.WildcardOptions]::CultureInvariant))
}
function Cdf-EnumeratedFiles($Enumeration,$Package) {
    if($Enumeration.legacy){return [pscustomobject]@{files=@($Package.files);skipped=@()}}
    $files=[Collections.Generic.List[string]]::new();$skipped=[Collections.Generic.List[object]]::new()
    $visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($root in $Enumeration.directories){
        if(-not $root.exists){continue}
        $pending=[Collections.Generic.Stack[object]]::new()
        $pending.Push([pscustomobject]@{path=$root.path;folderNamePattern=(Cdf-EnumerationFolderPattern $root)})
        while($pending.Count){
            $frame=$pending.Pop();$directory=$frame.path;$folderPattern=$frame.folderNamePattern
            if(-not $visited.Add($directory+'|'+$folderPattern)){continue}
            try{$snapshot=Cdf-ReadEnumerationDirectory $directory}catch{
                if(Cdf-IsMissingEnumerationDirectory $_){$skipped.Add([pscustomobject]@{path=$directory;status='NotChecked';signer='';reason='directory-disappeared'});continue}
                throw
            }
            if($snapshot.attributes -band [IO.FileAttributes]::ReparsePoint){$skipped.Add([pscustomobject]@{path=$directory;status='NotChecked';signer='';reason='reparse-directory'});continue}
            $matcher=if($folderPattern){Cdf-EnumerationFolderMatcher $folderPattern}else{$null};$matchedDirectories=0
            foreach($entry in $snapshot.entries){
                $entryPath=$entry.FullName
                if($entryPath.StartsWith('\\?\',[StringComparison]::Ordinal)){$entryPath=$entryPath.Substring(4)}
                if($matcher){
                    if(-not $entry.PSIsContainer -or -not $matcher.IsMatch($entry.Name)){continue}
                    $matchedDirectories++
                }
                if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){
                    if($entry.PSIsContainer -or $entry.Extension -ieq '.exe'){$skipped.Add([pscustomobject]@{path=$entryPath;status='NotChecked';signer='';reason='reparse-entry'})}
                    continue
                }
                if($entry.PSIsContainer){$pending.Push([pscustomobject]@{path=$entryPath;folderNamePattern=$null})}elseif($entry.Extension -ieq '.exe'){$files.Add($entryPath)}
            }
            if($matcher -and -not $matchedDirectories){$skipped.Add([pscustomobject]@{path=($directory+'\'+$folderPattern);status='NotChecked';signer='';reason='folder-pattern-no-match'})}
        }
    }
    [pscustomobject]@{files=@($files.ToArray()|Sort-Object -Unique);skipped=@($skipped.ToArray())}
}
function Cdf-PathInEnumeration([string]$Path,$Directories) {
    if(-not $Path){return $false}
    foreach($directory in $Directories){
        $prefix=$directory.path.TrimEnd('\')+'\'
        if(-not $Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){continue}
        $pattern=Cdf-EnumerationFolderPattern $directory
        if(-not $pattern){return $true}
        $relative=$Path.Substring($prefix.Length);$separator=$relative.IndexOf('\')
        if($separator -gt 0 -and (Cdf-EnumerationFolderMatcher $pattern).IsMatch($relative.Substring(0,$separator))){return $true}
    }
    return $false
}
function Cdf-ResolveRunningImage([string]$ReportedPath,$Diagnostic,$Images,$Directories) {
    # Store virtualization can expose an AppData alias through CIM while the
    # provider sees the actual package-cache image. Resolve against the exact
    # native path already captured by the provider; do not invent path aliases.
    $nativePath=if($Diagnostic.identity){$Diagnostic.identity.currentImagePath}else{$null}
    $entries=@($Images|Where-Object {
        $_.path -ieq $ReportedPath -or ($nativePath -and $_.nativePath -ieq $nativePath)
    })
    $resolvedPath=$ReportedPath
    if($entries.Count){$resolvedPath=$entries[0].path}
    elseif($Diagnostic.identity -and $Diagnostic.identity.matchedImagePath){
        # An old, now-removed identity remains visible in a running snapshot.
        # Its path helps explain scope, but must not mark it as currently listed.
        $resolvedPath=$Diagnostic.identity.matchedImagePath
    }
    [pscustomobject]@{
        listed=($entries.Count -gt 0)
        inEnumeration=((Cdf-PathInEnumeration $ReportedPath $Directories) -or (Cdf-PathInEnumeration $resolvedPath $Directories))
        resolvedPath=$resolvedPath
    }
}
