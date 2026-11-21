# Management helpers used only by the local console.
Set-StrictMode -Version Latest

function Get-GuiRevision([string]$Path) {
    $hash=Cdf-Hash $Path
    if($hash){return $hash}
    return 'missing'
}

function Read-GuiJson([string]$Path) {
    if(-not [IO.File]::Exists($Path)){return $null}
    $options=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$options)
    try {
        if($stream.Length -gt 4MB){throw '配置文件超出控制台读取上限。'}
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        try { $reader.ReadToEnd()|ConvertFrom-Json -AsHashtable -DateKind String }
        finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Read-GuiTimeConfig {
    $settings=Read-GuiJson $configPath
    if(-not $settings){
        return [ordered]@{
            schemaVersion=2
            time=[ordered]@{enabled=$true;timeZoneId='Pacific Standard Time';utcOffsetSeconds=0}
            locale=[ordered]@{enabled=$true;formatLocale='en-US';uiLanguage='en-US'}
        }
    }
    if($settings.schemaVersion -notin @(1,2,3)){throw '当前时区配置版本无法识别。'}
    return $settings
}

function New-GuiTimeDraft($Request,$Config) {
    if($Request.time.enabled -isnot [bool] -or $Request.locale.enabled -isnot [bool] -or
        $Request.time.timeZoneId -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.time.timeZoneId) -or
        $Request.time.utcOffsetSeconds -isnot [long]){
        throw '时区配置字段无效。UTC 偏移必须为整数秒。'
    }
    $time=[ordered]@{
        enabled=$Request.time.enabled
        timeZoneId=$Request.time.timeZoneId
        utcOffsetSeconds=$Request.time.utcOffsetSeconds
    }
    if($Config.schemaVersion -eq 1 -and -not $Request.locale.enabled){
        return [ordered]@{schemaVersion=1;enabled=$time.enabled;timeZoneId=$time.timeZoneId;utcOffsetSeconds=$time.utcOffsetSeconds}
    }
    $locale=[ordered]@{
        enabled=$Request.locale.enabled
        formatLocale=[string]$Request.locale.formatLocale
        uiLanguage=[string]$Request.locale.uiLanguage
    }
    if($Config.schemaVersion -eq 1){$Config=[ordered]@{schemaVersion=2}}
    foreach($part in @('time','locale')){if(-not $Config.Contains($part)){$Config[$part]=[ordered]@{}}}
    foreach($key in $time.Keys){$Config.time[$key]=$time[$key]}
    foreach($key in $locale.Keys){$Config.locale[$key]=$locale[$key]}
    return $Config
}

function New-GuiWorkDirectory([bool]$Elevated) {
    $parent=if($Elevated){Join-Path $guiRoot 'work'}else{[IO.Path]::GetTempPath()}
    if($Elevated){Cdf-SecureDirectory $parent}
    $path=Join-Path $parent ('cdf-'+[Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $path)
    if($Elevated){Cdf-SecureDirectory $path}
    return $path
}

function Get-GuiTimePreview([string]$Path,$Settings) {
    $preview=& (Join-Path $PSScriptRoot 'Show-TimeConfig.ps1') -ConfigPath $Path -BuildDirectory (Split-Path -Parent $bin)|ConvertFrom-Json -AsHashtable -DateKind String
    $result=[ordered]@{
        referenceUtc=$preview.referenceUtc
        virtualLocalTime=$preview.virtualLocalTime
        virtualUtc=$preview.virtualUtc
        timeZoneOffsetSeconds=$preview.timeZoneOffsetSeconds
        utcClockShiftSeconds=$preview.utcClockShiftSeconds
        daylightSavingTime=$preview.daylightSavingTime
        configVersion=$Settings.schemaVersion
    }
    if($Settings.schemaVersion -ge 2 -and $Settings.locale.enabled){
        $culture=[Globalization.CultureInfo]::new([string]$Settings.locale.formatLocale,$false)
        $date=[DateTime]::new(2026,1,15,13,45,0)
        $result.locale=[ordered]@{
            date=$date.ToString('d',$culture)
            number=([decimal]1234.56).ToString('N2',$culture)
            currency=([decimal]1234.56).ToString('C2',$culture)
            uiLanguage=$Settings.locale.uiLanguage
        }
    }
    return $result
}

function Read-GuiPrivateProfile {
    if(-not [IO.File]::Exists($proxyProfilePath)){throw '尚未部署代理配置。'}
    Add-Type -AssemblyName System.Security
    $sealed=[IO.File]::ReadAllBytes($proxyProfilePath)
    if($sealed.Length -gt 65536){throw '代理配置超出读取上限。'}
    try{
        $plain=[Security.Cryptography.ProtectedData]::Unprotect($sealed,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        try{[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json -AsHashtable}
        finally{[Array]::Clear($plain,0,$plain.Length)}
    }catch{throw '当前 Windows 帐户无法读取已部署的代理凭据。'}
}

function Get-GuiAdapters {
    @(Get-NetAdapter -Physical -ErrorAction Stop|ForEach-Object {
        [ordered]@{name=$_.Name;guid=([Guid]$_.InterfaceGuid).ToString('B');up=($_.Status -eq 'Up');index=[int]$_.InterfaceIndex}
    })
}

function Resolve-GuiAdapter([string]$Guid) {
    $value=[Guid]::Empty
    if(-not [Guid]::TryParseExact($Guid,'B',[ref]$value)){throw '物理网卡标识无效。'}
    $adapters=@(Get-GuiAdapters|Where-Object {$_.guid -eq $value.ToString('B') -and $_.up})
    if($adapters.Count -ne 1){throw '请选择已连接的物理网卡。'}
    return $adapters[0]
}

function Assert-GuiProxyProfile($Profile,$Adapter) {
    $address=$null
    $uuid=[Guid]::Empty
    if($Profile.type -cne 'vless' -or $Profile.network -cne 'tcp' -or
        $Profile.flow -cne 'xtls-rprx-vision' -or $Profile.'client-fingerprint' -cne 'chrome' -or
        -not [Net.IPAddress]::TryParse([string]$Profile.server,[ref]$address) -or $address.AddressFamily -ne 'InterNetwork' -or
        $Profile.port -lt 1 -or $Profile.port -gt 65535 -or
        -not [Guid]::TryParseExact([string]$Profile.uuid,'D',[ref]$uuid) -or $uuid -eq [Guid]::Empty -or
        $Profile.servername -notmatch '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z][a-zA-Z0-9-]{0,62}$' -or
        $Profile.'reality-opts'.'public-key' -cnotmatch '^[A-Za-z0-9_-]{43}$' -or
        [string]$Profile.'reality-opts'.'short-id' -cnotmatch '^(?:[A-Fa-f0-9]{2}){0,8}$'){
        throw 'VLESS/TCP/REALITY 配置无效。请检查地址、端口、SNI 和认证字段。'
    }
    $route=@(Find-NetRoute -RemoteIPAddress $address.IPAddressToString -InterfaceIndex $Adapter.index -ErrorAction Stop|
        Where-Object {$_.CimClass.CimClassName -eq 'MSFT_NetRoute'})
    if($route.Count -ne 1 -or $route[0].InterfaceIndex -ne $Adapter.index){throw '代理上游没有所选物理网卡的有效路由。'}
}

function New-GuiProxyDraft($Value) {
    if($Value.reuse){return Read-GuiPrivateProfile}
    return [ordered]@{
        type='vless';network='tcp';flow='xtls-rprx-vision';'client-fingerprint'='chrome'
        server=[string]$Value.server;port=[int]$Value.port;uuid=[string]$Value.uuid;servername=[string]$Value.serverName
        'reality-opts'=[ordered]@{'public-key'=[string]$Value.publicKey;'short-id'=[string]$Value.shortId}
    }
}

function Write-GuiProxyDraft([string]$Path,$Profile) {
    Add-Type -AssemblyName System.Security
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Profile -Compress -Depth 5))
    try{
        $encrypted=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($Path,$encrypted)
        Set-CdfNetworkFileAcl $Path -Private
    }finally{[Array]::Clear($bytes,0,$bytes.Length)}
}

function Find-GuiTargets($Manifest) {
    $names=@('claude.exe','cowork-svc.exe')
    $paths=@()
    if($Manifest){
        $paths=@($Manifest.images|ForEach-Object {$_.path})
        $names+=@($Manifest.images|ForEach-Object {$_.name})
    }
    $names=@($names|Where-Object {$_ -match '^[A-Za-z0-9_. -]+\.exe$'}|Sort-Object -Unique)
    $query=($names|ForEach-Object {"Name='$_'"}) -join ' OR '
    @(Get-CimInstance Win32_Process -Filter $query|Where-Object {
        $path=$_.ExecutablePath
        -not $path -or ($path -in $paths -or $path -match '(?i)\\WindowsApps\\AnthropicPBC\.Claude_[^\\]+\\' -or
            $path -match '(?i)\\Claude-3p\\claude-code\\')
    })
}

function Get-GuiTimeSource($Auto) {
    $target=Join-Path $env:SystemRoot 'System32\CdfClaudeTimeZone64.dll'
    if($Auto -and $Auto.release){
        $candidate=Join-Path $Auto.release 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll'
        if([IO.File]::Exists($candidate) -and (Cdf-Hash $candidate) -ceq (Cdf-Hash $target)){return $candidate}
    }
    return Join-Path $bin 'CdfClaudeTimeZone64.dll'
}

function Get-GuiSnapshot([bool]$Check) {
    $issues=[Collections.Generic.List[string]]::new()
    $beforeTime=Get-GuiRevision $configPath
    $beforeProxy=Get-GuiRevision $transportRecord
    $webRTCPath=Join-Path $networkRoot 'protection.json'
    $beforeWebRTC=Get-GuiRevision $webRTCPath
    $webRTC=Get-CdfWebRTCPolicy $networkRoot
    $settings=Read-GuiTimeConfig
    $state=Read-GuiJson (Join-Path $claudeRoot 'state.json')
    $manifest=Read-GuiJson (Join-Path $claudeRoot 'images.json')
    $auto=Read-GuiJson (Join-Path $autoRoot 'state.json')
    $policy=Read-GuiJson (Join-Path $networkRoot 'claude.json')
    $record=Read-GuiJson $transportRecord
    $transport=$null
    try{$transport=Get-CdfNetworkDeploymentStatus $networkRoot}
    catch{$issues.Add('无法读取代理部署记录：'+$_.Exception.Message)}
    $timeSource=Get-GuiTimeSource $auto
    $adapters=@()
    try{$adapters=@(Get-GuiAdapters)}catch{$issues.Add('无法读取物理网卡。')}
    $registered=@{}
    $projectReady=[bool]$state
    if($state){
        $context=New-CdfClaudeContext $claudeRoot $timeSource 'CdfClaudeTimeZone64.dll'
        $context.Base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64')
        try {
            $context.Ifeo=$context.Base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options')
            foreach($item in $state.images){
                try{
                    Cdf-AssertImage $context $item
                    $value=Cdf-RegistryValue $context $item.name 'VerifierDlls'
                    $providers=([string]$value.data) -split '\s+'
                    $registered[$item.name]=@{
                        time='CdfClaudeTimeZone64.dll' -in $providers
                        network='CdfClaudeNetwork64.dll' -in $providers
                    }
                }catch{$issues.Add('IFEO 登记冲突：'+$item.name);$projectReady=$false}
            }
            try{Cdf-AssertDeployment $context $state}
            catch{$issues.Add('项目部署校验失败：'+$_.Exception.Message);$projectReady=$false}
            if([IO.File]::Exists($context.Pending)){$issues.Add('检测到待恢复的项目事务。');$projectReady=$false}
        }finally{if($context.Ifeo){$context.Ifeo.Dispose()};$context.Base.Dispose()}
    }
    $networkEntry=$registered['claude.exe']
    $networkDll=Join-Path $env:SystemRoot 'System32\CdfClaudeNetwork64.dll'
    $networkDllHash=Cdf-Hash $networkDll
    $networkProviderCurrent=[bool]($networkDllHash -and $networkDllHash -ceq (Cdf-Hash (Join-Path $bin 'CdfClaudeNetwork64.dll')))
    $networkReady=$projectReady -and $networkEntry -and $networkEntry.network -and $transport -and $transport.hashesMatch -and
        $policy -and $policy.enabled -and ($networkDllHash -ceq $policy.dllSha256)
    $health=Read-GuiJson (Join-Path $autoRoot 'health.json')
    $monitor=$false
    if($auto -and $auto.enabled -and $health -and $health.heartbeatUtc){
        $heartbeat=[DateTimeOffset]::Parse([string]$health.heartbeatUtc)
        $monitor=$heartbeat -gt [DateTimeOffset]::UtcNow.AddSeconds(-30) -and $health.state -in @('starting','watching','refreshing','retrying')
    }
    $registeredPaths=@()
    if($manifest){$registeredPaths=@($manifest.images|ForEach-Object {$_.path})}
    $changedAt=if([IO.File]::Exists($configPath)){[IO.File]::GetLastWriteTimeUtc($configPath)}else{[DateTime]::MinValue}
    $processRows=@(foreach($target in @(Find-GuiTargets $manifest)){
        $pidValue=[int]$target.ProcessId
        $role=if($target.Name -ieq 'cowork-svc.exe'){'service'}
            elseif($target.CommandLine -match '--utility-sub-type=network\.mojom\.NetworkService'){'network-service'}
            elseif($target.CommandLine -match '--type=([a-z0-9-]+)'){$Matches[1]}
            elseif($target.Name -ieq 'claude.exe'){'desktop'}
            else{'helper'}
        if(-not $target.ExecutablePath){
            [ordered]@{pid=$pidValue;name=$target.Name;role='unknown';error='当前权限无法核实映像路径。'}
            continue
        }
        $proc=$null
        try{
            $proc=[Diagnostics.Process]::GetProcessById($pidValue)
            $files=@($proc.Modules|ForEach-Object ModuleName)
            $started=$proc.StartTime.ToUniversalTime()
            $created=$started.ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        }catch{
            [ordered]@{pid=$pidValue;name=$target.Name;role=$role;error='无法读取进程模块或进程已退出。'}
            continue
        }finally{if($proc){$proc.Dispose()}}
        $timeLoaded='CdfClaudeTimeZone64.dll' -in $files
        $netLoaded='CdfClaudeNetwork64.dll' -in $files
        $row=[ordered]@{
            pid=$pidValue;created=$created;name=$target.Name;role=$role
            registered=($registered.ContainsKey($target.Name) -and $registered[$target.Name].time -and $target.ExecutablePath -in $registeredPaths)
            timeLoaded=$timeLoaded;networkLoaded=$netLoaded
            timeReady=$null;localeReady=$null;networkHooksReady=$null;transportReady=$null;ipv4Only=$null
            needsRestart=$false;error=$null
        }
        if($timeLoaded){
            $diagnostic=Get-CdfClaudeProcessDiagnostic $pidValue $timeSource ([IO.Path]::ChangeExtension($timeSource,'map'))
            if($diagnostic.time){$row.timeReady=[bool]$diagnostic.time.active}
            if($diagnostic.locale){$row.localeReady=[bool]$diagnostic.locale.prepared}
            if($diagnostic.inspectionError){$row.error=$diagnostic.inspectionError}
            if($diagnostic.identity -and $diagnostic.identity.matchedImagePath -in $registeredPaths -and
                $registered.ContainsKey($target.Name) -and $registered[$target.Name].time){$row.registered=$true}
        }else{$row.timeReady=$false;$row.localeReady=$false}
        if($netLoaded){
            try{
                $net=& (Join-Path $PSScriptRoot 'Capture-Network.ps1') -ProcessId $pidValue -ProviderName CdfClaudeNetwork64.dll|ConvertFrom-Json
                $row.networkHooksReady=[bool]$net.hooksReady
                $row.transportReady=[bool]$net.transportReady
                $row.ipv4Only=[bool]($net.state -band 32)
                if($net.failed){$row.error="网络状态错误 $($net.errorStage)/$($net.errorCode)"}
            }catch{$row.error=$_.Exception.Message}
        }else{$row.networkHooksReady=$false;$row.transportReady=$false}
        $image=$registered[$target.Name]
        $row.needsRestart=([bool]$timeLoaded -ne [bool]($image -and $image.time)) -or
            ([bool]$netLoaded -ne [bool]($image -and $image.network)) -or ($timeLoaded -and $started -lt $changedAt)
        $row
    })
    $profile=$null
    $profileReadable=$false
    if([IO.File]::Exists($proxyProfilePath)){
        try{$profile=Read-GuiPrivateProfile;$profileReadable=$true}
        catch{$issues.Add($_.Exception.Message)}
    }
    if($beforeTime -ine (Get-GuiRevision $configPath) -or $beforeProxy -ine (Get-GuiRevision $transportRecord) -or
        $beforeWebRTC -ine (Get-GuiRevision $webRTCPath)){
        throw '配置正在更新，请等待下一次刷新。'
    }
    $candidateDll=Join-Path $bin 'CdfProxyTransport64.dll'
    $browserProvider=Join-Path ([Environment]::SystemDirectory) 'CdfClaudeTimeZone64.dll'
    $releaseProvider=Join-Path $bin 'CdfClaudeTimeZone64.dll'
    $browserProviderCurrent=$false
    if([IO.File]::Exists($browserProvider) -and [IO.File]::Exists($releaseProvider)){
        try{$browserProviderCurrent=(Cdf-Hash $browserProvider) -ceq (Cdf-Hash $releaseProvider)}catch{}
    }
    $transportCurrent=[bool]($record -and $record.transportSha256 -ceq (Cdf-Hash $candidateDll))
    if(-not $webRTC.valid){$issues.Add('WebRTC 保护配置无效，已使用默认禁用策略。')}
    $result=[ordered]@{
        ok=$true;projectEnabled=[bool]$projectReady;projectManaged=[bool]$state
        proxyEnabled=[bool]$networkReady;proxyRequested=[bool]($policy -and $policy.enabled)
        monitorEnabled=[bool]($auto -and $auto.enabled);monitorRunning=[bool]$monitor
        timeRevision=$beforeTime;proxyRevision=$beforeProxy;webRTCRevision=$beforeWebRTC;webRTCDisabled=$webRTC.disabled
        config=$settings;adapters=$adapters;browserConsentProviderCurrent=$browserProviderCurrent
        processes=$processRows;issues=@($issues);networkChildTargets=(Get-CdfNetworkChildTargets $manifest)
        proxy=[ordered]@{
            configured=[bool]$record;readable=$profileReadable
            valid=[bool]($transport -and $transport.hashesMatch)
            interfaceGuid=$(if($record){$record.interfaceGuid})
            server=$(if($profile){[string]$profile.server})
            port=$(if($profile){[int]$profile.port})
            supportsConnections=[bool]($transport -and $transport.hashesMatch -and $transportCurrent)
            ipv4Only=[bool]($transport -and $transport.hashesMatch -and $networkProviderCurrent -and $transportCurrent)
            upgradeAvailable=[bool]($record -and (-not $transportCurrent -or ($policy -and $networkDllHash -and -not $networkProviderCurrent)))
        }
    }
    if($Check){
        $checks=[Collections.Generic.List[object]]::new()
        try{
            if($beforeTime -eq 'missing'){throw '尚未保存配置。'}
            $preview=Get-GuiTimePreview $configPath $settings
            $checks.Add(@{name='时区与区域语言';ok=$true;message='配置通过现有校验器。'})
            $result.preview=$preview
        }catch{$checks.Add(@{name='时区与区域语言';ok=$false;message=$_.Exception.Message})}
        try{
            if(-not $result.proxy.valid){throw '代理部署文件缺失或哈希不符。'}
            if(-not $profile){throw '无法读取当前帐户的代理配置。'}
            $adapter=Resolve-GuiAdapter $record.interfaceGuid
            Assert-GuiProxyProfile $profile $adapter
            $checks.Add(@{name='代理和物理网卡';ok=$true;message=('配置和路由有效 · '+$adapter.name)})
        }catch{$checks.Add(@{name='代理和物理网卡';ok=$false;message=$_.Exception.Message})}
        $checks.Add(@{name='项目登记';ok=($projectReady -or -not $state);message=$(if($projectReady){'IFEO 和部署记录匹配。'}elseif($state){'检测到登记冲突。'}else{'项目当前关闭。'})})
        $result.checks=@($checks)
    }else{
        $result.timeZones=@([TimeZoneInfo]::GetSystemTimeZones()|ForEach-Object {@{id=$_.Id;label=$_.DisplayName}})
        $result.locales=@([Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures)|
            Where-Object {$_.LCID -ne 4096}|Sort-Object Name -Unique|ForEach-Object {@{id=$_.Name;label=$_.NativeName}})
    }
    return $result
}

function Invoke-GuiWebRTCSwitch($Request) {
    $mutex=[Threading.Mutex]::new($false,'Global\ClaudeDesktopFake.Network.Registry')
    $held=$false
    try{
        try{$held=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw '另一个代理操作仍在进行。'}
        $path=Join-Path $networkRoot 'protection.json'
        if($Request.revision -ine (Get-GuiRevision $path)){throw 'WebRTC 配置已被其他操作修改，请刷新。'}
        if(-not [IO.Directory]::Exists($networkRoot)){Cdf-SecureDirectory $networkRoot}
        $current=Get-CdfWebRTCPolicy $networkRoot
        if(-not $current.valid -or $current.disabled -ne $Request.enabled){
            Cdf-Save $path ([ordered]@{schemaVersion=1;webRTCDisabled=$Request.enabled})
        }
        [ordered]@{
            ok=$true;webRTCDisabled=$Request.enabled;webRTCRevision=(Get-GuiRevision $path)
            message=$(if($Request.enabled){'已启用 WebRTC 禁用策略。'}else{'已关闭 WebRTC 禁用策略。'})
        }
    }finally{
        if($held){$mutex.ReleaseMutex()}
        $mutex.Dispose()
    }
}

function Get-GuiNetworkUsers {
    $manifest=Read-GuiJson (Join-Path $claudeRoot 'images.json')
    $networkState=Read-GuiJson (Join-Path $networkRoot 'claude.json')
    $candidates=@(Find-GuiTargets $manifest)
    $tests=Join-Path $networkRoot 'state'
    if([IO.Directory]::Exists($tests)){
        $managed=@(Get-ChildItem -LiteralPath $tests -Filter '*.exe.json' -File)
        if($managed.Count){throw '仍有测试进程的共享代理登记，请撤销后再更新。'}
    }
    $reported=[Collections.Generic.HashSet[int]]::new()
    foreach($target in $candidates){
        if($networkState -and $target.Name -in @($networkState.excludedImages)){continue}
        $p=$null
        try{
            $p=[Diagnostics.Process]::GetProcessById($target.ProcessId)
            $names=@($p.Modules|ForEach-Object ModuleName)
            if('CdfClaudeNetwork64.dll' -in $names -or 'CdfProxyTransport64.dll' -in $names){
                if($reported.Add([int]$target.ProcessId)){"$($target.Name) ($($target.ProcessId))"}
            }
        }catch [ArgumentException]{
            # Process exited during inspection.
        }catch{if($reported.Add([int]$target.ProcessId)){"$($target.Name) ($($target.ProcessId)，无法核对模块)"}}
        finally{if($p){$p.Dispose()}}
    }
    # A fixture can still map the shared DLL after its IFEO has been removed.
    foreach($entry in @(Get-CdfNetworkModuleUsers (Join-Path $networkRoot 'CdfProxyTransport64.dll'))){
        if($reported.Add($entry.pid)){
            if($entry.verified){"$($entry.name) ($($entry.pid))"}else{"$($entry.name) ($($entry.pid)，无法核对模块)"}
        }
    }
}

function Invoke-GuiNetworkSave($Request) {
    $mutex=[Threading.Mutex]::new($false,'Global\ClaudeDesktopFake.Network.Registry')
    $held=$false
    $work=$null
    try{
        try{$held=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw '另一个代理操作仍在进行。'}
        if($Request.revision -ine (Get-GuiRevision $transportRecord)){throw '代理配置已被其他操作修改，请刷新。'}
        $inUse=@(Get-GuiNetworkUsers)
        if($inUse.Count){throw ('请先退出正在使用代理配置的进程：'+($inUse -join '、'))}
        $adapter=Resolve-GuiAdapter $Request.proxy.interfaceGuid
        $profile=New-GuiProxyDraft $Request.proxy
        Assert-GuiProxyProfile $profile $adapter
        $work=New-GuiWorkDirectory $true
        $profileSource=$proxyProfilePath
        if(-not $Request.proxy.reuse){
            $profileSource=Join-Path $work 'candidate.dpapi'
            Write-GuiProxyDraft $profileSource $profile
        }
        $existing=Read-GuiJson $transportRecord
        $transportSource=if($Request.upgrade -or -not $existing){Join-Path $bin 'CdfProxyTransport64.dll'}else{Join-Path $networkRoot 'CdfProxyTransport64.dll'}
        if(-not [IO.Directory]::Exists($networkRoot)){Cdf-SecureDirectory $networkRoot}
        $inUse=@(Get-GuiNetworkUsers)
        if($inUse.Count){throw ('检测到代理进程在准备期间启动：'+($inUse -join '、'))}
        try{
            $deployment=Initialize-CdfNetworkDeployment $networkRoot $transportSource $profileSource $adapter.name
        }catch{
            $reason=$_.Exception.Message
            try{Restore-CdfNetworkPending $networkRoot}
            catch{throw ('代理提交失败，恢复材料已保留：'+$_.Exception.Message)}
            throw $reason
        }
        if($Request.upgrade -and [IO.File]::Exists((Join-Path $networkRoot 'claude-deployment.json'))){
            $source=Join-Path $bin 'CdfClaudeNetwork64.dll'
            $target=Join-Path $env:SystemRoot 'System32\CdfClaudeNetwork64.dll'
            if((Cdf-Hash $source) -cne (Cdf-Hash $target)){
                try{& (Join-Path $PSScriptRoot 'Manage-ClaudeNetwork.ps1') -Action Upgrade -ProviderPath $source|Out-Null}
                catch{throw ('传输组件已更新。系统 Hook 升级未完成：'+$_.Exception.Message)}
            }
        }
        $later=@(Get-GuiNetworkUsers)
        [ordered]@{ok=$true;message=$(if($later.Count){'已保存。有进程在提交期间启动，请退出后再打开。'}else{'代理配置已保存，下次启动生效。'});verified=[bool]$deployment.hashesMatch;proxyRevision=(Get-GuiRevision $transportRecord)}
    }finally{
        if($work){
            [IO.File]::Delete((Join-Path $work 'candidate.dpapi'))
            [IO.Directory]::Delete($work,$false)
        }
        if($held){$mutex.ReleaseMutex()}
        $mutex.Dispose()
    }
}

function Invoke-GuiProxyTest($Request) {
    $adapter=Resolve-GuiAdapter $Request.proxy.interfaceGuid
    $profile=New-GuiProxyDraft $Request.proxy
    Assert-GuiProxyProfile $profile $adapter
    $work=New-GuiWorkDirectory $false
    try{
        $path=Join-Path $work 'candidate.dpapi'
        Write-GuiProxyDraft $path $profile
        $raw=& (Join-Path $bin 'CdfProxyCheck64.exe') $path $adapter.guid
        if(-not $raw){throw '代理测试进程未返回结果。'}
        $reply=$raw|ConvertFrom-Json -AsHashtable
        $reply.interfaceName=$adapter.name
        if(-not $reply.ok){$reply.message='代理实测失败，阶段 '+$reply.stage}
        return $reply
    }finally{
        [IO.File]::Delete((Join-Path $work 'candidate.dpapi'))
        [IO.Directory]::Delete($work,$false)
    }
}

function Invoke-GuiProjectSwitch([bool]$Enable) {
    if(-not $Enable){
        & (Join-Path $PSScriptRoot 'Manage-Claude.ps1') -Action Disable|Out-Null
        return @{ok=$true;message='已关闭项目登记。已运行进程在退出后解除 Hook。'}
    }
    $policy=Read-GuiJson (Join-Path $networkRoot 'claude.json')
    $auto=Read-GuiJson (Join-Path $autoRoot 'state.json')
    if($policy -and $policy.enabled -and $auto){
        Invoke-GuiProxySwitch $true -ProjectEnable
        return
    }
    # Existing signed time deployments may be older than the current build.
    # Use the owned release when restarting the refresh task.
    $source=Get-GuiTimeSource $auto
    $sourceBuild=if($auto){Join-Path $auto.release 'out\build\x64-release\bin\CdfClaudeTimeZone64.dll'}else{$null}
    if($sourceBuild -and $source -ieq $sourceBuild){
        Cdf-AutoVerifyRelease ([pscustomobject]$auto)
        $sources=Join-Path $guiRoot 'manager-sources'
        Cdf-SecureDirectory $sources
        $project=Join-Path $sources ([Guid]::NewGuid().ToString('N'))
        Cdf-SecureDirectory $project
        foreach($file in $auto.files){
            $destination=Join-Path $project $file.path
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
            Cdf-CopyAtomic (Join-Path $auto.release $file.path) $destination $file.sha256
        }
        foreach($name in @('Claude-ManagerCore.ps1','Claude-AutoCore.ps1','Manage-ClaudeAuto.ps1')){
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $project ('scripts\'+$name)) -Force
        }
        & (Join-Path $project 'scripts\Manage-ClaudeAuto.ps1') -Action Enable|Out-Null
    }else{
        & (Join-Path $PSScriptRoot 'Manage-Claude.ps1') -Action Enable|Out-Null
    }
    @{ok=$true;message='已启用项目登记。现有进程需要退出后重新启动。'}
}

function Invoke-GuiProxySwitch([bool]$Enable,[switch]$ProjectEnable) {
    $state=Read-GuiJson (Join-Path $claudeRoot 'state.json')
    if(-not $state -and -not $ProjectEnable){throw '请先启用项目。'}
    $source=Join-Path $bin 'CdfClaudeNetwork64.dll'
    $owned=Read-GuiJson (Join-Path $networkRoot 'claude-deployment.json')
    $installed=Join-Path $env:SystemRoot 'System32\CdfClaudeNetwork64.dll'
    if($owned -and $owned.dllPath -ieq $installed -and $owned.dllSha256 -ceq (Cdf-Hash $installed)){$source=$installed}
    $selection=if($Enable){'Enable'}else{'Disable'}
    $result=& (Join-Path $PSScriptRoot 'Manage-ClaudeNetwork.ps1') -Action $selection -ProviderPath $source -SelectionOnly:(-not $ProjectEnable)|ConvertFrom-Json
    if($result.issues.Count -or $result.requested -ne $Enable -or $result.enabled -ne $Enable){
        throw ('无法确认代理登记。'+($result.issues -join '；'))
    }
    $word=if($Enable){'开启'}else{'关闭'}
    @{ok=$true;proxyEnabled=[bool]$result.enabled;proxyRequested=[bool]$result.requested;message="代理登记已${word}。新启动的进程将使用该设置。"}
}
