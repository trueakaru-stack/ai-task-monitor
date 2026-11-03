function New-ClaudeLoopTracker {
 param([ValidateRange(3,10)][int]$Threshold=5,[ValidateRange(1,30)][int]$WindowMinutes=10)
 return [PSCustomObject]@{
  Threshold=$Threshold;WindowMinutes=$WindowMinutes;Fingerprint='';ExitCode=$null
  Times=(New-Object 'Collections.Generic.List[DateTimeOffset]')
  Seen=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
  SeenOrder=(New-Object 'Collections.Generic.Queue[string]')
  InFlight=(New-Object System.Collections.Hashtable ([StringComparer]::Ordinal));Overlap=$false;Warning=$false;Dismissed=$false;LastSeen=[DateTimeOffset]::MinValue
 }
}

function Reset-ClaudeLoopSequence($Tracker) {
 $Tracker.Fingerprint='';$Tracker.ExitCode=$null;$Tracker.Times.Clear();$Tracker.Warning=$false;$Tracker.Dismissed=$false
}

function Reset-ClaudeLoopTracker($Tracker) {
 Reset-ClaudeLoopSequence $Tracker
 $Tracker.InFlight.Clear();$Tracker.Overlap=$false
}

function Refresh-ClaudeLoopTracker($Tracker,[DateTimeOffset]$Now) {
 $cutoff=$Now.ToUniversalTime().AddMinutes(-$Tracker.WindowMinutes)
 while($Tracker.Times.Count -gt 0 -and $Tracker.Times[0] -lt $cutoff){$Tracker.Times.RemoveAt(0)}
 if($Tracker.Times.Count -lt $Tracker.Threshold){$Tracker.Warning=$false;$Tracker.Dismissed=$false}
 foreach($toolId in @($Tracker.InFlight.Keys)){
  if($Tracker.InFlight[$toolId].Time -lt $cutoff){Reset-ClaudeLoopTracker $Tracker;break}
 }
}

function Update-ClaudeLoopTracker($Tracker,$Event,[DateTimeOffset]$Now) {
 $time=Get-DiagnosticProperty $Event 'Time'
 if($time -isnot [DateTimeOffset] -or $time -gt $Now.ToUniversalTime().AddMinutes(5)){Reset-ClaudeLoopTracker $Tracker;return}
 $time=$time.ToUniversalTime()
 if($Tracker.LastSeen -ne [DateTimeOffset]::MinValue -and $time -lt $Tracker.LastSeen){Reset-ClaudeLoopTracker $Tracker;$Tracker.LastSeen=$time;return}
 $Tracker.LastSeen=$time
 Refresh-ClaudeLoopTracker $Tracker $Now
 $kind=[string](Get-DiagnosticProperty $Event 'Kind' '')
 if($kind -cin @('stop','reset')){Reset-ClaudeLoopTracker $Tracker;return}
 if($kind -ceq 'edit'){
  Reset-ClaudeLoopSequence $Tracker
  if($Tracker.InFlight.Count -gt 0){$Tracker.Overlap=$true}
  return
 }
 if($kind -cnotin @('start','failed','success')){Reset-ClaudeLoopTracker $Tracker;return}
 $id=[string](Get-DiagnosticProperty $Event 'ToolId' '')
 $fingerprint=[string](Get-DiagnosticProperty $Event 'Fingerprint' '')
 if($id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $fingerprint -cnotmatch '^[a-f0-9]{64}$'){Reset-ClaudeLoopTracker $Tracker;return}
 $eventId=$kind+'|'+$id
 if(-not $Tracker.Seen.Add($eventId)){return}
 $Tracker.SeenOrder.Enqueue($eventId)
 while($Tracker.SeenOrder.Count -gt 4096){[void]$Tracker.Seen.Remove($Tracker.SeenOrder.Dequeue())}
 if($kind -ceq 'start'){
  if($Tracker.InFlight.Count -gt 0){Reset-ClaudeLoopSequence $Tracker;$Tracker.Overlap=$true}
  if($Tracker.Fingerprint -and $Tracker.Fingerprint -cne $fingerprint){Reset-ClaudeLoopSequence $Tracker}
  if($Tracker.InFlight.Count -ge 32){Reset-ClaudeLoopTracker $Tracker}
  $Tracker.InFlight[$id]=[PSCustomObject]@{Fingerprint=$fingerprint;Time=$time}
  return
 }
 if(-not $Tracker.InFlight.ContainsKey($id)){Reset-ClaudeLoopTracker $Tracker;return}
 $started=$Tracker.InFlight[$id]
 $Tracker.InFlight.Remove($id)
 if($Tracker.Overlap){
  Reset-ClaudeLoopSequence $Tracker
  if($Tracker.InFlight.Count -eq 0){$Tracker.Overlap=$false}
  return
 }
 if($started.Fingerprint -cne $fingerprint -or $kind -ceq 'success'){Reset-ClaudeLoopSequence $Tracker;return}
 $exitCode=Get-DiagnosticProperty $Event 'ExitCode'
 if(($exitCode -isnot [int] -and $exitCode -isnot [long]) -or $exitCode -eq 0){Reset-ClaudeLoopSequence $Tracker;return}
 if($Tracker.Fingerprint -cne $fingerprint -or $Tracker.ExitCode -ne $exitCode){
  Reset-ClaudeLoopSequence $Tracker
  $Tracker.Fingerprint=$fingerprint;$Tracker.ExitCode=$exitCode
 }
 $cutoff=$time.AddMinutes(-$Tracker.WindowMinutes)
 while($Tracker.Times.Count -gt 0 -and $Tracker.Times[0] -lt $cutoff){$Tracker.Times.RemoveAt(0)}
 if($Tracker.Times.Count -lt $Tracker.Threshold -and $Tracker.Warning){$Tracker.Warning=$false;$Tracker.Dismissed=$false}
 $Tracker.Times.Add($time)
 while($Tracker.Times.Count -gt 10){$Tracker.Times.RemoveAt(0)}
 if($Tracker.Times.Count -ge $Tracker.Threshold){$Tracker.Warning=$true}
}
