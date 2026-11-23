$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application source could not be parsed.' }
$definitions = foreach ($name in @('Prop', 'Codex-TurnStartIndex', 'Codex-ContainsIdentifier', 'Codex-CurrentToolActivity', 'Codex-FigmaCompleted', 'Codex-FirstFigmaCompletion', 'Codex-Activity', 'Codex-ObservedActivity')) {
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
$completed = '{"type":"event_msg","payload":{"type":"item_completed","thread_id":"fixture","turn_id":"new-turn","item":{"type":"Reasoning","summary_text":["**Check build**"]}}}'
$comment = '{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Preparing check"}]}}'
$rolelessComment = '{"type":"response_item","payload":{"type":"message","phase":"commentary","content":[{"type":"output_text","text":"PRIVATE_ROLELESS_TEXT"}]}}'
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
$script:resolvedLanguage='en'
$figmaItem=@{type='McpToolCall';id='figma-call-1';server='codex_apps';tool='figma.use_figma';status='completed';arguments=@{description='Checking components';code='PRIVATE_FIGMA_CODE'};result=@{isError=$false}}
$figma=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=$figmaItem}}|ConvertTo-Json -Compress -Depth 12
$script:activityTail=$start+"`n"+$response+"`n"+$figma
Assert-Activity 'Last Figma action: Checking components' 'The recent completed Figma description was not identified'
if((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Last Figma action: Checking components'){throw 'The recent Figma action was not found in observed activity.'}
$script:activityTail=$start+"`n"+$figma+"`n"+$response
Assert-Activity 'Checking screenshot stability' 'An older Figma action hid a newer summary'
$script:activityTail=$start+"`n"+$figma+"`n"+$response+"`n"+$figma
Assert-Activity 'Checking screenshot stability' 'A duplicated Figma event hid a newer summary'
$otherAction=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=@{type='CommandExecution';id='other-1'}}}|ConvertTo-Json -Compress -Depth 8
$script:activityTail=$start+"`n"+$response+"`n"+$figma+"`n"+$otherAction
Assert-Activity 'Checking screenshot stability' 'An older Figma action hid a later different action'
$ambiguousAction='{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution"}}}'
$script:activityTail=$start+"`n"+$response+"`n"+$figma+"`n"+$ambiguousAction
Assert-Activity 'Checking screenshot stability' 'An action with unknown identity left an older Figma action current'
$wrongFigma=@{type='event_msg';payload=@{type='item_completed';thread_id='other';turn_id='new-turn';item=$figmaItem}}|ConvertTo-Json -Compress -Depth 12
$script:activityTail=$start+"`n"+$response+"`n"+$wrongFigma
Assert-Activity 'Checking screenshot stability' 'A Figma action from a different chat was displayed'
$failedItem=@{};foreach($key in $figmaItem.Keys){$failedItem[$key]=$figmaItem[$key]};$failedItem.status='failed'
$failedFigma=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=$failedItem}}|ConvertTo-Json -Compress -Depth 12
$script:activityTail=$start+"`n"+$response+"`n"+$failedFigma
Assert-Activity 'Checking screenshot stability' 'A failed Figma call was reported as a completed action'
$script:activityTail=$start+"`n"+$figma+"`n"+$firstTool
Assert-Activity 'Checking the window' 'An open confirmed operation lost priority over a completed Figma action'
if((Codex-Activity 'fixture') -match 'PRIVATE_FIGMA_CODE'){throw 'Figma code was exposed in activity.'}

$figmaFallback=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=@{type='Reasoning';id='fallback';summary_text=@('**Expected fallback**')}}}|ConvertTo-Json -Compress -Depth 8
$figmaFailures=New-Object 'Collections.Generic.List[string]'
function Check-FigmaPair([string]$label,[string]$expectedMain,[string]$expectedObserved) {
 $main=[string](Codex-Activity 'fixture');$observed=[string](Codex-ObservedActivity 'fixture' 'turn:new-turn')
 if($main -cne $expectedMain){$figmaFailures.Add("$label`: main returned '$main'")}
 if($observed -cne $expectedObserved){$figmaFailures.Add("$label`: observed returned '$observed'")}
}
$unscopedEarlierComment='{"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"Earlier unscoped commentary"}}'
$script:activityTail=$unscopedEarlierComment+"`n"+$start
Check-FigmaPair 'earlier commentary before current turn' '' ''
$script:activityTail=$unscopedEarlierComment
Check-FigmaPair 'commentary without visible turn boundary' 'Earlier unscoped commentary' 'Earlier unscoped commentary'
$errorItem=@{};foreach($key in $figmaItem.Keys){$errorItem[$key]=$figmaItem[$key]};$errorItem.id='figma-error';$errorItem.result=@{isError=$true}
$resultError=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=$errorItem}}|ConvertTo-Json -Compress -Depth 12
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$resultError
Check-FigmaPair 'error result' 'Expected fallback' 'Expected fallback'
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$resultError
Check-FigmaPair 'later error result' 'Expected fallback' 'Expected fallback'
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$failedFigma+"`n"+$figma
Check-FigmaPair 'failed completion followed by same ID' 'Expected fallback' 'Expected fallback'
$escapedFailure=$failedFigma.Replace('figma-call-1','figma-call-\u0031')
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$escapedFailure+"`n"+$figma
Check-FigmaPair 'failed escaped ID followed by completion' 'Expected fallback' 'Expected fallback'
$laterComment=@{type='event_msg';payload=@{type='agent_message';thread_id='fixture';turn_id='new-turn';phase='commentary';message='Newest status'}}|ConvertTo-Json -Compress
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$laterComment
Check-FigmaPair 'later commentary' 'Newest status' 'Newest status'
$script:activityTail=$start+"`n"+$laterComment+"`n"+$figmaFallback
Check-FigmaPair 'later summary' 'Expected fallback' 'Expected fallback'
$assistantNarration=@{type='response_item';payload=@{type='message';role='assistant';phase='commentary';content=@(@{type='output_text';text='Assistant update'})}}|ConvertTo-Json -Compress -Depth 8
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$assistantNarration
Check-FigmaPair 'later assistant message' 'Assistant update' 'Assistant update'
$userNarration=@{type='response_item';payload=@{type='message';role='user';phase='commentary';content=@(@{type='output_text';text='PRIVATE_USER_TEXT'})}}|ConvertTo-Json -Compress -Depth 8
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$userNarration
Check-FigmaPair 'user message must not replace Figma' 'Last Figma action: Checking components' 'Last Figma action: Checking components'
$nullRole=@{type='response_item';payload=@{type='message';role=$null;phase='commentary';content=@(@{type='output_text';text='PRIVATE_NULL_ROLE'})}}|ConvertTo-Json -Compress -Depth 8
$otherRole=@{type='response_item';payload=@{type='message';role='system';phase='commentary';content=@(@{type='output_text';text='PRIVATE_SYSTEM_ROLE'})}}|ConvertTo-Json -Compress -Depth 8
$mixedCaseRole=@{type='response_item';payload=@{type='message';role='Assistant';phase='commentary';content=@(@{type='output_text';text='PRIVATE_MIXED_ROLE'})}}|ConvertTo-Json -Compress -Depth 8
foreach($untrusted in @($rolelessComment,$nullRole,$otherRole,$mixedCaseRole,$userNarration)){
 $script:activityTail=$start+"`n"+$figmaFallback+"`n"+$untrusted
 Check-FigmaPair 'untrusted commentary role' 'Expected fallback' 'Expected fallback'
}
$spoofAgent=@{type='event_msg';payload=@{type='agent_message';thread_id='fixture';turn_id='new-turn';role='user';phase='commentary';message='PRIVATE_SPOOFED_AGENT'}}|ConvertTo-Json -Compress
$spoofItem=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=@{type='AgentMessage';role='user';phase='commentary';content=@(@{type='Text';text='PRIVATE_SPOOFED_ITEM'})}}}|ConvertTo-Json -Compress -Depth 8
foreach($untrusted in @($spoofAgent,$spoofItem)){
 $script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$untrusted
 Check-FigmaPair 'explicit user role must not replace Figma' 'Last Figma action: Checking components' 'Last Figma action: Checking components'
}
$figmaWrongTurn=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='other-turn';item=$figmaItem}}|ConvertTo-Json -Compress -Depth 12
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figmaWrongTurn
Check-FigmaPair 'Figma from another turn' 'Expected fallback' 'Expected fallback'
$foreignComment=@{type='event_msg';payload=@{type='agent_message';thread_id='fixture';turn_id='other-turn';phase='commentary';message='FOREIGN_TURN'}}|ConvertTo-Json -Compress
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$foreignComment
Check-FigmaPair 'commentary from another turn' 'Last Figma action: Checking components' 'Last Figma action: Checking components'
$caseTurnComment=@{type='event_msg';payload=@{type='agent_message';thread_id='fixture';turn_id='NEW-TURN';phase='commentary';message='PRIVATE_CASE_TURN'}}|ConvertTo-Json -Compress
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$caseTurnComment
Check-FigmaPair 'turn IDs are case-sensitive' 'Last Figma action: Checking components' 'Last Figma action: Checking components'
$foreignThread=@{type='event_msg';payload=@{type='agent_message';thread_id='other';turn_id='new-turn';phase='commentary';message='FOREIGN_THREAD'}}|ConvertTo-Json -Compress
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$foreignThread
Check-FigmaPair 'commentary from another chat' 'Last Figma action: Checking components' 'Last Figma action: Checking components'
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$figma
Check-FigmaPair 'duplicate Figma completion' 'Expected fallback' 'Expected fallback'
$conflictItem=@{};foreach($key in $figmaItem.Keys){$conflictItem[$key]=$figmaItem[$key]};$conflictItem.arguments=@{description='Conflicting description';code='PRIVATE_CONFLICT'}
$conflictingFigma=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=$conflictItem}}|ConvertTo-Json -Compress -Depth 12
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$conflictingFigma
Check-FigmaPair 'conflicting duplicate Figma' 'Expected fallback' 'Expected fallback'
$script:activityTail=$start+"`n"+$figma+"`n"+$figmaFallback+"`n"+$figma
Check-FigmaPair 'duplicate after newer summary' 'Expected fallback' 'Expected fallback'
$secondFigmaItem=@{};foreach($key in $figmaItem.Keys){$secondFigmaItem[$key]=$figmaItem[$key]};$secondFigmaItem.id='figma-call-2';$secondFigmaItem.arguments=@{description='Second design action';code='PRIVATE_SECOND_CODE'}
$secondFigma=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=$secondFigmaItem}}|ConvertTo-Json -Compress -Depth 12
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$secondFigma+"`n"+$figma
Check-FigmaPair 'duplicate after newer action' 'Expected fallback' 'Expected fallback'
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+'{"incomplete":'
Check-FigmaPair 'malformed after Figma' 'Expected fallback' 'Expected fallback'
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+'{"type":"event_msg"}'
Check-FigmaPair 'missing payload after Figma' 'Expected fallback' 'Expected fallback'
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+"`n"+$unicodeEnd
Check-FigmaPair 'oversized UTF-8 output after Figma' 'Expected fallback' 'Expected fallback'
$unboundReason=@{type='event_msg';payload=@{type='item_completed';turn_id='new-turn';item=@{type='Reasoning';summary_text=@('PRIVATE_UNBOUND_REASON')}}}|ConvertTo-Json -Compress -Depth 8
$unboundTurn=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';item=@{type='Reasoning';summary_text=@('PRIVATE_UNBOUND_TURN')}}}|ConvertTo-Json -Compress -Depth 8
$wrongRecordType=@{type='response_item';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=@{type='Reasoning';summary_text=@('PRIVATE_WRONG_RECORD')}}}|ConvertTo-Json -Compress -Depth 8
foreach($untrusted in @($unboundReason,$unboundTurn,$wrongRecordType)){
 $script:activityTail=$start+"`n"+$figmaFallback+"`n"+$untrusted
 Check-FigmaPair 'unbound item reasoning' 'Expected fallback' 'Expected fallback'
}
if($figmaFailures.Count){throw ($figmaFailures -join "`n")}
$figmaStress=New-Object 'Collections.Generic.List[string]'
for($stressIndex=0;$stressIndex -lt 300;$stressIndex++){
 $stressItem=@{type='McpToolCall';id="stress-$stressIndex";server='codex_apps';tool='figma.use_figma';status='completed';arguments=@{description="Synthetic $stressIndex"}}
 $stressRecord=@{type='event_msg';payload=@{type='item_completed';thread_id='fixture';turn_id='new-turn';item=$stressItem}}|ConvertTo-Json -Compress -Depth 8
 $figmaStress.Add($stressRecord)
}
$figmaFlood=$figmaStress -join "`n"
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figmaFlood+"`n"+$figmaFlood
$figmaWatch=[Diagnostics.Stopwatch]::StartNew()
Assert-Activity 'Expected fallback' 'An oversized Figma event set did not safely fall back'
$figmaWatch.Stop();$figmaMainMs=$figmaWatch.ElapsedMilliseconds
$figmaWatch.Restart()
if((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Expected fallback'){throw 'Observed Figma activity did not safely fall back under duplicate load.'}
$figmaWatch.Stop();$figmaObservedMs=$figmaWatch.ElapsedMilliseconds
if($figmaMainMs -gt 2000 -or $figmaObservedMs -gt 2000){throw "Figma duplicate handling exceeded two seconds: main=$figmaMainMs ms, observed=$figmaObservedMs ms."}
Write-Output "Figma duplicate load: main=$figmaMainMs ms, observed=$figmaObservedMs ms."
$manyUnique=@($figmaStress | Select-Object -First 129) -join "`n"
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$manyUnique
Assert-Activity 'Last Figma action: Synthetic 128' 'A new Figma action was lost in a long turn'
if((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Last Figma action: Synthetic 128'){throw 'Observed Figma activity was lost in a long turn.'}
$figmaOrdinary=('{"type":"event_msg","payload":{"type":"token_count"}}'+"`n")*5000
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figmaOrdinary+$figma
$figmaWatch.Restart()
Assert-Activity 'Last Figma action: Checking components' 'A recent Figma action was lost in a long turn'
$figmaWatch.Stop();$figmaLongMs=$figmaWatch.ElapsedMilliseconds
if($figmaLongMs -gt 2000){throw "A long turn with a Figma action exceeded two seconds: $figmaLongMs ms."}
Write-Output "Figma in 5,000-event turn: $figmaLongMs ms."
$ordinaryAfter='{"type":"event_msg","payload":{"type":"token_count"}}'
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+(("`n"+$ordinaryAfter)*512)
Assert-Activity 'Last Figma action: Checking components' 'Figma action was lost at the trailing-window limit'
if((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Last Figma action: Checking components'){throw 'Observed Figma action was lost at the trailing-window limit.'}
$script:activityTail+="`n"+$ordinaryAfter
Assert-Activity 'Expected fallback' 'Figma was displayed beyond the trailing-window limit'
if((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Expected fallback'){throw 'Observed Figma activity exceeded the trailing-window limit.'}
$script:activityTail=$start+"`n"+$figmaFallback+"`n"+$figma+(("`n"+$ordinaryAfter)*5000)
$figmaWatch.Restart()
Assert-Activity 'Expected fallback' 'Figma remained current after a long trailing sequence'
$figmaWatch.Stop();$figmaAfterMainMs=$figmaWatch.ElapsedMilliseconds
$figmaWatch.Restart()
if((Codex-ObservedActivity 'fixture' 'turn:new-turn') -cne 'Expected fallback'){throw 'Observed Figma remained current after a long trailing sequence.'}
$figmaWatch.Stop();$figmaAfterObservedMs=$figmaWatch.ElapsedMilliseconds
if($figmaAfterMainMs -gt 2000 -or $figmaAfterObservedMs -gt 2000){throw "Figma followed by 5,000 events exceeded two seconds: main=$figmaAfterMainMs ms, observed=$figmaAfterObservedMs ms."}
Write-Output "Figma followed by 5,000 events: main=$figmaAfterMainMs ms, observed=$figmaAfterObservedMs ms."
$script:resolvedLanguage='ru'
$script:activityTail = $start + "`n" + $response + "`n" + $completed
Assert-Activity 'Check build' 'Completed reasoning summary was ignored'
$script:activityTail = $response + "`n" + $comment
Assert-Activity 'Preparing check' 'A newer commentary was not selected'
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
$script:activityTail = $start + "`n" + $response + "`n" + $rolelessComment
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
$script:activityTail = $start + "`n" + '{invalid json}' + "`n" + $completed
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
