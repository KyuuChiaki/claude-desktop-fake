[CmdletBinding()]
param(
    [string]$SshTarget = 'claude',
    [string]$ClashConfigPath = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'),
    [string]$OutputPath = (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\network\private.dpapi')
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($SshTarget -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Use an SSH configuration alias, not shell text.' }
$remote=@'
import json,pathlib
x=json.loads(pathlib.Path('/etc/claude-proxy/client.json').read_text())
assert x['type']=='vless' and x['network']=='tcp' and x['tls'] is True and x['flow']=='xtls-rprx-vision'
print(json.dumps({k:x[k] for k in ['type','server','port','uuid','servername','client-fingerprint','flow','network','reality-opts']}))
'@
# Never echo this variable or include the remote response in exception messages.
$privateJson=($remote | & ssh.exe -o BatchMode=yes -o ConnectTimeout=10 -T $SshTarget 'python3 -') -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Read-only SSH profile import failed.' }
try {
    if($ClashConfigPath){
        if(-not [IO.File]::Exists($ClashConfigPath)){throw 'The current Clash runtime configuration is unavailable.'}
        $select=@'
import sys,json,pathlib,yaml
verified=json.loads(sys.stdin.read())
runtime=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
matches=[]
for candidate in runtime.get('proxies') or []:
    if candidate.get('type')!='vless':continue
    if all(candidate.get(k)==verified.get(k) for k in ['uuid','port','flow','servername','client-fingerprint','network']) and candidate.get('reality-opts')==verified.get('reality-opts'):
        matches.append(candidate)
if len(matches)!=1:raise SystemExit('Current Clash private profile is missing or ambiguous; no profile imported')
keys=['type','server','port','uuid','servername','client-fingerprint','flow','network','reality-opts']
print(json.dumps({k:matches[0][k] for k in keys}))
'@
        $selected=($privateJson | & python -c $select $ClashConfigPath) -join "`n"
        if($LASTEXITCODE -ne 0){throw 'Clash profile does not uniquely match the verified SSH parameters.'}
        $privateJson=$selected;$selected=$null
    }
    $profile=$privateJson | ConvertFrom-Json
    $address=$null
    if (-not [Net.IPAddress]::TryParse([string]$profile.server,[ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'The private upstream must use a numeric IPv4 address.' }
    $null=[Guid]::Parse($profile.uuid)
    if ([int]$profile.port -lt 1 -or [int]$profile.port -gt 65535 -or
        [string]::IsNullOrWhiteSpace($profile.servername) -or
        [string]::IsNullOrWhiteSpace($profile.'reality-opts'.'public-key') -or
        $profile.'client-fingerprint' -ne 'chrome') { throw 'Unsupported private profile.' }
    Add-Type -AssemblyName System.Security
    $plain=[Text.Encoding]::UTF8.GetBytes($privateJson)
    try { $sealed=[Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser) }
    finally { [Array]::Clear($plain,0,$plain.Length) }
    $destination=[IO.Path]::GetFullPath($OutputPath)
    if ([IO.File]::Exists($destination)) { throw 'A profile already exists. Import to a new path; do not replace credentials used by managed targets.' }
    $folder=Split-Path -Parent $destination
    $null=New-Item -ItemType Directory -Force -Path $folder
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $folder -AclObject $acl
    [IO.File]::WriteAllBytes($destination,$sealed)
    [pscustomobject]@{profilePath=$destination;scope='CurrentUser';protocol='VLESS/TCP/REALITY/Vision';sha256=(Get-FileHash -LiteralPath $destination).Hash;credentialsRedacted=$true} | ConvertTo-Json
} finally { $privateJson=$null; $profile=$null; $sealed=$null }
