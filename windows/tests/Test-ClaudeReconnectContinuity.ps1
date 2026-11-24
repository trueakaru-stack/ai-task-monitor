$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\app\ClaudeReaderCore.ps1')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Event([string]$id,[string]$kind,[DateTime]$time,[bool]$active,[string]$phase=''){
 $record=@{timestamp=$time.ToString('o');session_id=$id;event=$kind;active=$active;tool_name='Read'}
 if($phase){$record.stage_phase=$phase;$record.stage_version=1}
 return ($record|ConvertTo-Json -Compress)
}
$clock=[DateTime]::UtcNow
$firstTime=$clock.AddSeconds(-20);$boundary=$clock.AddSeconds(-10);$nextTime=$clock.AddSeconds(-5)
$first=Event 'synthetic-session' 'UserPromptSubmit' $firstTime $true
$next=Event 'synthetic-session' 'PreToolUse' $nextTime $true
$stop=Event 'synthetic-session' 'Stop' $nextTime.AddSeconds(1) $false 'stop_clear'

$reader=[AITaskMonitor.Claude.SessionReader]::new()
$initial=@($reader.Read($first,'',$firstTime.AddSeconds(1),$firstTime.AddSeconds(-10)))
Require ($initial.Count -eq 1 -and -not $initial[0].Unconfirmed) 'The synthetic starting event was not confirmed.'
$reader.MarkSourceLoss()
$lost=@($reader.Read($first,'',$boundary,$firstTime.AddSeconds(-10)))
Require ($lost.Count -eq 1 -and $lost[0].Unconfirmed) 'Source loss did not retain the prior card as unconfirmed.'
$afterNewEvent=@($reader.Read(($first+"`n"+$next),'',$clock,$firstTime.AddSeconds(-10)))
Require ($afterNewEvent.Count -eq 1 -and $afterNewEvent[0].Unconfirmed) 'A damaged source reader incorrectly restored confirmation.'

# A new epoch must not treat an old event as a new observation. A later event
# can confirm the new epoch; an explicit clear stop then removes that task.
$newReader=[AITaskMonitor.Claude.SessionReader]::new()
$oldOnly=@($newReader.Read($first,'',$clock,$boundary))
Require ($oldOnly.Count -eq 0) 'The new epoch confirmed an event from before reconnection.'
$resumed=@($newReader.Read(($first+"`n"+$next),'',$clock,$boundary))
Require ($resumed.Count -eq 1 -and -not $resumed[0].Unconfirmed -and $resumed[0].Id -ceq 'synthetic-session') 'A fresh event did not confirm the new epoch.'
$stopped=@($newReader.Read(($first+"`n"+$next+"`n"+$stop),'',$clock,$boundary))
Require ($stopped.Count -eq 0) 'A confirmed stop in the new epoch did not remove the task.'
Write-Output 'Claude SessionReader: source loss stays unconfirmed; a fresh reader distinguishes pre-boundary events, new activity and a confirmed stop on synthetic input.'
