Set-StrictMode -Version Latest
function Convert-CdfTraceAddress([string]$Value,[bool]$IPv6){
    if(-not $Value){return $Value}
    # The manifest serializes IPv6 win:Binary as 32 hex digits. Treating an
    # all-numeric value (notably ::1) as a UInt32 fabricates an IPv4 endpoint.
    if($IPv6 -and $Value -match '^[0-9a-fA-F]{32}$'){
        $bytes=[byte[]]::new(16)
        for($i=0;$i -lt 16;$i++){$bytes[$i]=[Convert]::ToByte($Value.Substring(2*$i,2),16)}
        return ([Net.IPAddress]::new($bytes)).IPAddressToString
    }
    if(-not $IPv6 -and $Value -match '^\d+$'){return ([Net.IPAddress]::new([BitConverter]::GetBytes([uint32]$Value))).IPAddressToString}
    return $Value
}
function Start-CdfNetworkTrace([string]$Directory){
    $name='CdfNetwork-'+[Guid]::NewGuid().ToString('N')
    $path=Join-Path $Directory 'network-metadata.etl'
    $providers=Join-Path $Directory 'trace-providers.txt'
    [IO.File]::WriteAllLines($providers,@('Microsoft-Windows-Kernel-Network 0xffffffffffffffff 5','Microsoft-Windows-DNS-Client 0xffffffffffffffff 5'),[Text.Encoding]::ASCII)
    $output=& logman.exe create trace $name -o $path -f bincirc -max 64 -pf $providers -ets 2>&1
    if($LASTEXITCODE -ne 0){throw "Cannot start the owned network metadata trace: $($output -join ' ')"}
    [pscustomobject]@{name=$name;path=$path;stopped=$false}
}
function Stop-CdfNetworkTrace($Trace,[int[]]$ProcessIds,[string]$Upstream,[string]$Directory){
    $output=& logman.exe stop $Trace.name -ets 2>&1
    if($LASTEXITCODE -ne 0){throw "Cannot stop the owned metadata trace: $($output -join ' ')"}
    $Trace.stopped=$true
    $target=[Collections.Generic.HashSet[int]]::new();foreach($id in $ProcessIds){$null=$target.Add($id)}
    $events=[Collections.Generic.List[object]]::new();$dns=[Collections.Generic.List[object]]::new();$violations=[Collections.Generic.List[object]]::new()
    foreach($event in Get-WinEvent -Path $Trace.path -Oldest -ErrorAction Stop){
        if($event.ProviderName -notin @('Microsoft-Windows-Kernel-Network','Microsoft-Windows-DNS-Client')){continue}
        [xml]$xml=$event.ToXml();$fields=@{}
        foreach($field in $xml.SelectNodes('//*[local-name()="EventData"]/*[local-name()="Data"]')){if($field.GetAttribute('Name')){$fields[$field.GetAttribute('Name')]=[string]$field.InnerText}}
        $owner=[int]$event.ProcessId
        foreach($key in @('PID','ProcessId','ProcessID','ClientPID','ClientProcessId')){if($fields.ContainsKey($key)){$number=0;if([int]::TryParse($fields[$key],[ref]$number)){$owner=$number;break}}}
        if(-not $target.Contains($owner)){continue}
        if($event.ProviderName -eq 'Microsoft-Windows-DNS-Client'){$row=[pscustomobject]@{processId=$owner;eventId=$event.Id;query=$(if($fields.ContainsKey('QueryName')){$fields.QueryName}else{'unavailable'})};$dns.Add($row);continue}
        $destination=$null;$source=$null;$port=$null;$sourcePort=$null
        foreach($key in @('daddr','DestAddress','DestinationAddress')){if($fields.ContainsKey($key)){$destination=$fields[$key];break}}
        foreach($key in @('saddr','SourceAddress')){if($fields.ContainsKey($key)){$source=$fields[$key];break}}
        foreach($key in @('dport','DestPort','DestinationPort')){if($fields.ContainsKey($key)){$port=$fields[$key];break}}
        foreach($key in @('sport','SourcePort')){if($fields.ContainsKey($key)){$sourcePort=$fields[$key];break}}
        # Kernel-Network schemas expose IPv4 and ports in network byte order.
        $ipv6=$event.Id -in @(26,27,28,29,30,31,32,58,59)
        $destination=Convert-CdfTraceAddress $destination $ipv6
        $source=Convert-CdfTraceAddress $source $ipv6
        if($port -match '^\d+$'){$p=[uint32]$port;$port=(($p -band 255)-shl 8)-bor($p-shr 8)}
        if($sourcePort -match '^\d+$'){$p=[uint32]$sourcePort;$sourcePort=(($p -band 255)-shl 8)-bor($p-shr 8)}
        $row=[pscustomobject]@{processId=$owner;eventId=$event.Id;time=$event.TimeCreated.ToUniversalTime().ToString('o');source=$source;sourcePort=$sourcePort;destination=$destination;port=$port}
        $events.Add($row)
        # Connect and send events are outbound. Receive events reverse the tuple.
        if(($event.Id -in @(10,12,26,28,42,58)) -and $destination){$address=$null;if([Net.IPAddress]::TryParse($destination,[ref]$address)){
            if(-not [Net.IPAddress]::IsLoopback($address)-and $address.IPAddressToString -ne $Upstream){$violations.Add($row)}
        }else{$violations.Add($row)}}
    }
    $report=[pscustomobject]@{method='Independent Kernel-Network and DNS-Client ETW metadata';processIds=$ProcessIds;events=$events;dnsEvents=$dns;violations=$violations;passed=($events.Count -gt 0 -and $dns.Count -eq 0 -and $violations.Count -eq 0);packetCaptureVerified=$false}
    [IO.File]::WriteAllText((Join-Path $Directory 'network-observation.json'),($report|ConvertTo-Json -Depth 9),[Text.UTF8Encoding]::new($false))
    # Raw machine-wide metadata is not retained; reports contain target PIDs only.
    Remove-Item -LiteralPath $Trace.path -ErrorAction Stop
    $report
}
