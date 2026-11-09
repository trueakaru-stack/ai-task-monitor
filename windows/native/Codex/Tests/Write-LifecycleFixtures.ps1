param([Parameter(Mandatory=$true)][string]$ReferenceSource)
$ErrorActionPreference = 'Stop'

# This process executes only the two extracted functions against the in-memory
# stubs below. It never opens a session, profile or lock file.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($ReferenceSource), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Unable to parse the reference source.' }
foreach ($name in @('Thread-State','Codex-Uncertain')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $definition) { throw "Missing reference function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$script:monitorStartedUtc = [DateTime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime()
$lockDirectory = 'synthetic-lock-directory'
function Session-File([string]$id) { return $script:fakePath }
function Test-Path([string]$LiteralPath) { return $script:present }
function Get-Item([string]$LiteralPath) { return [PSCustomObject]@{ Length=$script:fakeTail.Length; LastWriteTimeUtc=$script:modified } }
function Read-TailText([string]$path,[long]$maxBytes) { return $script:fakeTail }
function Lock-State([string]$path) { return $script:lock }

function Event([string]$type, [string]$turn='', [string]$timestamp='') {
    $kind = switch ($type) {
        { $_ -in @('task_started','turn_started') } { 'Started'; break }
        { $_ -in @('task_complete','turn_complete') } { 'Completed'; break }
        'turn_aborted' { 'Aborted'; break }
        default { 'Activity' }
    }
    return [ordered]@{ Kind=$kind; Type=$type; TurnId=$turn; Timestamp=$timestamp }
}

$script:cases = New-Object 'Collections.Generic.List[object]'
function Start-Case([string]$name) {
    $script:lifecycleState = @{}; $script:observedCodex = @{}
    $script:fakeTail = ''; $script:pathGeneration = 0; $script:fakePath = 'synthetic-session-0'
    $script:case = [ordered]@{ Name=$name; MonitorStartedUtc='2026-01-01T00:00:00Z'; Steps=(New-Object 'Collections.Generic.List[object]') }
    $script:cases.Add($script:case)
}

function Step {
    param(
        [string]$Name, [string]$Expected, [bool]$Unconfirmed=$false,
        [object[]]$Events=@(), [string]$Lock='held', [string]$Updated='2026-01-01T00:00:02Z',
        [bool]$Present=$true, [switch]$FullHistory, [switch]$SamePath
    )
    $previousLength = $script:fakeTail.Length
    if ($FullHistory) {
        if (-not $SamePath) {
            $script:pathGeneration++
            $script:fakePath = 'synthetic-session-' + $script:pathGeneration
        }
        $script:fakeTail = ''
    }
    foreach ($event in $Events) {
        $payload = [ordered]@{type=$event.Type}
        if ($event.TurnId) { $payload.turn_id = $event.TurnId }
        $record = [ordered]@{type='event_msg';payload=$payload}
        if ($event.Timestamp) { $record.timestamp = $event.Timestamp }
        if ($script:fakeTail) { $script:fakeTail += "`n" }
        $script:fakeTail += ConvertTo-Json -InputObject $record -Compress -Depth 8
    }
    if ($SamePath -and (-not $FullHistory -or $script:fakeTail.Length -ge $previousLength)) {
        throw 'The same-path replacement fixture must be shorter than the preceding history.'
    }
    $script:lock = $Lock; $script:present = $Present
    $script:modified = [DateTime]::Parse($Updated).ToUniversalTime()
    $sourceError = $false; $snapshot = $null; $actualUnconfirmed = $false
    try {
        $snapshot = Thread-State 'synthetic-id'
        $actualUnconfirmed = [bool](Codex-Uncertain 'synthetic-id' $snapshot)
        $actual = [string]$snapshot.State
    } catch {
        if ($_.Exception.Message -notlike '*Codex session lock cannot be checked*') { throw }
        $sourceError = $true; $actual = 'source_error'
    }
    if ($actual -ne $Expected -or (-not $sourceError -and $actualUnconfirmed -ne $Unconfirmed)) {
        throw "Reference fixture failed: $($script:case.Name) / $Name."
    }
    $cache = $script:lifecycleState[$script:fakePath]
    $marker = if ($null -eq $cache) { 'None' } else {
        switch ([string]$cache.Lifecycle) {
            'task_started' { 'Started' }; 'task_complete' { 'Completed' }; 'turn_aborted' { 'Aborted' }; default { 'None' }
        }
    }
    $expectedState = [ordered]@{
        Marker=$marker
        TurnId=$(if ($null -eq $cache) { '' } else { [string]$cache.TurnId })
        LastEventTicks=$(if ($null -eq $cache) { [long]0 } else { [long]$cache.LastEventUtc.Ticks })
        StartKey=$(if ($null -eq $cache) { '' } else { [string]$cache.StartKey })
        StartedTicks=$(if ($null -eq $cache) { [long]0 } else { [long]$cache.StartedUtc.Ticks })
        Observed=[bool]$script:observedCodex.ContainsKey('synthetic-id')
    }
    $expectedSnapshot = if ($sourceError) { $null } else {
        [ordered]@{
            Status=$actual; HasStartMarker=[bool]$snapshot.HasStartMarker; UpdatedTicks=[long]$snapshot.UpdatedUtc.Ticks
            StartKey=[string]$snapshot.StartKey; StartedTicks=[long]$snapshot.StartedUtc.Ticks; Unconfirmed=$actualUnconfirmed
        }
    }
    $script:case.Steps.Add([ordered]@{
        Name=$Name; Events=@($Events); Lock=$Lock; UpdatedUtc=$Updated; SourcePresent=$Present
        BatchKind=$(if ($FullHistory) { 'FullHistory' } else { 'Incremental' })
        ExpectedState=$expectedState; ExpectedSnapshot=$expectedSnapshot; SourceUnavailable=$sourceError
    })
}

Start-Case 'old quiet and observed'
Step -Name 'old held lock remains hidden' -Events @((Event task_started turn-a '2025-12-31T20:00:00Z')) -Updated '2025-12-31T20:00:00Z' -Expected unobserved
Step -Name 'new file time alone does not make held turn active' -Expected unobserved
Step -Name 'new file time and free lock become unconfirmed' -Lock free -Expected unknown -Unconfirmed $true
Step -Name 'observed turn regains held lock' -Expected active
Step -Name 'missing lock is unconfirmed' -Lock missing -Expected unknown -Unconfirmed $true
Step -Name 'matching new activity and held lock' -Events @((Event agent_reasoning turn-a '2026-01-01T00:00:03Z')) -Expected active

Start-Case 'turn changes and terminal markers'
Step -Name 'new start' -Events @((Event task_started TURN-A '2026-01-01T00:00:01Z')) -Expected active
Step -Name 'other turn completion ignored' -Events @((Event task_complete turn-b)) -Expected active
Step -Name 'same turn abortion' -Events @((Event turn_aborted TURN-A)) -Expected interrupted
Step -Name 'activity after interruption ignored' -Events @((Event item_completed TURN-A '2026-01-01T00:00:05Z')) -Expected interrupted
Step -Name 'new turn resumes' -Events @((Event turn_started turn-c '2026-01-01T00:00:06Z')) -Expected active
Step -Name 'terminal without turn ends current turn' -Events @((Event turn_complete)) -Expected completed
Step -Name 'repeat start same turn follows published behavior' -Events @((Event task_started turn-c '2026-01-01T00:00:07Z')) -Expected active
Step -Name 'matching terminal overrides held lock' -Events @((Event task_complete turn-c)) -Expected completed

Start-Case 'lock availability and missing source'
Step -Name 'fresh start without lock is unconfirmed' -Events @((Event task_started fresh '2026-01-01T00:00:01Z')) -Lock free -Expected unknown -Unconfirmed $true
Step -Name 'lock becomes held' -Expected active
Step -Name 'unreadable lock is source error' -Lock unavailable -Expected source_error
Step -Name 'absent source retains observation as unconfirmed' -Present $false -Lock unavailable -Expected unknown -Unconfirmed $true
Step -Name 'source and held lock return' -Expected active
Step -Name 'terminal does not require lock read' -Events @((Event task_complete fresh)) -Lock unavailable -Expected completed
Step -Name 'absent source after completion stays hidden' -Present $false -Expected unknown

Start-Case 'history replacement after observation'
Step -Name 'initial session active' -Events @((Event turn_started first '2026-01-01T00:00:01Z')) -Expected active
Step -Name 'replacement has no start marker' -FullHistory -Events @((Event token_count '' '2026-01-01T00:00:02Z')) -Expected unknown -Unconfirmed $true
Step -Name 'new start after replacement' -Events @((Event task_started second '2026-01-01T00:00:03Z')) -Expected active

Start-Case 'no start and terminal first'
Step -Name 'activity alone is hidden' -Events @((Event token_count '' '2026-01-01T00:00:01Z')) -Expected unknown
Step -Name 'terminal without start is completed' -Events @((Event task_complete lone)) -Expected completed
Step -Name 'activity cannot make terminal active' -Events @((Event token_count '' '2026-01-01T00:00:02Z')) -Expected completed

Start-Case 'timestamp offset and no turn'
Step -Name 'exact monitor boundary after offset conversion' -Events @((Event task_started '' '2026-01-01T03:00:00+03:00')) -Expected active
Step -Name 'completion clears observation' -Events @((Event task_complete)) -Expected completed
Step -Name 'no timestamp has no start key or fresh activity' -FullHistory -Events @((Event turn_started)) -Updated '2025-12-31T20:00:00Z' -Expected unobserved
Step -Name 'fresh activity reveals that turn' -Events @((Event agent_reasoning '' '2026-01-01T00:00:01Z')) -Expected active

Start-Case 'old free lock remains hidden'
Step -Name 'old unseen start' -Events @((Event task_started old '2025-12-31T23:59:59Z')) -Lock free -Updated '2025-12-31T23:59:59Z' -Expected unknown
Step -Name 'fresh event without a lock' -Events @((Event token_count old '2026-01-01T00:00:01Z')) -Lock free -Expected unknown -Unconfirmed $true

Start-Case 'activity from another turn'
Step -Name 'old start remains hidden' -Events @((Event task_started original '2025-12-31T23:00:00Z')) -Updated '2025-12-31T23:00:00Z' -Expected unobserved
Step -Name 'new event for another turn does not reveal it' -Events @((Event item_completed different '2026-01-01T00:00:01Z')) -Expected unobserved
Step -Name 'event for current turn reveals it' -Events @((Event item_completed original '2026-01-01T00:00:02Z')) -Expected active

Start-Case 'failure on first observation'
Step -Name 'fresh start with unreadable lock has no snapshot' -Events @((Event task_started first '2026-01-01T00:00:01Z')) -Lock unavailable -Expected source_error
Step -Name 'subsequent free lock gives unconfirmed' -Lock free -Expected unknown -Unconfirmed $true
Step -Name 'subsequent held lock gives active' -Expected active
Step -Name 'aborted marker does not require a lock' -Events @((Event turn_aborted first)) -Lock unavailable -Expected interrupted

Start-Case 'same path truncated'
Step -Name 'original session active' -Events @((Event task_started old-turn '2026-01-01T00:00:01Z')) -Expected active
Step -Name 'append another event' -Events @((Event token_count old-turn '2026-01-01T00:00:02Z')) -Expected active
Step -Name 'shorter replacement has no start' -FullHistory -SamePath -Events @((Event token_count)) -Expected unknown -Unconfirmed $true
Step -Name 'new turn after replacement' -Events @((Event task_started new-turn '2026-01-01T00:00:03Z')) -Expected active

Start-Case 'invalid start timestamp'
Step -Name 'invalid time alone is not fresh evidence' -Events @((Event task_started '' 'not-a-date')) -Expected unobserved
Step -Name 'fresh activity reveals started turn' -Events @((Event token_count '' '2026-01-01T00:00:01Z')) -Expected active

ConvertTo-Json -InputObject @($script:cases.ToArray()) -Depth 30 -Compress
