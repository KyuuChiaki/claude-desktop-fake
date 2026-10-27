Set-StrictMode -Version Latest

function Get-CdfRuntimeProfile(
    [string]$Path,
    [string]$CatalogPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'profiles\runtime-adapters.json'),
    [bool]$Capture=$false,[switch]$CreateBinding,[string]$SymbolsPath
){
    $project=Split-Path -Parent $PSScriptRoot
    $resolver=Join-Path $project 'out\build\x64-release\bin\CdfRuntimeResolve64.exe'
    if(-not(Test-Path -LiteralPath $resolver)){throw 'Build CdfRuntimeResolve64.exe before inspecting runtime compatibility.'}
    $arguments=@('--image',[IO.Path]::GetFullPath($Path));$temporary=$null
    if($Capture){$arguments+='--capture'}
    if($SymbolsPath){
        $arguments+=@('--symbols',[IO.Path]::GetFullPath($SymbolsPath))
        . (Join-Path $PSScriptRoot 'Toolchain.ps1')
        $dia=Find-CdfDiaLibrary
        if($dia){$arguments+=@('--dia-library',$dia)}
    }
    try{
        if($CreateBinding){
            $cache=Join-Path $project 'out\runtime-bindings';[void](New-Item -ItemType Directory -Path $cache -Force)
            $temporary=Join-Path $cache ([Guid]::NewGuid().ToString('N')+'.tmp')
            $arguments+=@('--binding-output',$temporary)
        }
        $text=& $resolver @arguments;$code=$LASTEXITCODE
        if($code -notin @(0,1)){throw "Runtime resolver failed ($code)."}
        $result=($text -join "`n")|ConvertFrom-Json
        if($result.catalogSha256 -cne (Get-FileHash -LiteralPath $CatalogPath).Hash){$result.supported=$false;$result.reason='catalogue-build-mismatch'}
        $bindingSource=$null
        if($CreateBinding -and $result.supported -and $result.type -eq 'electron'){
            if((Get-FileHash -LiteralPath $temporary).Hash -cne $result.bindingSha256){throw 'Runtime binding output hash mismatch.'}
            $bindingSource=Join-Path $cache ($result.bindingSha256+'.bin')
            if(Test-Path -LiteralPath $bindingSource){if((Get-FileHash -LiteralPath $bindingSource).Hash -cne $result.bindingSha256){throw 'Cached runtime binding changed externally.'}}
            else{[IO.File]::Move($temporary,$bindingSource);$temporary=$null}
        }
        $result|Add-Member -NotePropertyMembers @{bindingSource=$bindingSource;instructionChecks=@($result.sites|ForEach-Object{[pscustomobject]@{rva=$_.rva;valid=($_.rva -ne 0)}})}
        return $result
    }finally{if($temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
