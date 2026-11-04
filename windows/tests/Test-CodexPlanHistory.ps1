$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The application source failed to parse.' }
$definitions = foreach ($name in @('Prop', 'Read-TailText', 'Codex-Plan')) {
    $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true)
    if ($null -eq $node) { throw "Missing function: $name" }
    $node.Extent.Text
}
$path = Join-Path ([IO.Path]::GetTempPath()) ('aitm-plan-history-' + [Guid]::NewGuid().ToString('N') + '.jsonl')
$checks = @'
$script:planPath=$args[0]
$script:planCache=@{}
$script:planConfirmations=@{}
function Session-File([string]$id) { return $script:planPath }
function Add-Record($record) {
    $line=$record|ConvertTo-Json -Compress -Depth 20
    [IO.File]::AppendAllText($script:planPath,($line+"`n"),[Text.UTF8Encoding]::new($false))
}
function Add-Plan([string]$title) {
    $payload=@{plan=@(@{step=$title;status='in_progress'})}|ConvertTo-Json -Compress -Depth 10
    Add-Record @{type='response_item';payload=@{type='function_call';name='update_plan';arguments=$payload}}
}
Add-Record @{type='event_msg';payload=@{type='task_started';turn_id='one'}}
Add-Plan 'First synthetic plan'
$filler = '{"type":"response_item","payload":{"text":"' + ('x'*65536) + '"}}' + "`n"
for ($i=0; $i -lt 66; $i++) { [IO.File]::AppendAllText($script:planPath,$filler,[Text.UTF8Encoding]::new($false)) }
$steps=@(Codex-Plan 'session')
if ($steps.Count -ne 1 -or $steps[0].title -ne 'First synthetic plan') { throw 'A current plan beyond a 4 MiB tail must remain visible.' }
if (-not $script:planConfirmations['session']) { throw 'A plan published in the current turn must be confirmed.' }
Add-Record @{type='event_msg';payload=@{type='task_complete';turn_id='one'}}
Add-Record @{type='event_msg';payload=@{type='task_started';turn_id='two'}}
$steps=@(Codex-Plan 'session')
if ($steps.Count -ne 1 -or $script:planConfirmations['session']) { throw 'A carried-over plan must remain visible but unconfirmed.' }
Add-Plan 'Second synthetic plan'
$steps=@(Codex-Plan 'session')
if ($steps.Count -ne 1 -or $steps[0].title -ne 'Second synthetic plan' -or -not $script:planConfirmations['session']) { throw 'A new plan must replace and confirm the earlier plan.' }
$partial = '{"type":"event_msg","payload":{"type":"task_started","turn_id":"three"}}'
[IO.File]::AppendAllText($script:planPath,$partial,[Text.UTF8Encoding]::new($false))
$steps=@(Codex-Plan 'session')
if (-not $script:planConfirmations['session']) { throw 'An incomplete JSONL line must not change confirmation state.' }
[IO.File]::AppendAllText($script:planPath,"`n",[Text.UTF8Encoding]::new($false))
$steps=@(Codex-Plan 'session')
if ($script:planConfirmations['session']) { throw 'A completed line after an append must update confirmation state.' }
$empty=@{plan=@()}|ConvertTo-Json -Compress
Add-Record @{type='response_item';payload=@{type='function_call';name='update_plan';arguments=$empty}}
if (@(Codex-Plan 'session').Count -ne 0) { throw 'An explicitly empty plan must clear prior steps.' }
[IO.File]::WriteAllText($script:planPath,'{"type":"event_msg","payload":{"type":"task_started","turn_id":"replacement"}}' + "`n",[Text.UTF8Encoding]::new($false))
if (@(Codex-Plan 'session').Count -ne 0) { throw 'A replaced or truncated session must not reuse an old plan.' }
$shortPlan=@{plan=@(@{step='Alpha';status='in_progress'})}|ConvertTo-Json -Compress -Depth 10
$lineA=(@{type='response_item';payload=@{type='function_call';name='update_plan';arguments=$shortPlan}}|ConvertTo-Json -Compress -Depth 20)+"`n"
$suffix=('{"type":"response_item","payload":{"text":"'+('z'*200)+'"}}'+"`n")
[IO.File]::WriteAllText($script:planPath,($lineA+$suffix),[Text.UTF8Encoding]::new($false))
if (@(Codex-Plan 'session')[0].title -ne 'Alpha') { throw 'The rewritten plan fixture did not load.' }
$lineB=$lineA.Replace('Alpha','Bravo')
[IO.File]::WriteAllText($script:planPath,($lineB+$suffix),[Text.UTF8Encoding]::new($false))
[IO.File]::SetLastWriteTimeUtc($script:planPath,[DateTime]::UtcNow.AddSeconds(1))
if (@(Codex-Plan 'session')[0].title -ne 'Bravo') { throw 'A same-length rewrite must not reuse the stale plan cache.' }
Write-Output 'Codex plans: long history, unconfirmed continuation, replacement and clearing verified.'
'@
try { & ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks)) $path }
finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
