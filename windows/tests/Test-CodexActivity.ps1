$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application source could not be parsed.' }
$definitions = foreach ($name in @('Prop', 'Codex-CurrentToolActivity', 'Codex-Activity', 'Codex-ObservedActivity')) {
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
function Tool-Start([string]$id,[string]$title,[string]$namespace='mcp__cua_repl') {
    $arguments=@{title=$title;code='PRIVATE_TOOL_INPUT'}|ConvertTo-Json -Compress
    return @{type='response_item';payload=@{type='function_call';namespace=$namespace;name='js';call_id=$id;arguments=$arguments}}|ConvertTo-Json -Compress -Depth 8
}
function Tool-End([string]$id) { return @{type='response_item';payload=@{type='function_call_output';call_id=$id;output='PRIVATE_TOOL_OUTPUT'}}|ConvertTo-Json -Compress }
$firstTool=Tool-Start 'call-1' 'Checking the window'
$secondTool=Tool-Start 'call-2' 'Inspecting the current operation'
$firstEnd=Tool-End 'call-1';$secondEnd=Tool-End 'call-2'
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+$secondTool
Assert-Activity 'Inspecting the current operation' 'The latest open titled operation was not shown'
if ((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Inspecting the current operation') { throw 'The open operation was not found in observed activity.' }
$script:activityTail+="`n"+$secondEnd
Assert-Activity 'Checking the window' 'An earlier still-open operation was not restored'
$script:activityTail+="`n"+$firstEnd
Assert-Activity 'Checking screenshot stability' 'A finished operation remained current'
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+$firstEnd+"`n"+$firstTool
Assert-Activity 'Checking screenshot stability' 'A duplicate start revived a finished operation'
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+$secondTool+"`n"+$firstTool
Assert-Activity 'Inspecting the current operation' 'A duplicate start changed the order of open operations'
$oversizedEnd=@{type='response_item';payload=@{type='function_call_output';call_id='call-1';output=('x'*1100000)}}|ConvertTo-Json -Compress
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+$oversizedEnd
Assert-Activity 'Checking screenshot stability' 'An oversized output left an operation falsely current'
$unicodeEnd=@{type='response_item';payload=@{type='function_call_output';call_id='call-1';output=([string][char]0x0416*600000)}}|ConvertTo-Json -Compress
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+$unicodeEnd
Assert-Activity 'Checking screenshot stability' 'A UTF-8 oversized output left an operation falsely current'
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+'{"incomplete":'
Assert-Activity 'Checking screenshot stability' 'Malformed later data left an operation falsely current'
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+'{"type":"response_item"}'
Assert-Activity 'Checking screenshot stability' 'A later record without payload left an operation falsely current'
$foreign=@{type='response_item';payload=@{type='function_call';namespace='mcp__cua_repl';name='js';call_id='foreign';turn_id='other-turn';arguments=(@{title='Other turn'}|ConvertTo-Json -Compress)}}|ConvertTo-Json -Compress -Depth 8
$script:activityTail=$start+"`n"+$response+"`n"+$foreign
Assert-Activity 'Checking screenshot stability' 'An operation from a different turn was displayed'
$script:activityTail=$start+"`n"+$response+"`n"+(Tool-Start 'unknown' 'PRIVATE_TITLE' 'unknown')
Assert-Activity 'Checking screenshot stability' 'An unknown tool was treated as a current operation'
$script:activityTail=$start+"`n"+$response+"`n"+(Tool-Start 'unsupported/id' 'Unsupported ID')
Assert-Activity 'Checking screenshot stability' 'An unverified call ID format was treated as current'
if (Codex-CurrentToolActivity @($firstTool) 'new-turn') { throw 'An operation without a visible turn boundary was treated as current.' }
if (Codex-CurrentToolActivity @($start,$firstTool) 'other-turn') { throw 'An operation was attributed to a different turn.' }
$endTurn='{"type":"event_msg","payload":{"type":"task_complete","turn_id":"new-turn"}}'
if (Codex-CurrentToolActivity @($start,$firstTool,$endTurn) 'new-turn') { throw 'An operation survived the end of its turn.' }
if ((Codex-CurrentToolActivity @($start,$firstTool) 'new-turn') -match 'PRIVATE_TOOL') { throw 'Private tool arguments were displayed.' }

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
$ordinaryEvents=('{"type":"event_msg","payload":{"type":"token_count","input_tokens":12}}'+"`n")*5000
$script:activityTail=$start+"`n"+$response+"`n"+$ordinaryEvents+$firstTool
$watch.Restart()
Assert-Activity 'Checking the window' 'A long valid turn lost its open operation'
$watch.Stop()
if($watch.ElapsedMilliseconds -gt 2000){throw "A 5,000-event open operation blocked the two-second refresh: $($watch.ElapsedMilliseconds) ms."}
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+$ordinaryEvents
Assert-Activity 'Checking screenshot stability' 'An operation outside the bounded window was reported as current'
$script:activityTail=$start+"`n"+$response+"`n"+$firstTool+"`n"+$firstEnd+"`n"+$ordinaryEvents+$firstTool
Assert-Activity 'Checking screenshot stability' 'An old completed operation was revived across the bounded window'
$escapedStart=$firstTool.Replace('call-1','call-\u0031')
$escapedEnd=$firstEnd.Replace('call-1','call-\u0031')
$script:activityTail=$start+"`n"+$response+"`n"+$escapedStart+"`n"+$escapedEnd+"`n"+$ordinaryEvents+$firstTool
Assert-Activity 'Checking screenshot stability' 'An escaped old call ID was revived across the bounded window'
Write-Output "Codex activity: current and legacy summaries, turn reset, commentary fallback and privacy verified; 5,000 events with an open operation in $($watch.ElapsedMilliseconds) ms."
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))
