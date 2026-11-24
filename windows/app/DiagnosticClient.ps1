# UI-side diagnostic mailbox. The worker owns reading, writing and tracking;
# operations remain pending until the worker acknowledges their unique IDs.
function New-DiagnosticClient($owner,[scriptblock]$ownerFactory=$null) {
 return [PSCustomObject]@{Owner=$owner;Warnings=@{};Error=$false;Fresh=$false;FailureStage='';FailureKind='';PendingClear='';PendingDismissals=@{};
  LastClearCompleted=$false;LastClearUncertain=$false;PendingStartedAt=[long]0;TimeoutMilliseconds=6000;TimedOut=$false;
  Frames=[Collections.Generic.Queue[object]]::new();FrameCounter=[long]0;InFlightId=[long]0;Gap=$false;GapRevision=[long]0;ClearGapRevision=[long]0;
  PendingClearSent=$false;OwnerFactory=$ownerFactory;RetryCount=0;MaximumRetries=5;RetryDelayMilliseconds=2000;NextRetryAt=[long]0;
  FirstFreshAt=[long]0;LastFreshAt=[long]0;StableMilliseconds=30000}
}

function Set-DiagnosticClearUnconfirmed($client) {
 if($client.PendingClear -and $client.PendingClearSent){
  $client.PendingClear='';$client.PendingClearSent=$false;$client.LastClearUncertain=$true
  $client.Gap=$true;$client.GapRevision++
 }
}

function Invalidate-DiagnosticClientSettings($client) {
 Set-DiagnosticClearUnconfirmed $client
 if($null -ne $client.Owner){$client.Owner.Invalidate()}
 $client.Warnings=@{};$client.Fresh=$false;$client.PendingStartedAt=[long]0;$client.TimedOut=$false;$client.InFlightId=[long]0
}

function Queue-DiagnosticClear($client) {
 if($client.PendingClear){return [string]$client.PendingClear}
 $client.PendingClear=[Guid]::NewGuid().ToString('N')
 if($null -ne $client.Owner){$client.Owner.Invalidate()}
 $client.Frames.Clear();$client.InFlightId=[long]0;$client.ClearGapRevision=$client.GapRevision
 $client.PendingStartedAt=[long]0;$client.TimedOut=$false;$client.LastClearCompleted=$false;$client.LastClearUncertain=$false;$client.PendingClearSent=$false
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

function Add-DiagnosticClientFrame($client,$tasks,[string[]]$unavailable) {
 $codes=New-Object 'Collections.Generic.List[string]'
 if($unavailable -ccontains 'Codex'){$codes.Add('codex')};if($unavailable -ccontains 'Claude Code'){$codes.Add('claude')}
 $records=New-Object 'Collections.Generic.List[string]'
 foreach($task in @($tasks)){
  $provider=[string](Prop $task 'Provider' '');$id=[string](Prop $task 'Id' '');$state=[string](Prop $task 'State' '')
  if($provider -cnotin @('codex','claude')){continue}
  if($id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $state -cnotin @('active','unknown')){$client.Gap=$true;$client.GapRevision++;continue}
  if($records.Count -ge 512){$client.Gap=$true;$client.GapRevision++;break}
  $records.Add($provider+','+$id+','+$state)
 }
 $records.Sort([StringComparer]::Ordinal)
 $recordValues=$records.ToArray();$codeValues=$codes.ToArray()
 $signature=($recordValues -join ';')+'|'+($codeValues -join ',')
 $queued=$client.Frames.ToArray()
 if($queued.Count -gt 0 -and [string]$queued[$queued.Count-1].Signature -ceq $signature){return}
 if($client.Frames.Count -ge 64){
  # Preserve the only in-flight observation and the latest state; missing
  # intermediate frames are reported until a confirmed journal clear.
  $head=if($client.InFlightId -ne 0){$client.Frames.Peek()}else{$null}
  $client.Frames.Clear();if($null -ne $head){$client.Frames.Enqueue($head)}
  $client.Gap=$true;$client.GapRevision++
 }
 $client.FrameCounter++
 $client.Frames.Enqueue([PSCustomObject]@{Id=[long]$client.FrameCounter;Signature=$signature;Records=$recordValues;Codes=$codeValues;ObservedAt=[DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)})
}

function Get-DiagnosticRetryDelay($client) {
 $exponent=[Math]::Min(4,[Math]::Max(0,[int]$client.RetryCount))
 return [long]([Diagnostics.Stopwatch]::Frequency * [Math]::Min(30000,[double]$client.RetryDelayMilliseconds*[Math]::Pow(2,$exponent)) / 1000)
}

function Confirm-DiagnosticOwnerFresh($client,[long]$now) {
 if($client.RetryCount -le 0){return}
 $maximumGap=[Diagnostics.Stopwatch]::Frequency*[double]$client.TimeoutMilliseconds/1000
 if($client.FirstFreshAt -eq 0 -or $client.LastFreshAt -eq 0 -or ($now-$client.LastFreshAt) -gt $maximumGap){$client.FirstFreshAt=$now}
 $client.LastFreshAt=$now
 if(($now-$client.FirstFreshAt) -ge ([Diagnostics.Stopwatch]::Frequency*[double]$client.StableMilliseconds/1000)){$client.RetryCount=0;$client.FirstFreshAt=[long]0;$client.LastFreshAt=[long]0}
}

function Repair-DiagnosticClientOwner($client,[long]$now) {
 if($null -ne $client.Owner){
  if(-not $client.Owner.HasExited){return}
  $client.Error=$true;$client.Fresh=$false;$client.Warnings=@{}
  # A failed cleanup does not prove that the old writer has stopped. Never
  # start a replacement while that question remains unresolved.
  if(-not $client.Owner.CanReplace){return}
  Set-DiagnosticClearUnconfirmed $client
  $client.Gap=$true;$client.GapRevision++
  $client.Owner.Dispose();$client.Owner=$null
  $client.PendingStartedAt=[long]0;$client.InFlightId=[long]0;$client.TimedOut=$false;$client.FirstFreshAt=[long]0;$client.LastFreshAt=[long]0
  $client.NextRetryAt=$now+(Get-DiagnosticRetryDelay $client)
 }
 if($null -eq $client.Owner -and $null -ne $client.OwnerFactory -and $client.RetryCount -lt $client.MaximumRetries -and $now -ge $client.NextRetryAt){
  $client.RetryCount++
  try{$client.Owner=& $client.OwnerFactory}catch{$client.Owner=$null}
  if($null -eq $client.Owner){$client.NextRetryAt=$now+(Get-DiagnosticRetryDelay $client)}
 }
}

function Get-DiagnosticClientUpdate($client,$tasks,[string[]]$unavailable) {
 $client.Fresh=$false;$client.LastClearCompleted=$false
 try{Add-DiagnosticClientFrame $client $tasks $unavailable}catch{$client.Error=$true;$client.Warnings=@{};$client.Gap=$true;$client.GapRevision++;return}
 $now=[Diagnostics.Stopwatch]::GetTimestamp()
 if($null -ne $client.Owner -and $client.PendingStartedAt -gt 0 -and ($now-$client.PendingStartedAt) -ge ([Diagnostics.Stopwatch]::Frequency * [double]$client.TimeoutMilliseconds / 1000)){
  Set-DiagnosticClearUnconfirmed $client
  $client.Owner.Invalidate();$client.Warnings=@{};$client.Error=$true;$client.TimedOut=$true;$client.PendingStartedAt=[long]0;$client.InFlightId=[long]0;$client.FirstFreshAt=[long]0;$client.LastFreshAt=[long]0
 }
 $result=if($null -ne $client.Owner){$client.Owner.TryReceive()}else{$null}
 if($null -ne $result){
  $value=$result.Value;$valid=$result.Success -and $result.Generation -eq $client.Owner.Generation -and $null -ne $value -and
   $result.HasRequestStamp -and [long]$result.RequestStamp -eq $client.InFlightId -and $client.InFlightId -ne 0 -and
   $client.Frames.Count -gt 0 -and [long]$client.Frames.Peek().Id -eq $client.InFlightId
  foreach($field in @('Failed','Warnings','ClearAck','DismissAck')){if($null -eq $value -or $null -eq $value.PSObject.Properties[$field]){$valid=$false;break}}
  if($valid){
   $hasNewerFrame=$client.Frames.Count -gt 1
   $warnings=@{}
   foreach($warning in @($value.Warnings|Where-Object {$null -ne $_})){
    $key=[string]$warning.Key;$token=[string]$warning.Token
    if($key -cnotmatch '^codex:([A-Za-z0-9_-]{1,128})$' -or $token -cnotmatch '^[a-f0-9]{32}$' -or
       [int]$warning.Threshold -lt 3 -or [int]$warning.Threshold -gt 10 -or [int]$warning.WindowMinutes -lt 1 -or [int]$warning.WindowMinutes -gt 30){$valid=$false;break}
    $warnings[$key]=[PSCustomObject]@{Warning=[bool]$warning.Warning;Dismissed=[bool]$warning.Dismissed;Threshold=[int]$warning.Threshold;WindowMinutes=[int]$warning.WindowMinutes;Token=$token}
   }
  }
  if($client.PendingClear -and $client.PendingClearSent -and
     (-not $valid -or [bool]$value.Failed -or [string]$value.ClearAck -cne [string]$client.PendingClear)){Set-DiagnosticClearUnconfirmed $client}
  $clearCompleted=$false
  if($valid){
   if($client.PendingClear -and $client.PendingClearSent -and -not [bool]$value.Failed -and [string]$value.ClearAck -ceq [string]$client.PendingClear){
    $client.PendingClear='';$client.PendingClearSent=$false;$client.LastClearCompleted=$true
    $clearCompleted=$true
    if($client.GapRevision -eq $client.ClearGapRevision){$client.Gap=$false}
   }
   foreach($ack in @($value.DismissAck|Where-Object {$_})){
    foreach($id in @($client.PendingDismissals.Keys)){if([string]$client.PendingDismissals[$id].Operation -ceq [string]$ack){[void]$client.PendingDismissals.Remove($id)}}
   }
   foreach($id in @($client.PendingDismissals.Keys)){
    $entry=$client.PendingDismissals[$id];$key='codex:'+ [string]$id
    if($warnings.ContainsKey($key) -and [string]$warnings[$key].Token -ceq [string]$entry.Token){$warnings[$key].Dismissed=$true}
   }
   $client.Error=[bool]$value.Failed;$client.Warnings=if($client.Error -or $hasNewerFrame -or $clearCompleted){@{}}else{$warnings}
   if($client.Error){$client.FirstFreshAt=[long]0;$client.LastFreshAt=[long]0}
   $stage=[string](Prop $value 'FailureStage' '');$kind=[string](Prop $value 'FailureKind' '')
   $client.FailureStage=if($client.Error -and $stage -cmatch '^[a-z-]{1,32}$'){$stage}else{''}
   $client.FailureKind=if($client.Error -and $kind -cmatch '^[A-Za-z0-9]{1,64}$'){$kind}else{''}
   $client.Fresh=-not $client.Error -and -not $hasNewerFrame -and -not $clearCompleted;$client.PendingStartedAt=[long]0;$client.TimedOut=$false
   if($client.Fresh){Confirm-DiagnosticOwnerFresh $client $now}
   if(-not $client.Error -and -not $clearCompleted){[void]$client.Frames.Dequeue()}
  }else{$client.Error=$true;$client.Warnings=@{};$client.FirstFreshAt=[long]0;$client.LastFreshAt=[long]0}
  $client.InFlightId=[long]0
 }
 try{
  if($client.Frames.Count -eq 0){Add-DiagnosticClientFrame $client $tasks $unavailable}
  Repair-DiagnosticClientOwner $client $now
  if($null -eq $client.Owner){$client.Error=$true;$client.Warnings=@{};return}
  if($client.InFlightId -ne 0){return}
  $frame=$client.Frames.Peek()
  $parts=New-Object 'Collections.Generic.List[string]';$parts.Add('poll')
  $parts.Add('observed:'+ [string]$frame.ObservedAt)
  if($client.PendingClear){$parts.Add('clear:'+ [string]$client.PendingClear)}
  if($frame.Codes.Count){$parts.Add('unavailable:'+($frame.Codes -join ','))}
  Add-DiagnosticPacketChunks $parts 'tasks:' ([string[]]$frame.Records)
  $records=New-Object 'Collections.Generic.List[string]'
  foreach($id in @($client.PendingDismissals.Keys)){$entry=$client.PendingDismissals[$id];$records.Add(([string]$entry.Id+','+[string]$entry.Token+','+[string]$entry.Operation))}
  Add-DiagnosticPacketChunks $parts 'dismiss:' $records.ToArray()
  if($parts.Count -gt 32){throw 'Too many diagnostic request fields.'}
  if(-not $client.Owner.Request($parts.ToArray(),[long]$frame.Id)){throw 'The diagnostic owner is unavailable.'}
  if($client.PendingClear){$client.PendingClearSent=$true}
  $client.InFlightId=[long]$frame.Id;$client.PendingStartedAt=$now
 }catch{$client.Error=$true;$client.Warnings=@{};if($client.Frames.Count -gt 0 -and $client.InFlightId -eq 0){$client.Gap=$true;$client.GapRevision++}}
}
