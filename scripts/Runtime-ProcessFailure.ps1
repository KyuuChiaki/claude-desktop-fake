# Preserve bounded test-process diagnostics before the caller restores IFEO and
# shared configuration. This helper never operates on real Claude processes.
function Save-CdfRuntimeProcessFailure($Process,[bool]$Started,$Stdout,$Stderr,[string]$Path,[long]$Start,$Creation,$ErrorRecord,[bool]$TimedOut){
    $exitCode=$null;$unsigned=$null;$stdoutText='';$stderrText=''
    if($Started){
        try{
            if(-not $Process.HasExited){$Process.Kill($true);$Process.WaitForExit()}
            $exitCode=$Process.ExitCode;$unsigned=([long]$exitCode -band 4294967295L)
            if($Stdout){$stdoutText=$Stdout.GetAwaiter().GetResult()}
            if($Stderr){$stderrText=$Stderr.GetAwaiter().GetResult()}
        }catch{$stderrText+="`nDiagnostic collection: "+$_.Exception.Message}
    }
    $record=[pscustomobject]@{started=$Started;timedOut=$TimedOut;utcStartMs=$Start;utcEndMs=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();realCreationFileTime=$Creation;exitCode=$exitCode;unsignedExitCode=$unsigned;stdout=$stdoutText;stderr=$stderrText;failure=$ErrorRecord.Exception.ToString()}
    [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $record -Depth 6),[Text.UTF8Encoding]::new($false))
}
