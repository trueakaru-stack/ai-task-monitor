$ErrorActionPreference="Stop"
$appRoot=Join-Path $PSScriptRoot "..\app"
. (Join-Path $appRoot "DiagnosticPolicy.ps1")
. (Join-Path $appRoot "LoopDetection.ps1")
$now=[DateTimeOffset]::Parse("2026-11-02T12:00:00Z")
$key=[byte[]](0..31)
$secret="SYNTHETIC_COMMAND_SECRET"
function CommandEvent([string]$id,[int]$seconds,[string]$status,[int]$exit,[string]$argument=$secret){
 return [PSCustomObject]@{timestamp=$now.AddSeconds($seconds).ToString("o");type="event_msg";payload=[PSCustomObject]@{type="item_completed";item=[PSCustomObject]@{type="CommandExecution";id=$id;status=$status;exit_code=$exit;command=@("synthetic-tool",$argument);cwd="/synthetic/workspace";aggregated_output=$secret}}}
}
function FileEvent([string]$id,[int]$seconds){
 return [PSCustomObject]@{timestamp=$now.AddSeconds($seconds).ToString("o");type="event_msg";payload=[PSCustomObject]@{type="item_completed";item=[PSCustomObject]@{type="FileChange";id=$id;status="completed"}}}
}
$tracker=New-CodexLoopTracker -Key $key -Since $now -Threshold 5 -WindowMinutes 10
1..4|ForEach-Object {Update-CodexLoopTracker $tracker (CommandEvent "first-$_" $_ "failed" 1) $now.AddSeconds(10)}
if($tracker.Warning -or $tracker.Times.Count -ne 4){throw "Four failures must not trigger the default warning."}
Update-CodexLoopTracker $tracker (CommandEvent "first-4" 4 "failed" 1) $now.AddSeconds(10)
if($tracker.Times.Count -ne 4){throw "Duplicate source events must not be counted twice."}
Update-CodexLoopTracker $tracker (CommandEvent "first-5" 5 "failed" 1) $now.AddSeconds(10)
if(-not $tracker.Warning -or $tracker.Dismissed){throw "Five identical failures must trigger a warning."}
$tracker.Dismissed=$true
Update-CodexLoopTracker $tracker (CommandEvent "first-6" 6 "failed" 1) $now.AddSeconds(10)
if(-not $tracker.Warning -or -not $tracker.Dismissed){throw "Dismissal must persist for the same repeated-failure sequence."}
Update-CodexLoopTracker $tracker (CommandEvent "different" 7 "failed" 1 "different-command") $now.AddSeconds(10)
if($tracker.Warning -or $tracker.Dismissed -or $tracker.Times.Count -ne 1){throw "A different command must start a new sequence."}
$started=CommandEvent "different-started" 8 "in_progress" 0 "new-command"
$started.payload.type="item_started"
Update-CodexLoopTracker $tracker $started $now.AddSeconds(20)
if($tracker.Warning -or $tracker.Times.Count -ne 0){throw "Starting a different command must immediately reset the previous sequence."}
$completed=CommandEvent "different-started" 9 "failed" 1 "new-command"
Update-CodexLoopTracker $tracker $completed $now.AddSeconds(20)
if($tracker.Times.Count -ne 1){throw "An item-start event must not suppress its matching completion."}
$unknown=CommandEvent "unknown-start" 10 "in_progress" 0
$unknown.payload.type="item_started"
$unknown.payload.item.command=@()
Update-CodexLoopTracker $tracker $unknown $now.AddSeconds(20)
if($tracker.Times.Count -ne 0){throw "A command without a comparable fingerprint must reset the sequence."}
Reset-CodexLoopSequence $tracker
Update-CodexLoopTracker $tracker (CommandEvent "different-reset" 8 "failed" 1 "different-command") $now.AddSeconds(20)
2..5|ForEach-Object {Update-CodexLoopTracker $tracker (CommandEvent "different-$_" (7+$_) "failed" 1 "different-command") $now.AddSeconds(20)}
if(-not $tracker.Warning){throw "A new failure sequence must be eligible for a warning."}
Update-CodexLoopTracker $tracker (FileEvent "file-edit" 15) $now.AddSeconds(20)
if($tracker.Warning -or $tracker.Times.Count -ne 0){throw "A file change must reset the warning."}
1..5|ForEach-Object {Update-CodexLoopTracker $tracker (CommandEvent "again-$_" (20+$_) "failed" 1) $now.AddSeconds(30)}
Update-CodexLoopTracker $tracker (CommandEvent "success" 26 "completed" 0) $now.AddSeconds(30)
if($tracker.Warning -or $tracker.Times.Count -ne 0){throw "A successful command must reset the warning."}
1..4|ForEach-Object {Update-CodexLoopTracker $tracker (CommandEvent "later-$_" (30+$_) "failed" 1) $now.AddSeconds(40)}
Update-CodexLoopTracker $tracker (CommandEvent "later-5" 700 "failed" 1) $now.AddSeconds(700)
if($tracker.Warning -or $tracker.Times.Count -ne 1){throw "Failures outside the analysis window must expire."}
$copy=Copy-CodexLoopTracker $tracker
Update-CodexLoopTracker $copy (CommandEvent "copy-only" 701 "failed" 1) $now.AddSeconds(701)
if($copy.Times.Count -ne 2 -or $tracker.Times.Count -ne 1){throw "A copied tracker must not mutate the original."}
$serialized=$tracker|Select-Object Fingerprint,ExitCode,Times,Warning,Dismissed|ConvertTo-Json -Compress -Depth 5
if($serialized.Contains($secret) -or $serialized.Contains("/synthetic/workspace")){throw "The tracker retained a raw command or path."}
$custom=New-CodexLoopTracker -Key $key -Since $now -Threshold 3 -WindowMinutes 1
1..3|ForEach-Object {Update-CodexLoopTracker $custom (CommandEvent "custom-$_" $_ "failed" 2) $now.AddSeconds(5)}
if(-not $custom.Warning){throw "The configured threshold must be applied."}
Refresh-CodexLoopTracker $custom $now.AddSeconds(64)
if($custom.Warning){throw "A warning must expire when the configured window elapses."}
Write-Output "Loop detector: thresholds, task isolation, reset, deduplication, dismissal and privacy verified."
