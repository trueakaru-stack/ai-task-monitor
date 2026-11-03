$ErrorActionPreference='Stop'
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
. (Join-Path $appRoot 'DiagnosticPolicy.ps1')
. (Join-Path $appRoot 'ClaudeLoopDetection.ps1')
$now=[DateTimeOffset]::UtcNow
$same='a'*64;$different='b'*64
function Event([string]$kind,[string]$id,[string]$fingerprint=$same,$code=7,[DateTimeOffset]$time=$now){
 return [PSCustomObject]@{Kind=$kind;ToolId=$id;Fingerprint=$fingerprint;ExitCode=$code;Time=$time}
}
function Attempt($tracker,[string]$id,[string]$fingerprint=$same,$code=7,[DateTimeOffset]$time=$now){
 Update-ClaudeLoopTracker $tracker (Event 'start' $id $fingerprint $null $time) $time
 Update-ClaudeLoopTracker $tracker (Event 'failed' $id $fingerprint $code $time) $time
}
$tracker=New-ClaudeLoopTracker
for($i=1;$i -le 4;$i++){Attempt $tracker ('a'+$i)}
if($tracker.Warning -or $tracker.Times.Count -ne 4){throw 'A warning appeared before the threshold.'}
Attempt $tracker 'a5'
if(-not $tracker.Warning -or $tracker.Times.Count -ne 5){throw 'Five matching failures did not produce a warning.'}
$tracker.Dismissed=$true
Attempt $tracker 'a6'
if(-not $tracker.Warning -or -not $tracker.Dismissed){throw 'Dismissal did not persist for the same sequence.'}
Update-ClaudeLoopTracker $tracker (Event 'edit' '') $now
if($tracker.Warning -or $tracker.Dismissed -or $tracker.Times.Count -ne 0){throw 'A file edit did not reset the sequence.'}

for($i=1;$i -le 4;$i++){Attempt $tracker ('different'+$i)}
Attempt $tracker 'different5' $different
if($tracker.Warning -or $tracker.Times.Count -ne 1){throw 'A different command did not reset the sequence.'}
Attempt $tracker 'different6' $different 3
if($tracker.Warning -or $tracker.Times.Count -ne 1){throw 'A different exit code did not reset the sequence.'}
Update-ClaudeLoopTracker $tracker (Event 'start' 'success' $different $null) $now
Update-ClaudeLoopTracker $tracker (Event 'success' 'success' $different $null) $now
if($tracker.Times.Count -ne 0 -or $tracker.Warning){throw 'A successful command did not reset the sequence.'}

Attempt $tracker 'duplicate'
Update-ClaudeLoopTracker $tracker (Event 'failed' 'duplicate') $now
if($tracker.Times.Count -ne 1){throw 'A duplicate failure was counted twice.'}
Update-ClaudeLoopTracker $tracker (Event 'failed' 'unmatched') $now
if($tracker.Times.Count -ne 0){throw 'An unmatched failure must reset the sequence.'}
Update-ClaudeLoopTracker $tracker (Event 'start' 'unknown') $now
Update-ClaudeLoopTracker $tracker (Event 'reset' '') $now
if($tracker.Times.Count -ne 0 -or $tracker.InFlight.Count -ne 0){throw 'An unknown or interrupted result must reset the sequence.'}

Update-ClaudeLoopTracker $tracker (Event 'start' 'parallel-a') $now
Update-ClaudeLoopTracker $tracker (Event 'start' 'parallel-b') $now
Update-ClaudeLoopTracker $tracker (Event 'failed' 'parallel-a') $now
Update-ClaudeLoopTracker $tracker (Event 'failed' 'parallel-b') $now
if($tracker.Warning -or $tracker.Times.Count -ne 0 -or $tracker.Overlap){throw 'Concurrent calls were incorrectly counted as a sequence.'}
Attempt $tracker 'after-parallel'
if($tracker.Times.Count -ne 1){throw 'Monitoring did not recover after concurrent calls.'}

$second=New-ClaudeLoopTracker -Threshold 3 -WindowMinutes 1
for($i=1;$i -le 3;$i++){Attempt $second ('second'+$i) $same 7 $now}
if(-not $second.Warning -or $tracker.Warning){throw 'Session isolation or configurable thresholds failed.'}
Refresh-ClaudeLoopTracker $second $now.AddMinutes(2)
if($second.Warning -or $second.Times.Count -ne 0){throw 'A warning did not expire.'}

$clock=New-ClaudeLoopTracker -Threshold 3
Attempt $clock 'clock1' $same 7 $now
Update-ClaudeLoopTracker $clock (Event 'start' 'old' $same $null $now.AddMinutes(-1)) $now
if($clock.Times.Count -ne 0 -or $clock.InFlight.Count -ne 0){throw 'Out-of-order events did not reset the sequence.'}
for($i=1;$i -le 3;$i++){Attempt $clock ('clock-new'+$i) $same 7 $now}
if(-not $clock.Warning){throw 'Monitoring did not recover after an out-of-order event.'}

Reset-ClaudeLoopTracker $clock
Update-ClaudeLoopTracker $clock (Event 'start' 'edit-during-command') $now
Update-ClaudeLoopTracker $clock (Event 'edit' '') $now
Update-ClaudeLoopTracker $clock (Event 'failed' 'edit-during-command') $now
if($clock.Warning -or $clock.Times.Count -ne 0){throw 'A failure concurrent with an edit was incorrectly counted.'}
Write-Output 'Claude loop detector: threshold, isolation, resets, expiry, concurrency and dismissal verified.'
