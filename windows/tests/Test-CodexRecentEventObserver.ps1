$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot '..\app\CodexRecentEventObserver.cs'
Add-Type -Path $source -ErrorAction Stop
$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixture = [IO.Path]::GetFullPath((Join-Path $temporary ('aitm-recent-event-' + [Guid]::NewGuid().ToString('N'))))
if (-not $fixture.StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid synthetic fixture path.' }
$sessions = Join-Path $fixture 'sessions'
$first = Join-Path $sessions 'first.jsonl'
$second = Join-Path $sessions 'second.jsonl'
$replacement = Join-Path $sessions 'replacement.jsonl'
$capacityDirectory = Join-Path $sessions 'capacity'
$capacityFiles = [Collections.Generic.List[string]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)

function Require([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Append-Synthetic([string]$path, [string]$value) { [IO.File]::AppendAllText($path, $value, $utf8) }
function Wait-Synthetic($observer, [string]$id, [string]$path, [scriptblock]$condition) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $snapshot = $observer.Snapshot($id, $path)
        if (& $condition $snapshot) { return $snapshot }
        Start-Sleep -Milliseconds 40
    } while ($clock.ElapsedMilliseconds -lt 12000)
    $caller = @(Get-PSCallStack)[1]
    throw "The synthetic observer did not reach $condition (caller=$($caller.ScriptLineNumber), checks=$($snapshot.CheckCount), ready=$($snapshot.BaselineReady), event=$($snapshot.HasEvent))."
}
function Wait-Checks($observer, [string]$id, [string]$path, [long]$target) {
    return Wait-Synthetic $observer $id $path { param($snapshot) $snapshot.CheckCount -ge $target }
}
function Event([string]$id, [string]$turn) {
    return ('{"type":"event_msg","payload":{"type":"item_completed","thread_id":"' + $id + '","turn_id":"' + $turn + '","item":{"type":"Synthetic","id":"item"}}}' + "`n")
}
function Write-Synthetic([string]$path, [string]$id) {
    [IO.File]::WriteAllText($path, ('{"type":"session_meta","payload":{"id":"' + $id + '"}}' + "`n"), $utf8)
}

$observer = $null
$blocked = $null
$idleObserver = $null
$gate = $null
try {
    [void][IO.Directory]::CreateDirectory($sessions)
    $id = 'synthetic-parent'
    $neighbor = 'synthetic-neighbor'
    Write-Synthetic $first $id
    Write-Synthetic $second $neighbor

    # A genuine long log is used: its previous start is more than 16 MiB back.
    Append-Synthetic $first ('{"type":"event_msg","payload":{"type":"task_started","turn_id":"old-turn"}}' + "`n")
    $row = '{"type":"event_msg","payload":{"type":"synthetic_padding","value":"' + ('x' * 1024) + '"}}' + "`n"
    $block = $utf8.GetBytes(($row * 64))
    $stream = [IO.File]::Open($first, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { for ($i = 0; $i -lt 270; $i++) { $stream.Write($block, 0, $block.Length) } } finally { $stream.Dispose() }
    Require (([IO.FileInfo]::new($first)).Length -gt 16MB) 'The synthetic long journal is too short.'

    $observer = [AITaskMonitor.CodexObservation.CodexRecentEventObserver]::new($sessions)
    $baseline = Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.BaselineReady }
    Require (-not $baseline.HasEvent) 'A historical event was treated as a new observation.'
    [void](Wait-Synthetic $observer $neighbor $second { param($snapshot) $snapshot.BaselineReady })

    Append-Synthetic $first (Event 'different-thread' 'turn-1')
    Append-Synthetic $first (Event $id '')
    $checked = Wait-Checks $observer $id $first ($baseline.CheckCount + 2)
    Require (-not $checked.HasEvent) 'An event with missing or mismatched identifiers was accepted.'
    $checked = Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.BaselineReady }

    $complete = Event $id 'turn-1'
    $split = [Math]::Floor($complete.Length / 2)
    Append-Synthetic $first $complete.Substring(0, $split)
    $partial = Wait-Checks $observer $id $first ($checked.CheckCount + 2)
    Require (-not $partial.HasEvent) 'An incomplete JSONL record was accepted.'
    Append-Synthetic $first $complete.Substring($split)
    $found = Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.HasEvent }
    Require ($found.BaselineReady) 'The long journal did not produce an unconfirmed observation.'
    Require ($null -eq $found.PSObject.Properties['Active'] -and $null -eq $found.PSObject.Properties['Terminal']) 'An observation was exposed as lifecycle confirmation.'
    $other = $observer.Snapshot($neighbor, $second)
    Require (-not $other.HasEvent) 'One thread produced evidence for its neighbor.'
    $payloadFirst = [ordered]@{ payload = [ordered]@{ item = [ordered]@{ type = 'Synthetic' }; turn_id = 'turn/2'; thread_id = $neighbor; type = 'item_completed' }; type = 'event_msg' }
    $serialized = ConvertTo-Json -InputObject $payloadFirst -Depth 6 -Compress
    Append-Synthetic $second ($serialized + "`n")
    [void](Wait-Synthetic $observer $neighbor $second { param($snapshot) $snapshot.HasEvent })
    $outside = $observer.Snapshot('outside-thread', (Join-Path $fixture 'outside.jsonl'))
    Require (-not $outside.BaselineReady -and -not $outside.HasEvent) 'A path outside the sessions directory was accepted.'

    # Duplicate routing keys cannot turn a different thread into this thread.
    Append-Synthetic $first ('{"type":"event_msg","payload":{"type":"item_completed","thread_id":"different","thread_id":"synthetic-parent","turn_id":"turn-1"}}' + "`n")
    [void](Wait-Synthetic $observer $id $first { param($snapshot) -not $snapshot.HasEvent })
    [void](Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.BaselineReady })
    Append-Synthetic $first ('{"type":"event_msg","payload":{"type":"item_completed","thread_id":"\u0073ynthetic-parent","turn_id":"turn-1","item":{"type":"Synthetic","id":"item"}}}' + "`n")
    [void](Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.HasEvent })
    Append-Synthetic $first ('{"type":"event_msg","payload":{"thread_id":"synthetic-parent"}}' + "`n")
    [void](Wait-Synthetic $observer $id $first { param($snapshot) -not $snapshot.HasEvent })
    [void](Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.BaselineReady })
    Append-Synthetic $first (Event $id 'turn-1')
    [void](Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.HasEvent })

    # A malformed record invalidates the previous observation and is never echoed.
    Append-Synthetic $first ("{invalid-json}`n")
    $afterBad = Wait-Synthetic $observer $id $first { param($snapshot) -not $snapshot.HasEvent }
    Require (-not $afterBad.HasEvent) 'A damaged record retained an earlier observation.'
    $readyAgain = Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.BaselineReady }
    Append-Synthetic $first (Event $id 'turn-2')
    [void](Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.HasEvent })

    # A lost range is not treated as a valid sequence of events.
    $range = $observer.Snapshot($id, $first)
    $stream = [IO.File]::Open($first, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { $stream.Write((New-Object byte[] (2MB + 1)), 0, (2MB + 1)) } finally { $stream.Dispose() }
    $lost = Wait-Checks $observer $id $first ($range.CheckCount + 2)
    Require (-not $lost.HasEvent) 'A lost range retained evidence.'

    # Replacement at the same pathname cannot inherit an old file's evidence.
    Write-Synthetic $replacement $id
    [IO.File]::Delete($first)
    [IO.File]::Move($replacement, $first)
    [void](Wait-Checks $observer $id $first ($lost.CheckCount + 2))
    $replaced = Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.BaselineReady -and -not $snapshot.HasEvent }
    Append-Synthetic $first (Event $id 'turn-3')
    [void](Wait-Synthetic $observer $id $first { param($snapshot) $snapshot.HasEvent })
    [IO.File]::WriteAllText($first, ('{"type":"session_meta","payload":{"id":"' + $id + '"}}' + "`n"), $utf8)
    $truncated = Wait-Synthetic $observer $id $first { param($snapshot) -not $snapshot.HasEvent }
    Require (-not $truncated.HasEvent) 'A truncated file retained evidence.'

    # A different path, even with the same owner, starts with a fresh baseline.
    Write-Synthetic $replacement $id
    Append-Synthetic $replacement (Event $id 'old-turn')
    $moved = $observer.Snapshot($id, $replacement)
    Require (-not $moved.HasEvent) 'A changed path inherited earlier evidence.'
    [void](Wait-Synthetic $observer $id $replacement { param($snapshot) $snapshot.BaselineReady })
    Append-Synthetic $replacement (Event $id 'new-turn')
    [void](Wait-Synthetic $observer $id $replacement { param($snapshot) $snapshot.HasEvent })

    # At the reader's full 768-path bound, repeated discovery must not evict
    # an already observed task before its next refresh.
    [void][IO.Directory]::CreateDirectory($capacityDirectory)
    for ($i = 0; $i -lt 766; $i++) {
        $capacityId = 'capacity-{0:D4}' -f $i
        $capacityPath = Join-Path $capacityDirectory ($capacityId + '.jsonl')
        $capacityFiles.Add($capacityPath)
        Write-Synthetic $capacityPath $capacityId
        [void]$observer.Snapshot($capacityId, $capacityPath)
    }
    $stillObserved = $observer.Snapshot($id, $replacement)
    Require ($stillObserved.BaselineReady -and $stillObserved.HasEvent) 'Candidate capacity evicted an observed task.'

    # Simulate the two-second UI poll while one log continues to grow. The
    # independently scheduled worker must complete at least two regular
    # rounds and keep the observed cursor through more than 2 MiB of appends.
    $lastCapacityId = 'capacity-0765'
    $lastCapacityPath = $capacityFiles[$capacityFiles.Count - 1]
    $lastCapacity = Wait-Synthetic $observer $lastCapacityId $lastCapacityPath { param($snapshot) $snapshot.BaselineReady }
    $activeChecks = $stillObserved.CheckCount
    $paddingLine = '{"type":"event_msg","payload":{"type":"fixture_padding","value":"' + ('x' * 65536) + '"}}' + "`n"
    for ($round = 0; $round -lt 40; $round++) {
        Append-Synthetic $replacement $paddingLine
        if (($round % 8) -eq 0) {
            $callClock = [Diagnostics.Stopwatch]::StartNew()
            for ($item = 0; $item -lt $capacityFiles.Count; $item++) {
                [void]$observer.Snapshot(('capacity-{0:D4}' -f $item), $capacityFiles[$item])
            }
            Require ($callClock.ElapsedMilliseconds -lt 2000) 'A full candidate poll blocked the caller.'
        }
        Start-Sleep -Milliseconds 250
        $running = $observer.Snapshot($id, $replacement)
        Require ($running.BaselineReady) ('Normal appends reset the baseline at round ' + $round + '.')
    }
    $lastAgain = $observer.Snapshot($lastCapacityId, $lastCapacityPath)
    Require ($lastAgain.CheckCount -ge $lastCapacity.CheckCount + 2) 'The background worker did not complete two fair rounds.'
    Require ($running.CheckCount -gt $activeChecks + 2) 'The observed log did not receive repeated background checks.'
    [void](Wait-Synthetic $observer $id $replacement { param($snapshot) $snapshot.HasEvent })

    # Once entries are no longer requested, the worker must stop; a later
    # request must be able to start it again without involving the UI.
    $idleObserver = [AITaskMonitor.CodexObservation.CodexRecentEventObserver]::new($sessions)
    [void](Wait-Synthetic $idleObserver $id $replacement { param($snapshot) $snapshot.BaselineReady })
    $private = [Reflection.BindingFlags]'Instance,NonPublic'
    $idleType = $idleObserver.GetType();$idleGate = $idleType.GetField('gate', $private).GetValue($idleObserver)
    $idleEntries = $idleType.GetField('entries', $private).GetValue($idleObserver)
    [Threading.Monitor]::Enter($idleGate)
    try { $idleEntries[$id].GetType().GetField('Requested').SetValue($idleEntries[$id], [long]0) }
    finally { [Threading.Monitor]::Exit($idleGate) }
    $idleClock = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 50
        $idleWorker = $idleType.GetField('worker', $private).GetValue($idleObserver)
    } while ($null -ne $idleWorker -and $idleClock.ElapsedMilliseconds -lt 5000)
    Require ($null -eq $idleWorker) 'The observer kept a worker running after all entries expired.'
    [void](Wait-Synthetic $idleObserver $id $replacement { param($snapshot) $snapshot.BaselineReady })

    # A blocked worker must not block the UI-facing method or start more work.
    $gate = [Threading.ManualResetEvent]::new($false)
    $blocked = [AITaskMonitor.CodexObservation.CodexRecentEventObserver]::new($sessions, $gate)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt 200; $i++) { [void]$blocked.Snapshot($id, $replacement) }
    Require ($clock.ElapsedMilliseconds -lt 1000) 'The blocked observer delayed the caller.'
    Require (-not $blocked.Snapshot($id, $replacement).HasEvent) 'A blocked worker invented evidence.'
    [void]$gate.Set()
    [void](Wait-Synthetic $blocked $id $replacement { param($snapshot) $snapshot.BaselineReady })
    Write-Output 'Synthetic recent-event observer: long journal, exact IDs, partial/corrupt data, replacement, isolation, 768 candidates and nonblocking snapshot verified.'
} finally {
    if ($null -ne $observer) { $observer.Dispose() }
    if ($null -ne $idleObserver) { $idleObserver.Dispose() }
    if ($null -ne $gate) { [void]$gate.Set() }
    if ($null -ne $blocked) { $blocked.Dispose() }
    if ($null -ne $gate) { $gate.Dispose() }
    foreach ($path in $capacityFiles) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    if ([IO.Directory]::Exists($capacityDirectory)) { [IO.Directory]::Delete($capacityDirectory) }
    foreach ($path in @($first, $second, $replacement)) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    if ([IO.Directory]::Exists($sessions)) { [IO.Directory]::Delete($sessions) }
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture) }
}
