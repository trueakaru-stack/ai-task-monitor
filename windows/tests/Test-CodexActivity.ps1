$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application source could not be parsed.' }
$definitions = foreach ($name in @('Prop', 'Codex-Activity', 'Codex-ObservedActivity')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $function) { throw "Missing function: $name" }
    $function.Extent.Text
}
$checks = @'
function Session-File([string]$id) { return 'fixture' }
function Read-TailText([string]$path, [long]$maxBytes) { return $script:activityTail }
function Read-ObservedCodexTail([string]$path,[string]$id) { return $script:activityTail }
function Assert-Activity([string]$expected, [string]$message) {
    $actual = [string](Codex-Activity 'fixture')
    if ($actual -cne $expected) { throw "$message. Expected '$expected', got '$actual'." }
}
$old = '{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Old action"}}'
$response = '{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"**Checking screenshot stability**\n\nPRIVATE_REASONING"}],"content":[{"text":"PRIVATE_RAW_CONTENT"}]}}'
$completed = '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","summary_text":["**Check build**"]}}}'
$comment = '{"type":"response_item","payload":{"type":"message","phase":"commentary","content":[{"type":"output_text","text":"Preparing check"}]}}'
$start = '{"type":"event_msg","payload":{"type":"task_started","turn_id":"new-turn"}}'

$script:activityTail = $old + "`n" + $response
Assert-Activity 'Checking screenshot stability' 'A newer response summary was ignored'
$script:activityTail = $response + "`n" + $completed
Assert-Activity 'Check build' 'Completed reasoning summary was ignored'
$script:activityTail = $response + "`n" + $comment
Assert-Activity 'Checking screenshot stability' 'A longer commentary replaced the current short status'
$script:activityTail = $response + "`n" + $start
Assert-Activity '' 'A new turn retained a stale status'
$script:activityTail = $response + "`n" + $start + "`n" + $comment
Assert-Activity 'Preparing check' 'Commentary fallback was not used'
$wrongTurn = '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"old-turn","item":{"type":"Reasoning","summary_text":["**Wrong turn**"]}}}'
$script:activityTail = $start + "`n" + $comment + "`n" + $wrongTurn
Assert-Activity 'Preparing check' 'A late event from a previous turn was displayed'
$matchingComment = '{"type":"event_msg","payload":{"type":"item_completed","thread_id":"fixture","turn_id":"new-turn","item":{"type":"AgentMessage","id":"message-1","phase":"commentary","content":[{"type":"Text","text":"Preparing check"}]}}}'
$script:activityTail = $start + "`n" + $response + "`n" + $matchingComment
if ((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Preparing check') { throw 'The newest observed commentary was not selected for the matching turn.' }
if (Codex-ObservedActivity 'fixture' 'turn:other-turn') { throw 'A different turn produced an observed message.' }
$script:activityTail = $start + "`n" + $response + "`n" + $comment
if (Codex-ObservedActivity 'fixture' 'turn:new-turn') { throw 'A roleless response was shown as an observed assistant message.' }
$script:activityTail = $response
if (Codex-ObservedActivity 'fixture' 'turn:new-turn') { throw 'Raw reasoning without turn identity was displayed.' }
$matchingEvent = '{"type":"event_msg","payload":{"type":"item_completed","thread_id":"fixture","turn_id":"new-turn","item":{"type":"Reasoning","id":"reasoning-1","summary_text":["**Observed after boundary**"],"raw_content":[]}}}'
$script:activityTail = $wrongTurn + "`n" + $matchingEvent
if ((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Observed after boundary') { throw 'A turn-identified event in a long tail was not retained.' }
$wrongThread = '{"type":"event_msg","payload":{"type":"item_completed","thread_id":"other","turn_id":"new-turn","item":{"type":"Reasoning","id":"other-1","summary_text":["Other session"],"raw_content":[]}}}'
$script:activityTail = $start + "`n" + $wrongThread
if (Codex-ObservedActivity 'fixture' 'turn:new-turn') { throw 'A message from a different thread was attributed to this session.' }
$legacyComment='{"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"Delayed legacy commentary"}}'
$script:activityTail = $matchingEvent + "`n" + $start + "`n" + $legacyComment
if ((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Delayed legacy commentary') { throw 'The last written legacy commentary was not reported as a log observation.' }
$assistantComment='{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Assistant commentary"}]}}'
$script:activityTail = $legacyComment + "`n" + $assistantComment
if ((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Assistant commentary') { throw 'The last assistant commentary response was not found.' }
$userComment='{"type":"response_item","payload":{"type":"message","role":"user","phase":"commentary","content":[{"type":"output_text","text":"USER_TEXT"}]}}'
$finalAnswer='{"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"FINAL_TEXT"}}'
$script:activityTail = $legacyComment + "`n" + $userComment + "`n" + $finalAnswer
if ((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Delayed legacy commentary') { throw 'A user message or final answer was treated as commentary.' }
$unicode = '{ "payload": { "summary": [{"text":"**\u0410**","type":"summary_text"}], "type":"reasoning" }, "type":"response_item" }'
$script:activityTail = $unicode
Assert-Activity ([string][char]0x0410) 'An escaped Unicode status was not decoded'
$script:activityTail = '{"type":"response_item","payload":{"type":"reasoning","summary":[],"content":[{"text":"PRIVATE_RAW_CONTENT"}]}}'
Assert-Activity '' 'Raw reasoning was exposed without a summary'
$script:activityTail = '{invalid json}' + "`n" + $completed
Assert-Activity 'Check build' 'Malformed records blocked a valid status'
$script:activityTail = ($response + "`n") * 5000
$watch = [Diagnostics.Stopwatch]::StartNew()
Assert-Activity 'Checking screenshot stability' 'A long event tail lost its latest summary'
$watch.Stop()
if ($watch.ElapsedMilliseconds -gt 2000) { throw "A 5,000-event activity tail blocked the two-second refresh: $($watch.ElapsedMilliseconds) ms." }
Write-Output "Codex activity: current and legacy summaries, turn reset, commentary fallback and privacy verified; 5,000 events in $($watch.ElapsedMilliseconds) ms."
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))
