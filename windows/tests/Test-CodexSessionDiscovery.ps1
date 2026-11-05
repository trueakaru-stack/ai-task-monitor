$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Unable to parse the application source.' }
$names = @(
    'Prop', 'Lock-State', 'Find-PriorLifecycle', 'Thread-State', 'Codex-Uncertain',
    'Session-File', 'Session-Workspace', 'Progress-Files', 'Manual-Tasks',
    'Read-TailText', 'Codex-Plan', 'Codex-Activity', 'Plan-Progress',
    'Codex-IndexCandidates', 'Codex-Tasks', 'Unconfirmed-Tasks', 'Source-Snapshot'
)
$definitions = foreach ($name in $names) {
    $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true)
    if ($null -eq $node) { throw "Missing function: $name" }
    $node.Extent.Text
}
$initializers = foreach ($name in @('$script:sessionFiles', '$script:sessionDates', '$script:sessionDiscovery')) {
    $matches = @($ast.FindAll({ param($item) $item -is [Management.Automation.Language.AssignmentStatementAst] -and $item.Left.Extent.Text -ceq $name }, $true))
    if ($matches.Count -ne 1) { throw "Expected one initialization for $name" }
    $matches[0].Extent.Text
}
$sessionFunction = ($ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Session-File' }, $true)).Extent.Text
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$root = [IO.Path]::GetFullPath((Join-Path $tempPrefix ('aitm-codex-discovery-' + [Guid]::NewGuid().ToString('N'))))
if (-not $root.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture directory.' }
[void][IO.Directory]::CreateDirectory($root)
$checks = @'
$fixture = $args[0]
$sessionFunction = $args[1]
$env:USERPROFILE = $fixture
$env:CODEX_HOME = $fixture
$env:LOCALAPPDATA = $fixture
$ProgressFile = ''
$ClaudeEventFile = ''
$script:codexCloudModulesAvailable = $false
$script:externalProviderModulesAvailable = $false
$script:lastClaudeTasks = @()
function Claude-ConnectionState { return 'disconnected' }
function Require([bool]$condition,[string]$message) { if(-not $condition){throw $message} }
Require ([object]::ReferenceEquals($script:sessionDiscovery.Files,$script:sessionFiles) -and
    $script:sessionDiscovery.Gate -is [object] -and -not $script:sessionDiscovery.Attempted -and
    -not $script:sessionDiscovery.ScanFailed -and $script:sessionDates.IsSynchronized) 'The actual session discovery initialization is invalid.'
function New-Discovery {
    return [PSCustomObject]@{
        Gate=[object]::new()
        Files=@{}
        Rollouts=$null
        LastScanTicks=[long]0
        Attempted=$false
        ScanFailed=$false
        RetrySeconds=5
        HotUntilTicks=[long]0
        IndexVersions=@{}
        DatedMisses=@{}
        RolloutMisses=@{}
    }
}
function Reset-MonitorState {
    $script:sessionDiscovery = New-Discovery
    $script:sessionDates = @{}
    $script:sessionIndexLookup = @{}
    $script:planCache = @{}
    $script:planConfirmations = @{}
    $script:lifecycleState = @{}
    $script:observedCodex = @{}
    $script:lastCodexTasks = @()
    $script:monitorStartedUtc = [DateTime]::UtcNow.AddSeconds(-10)
}
function Write-Event([string]$path,[string]$type,[string]$turn) {
    $record=@{timestamp=[DateTime]::UtcNow.ToString('o');type='event_msg';payload=@{type=$type;turn_id=$turn;text='Synthetic activity'}} | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($path, ($record + "`n"), [Text.UTF8Encoding]::new($false))
}
function Active-Ids {
    return @((Codex-Tasks | Where-Object { $_.Active } | ForEach-Object { $_.Id }) | Sort-Object)
}
function Wait-Session([string]$id,[int]$timeoutMilliseconds=8000) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        try { $path=Session-File $id; if($path){return $path} } catch {}
        Start-Sleep -Milliseconds 100
    } while($watch.ElapsedMilliseconds -lt $timeoutMilliseconds)
    throw 'A synthetic session was not discovered after the retry interval.'
}

# Reproduce the real task projection, not just the path lookup.
$codexHome = Join-Path $fixture 'profile'
$sessionIndex = Join-Path $codexHome 'session_index.jsonl'
$sessionsDirectory = Join-Path $codexHome 'sessions'
$lockDirectory = Join-Path $codexHome 'thread-writer-locks'
[void][IO.Directory]::CreateDirectory($sessionsDirectory)
[void][IO.Directory]::CreateDirectory($lockDirectory)
Reset-MonitorState
$indexStamp = [DateTime]::UtcNow.ToString('o')
$date = [DateTime]$indexStamp
$dated = Join-Path (Join-Path (Join-Path $sessionsDirectory ([string]$date.Year)) $date.Month.ToString('00')) $date.Day.ToString('00')
[void][IO.Directory]::CreateDirectory($dated)
$ready = 'synthetic-ready'
$late = 'synthetic-late'
$records = @(
    (@{id=$ready;thread_name='Synthetic ready';updated_at=$indexStamp} | ConvertTo-Json -Compress),
    (@{id=$late;thread_name='Synthetic late';updated_at=$indexStamp} | ConvertTo-Json -Compress)
)
[IO.File]::WriteAllText($sessionIndex, (($records -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
$readyPath = Join-Path $dated ('rollout-' + $ready + '.jsonl')
$latePath = Join-Path $dated ('rollout-' + $late + '.jsonl')
Write-Event $readyPath 'task_started' 'ready-turn'
$readyLock = [IO.File]::Open((Join-Path $lockDirectory ($ready+'.lock')), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$lateLock = [IO.File]::Open((Join-Path $lockDirectory ($late+'.lock')), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $initial=@(Active-Ids)
    Require ($initial.Count -eq 1 -and $initial[0] -eq $ready) 'The already-created task was not visible.'
    Write-Event $latePath 'task_started' 'late-turn'
    Write-Event $latePath 'agent_reasoning' 'late-turn'
    $after=@(Active-Ids)
    Require ($after.Count -eq 2 -and $after -contains $ready -and $after -contains $late) 'A late dated session was not discovered on the next refresh.'

    # A temporary failure keeps the last task snapshot unconfirmed and then recovers.
    $snapshot=Source-Snapshot
    Require (@($snapshot.Tasks | Where-Object Active).Count -eq 2) 'The initial source snapshot is incomplete.'
    $hidden=Join-Path $codexHome 'sessions-hidden'
    Move-Item -LiteralPath $sessionsDirectory -Destination $hidden
    try {
        $failed=Source-Snapshot
        Require (@($failed.Unavailable) -contains 'Codex') 'An unavailable source was treated as an empty list.'
        Require (@($failed.Tasks).Count -eq 2 -and @($failed.Tasks | Where-Object Active).Count -eq 0) 'Previously observed tasks were not retained as unconfirmed.'
    } finally {
        Move-Item -LiteralPath $hidden -Destination $sessionsDirectory
    }
    $recovered=Source-Snapshot
    Require (@($recovered.Unavailable).Count -eq 0 -and @($recovered.Tasks | Where-Object Active).Count -eq 2) 'The source did not recover after the directory returned.'
} finally {
    $readyLock.Dispose()
    $lateLock.Dispose()
}

# A single shared fallback snapshot serves 20 missing IDs within the interval.
$sessionsDirectory=Join-Path $fixture 'fallback'
$other=Join-Path $sessionsDirectory 'other'
$dated=Join-Path $sessionsDirectory 'dated'
[void][IO.Directory]::CreateDirectory($other)
[void][IO.Directory]::CreateDirectory($dated)
$script:sessionDiscovery=New-Discovery
$script:sessionDates=@{}
$stamps=New-Object 'Collections.Generic.List[long]'
for($i=0;$i -lt 20;$i++){
    $id='missing-{0:D2}' -f $i
    Require ((Session-File $id) -ceq '') 'A missing session was invented.'
    $stamps.Add([long]$script:sessionDiscovery.LastScanTicks)
    Start-Sleep -Milliseconds 2
}
$attempts=@($stamps | Select-Object -Unique).Count
Require ($attempts -eq 1) 'Missing IDs caused repeated recursive scans.'
Write-Output ("Recursive scans for 20 missing IDs in one interval: $attempts")

# Repeated lookups in one refresh reuse negative dated and fallback results.
$savedDiscovery=$script:sessionDiscovery
$savedDates=$script:sessionDates
$savedSessions=$sessionsDirectory
$sessionsDirectory=Join-Path $fixture 'repeated-lookups'
$script:datedProbeFolder=Join-Path $sessionsDirectory 'dated'
[void][IO.Directory]::CreateDirectory($script:datedProbeFolder)
$script:sessionDiscovery=New-Discovery
$script:sessionDates=@{}
$script:datedProbeCalls=0
function Get-ChildItem {
    [CmdletBinding()]param([string]$LiteralPath,[switch]$File,[string]$Filter)
    if([string]::Equals($LiteralPath,$script:datedProbeFolder,[StringComparison]::OrdinalIgnoreCase)){$script:datedProbeCalls++}
    Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
}
try {
    for($i=0;$i -lt 50;$i++){
        $id='repeated-{0:D2}' -f $i
        $script:sessionDates[$id]=$script:datedProbeFolder
        Require ((Session-File $id) -ceq '') 'A missing repeated lookup was invented.'
        Require ((Session-File $id) -ceq '') 'A repeated missing lookup changed unexpectedly.'
    }
    Require ($script:datedProbeCalls -eq 50) 'Repeated lookups re-enumerated dated directories inside the same cycle.'
    Require ($script:sessionDiscovery.RolloutMisses.Count -eq 50) 'Absent IDs were not cached for the current recursive snapshot.'
    Write-Output 'Repeated lookups: 50 dated enumerations for 100 calls.'
} finally {
    Remove-Item -LiteralPath 'function:Get-ChildItem' -Force
    $script:sessionDiscovery=$savedDiscovery
    $script:sessionDates=$savedDates
    $sessionsDirectory=$savedSessions
}

# A dated file appears after the short miss cache expires; an outside file waits for a shared refresh.
$script:sessionDates['dated-late']=$dated
Require ((Session-File 'dated-late') -ceq '') 'A future dated file already exists.'
$datedLate=Join-Path $dated 'rollout-dated-late.jsonl'
[IO.File]::WriteAllText($datedLate,"{}`n",[Text.UTF8Encoding]::new($false))
Require ((Wait-Session 'dated-late' 2500) -ceq $datedLate) 'A late dated file waited for the recursive scan.'
$outside=Join-Path $other 'rollout-outside-late.jsonl'
[IO.File]::WriteAllText($outside,"{}`n",[Text.UTF8Encoding]::new($false))
Require ((Session-File 'outside-late') -ceq '') 'The shared recursive snapshot was refreshed too soon.'
Require ((Wait-Session 'outside-late') -ceq $outside) 'An outside file was not recovered.'

# An outside path without new index activity can wait up to 60 seconds, the next refresh and scan time.
# Simulate elapsed time to exercise the capped retry sequence without waiting minutes.
$sessionsDirectory=Join-Path $fixture 'backoff-empty'
[void][IO.Directory]::CreateDirectory($sessionsDirectory)
$script:sessionDiscovery=New-Discovery
$script:sessionDates=@{}
Require ((Session-File 'backoff-missing') -ceq '') 'The backoff fixture was unexpectedly found.'
Require ($script:sessionDiscovery.RetrySeconds -eq 5) 'The initial retry interval is not five seconds.'
$script:sessionDiscovery.HotUntilTicks=[Diagnostics.Stopwatch]::GetTimestamp()+([long][Diagnostics.Stopwatch]::Frequency * 30)
$script:sessionDiscovery.LastScanTicks=[Diagnostics.Stopwatch]::GetTimestamp()-([long][Diagnostics.Stopwatch]::Frequency * 6)
Require ((Session-File 'backoff-missing') -ceq '' -and $script:sessionDiscovery.RetrySeconds -eq 5) 'A fresh unresolved task left the quick retry period.'
foreach($expected in @(10,20,40,60,60)){
    $previous=[int]$script:sessionDiscovery.RetrySeconds
    $script:sessionDiscovery.HotUntilTicks=[long]0
    $script:sessionDiscovery.LastScanTicks=[Diagnostics.Stopwatch]::GetTimestamp()-([long][Diagnostics.Stopwatch]::Frequency * ($previous+1))
    Require ((Session-File 'backoff-missing') -ceq '') 'The backoff fixture was unexpectedly found.'
    Require ($script:sessionDiscovery.RetrySeconds -eq $expected) 'The recursive scan retry interval did not grow or cap correctly.'
}

# Only a new or updated unresolved index entry restores quick retries.
$codexHome=Join-Path $fixture 'backoff-profile'
$sessionIndex=Join-Path $codexHome 'session_index.jsonl'
$sessionsDirectory=Join-Path $codexHome 'sessions'
$lockDirectory=Join-Path $codexHome 'thread-writer-locks'
$backoffOther=Join-Path $sessionsDirectory 'other'
[void][IO.Directory]::CreateDirectory($backoffOther)
[void][IO.Directory]::CreateDirectory($lockDirectory)
Reset-MonitorState
$initialStamp=[DateTime]::UtcNow.ToString('o')
$date=[DateTime]$initialStamp
$dated=Join-Path (Join-Path (Join-Path $sessionsDirectory ([string]$date.Year)) $date.Month.ToString('00')) $date.Day.ToString('00')
[void][IO.Directory]::CreateDirectory($dated)
$known='backoff-known'
$missing='backoff-missing'
$knownPath=Join-Path $dated ('rollout-'+$known+'.jsonl')
Write-Event $knownPath 'task_started' 'known-turn'
$knownLock=[IO.File]::Open((Join-Path $lockDirectory ($known+'.lock')),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    function Write-BackoffIndex([string]$knownStamp,[string]$missingStamp,[bool]$includeNew) {
        $records=@(
            (@{id=$known;thread_name='Synthetic known';updated_at=$knownStamp}|ConvertTo-Json -Compress),
            (@{id=$missing;thread_name='Synthetic missing';updated_at=$missingStamp}|ConvertTo-Json -Compress)
        )
        if($includeNew){$records+=(@{id='backoff-new';thread_name='Synthetic new';updated_at=$missingStamp}|ConvertTo-Json -Compress)}
        [IO.File]::WriteAllText($sessionIndex,(($records -join "`n")+"`n"),[Text.UTF8Encoding]::new($false))
    }
    Write-BackoffIndex $initialStamp $initialStamp $false
    Require (@(Active-Ids).Count -eq 1) 'The backoff fixture did not observe its active task.'
    $cache=$script:sessionDiscovery
    $cache.RetrySeconds=60
    $cache.HotUntilTicks=[long]0
    $cache.LastScanTicks=[Diagnostics.Stopwatch]::GetTimestamp()
    $stamp=$cache.LastScanTicks
    $changedKnown=[DateTime]::UtcNow.AddSeconds(1).ToString('o')
    Write-BackoffIndex $changedKnown $initialStamp $false
    [void](Codex-Tasks)
    Require ($cache.RetrySeconds -eq 60 -and $cache.LastScanTicks -eq $stamp) 'An already-found task reset the missing-session backoff.'
    $changedMissing=[DateTime]::UtcNow.AddSeconds(2).ToString('o')
    Write-BackoffIndex $changedKnown $changedMissing $false
    [void](Codex-Tasks)
    Require ($cache.RetrySeconds -eq 5 -and $cache.HotUntilTicks -gt [Diagnostics.Stopwatch]::GetTimestamp() -and $cache.LastScanTicks -eq $stamp) 'An updated missing entry did not restore the quick interval safely.'
    $cache.RetrySeconds=60
    $cache.HotUntilTicks=[long]0
    $cache.LastScanTicks=[Diagnostics.Stopwatch]::GetTimestamp()
    $stamp=$cache.LastScanTicks
    Write-BackoffIndex $changedKnown $changedMissing $true
    [void](Codex-Tasks)
    Require ($cache.RetrySeconds -eq 5 -and $cache.LastScanTicks -eq $stamp) 'A new missing ID did not restore quick retries or caused an early scan.'
    $newPath=Join-Path $backoffOther 'rollout-backoff-new.jsonl'
    [IO.File]::WriteAllText($newPath,"{}`n",[Text.UTF8Encoding]::new($false))
    Require ((Session-File 'backoff-new') -ceq '' -and $cache.LastScanTicks -eq $stamp) 'A new ID caused a scan before the five-second minimum.'
    Require ((Wait-Session 'backoff-new') -ceq $newPath) 'A new outside session did not recover after the minimum interval.'
} finally {
    $knownLock.Dispose()
}

# Previously found paths are validated; moved or deleted files cannot stay positive forever.
$sessionsDirectory=Join-Path $fixture 'fallback'
$other=Join-Path $sessionsDirectory 'other'
$dated=Join-Path $sessionsDirectory 'dated'
$script:sessionDiscovery=New-Discovery
$script:sessionDates=@{'moving'=$dated}
$old=Join-Path $dated 'rollout-moving.jsonl'
$moved=Join-Path $other 'rollout-moving.jsonl'
[IO.File]::WriteAllText($old,"{}`n",[Text.UTF8Encoding]::new($false))
Require ((Session-File 'moving') -ceq $old) 'The dated session was not found.'
Require ((Session-File 'moving') -ceq $old) 'A valid positive cache changed.'
Move-Item -LiteralPath $old -Destination $moved
Require ((Session-File 'moving') -ceq $moved) 'A moved cached file was not rediscovered.'
Remove-Item -LiteralPath $moved
Require ((Session-File 'moving') -ceq '' -and -not $script:sessionDiscovery.RolloutMisses.ContainsKey('moving')) 'A vanished path was permanently cached as missing.'
[IO.File]::WriteAllText($moved,"{}`n",[Text.UTF8Encoding]::new($false))
Require ((Session-File 'moving') -ceq $moved) 'A known path that reappeared was not rediscovered.'
$other2=Join-Path $sessionsDirectory 'other2'
[void][IO.Directory]::CreateDirectory($other2)
$movedAgain=Join-Path $other2 'rollout-moving.jsonl'
Move-Item -LiteralPath $moved -Destination $movedAgain
Require ((Session-File 'moving') -ceq '') 'A stale recursive snapshot returned a moved file.'
Require ((Wait-Session 'moving') -ceq $movedAgain) 'A moved file outside the dated directory was not rediscovered.'
Remove-Item -LiteralPath $movedAgain
Require ((Session-File 'moving') -ceq '') 'A deleted cached file was returned.'
$recreated=Join-Path $dated 'new-rollout-moving.jsonl'
[IO.File]::WriteAllText($recreated,"{}`n",[Text.UTF8Encoding]::new($false))
Require ((Wait-Session 'moving' 2500) -ceq $recreated) 'A recreated dated session was not rediscovered.'

# A missing root must raise an error and recover when it returns.
$sessionsDirectory=Join-Path $fixture 'temporarily-missing'
$script:sessionDiscovery=New-Discovery
$script:sessionDates=@{}
$threw=$false
try { [void](Session-File 'unavailable') } catch { $threw=$true }
Require $threw 'An unreadable source was represented as an empty result.'
[void][IO.Directory]::CreateDirectory($sessionsDirectory)
$restored=Join-Path $sessionsDirectory 'rollout-unavailable.jsonl'
[IO.File]::WriteAllText($restored,"{}`n",[Text.UTF8Encoding]::new($false))
Require ((Wait-Session 'unavailable') -ceq $restored) 'A recovered source did not retry.'

# After a negative lookup, the next monitor cycle must detect an actual ACL denial.
$codexHome=Join-Path $fixture 'permission-profile'
$sessionIndex=Join-Path $codexHome 'session_index.jsonl'
$sessionsDirectory=Join-Path $codexHome 'sessions'
$lockDirectory=Join-Path $codexHome 'thread-writer-locks'
[void][IO.Directory]::CreateDirectory($lockDirectory)
$permissionStamp=[DateTime]::UtcNow.ToString('o')
$date=[DateTime]$permissionStamp
$deniedDate=Join-Path (Join-Path (Join-Path $sessionsDirectory ([string]$date.Year)) $date.Month.ToString('00')) $date.Day.ToString('00')
[void][IO.Directory]::CreateDirectory($deniedDate)
Reset-MonitorState
$permissionRecord=@{id='denied';thread_name='Synthetic denied';updated_at=$permissionStamp}|ConvertTo-Json -Compress
[IO.File]::WriteAllText($sessionIndex,($permissionRecord+"`n"),[Text.UTF8Encoding]::new($false))
[void](Codex-Tasks)
Require ($script:sessionDiscovery.DatedMisses.ContainsKey('denied')) 'The initial dated miss was not recorded.'
$originalAcl=Get-Acl -LiteralPath $deniedDate
$deniedAcl=Get-Acl -LiteralPath $deniedDate
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$denyRule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'ListDirectory','None','None','Deny')
[void]$deniedAcl.AddAccessRule($denyRule)
try {
    Set-Acl -LiteralPath $deniedDate -AclObject $deniedAcl
    $deniedSnapshot=Source-Snapshot
    Require (@($deniedSnapshot.Unavailable) -contains 'Codex') 'A denied dated directory was represented as an empty result.'
} finally {
    Set-Acl -LiteralPath $deniedDate -AclObject $originalAcl
}
$allowed=Join-Path $deniedDate 'rollout-denied.jsonl'
[IO.File]::WriteAllText($allowed,"{}`n",[Text.UTF8Encoding]::new($false))
Require ((Session-File 'denied') -ceq $allowed) 'The dated directory did not recover after access was restored.'

# A failure inside the shared recursive scan is surfaced and retried after its interval.
$sessionsDirectory=Join-Path $fixture 'recursive-permission'
$deniedChild=Join-Path $sessionsDirectory 'denied-child'
[void][IO.Directory]::CreateDirectory($deniedChild)
$recursiveFile=Join-Path $deniedChild 'rollout-recursive-denied.jsonl'
[IO.File]::WriteAllText($recursiveFile,"{}`n",[Text.UTF8Encoding]::new($false))
$script:sessionDiscovery=New-Discovery
$script:sessionDates=@{}
$originalAcl=Get-Acl -LiteralPath $deniedChild
$deniedAcl=Get-Acl -LiteralPath $deniedChild
[void]$deniedAcl.AddAccessRule($denyRule)
try {
    Set-Acl -LiteralPath $deniedChild -AclObject $deniedAcl
    $threw=$false
    try { [void](Session-File 'recursive-denied') } catch { $threw=$true }
    Require ($threw -and $script:sessionDiscovery.ScanFailed) 'A failed recursive scan was not reported.'
} finally {
    Set-Acl -LiteralPath $deniedChild -AclObject $originalAcl
}
$failedStamp=$script:sessionDiscovery.LastScanTicks
$threw=$false
try { [void](Session-File 'recursive-denied') } catch { $threw=$true }
Require ($threw -and $script:sessionDiscovery.LastScanTicks -eq $failedStamp) 'A failed scan retried too soon or was hidden.'
Require ((Wait-Session 'recursive-denied') -ceq $recursiveFile) 'The recursive scan did not recover after access was restored.'

# Separate PowerShell runspaces share the same gate and catalog.
$sessionsDirectory=Join-Path $fixture 'parallel'
$parallelDir=Join-Path $sessionsDirectory 'other'
$parallelDated=Join-Path $sessionsDirectory 'dated'
[void][IO.Directory]::CreateDirectory($parallelDir)
[void][IO.Directory]::CreateDirectory($parallelDated)
$parallelCache=New-Discovery
$parallelDates=[hashtable]::Synchronized(@{})
$gate=[Threading.ManualResetEvent]::new($false)
$worker=@(
    '$script:sessionDiscovery=$args[0]'
    '$script:sessionDates=$args[1]'
    '$sessionsDirectory=$args[2]'
    '$id=[string]$args[3]'
    '$gate=$args[4]'
    'if(-not $gate.WaitOne(10000)){throw "Concurrent start timed out."}'
    '$script:sessionDates[$id]=$args[5]'
    '$path=Session-File $id'
    '[PSCustomObject]@{Id=$id;Path=$path;ScanTicks=[long]$script:sessionDiscovery.LastScanTicks}'
) -join "`n"
$jobs=New-Object 'Collections.Generic.List[object]'
try {
    for($i=0;$i -lt 12;$i++){
        $id='parallel-{0:D2}' -f $i
        [IO.File]::WriteAllText((Join-Path $parallelDir ('rollout-'+$id+'.jsonl')),"{}`n",[Text.UTF8Encoding]::new($false))
        $shell=[PowerShell]::Create()
        [void]$shell.AddScript($sessionFunction+"`n"+$worker)
        foreach($argument in @($parallelCache,$parallelDates,$sessionsDirectory,$id,$gate,$parallelDated)){[void]$shell.AddArgument($argument)}
        $jobs.Add([PSCustomObject]@{Shell=$shell;Handle=$shell.BeginInvoke();Id=$id})
    }
    [void]$gate.Set()
    $parallelResults=@(foreach($job in $jobs){
        $output=@($job.Shell.EndInvoke($job.Handle))
        if($job.Shell.HadErrors -or $output.Count -ne 1){throw 'A concurrent lookup failed.'}
        $output[0]
    })
    Require ($parallelResults.Count -eq 12 -and @($parallelResults | Where-Object { -not $_.Path -or -not $_.Path.EndsWith($_.Id+'.jsonl') }).Count -eq 0) 'Concurrent lookups lost a session.'
    Require (@($parallelResults.ScanTicks | Select-Object -Unique).Count -eq 1) 'Concurrent lookups repeated the recursive scan.'
    Write-Output 'Concurrent lookups: 12 sessions found using one shared scan.'
} finally {
    [void]$gate.Set()
    foreach($job in $jobs){$job.Shell.Dispose()}
    $gate.Dispose()
}
Write-Output 'Codex session discovery: delayed paths, caching, errors, recovery and concurrency verified.'
'@
try {
    & ([scriptblock]::Create(($initializers -join "`n") + "`n" + ($definitions -join "`n") + "`n" + $checks)) $root $sessionFunction
} finally {
    if (Test-Path -LiteralPath $root) {
        $resolved=(Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
