function New-CodexLoopTracker {
 param(
  [Parameter(Mandatory=$true)][byte[]]$Key,
  [Parameter(Mandatory=$true)][DateTimeOffset]$Since,
  [ValidateRange(3,10)][int]$Threshold=5,
  [ValidateRange(1,30)][int]$WindowMinutes=10
 )
 if($Key.Length -lt 32){throw "The loop comparison key must contain at least 32 bytes."}
 return [PSCustomObject]@{
  Key=$Key;Since=$Since.ToUniversalTime();Threshold=$Threshold;WindowMinutes=$WindowMinutes
  Fingerprint="";ExitCode=$null;Times=(New-Object 'Collections.Generic.List[DateTimeOffset]')
  Seen=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal));SeenOrder=(New-Object 'Collections.Generic.Queue[string]')
  Warning=$false;Dismissed=$false
 }
}

function Copy-CodexLoopTracker($Tracker) {
 $copy=New-CodexLoopTracker -Key $Tracker.Key -Since $Tracker.Since -Threshold $Tracker.Threshold -WindowMinutes $Tracker.WindowMinutes
 $copy.Fingerprint=$Tracker.Fingerprint;$copy.ExitCode=$Tracker.ExitCode;$copy.Warning=$Tracker.Warning;$copy.Dismissed=$Tracker.Dismissed
 foreach($time in $Tracker.Times){$copy.Times.Add($time)}
 foreach($id in $Tracker.SeenOrder){if($copy.Seen.Add($id)){$copy.SeenOrder.Enqueue($id)}}
 return $copy
}

function Reset-CodexLoopSequence($Tracker) {
 $Tracker.Fingerprint="";$Tracker.ExitCode=$null;$Tracker.Times.Clear();$Tracker.Warning=$false;$Tracker.Dismissed=$false
}

function Get-CodexLoopDigest([byte[]]$Key,[string]$Context,[string]$Value) {
 $hmac=[Security.Cryptography.HMACSHA256]::new($Key)
 try{
  $bytes=[Text.Encoding]::UTF8.GetBytes($Context+"`0"+$Value)
  return [BitConverter]::ToString($hmac.ComputeHash($bytes)).Replace("-","").ToLowerInvariant()
 }finally{$hmac.Dispose()}
}

function Get-CodexCommandDigest($Tracker,$Item) {
 # Access the property directly: the shared helper unwraps a one-item array
 # into a scalar, which otherwise prevents single-argument commands matching.
 $commandProperty=if($null -ne $Item){$Item.PSObject.Properties["command"]}else{$null}
 if($null -eq $commandProperty){return ""}
 $command=$commandProperty.Value
 $cwd=Get-DiagnosticProperty $Item "cwd"
 if($command -isnot [array] -or $command.Count -eq 0 -or $command.Count -gt 256 -or $cwd -isnot [string] -or $cwd.Length -gt 32768){return ""}
 $builder=New-Object Text.StringBuilder
 [void]$builder.Append($cwd.Length).Append(":").Append($cwd)
 foreach($argument in $command){
  if($argument -isnot [string] -or $argument.Length -gt 32768 -or $builder.Length+$argument.Length -gt 131072){return ""}
  [void]$builder.Append($argument.Length).Append(":").Append($argument)
 }
 return Get-CodexLoopDigest $Tracker.Key "command" $builder.ToString()
}

function Update-CodexLoopTracker($Tracker,$Record,[DateTimeOffset]$Now) {
 if([string](Get-DiagnosticProperty $Record "type" "") -cne "event_msg"){return}
 $payload=Get-DiagnosticProperty $Record "payload"
 $eventType=[string](Get-DiagnosticProperty $payload "type" "")
 if($eventType -cnotin @("item_started","item_completed")){return}
 $item=Get-DiagnosticProperty $payload "item"
 $itemType=[string](Get-DiagnosticProperty $item "type" "")
 if($itemType -cnotin @("CommandExecution","FileChange")){return}
 $reference=[string](Get-DiagnosticProperty $item "id" "")
 $time=Get-DiagnosticTimestamp (Get-DiagnosticProperty $Record "timestamp")
 if($reference -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $null -eq $time -or $time -lt $Tracker.Since -or $time -gt $Now.ToUniversalTime().AddMinutes(5)){return}
 $eventKey=Get-CodexLoopDigest $Tracker.Key "event" ($eventType+"`0"+$itemType+"`0"+$reference)
 if(-not $Tracker.Seen.Add($eventKey)){return}
 $Tracker.SeenOrder.Enqueue($eventKey)
 while($Tracker.SeenOrder.Count -gt 4096){[void]$Tracker.Seen.Remove($Tracker.SeenOrder.Dequeue())}
 if($itemType -ceq "FileChange"){if($eventType -ceq "item_completed"){Reset-CodexLoopSequence $Tracker};return}
 if($eventType -ceq "item_started"){
  $startedFingerprint=Get-CodexCommandDigest $Tracker $item
  if($Tracker.Fingerprint -and (-not $startedFingerprint -or $Tracker.Fingerprint -cne $startedFingerprint)){Reset-CodexLoopSequence $Tracker}
  return
 }
 $status=[string](Get-DiagnosticProperty $item "status" "")
 $exitCode=Get-DiagnosticProperty $item "exit_code"
 if($status -cne "failed" -or ($exitCode -isnot [int] -and $exitCode -isnot [long]) -or $exitCode -eq 0){Reset-CodexLoopSequence $Tracker;return}
 $fingerprint=Get-CodexCommandDigest $Tracker $item
 if(-not $fingerprint){Reset-CodexLoopSequence $Tracker;return}
 if($Tracker.Fingerprint -cne $fingerprint -or $Tracker.ExitCode -ne $exitCode -or ($Tracker.Times.Count -gt 0 -and $time -lt $Tracker.Times[$Tracker.Times.Count-1])){
  Reset-CodexLoopSequence $Tracker
  $Tracker.Fingerprint=$fingerprint;$Tracker.ExitCode=$exitCode
 }
 $cutoff=$time.AddMinutes(-$Tracker.WindowMinutes)
 while($Tracker.Times.Count -gt 0 -and $Tracker.Times[0] -lt $cutoff){$Tracker.Times.RemoveAt(0)}
 if($Tracker.Times.Count -lt $Tracker.Threshold -and $Tracker.Warning){$Tracker.Warning=$false;$Tracker.Dismissed=$false}
 $Tracker.Times.Add($time)
 while($Tracker.Times.Count -gt 10){$Tracker.Times.RemoveAt(0)}
 if($Tracker.Times.Count -ge $Tracker.Threshold){$Tracker.Warning=$true}
}

function Refresh-CodexLoopTracker($Tracker,[DateTimeOffset]$Now) {
 $cutoff=$Now.ToUniversalTime().AddMinutes(-$Tracker.WindowMinutes)
 while($Tracker.Times.Count -gt 0 -and $Tracker.Times[0] -lt $cutoff){$Tracker.Times.RemoveAt(0)}
 if($Tracker.Times.Count -lt $Tracker.Threshold){$Tracker.Warning=$false;$Tracker.Dismissed=$false}
}
