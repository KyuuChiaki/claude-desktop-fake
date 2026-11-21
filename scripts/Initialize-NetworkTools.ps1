[CmdletBinding()]
param([string]$CacheDirectory = (Join-Path $env:LOCALAPPDATA 'ClaudeDesktopFake\network-tools'), [string]$DownloadProxy)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -LiteralPath (Join-Path $root 'profiles\network-toolchain.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cache = [IO.Path]::GetFullPath($CacheDirectory)
$null = New-Item -ItemType Directory -Force -Path $cache
foreach ($item in @($lock.go, $lock.llvmMingw, $lock.xray)) {
    $name = if ($item -eq $lock.xray) { 'xray-' + $item.commit } elseif ($item -eq $lock.go) { 'go-' + $item.version } else { 'llvm-mingw-' + $item.version }
    $archive = Join-Path $cache ($name + '.zip')
    $folder = Join-Path $cache $name
    if (-not (Test-Path -LiteralPath $archive)) {
        $temporary = $archive + '.download'
        $downloadOptions = @('--fail','--location','--retry','2','--connect-timeout','20','--max-time','1200','--silent','--show-error','--output',$temporary)
        if ($DownloadProxy) { $downloadOptions += @('--proxy',$DownloadProxy) }
        & curl.exe @downloadOptions $item.url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $name" }
        Move-Item -LiteralPath $temporary -Destination $archive
    }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($item.PSObject.Properties['sha256'] -and $item.sha256 -cne $hash) { throw "Archive hash mismatch: $name" }
    if (-not (Test-Path -LiteralPath (Join-Path $folder '.complete.json'))) {
        $null = New-Item -ItemType Directory -Force -Path $folder
        Expand-Archive -LiteralPath $archive -DestinationPath $folder -Force
        [IO.File]::WriteAllText((Join-Path $folder '.complete.json'), (@{sha256=$hash;url=$item.url} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
}
[pscustomobject]@{
    cacheDirectory=$cache
    go=(Join-Path $cache ('go-' + $lock.go.version + '\go\bin\go.exe'))
    compiler=(Join-Path $cache ('llvm-mingw-' + $lock.llvmMingw.version + '\llvm-mingw-' + $lock.llvmMingw.version + '-ucrt-x86_64\bin\x86_64-w64-mingw32-gcc.exe'))
    xray=(Join-Path $cache ('xray-' + $lock.xray.commit + '\Xray-core-' + $lock.xray.commit))
}
