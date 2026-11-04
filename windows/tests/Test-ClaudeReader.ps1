$ErrorActionPreference="Stop"
. (Join-Path $PSScriptRoot "..\app\ClaudeReaderCore.ps1")
$now=[DateTime]::UtcNow
$secret="SYNTHETIC_SECRET_NOT_FOR_DISPLAY"
function New-Event([string]$id,[string]$event,[DateTime]$at,$active,[string]$taskId="",[string]$subject="",[string]$status="") {
 return (@{timestamp=$at.ToString("o");session_id=$id;event=$event;active=$active;task_id=$taskId;task_subject=$subject;task_status=$status;activity=$secret;tool_name="Read"}|ConvertTo-Json -Compress)
}
$time=$now.AddSeconds(-10)
$legacy=@(
 (New-Event "observed" "TaskCreated" $time $true "step-1" "Synthetic step" "in_progress"),
 (New-Event "ghost" "UserPromptSubmit" $time $true),
 (New-Event "tie" "Stop" $time $false)
) -join "`n"
$current=@(
 (New-Event "observed" "PreToolUse" $time.AddSeconds(1) $true),
 (New-Event "tie" "UserPromptSubmit" $time $true),
 (New-Event "completed" "TaskCreated" $time $true "step-2" "Second step" "pending"),
 (New-Event "completed" "TaskCompleted" $time.AddSeconds(2) $true "step-2" "Second step" "completed"),
 (New-Event "completed" "PostToolUse" $time.AddSeconds(3) "false"),
 '{invalid json}',
 '{"timestamp":"not-a-date","session_id":"invalid","active":true}'
) -join "`n"
$tasks=@([AITaskMonitor.Claude.Reader]::Read($current,$legacy,$now))
if($tasks.Count -ne 3 -or @($tasks|Where-Object Id -eq "ghost").Count -ne 0){throw "Only observed valid sessions should be returned."}
$observed=@($tasks|Where-Object Id -eq "observed")[0]
if($observed.Steps.Count -ne 1 -or $observed.Steps[0].title -ne "Synthetic step" -or $observed.Steps[0].status -ne "active"){throw "Legacy plan data was not preserved for the observed session."}
if($observed.Steps[0].generated){throw 'A user-provided step title must not be treated as generated.'}
$unnamed=New-Event 'unnamed' 'TaskCreated' $now $true 'step-id' '' 'pending'
$unnamedTasks=@([AITaskMonitor.Claude.Reader]::Read($unnamed,'',$now))
if($unnamedTasks.Count -ne 1 -or -not $unnamedTasks[0].Steps[0].generated -or $unnamedTasks[0].Steps[0].id -ne 'step-id'){throw 'An unnamed step must be identified as generated for localization.'}
if($observed.Activity.Contains($secret)){throw "Raw event activity leaked into the view."}
$completed=@($tasks|Where-Object Id -eq "completed")[0]
if($completed.Steps.Count -ne 1 -or $completed.Steps[0].status -ne "done"){throw "The latest plan step status was not preserved."}
if(@($tasks|Where-Object Id -eq "tie").Count -ne 1){throw "A current event must take precedence over an older event at the same time."}
$afterStart=$now.AddSeconds(-2)
if(@([AITaskMonitor.Claude.Reader]::Read($current,$legacy,$now,$afterStart)).Count -ne 0){throw "Sessions without a new event after monitor startup must remain hidden."}
$newEvent=New-Event "observed" "PreToolUse" $now $true
$resumed=@([AITaskMonitor.Claude.Reader]::Read(($current+"`n"+$newEvent),$legacy,$now,$afterStart))
if($resumed.Count -ne 1 -or $resumed[0].Id -ne "observed" -or $resumed[0].Steps[0].title -ne "Synthetic step"){throw "A newly observed session must recover its legacy plan without exposing other old sessions."}
$stopped=New-Event "observed" "Stop" $now.AddSeconds(1) $false
if(@([AITaskMonitor.Claude.Reader]::Read(($current+"`n"+$newEvent+"`n"+$stopped),$legacy,$now.AddSeconds(1),$afterStart)).Count -ne 0){throw "A stopped session must not remain active."}
$quiet=New-Event "quiet" "PreToolUse" $now.AddHours(-3) $true
$quietTasks=@([AITaskMonitor.Claude.Reader]::Read($quiet,"",$now,$now.AddHours(-4)))
if($quietTasks.Count -ne 1 -or -not $quietTasks[0].Unconfirmed){throw "An observed quiet session must remain visible as unconfirmed, not disappear."}
$quietResumed=New-Event "quiet" "PostToolUse" $now $true
$quietTasks=@([AITaskMonitor.Claude.Reader]::Read(($quiet+"`n"+$quietResumed),"",$now,$now.AddHours(-4)))
if($quietTasks.Count -ne 1 -or $quietTasks[0].Unconfirmed){throw "A new activity event must restore the active state."}
$firstPrompt=New-Event "same" "UserPromptSubmit" $time $true
$normalAction=New-Event "same" "PreToolUse" $time.AddSeconds(1) $true
$firstTask=@([AITaskMonitor.Claude.Reader]::Read($firstPrompt,"",$now))[0]
$updatedTask=@([AITaskMonitor.Claude.Reader]::Read(($firstPrompt+"`n"+$normalAction),"",$now))[0]
if(-not $firstTask.StartKey -or $firstTask.StartKey -cne $updatedTask.StartKey -or $firstTask.Started -ne $updatedTask.Started){throw "A normal action changed the Claude turn identity."}
$nextPrompt=New-Event "same" "UserPromptSubmit" $time.AddSeconds(2) $true
$nextTask=@([AITaskMonitor.Claude.Reader]::Read(($firstPrompt+"`n"+$normalAction+"`n"+$nextPrompt),"",$now))[0]
if($nextTask.StartKey -ceq $firstTask.StartKey -or $nextTask.Started -le $firstTask.Started){throw "A continued Claude task did not receive a new start identity."}
$bulk=(New-Event "bulk" "PreToolUse" $now $true)+"`n"
$watch=[Diagnostics.Stopwatch]::StartNew()
$bulkTasks=@([AITaskMonitor.Claude.Reader]::Read(($bulk*5000),($bulk*5000),$now))
$watch.Stop()
if($bulkTasks.Count -ne 1){throw "The bounded large-log fixture did not retain its task."}
Write-Output "Claude reader: startup observation, migration, ordering, plans, invalid input and 10,000 events ($($watch.ElapsedMilliseconds) ms) verified."
