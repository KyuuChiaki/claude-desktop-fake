# Resolve development tools from this machine, not from repository-local paths.
Set-StrictMode -Version Latest
function Find-CdfExecutable([string]$ExplicitPath,[string]$Name,[string[]]$Candidates=@()) {
    if($ExplicitPath){
        $resolved=Get-Command $ExplicitPath -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        if($resolved){return $resolved.Source}
        if(Test-Path -LiteralPath $ExplicitPath -PathType Leaf){return [IO.Path]::GetFullPath($ExplicitPath)}
        throw "Tool was not found: $ExplicitPath"
    }
    $command=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if($command){return $command.Source}
    foreach($candidate in $Candidates){if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)){return [IO.Path]::GetFullPath($candidate)}}
    throw "Required tool $Name was not found. Add it to PATH or pass its explicit path."
}
function Find-CdfVisualStudio([string]$InstallationPath) {
    if($InstallationPath){
        $root=[IO.Path]::GetFullPath($InstallationPath)
        if(-not(Test-Path -LiteralPath (Join-Path $root 'VC\Auxiliary\Build\vcvars64.bat'))){throw 'The supplied Visual Studio installation has no x64 MSVC environment.'}
        return $root
    }
    if($env:VSINSTALLDIR -and (Test-Path -LiteralPath (Join-Path $env:VSINSTALLDIR 'VC\Auxiliary\Build\vcvars64.bat'))){return [IO.Path]::GetFullPath($env:VSINSTALLDIR)}
    $candidates=@()
    foreach($base in @(${env:ProgramFiles(x86)},$env:ProgramFiles)){if($base){$candidates+=Join-Path $base 'Microsoft Visual Studio\Installer\vswhere.exe'}}
    $vswhere=Find-CdfExecutable '' 'vswhere.exe' $candidates
    $installations=@(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    $code=$LASTEXITCODE
    $root=$installations|Select-Object -First 1
    if($code -ne 0 -or -not $root){throw 'Install Visual Studio 2022 or Build Tools with Desktop development with C++.'}
    return [IO.Path]::GetFullPath($root.Trim())
}
function Find-CdfDiaLibrary {
    if($env:CDF_DIA_DLL){return Find-CdfExecutable $env:CDF_DIA_DLL 'msdia140.dll'}
    try{$root=Find-CdfVisualStudio $env:CDF_VS_INSTALLATION}catch{return $null}
    $candidate=Join-Path $root 'DIA SDK\bin\amd64\msdia140.dll'
    if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}
    return $null
}
