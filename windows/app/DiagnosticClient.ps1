# UI-side diagnostic mailbox. The worker owns reading, writing and tracking;
# operations remain pending until the worker acknowledges their unique IDs.
function New-DiagnosticClient($owner) {
 return [PSCustomObject]@{Owner=$owner;Warnings=@{};Error=$false;Fresh=$false;PendingClear='';PendingDismissals=@{};
  LastClearCompleted=$false;PendingStartedAt=[long]0;TimeoutMilliseconds=6000;TimedOut=$false}
}

function Invalidate-DiagnosticClientSettings($client) {
 if($null -ne $client.Owner){$client.Owner.Invalidate()}
 $client.Warnings=@{};$client.Fresh=$false;$client.PendingStartedAt=[long]0;$client.TimedOut=$false
}

function Queue-DiagnosticClear($client) {
 if($client.PendingClear){return [string]$client.PendingClear}
 $client.PendingClear=[Guid]::NewGuid().ToString('N')
 if($null -ne $client.Owner){$client.Owner.Invalidate()}
 $client.PendingStartedAt=[long]0;$client.TimedOut=$false;$client.LastClearCompleted=$false
 return [string]$client.PendingClear
}

function Queue-DiagnosticDismiss($client,[string]$id,[string]$token) {
 if($id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $token -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid diagnostic dismissal.'}
 $operation=[Guid]::NewGuid().ToString('N')
 $client.PendingDismissals[$id]=[PSCustomObject]@{Id=$id;Token=$token;Operation=$operation}
 $key='codex:'+$id
 if($client.Warnings.ContainsKey($key) -and [string]$client.Warnings[$key].Token -ceq $token){$client.Warnings[$key].Dismissed=$true}
 return $operation
}

function Add-DiagnosticPacketChunks($parts,[string]$prefix,[string[]]$records) {
 $builder=[Text.StringBuilder]::new()
 foreach($record in $records){
  if($record.Length -gt 29900){throw 'A diagnostic record is too large.'}
  if($builder.Length -gt 0 -and ($prefix.Length+$builder.Length+1+$record.Length) -gt 30000){$parts.Add($prefix+$builder.ToString());[void]$builder.Clear()}
  if($builder.Length){[void]$builder.Append(';')}
  [void]$builder.Append($record)
 }
 if($builder.Length){$parts.Add($prefix+$builder.ToString())}
}

function Get-DiagnosticClientUpdate($client,$tasks,[string[]]$unavailable) {
 $client.Fresh=$false;$client.LastClearCompleted=$false
 if($null -eq $client.Owner){$client.Error=$true;$client.Warnings=@{};return}
 $now=[Diagnostics.Stopwatch]::GetTimestamp()
 if($client.PendingStartedAt -gt 0 -and ($now-$client.PendingStartedAt) -ge ([Diagnostics.Stopwatch]::Frequency * [double]$client.TimeoutMilliseconds / 1000)){
  $client.Owner.Invalidate();$client.Warnings=@{};$client.Error=$true;$client.TimedOut=$true;$client.PendingStartedAt=$now
 }
 $result=$client.Owner.TryReceive()
 if($null -ne $result){
  $value=$result.Value;$valid=$result.Success -and $result.Generation -eq $client.Owner.Generation -and $null -ne $value
  foreach($field in @('Failed','Warnings','ClearAck','DismissAck')){if($null -eq $value -or $null -eq $value.PSObject.Properties[$field]){$valid=$false;break}}
  if($valid){
   $warnings=@{}
   foreach($warning in @($value.Warnings|Where-Object {$null -ne $_})){
    $key=[string]$warning.Key;$token=[string]$warning.Token
    if($key -cnotmatch '^codex:([A-Za-z0-9_-]{1,128})$' -or $token -cnotmatch '^[a-f0-9]{32}$' -or
       [int]$warning.Threshold -lt 3 -or [int]$warning.Threshold -gt 10 -or [int]$warning.WindowMinutes -lt 1 -or [int]$warning.WindowMinutes -gt 30){$valid=$false;break}
    $warnings[$key]=[PSCustomObject]@{Warning=[bool]$warning.Warning;Dismissed=[bool]$warning.Dismissed;Threshold=[int]$warning.Threshold;WindowMinutes=[int]$warning.WindowMinutes;Token=$token}
   }
  }
  if($valid){
   if($client.PendingClear -and [string]$value.ClearAck -ceq [string]$client.PendingClear){$client.PendingClear='';$client.LastClearCompleted=$true}
   foreach($ack in @($value.DismissAck|Where-Object {$_})){
    foreach($id in @($client.PendingDismissals.Keys)){if([string]$client.PendingDismissals[$id].Operation -ceq [string]$ack){[void]$client.PendingDismissals.Remove($id)}}
   }
   foreach($id in @($client.PendingDismissals.Keys)){
    $entry=$client.PendingDismissals[$id];$key='codex:'+ [string]$id
    if($warnings.ContainsKey($key) -and [string]$warnings[$key].Token -ceq [string]$entry.Token){$warnings[$key].Dismissed=$true}
   }
   $client.Error=[bool]$value.Failed;$client.Warnings=if($client.Error){@{}}else{$warnings}
   $client.Fresh=-not $client.Error;$client.PendingStartedAt=[long]0;$client.TimedOut=$false
  }else{$client.Error=$true;$client.Warnings=@{}}
 }
 try{
  $parts=New-Object 'Collections.Generic.List[string]';$parts.Add('poll')
  if($client.PendingClear){$parts.Add('clear:'+ [string]$client.PendingClear)}
  $codes=@();if($unavailable -ccontains 'Codex'){$codes+='codex'};if($unavailable -ccontains 'Claude Code'){$codes+='claude'}
  if($codes.Count){$parts.Add('unavailable:'+($codes -join ','))}
  $records=New-Object 'Collections.Generic.List[string]'
  foreach($task in @($tasks)){
   $provider=[string](Prop $task 'Provider' '');$id=[string](Prop $task 'Id' '');$state=[string](Prop $task 'State' '')
   if($provider -cnotin @('codex','claude') -or $id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $state -cnotin @('active','unknown')){continue}
   $records.Add($provider+','+$id+','+$state)
  }
  Add-DiagnosticPacketChunks $parts 'tasks:' $records.ToArray()
  $records.Clear()
  foreach($id in @($client.PendingDismissals.Keys)){$entry=$client.PendingDismissals[$id];$records.Add(([string]$entry.Id+','+[string]$entry.Token+','+[string]$entry.Operation))}
  Add-DiagnosticPacketChunks $parts 'dismiss:' $records.ToArray()
  if($parts.Count -gt 32){throw 'Too many diagnostic request fields.'}
  if(-not $client.Owner.Request($parts.ToArray())){throw 'The diagnostic owner is unavailable.'}
  if($client.PendingStartedAt -eq 0){$client.PendingStartedAt=$now}
 }catch{$client.Error=$true;$client.Warnings=@{}}
}
