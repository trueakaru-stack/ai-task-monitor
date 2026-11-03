$ErrorActionPreference = "Stop"
$policy = Join-Path (Join-Path $PSScriptRoot "..\app") "DiagnosticPolicy.ps1"
if (-not (Test-Path -LiteralPath $policy)) { throw "Diagnostic policy is missing." }
. $policy

$now = [DateTimeOffset]::Parse("2026-11-02T12:00:00Z")
$secret = "SYNTHETIC_SECRET_DO_NOT_STORE"
$key = [byte[]](0..31)
$taskKey = Get-DiagnosticTaskKey -Provider "codex" -TaskId "synthetic-task" -Key $key
if ($taskKey -notmatch '^[a-f0-9]{64}$') { throw "Task identifiers must be pseudonymous hashes." }
if ($taskKey -ne (Get-DiagnosticTaskKey -Provider "codex" -TaskId "synthetic-task" -Key $key)) { throw "Task keys must be stable with the same key." }
if ($taskKey -ne (Get-DiagnosticTaskKey -Provider "CODEX" -TaskId "synthetic-task" -Key $key)) { throw "Provider case must not change the task key." }
if ($taskKey -eq (Get-DiagnosticTaskKey -Provider "claude" -TaskId "synthetic-task" -Key $key)) { throw "Different providers must not share task keys." }

$events = @(
    [PSCustomObject]@{ version=1; time=$now.AddDays(-8).ToString("o"); source="codex"; task=$taskKey; type="tool_started"; id=("a"*64); prompt=$secret },
    [PSCustomObject]@{ version=1; time=$now.AddDays(-1).ToString("o"); source="codex"; task=$taskKey; type="tool_started"; id=("b"*64); command=$secret },
    [PSCustomObject]@{ version=1; time=$now.ToString("o"); source="codex"; task=$taskKey; type="tool_finished"; id=("c"*64); output=$secret },
    [PSCustomObject]@{ version=1; time=$now.ToString("o"); source="codex"; task=$taskKey; type="tool_finished"; id=("c"*64); output=$secret },
    [PSCustomObject]@{ version=1; time=$now.ToString("o"); source="codex"; task=$taskKey; type=$secret; id=("d"*64) }
)
$result = Limit-DiagnosticEvents -Events $events -Now $now -RetentionDays 7 -MaximumBytes 10000
if ($result.Events.Count -ne 2) { throw "Expired, duplicate, or unknown events were not filtered correctly." }
$json = $result.Events | ConvertTo-Json -Compress -Depth 4
if ($json.Contains($secret) -or $json -match 'prompt|command|output') { throw "Sensitive or unapproved fields reached the diagnostic result." }
if ($result.Events[0].id -ne ("b"*64) -or $result.Events[1].id -ne ("c"*64)) { throw "Event order was not preserved." }
$limited = Limit-DiagnosticEvents -Events $result.Events -Now $now -RetentionDays 7 -MaximumBytes 390
if ($limited.Bytes -gt 390 -or $limited.Events.Count -ge $result.Events.Count) { throw "The size limit must remove older events." }
if ($limited.Events.Count -ne 1 -or $limited.Events[0].id -ne ("c"*64)) { throw "The newest fitting event should be retained." }
$events[1].time = $now.AddDays(-1).UtcDateTime
$typed = Limit-DiagnosticEvents -Events $events -Now $now -RetentionDays 7 -MaximumBytes 10000
if ($typed.Events.Count -ne 2) { throw "UTC DateTime values must preserve retained event timestamps." }
$future = [PSCustomObject]@{version=1;time=$now.AddHours(1).ToString("o");source="codex";task=$taskKey;type="task_observed";id=("e"*64)}
$clockChange = Limit-DiagnosticEvents -Events @($future) -Now $now -RetentionDays 7 -MaximumBytes 10000
if ($clockChange.Events.Count -ne 1) { throw "A clock adjustment must not delete future-dated events." }
$otherTask = Get-DiagnosticTaskKey -Provider "claude" -TaskId "another-synthetic-task" -Key $key
$filterFixture = @(
    [PSCustomObject]@{ task=$taskKey; type="task_observed" },
    [PSCustomObject]@{ task=$otherTask; type="task_observed" },
    [PSCustomObject]@{ task=""; type="source_unavailable" },
    [PSCustomObject]@{ task=$taskKey; type="tool_finished" }
)
$all = @(Select-DiagnosticEvents -Events $filterFixture -TaskKey "")
$selected = @(Select-DiagnosticEvents -Events $filterFixture -TaskKey $taskKey)
$none = @(Select-DiagnosticEvents -Events $filterFixture -TaskKey ("f"*64))
if ($all.Count -ne 4 -or $selected.Count -ne 2 -or $none.Count -ne 0) { throw "The journal task filter mixed tasks or source events." }
if ($selected[0].type -ne "task_observed" -or $selected[1].type -ne "tool_finished") { throw "The journal task filter changed event order." }
$viewFixture = @(
    [PSCustomObject]@{version=1;time=$now.ToString("o");source="codex";task=$taskKey;type="task_observed";id=("1"*64)},
    [PSCustomObject]@{version=1;time=$now.AddSeconds(1).ToString("o");source="claude";task=$otherTask;type="task_observed";id=("2"*64)},
    [PSCustomObject]@{version=1;time=$now.AddSeconds(2).ToString("o");source="codex";task="";type="source_unavailable";id=("3"*64)}
)
$viewEvents = (Limit-DiagnosticEvents -Events $viewFixture -Now $now.AddSeconds(2) -RetentionDays 7 -MaximumBytes 10000).Events
[Array]::Reverse($viewEvents)
$references = @([AITaskMonitor.Diagnostics.Policy]::DistinctTasks($viewEvents))
$labels = @{ task_observed="observed";source_unavailable="unavailable" }
$rows = @([AITaskMonitor.Diagnostics.Policy]::MakeRows($viewEvents,"",$labels))
$selectedRows = @([AITaskMonitor.Diagnostics.Policy]::MakeRows($viewEvents,$otherTask,$labels))
if ($references.Count -ne 2 -or $references[0].Key -ne $otherTask -or $references[1].Key -ne $taskKey) { throw "Task options must be unique and ordered by latest event." }
if ($rows.Count -ne 3 -or $rows[0].EventLabel -ne "unavailable" -or $rows[1].SourceLabel -ne "Claude Code") { throw "Journal rows must keep event order, source and type." }
if ($selectedRows.Count -ne 1 -or $selectedRows[0].SourceLabel -ne "Claude Code") { throw "Filtered journal rows must contain only the selected task." }
$untrusted = [AITaskMonitor.Diagnostics.Policy]::ParseCanonical('{"version":1,"time":"malicious","source":"codex","task":"","type":"source_unavailable","id":"'+("4"*64)+'"}')
$refused = $false
try { [void]([AITaskMonitor.Diagnostics.Policy]::Serialize(@($untrusted),$script:DiagnosticHeader)) } catch { $refused = $true }
if (-not $refused) { throw "Parsed but unvalidated records must not be serialized." }
$invalid = Limit-DiagnosticEvents -Events @($untrusted) -Now $now -RetentionDays 7 -MaximumBytes 10000
if ($invalid.Events.Count -ne 0) { throw "Invalid timestamps must not enter the journal." }
Write-Output "Diagnostic policy: pseudonyms, retention, filtering, size, deduplication and metadata-only output verified."
