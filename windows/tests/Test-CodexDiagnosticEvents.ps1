$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
. (Join-Path $appRoot "DiagnosticPolicy.ps1")

$now = [DateTimeOffset]::Parse("2026-11-02T12:00:00Z")
$since = $now.AddMinutes(-1)
$key = [byte[]](0..31)
$task = Get-DiagnosticTaskKey -Provider "codex" -TaskId "synthetic-task" -Key $key
$secret = "SYNTHETIC_PROMPT_COMMAND_OUTPUT_SECRET"
$records = @(
    [PSCustomObject]@{ timestamp=$now.AddMinutes(-2).ToString("o"); type="response_item"; payload=[PSCustomObject]@{type="custom_tool_call"; name="exec"; call_id="earlier-call"; input=$secret} },
    [PSCustomObject]@{ timestamp=$now.AddSeconds(-10).ToString("o"); type="response_item"; payload=[PSCustomObject]@{type="custom_tool_call_output"; call_id="earlier-call"; output=$secret} },
    [PSCustomObject]@{ timestamp=$now.ToString("o"); type="response_item"; payload=[PSCustomObject]@{type="custom_tool_call"; name="update_plan"; call_id="plan-call"; input=$secret} },
    [PSCustomObject]@{ timestamp=$now.ToString("o"); type="response_item"; payload=[PSCustomObject]@{type="function_call"; name="request_user_input_async"; call_id="question-call"; arguments=$secret} },
    [PSCustomObject]@{ timestamp=$now.ToString("o"); type="response_item"; payload=[PSCustomObject]@{type="custom_tool_call"; name="exec"; call_id="current-call"; input=$secret} },
    [PSCustomObject]@{ timestamp=$now.ToString("o"); type="response_item"; payload=[PSCustomObject]@{type="custom_tool_call_output"; call_id="current-call"; output=$secret} },
    [PSCustomObject]@{ timestamp=$now.ToString("o"); type="response_item"; payload=[PSCustomObject]@{type="function_call_output"; call_id="unknown-call"; output=$secret} }
)
$events = @(Convert-CodexToolEvents -Records $records -TaskKey $task -Key $key -Since $since)
if ($events.Count -ne 3 -or $events[0].type -ne "tool_finished" -or $events[1].type -ne "tool_started" -or $events[2].type -ne "tool_finished") {
    throw "Only matched post-start tool events should be recorded."
}
$text = $events | ConvertTo-Json -Compress -Depth 5
if ($text.Contains($secret) -or $text -match 'input|output|arguments|call_id|request_user|update_plan') { throw "Source content leaked into diagnostic events." }
if (@($events | Where-Object { $_.id -notmatch '^[a-f0-9]{64}$' -or $_.task -ne $task }).Count -ne 0) { throw "Diagnostic identifiers must be pseudonymous." }
$repeated = @(Convert-CodexToolEvents -Records $records -TaskKey $task -Key $key -Since $since)
if ((@($events | ForEach-Object id) -join ",") -ne (@($repeated | ForEach-Object id) -join ",")) { throw "The same source event must have a stable deduplication key." }
$records[4].timestamp = $now.UtcDateTime
$records[5].timestamp = $now.UtcDateTime
$typed = @(Convert-CodexToolEvents -Records $records -TaskKey $task -Key $key -Since $since)
if ($typed.Count -ne 3) { throw "UTC DateTime values must preserve source-event timestamps." }
$calls = @{}
$firstBatch = @(Convert-CodexToolEvents -Records @($records[4]) -TaskKey $task -Key $key -Since $since -Calls $calls)
$secondBatch = @(Convert-CodexToolEvents -Records @($records[5]) -TaskKey $task -Key $key -Since $since -Calls $calls)
if ($firstBatch.Count -ne 1 -or $secondBatch.Count -ne 1 -or $secondBatch[0].type -ne "tool_finished" -or $calls.Count -ne 0) {
    throw "Tool calls must be paired across batches without retaining completed call IDs."
}
$commandRecords = @(
    [PSCustomObject]@{timestamp=$now.ToString("o");type="event_msg";payload=[PSCustomObject]@{type="item_completed";item=[PSCustomObject]@{type="CommandExecution";id="command-1";status="failed";exit_code=1;command=@($secret);aggregated_output=$secret}}},
    [PSCustomObject]@{timestamp=$now.ToString("o");type="event_msg";payload=[PSCustomObject]@{type="item_completed";item=[PSCustomObject]@{type="CommandExecution";id="command-2";status="completed";exit_code=0;command=@($secret)}}},
    [PSCustomObject]@{timestamp=$now.ToString("o");type="event_msg";payload=[PSCustomObject]@{type="item_completed";item=[PSCustomObject]@{type="CommandExecution";id="command-3";status="failed";exit_code=$null;command=@($secret)}}},
    [PSCustomObject]@{timestamp=$now.ToString("o");type="event_msg";payload=[PSCustomObject]@{type="item_completed";item=[PSCustomObject]@{type="CommandExecution";id="command-4";status="completed";exit_code=1;command=@($secret)}}},
    [PSCustomObject]@{timestamp=$now.ToString("o");type="event_msg";payload=[PSCustomObject]@{type="item_completed";item=[PSCustomObject]@{type="CommandExecution";id="command-5";status="failed";exit_code="1";command=@($secret)}}}
)
$commandEvents=@(Convert-CodexToolEvents -Records $commandRecords -TaskKey $task -Key $key -Since $since)
if($commandEvents.Count -ne 1 -or $commandEvents[0].type -ne "tool_failed"){throw "Only a structured failed command with a nonzero numeric exit code should be recorded."}
$commandJson=$commandEvents|ConvertTo-Json -Compress -Depth 4
if($commandJson.Contains($secret) -or $commandJson -match 'command|aggregated_output|exit_code'){throw "Command details leaked into the diagnostic event."}
if($commandEvents[0].id -ne (@(Convert-CodexToolEvents -Records $commandRecords -TaskKey $task -Key $key -Since $since)[0]).id){throw "Structured failures must deduplicate deterministically."}
Write-Output "Codex diagnostics: metadata-only tool starts, finishes and structured command failures verified."
