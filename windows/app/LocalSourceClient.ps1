# The UI owns only this small cache. The source owner performs all polling.
# This module does not open source files or wait for the worker.
function New-LocalSourceClient($owner,[string]$language) {
 if($language -notin @('ru','en')){throw 'Unsupported local source language.'}
 return [PSCustomObject]@{
  Owner=$owner;Epoch=[Guid]::NewGuid().ToString('N');Enabled=$true;Language=$language
  Snapshot=[PSCustomObject]@{Codex=@();Claude=@();Unavailable=@('Codex');PartialConnection=@();PartialData=@('Codex');CodexIncomplete=$false;ClaudeConnection='unknown'}
  Fresh=$false;HasRequestStamp=$false;RequestStamp=[long]0;Failed=$false
  PendingStartedAt=[long]0;TimedOut=$false;TimeoutMilliseconds=6000
 }
}

function Set-LocalSourceClientConnection($client,[bool]$enabled) {
 if($client.Enabled -eq $enabled){return}
 if($null -ne $client.Owner){$client.Owner.Invalidate()}
 $client.Epoch=[Guid]::NewGuid().ToString('N')
 $client.Enabled=$enabled;$client.Fresh=$false;$client.HasRequestStamp=$false
 $client.PendingStartedAt=[long]0;$client.TimedOut=$false
 # The discarded response may contain the only observed ending or source
 # failure. Known cards are uncertain until a new read has completed.
 Set-LocalSourceClientUnavailable $client
 if(-not $enabled){
  $old=$client.Snapshot
  $client.Snapshot=[PSCustomObject]@{Codex=@($old.Codex);Claude=@();Unavailable=@($old.Unavailable|Where-Object {$_ -cne 'Claude Code'});PartialConnection=@($old.PartialConnection|Where-Object {$_ -cne 'Claude Code'});PartialData=@($old.PartialData|Where-Object {$_ -cne 'Claude Code'});CodexIncomplete=[bool]$old.CodexIncomplete;ClaudeConnection='disconnected'}
 }
}

function Convert-LocalSourceClientUnconfirmed($tasks) {
 return @(Unconfirmed-Tasks $tasks)
}

function Set-LocalSourceClientUnavailable($client) {
 $old=$client.Snapshot
 $codex=@(Convert-LocalSourceClientUnconfirmed @($old.Codex))
 [object[]]$claude=@()
 if($client.Enabled){$claude=@(Convert-LocalSourceClientUnconfirmed @($old.Claude))}
 foreach($task in $codex){
  if($null -ne $task.PSObject.Properties['RelatedAgentCount'] -and [int]$task.RelatedAgentCount -gt 0){
   if($null -ne $task.PSObject.Properties['RelatedAgentsUnconfirmed']){$task.RelatedAgentsUnconfirmed=$true}
   if($null -ne $task.PSObject.Properties['RelatedAgents']){$task.RelatedAgents=@(Convert-LocalSourceClientUnconfirmed @($task.RelatedAgents))}
  }
 }
 $unavailable=@('Codex')
 if($client.Enabled -and ($old.ClaudeConnection -notin @('unknown','disconnected') -or $claude.Count -gt 0)){$unavailable+=@('Claude Code')}
 $client.Snapshot=[PSCustomObject]@{Codex=$codex;Claude=$claude;Unavailable=$unavailable;PartialConnection=@();PartialData=@('Codex');CodexIncomplete=$false;ClaudeConnection=$(if($client.Enabled){'unknown'}else{'disconnected'})}
 $client.Failed=$true
}

function Get-LocalSourceClientSnapshot($client,[string]$language,[long]$selectionRevision) {
 if($language -notin @('ru','en')){throw 'Unsupported local source language.'}
 $client.Fresh=$false;$client.HasRequestStamp=$false
 if($null -eq $client.Owner){Set-LocalSourceClientUnavailable $client;return $client.Snapshot}
 if($client.Language -cne $language){
  $client.Owner.Invalidate();$client.Language=$language
  $client.PendingStartedAt=[long]0;$client.TimedOut=$false
  Set-LocalSourceClientUnavailable $client
 }
 $now=[Diagnostics.Stopwatch]::GetTimestamp()
 if($client.PendingStartedAt -gt 0 -and
    ($now-$client.PendingStartedAt) -ge ([Diagnostics.Stopwatch]::Frequency * [double]$client.TimeoutMilliseconds / 1000)){
  # The result may already be waiting when the UI wakes up. Check its age
  # before receiving it, so a stale snapshot cannot regain confirmation.
  $client.Owner.Invalidate();Set-LocalSourceClientUnavailable $client
  $client.TimedOut=$true;$client.PendingStartedAt=$now
 }
 $result=$client.Owner.TryReceive()
 if($null -ne $result){
  $value=$result.Value
  $valid=$result.Success -and $result.Generation -eq $client.Owner.Generation -and $null -ne $value
  foreach($field in @('Codex','Claude','Unavailable','PartialConnection','PartialData','CodexIncomplete','ClaudeConnection')){
   if($null -eq $value -or $null -eq $value.PSObject.Properties[$field]){$valid=$false;break}
  }
  if($valid -and [string]$value.ClaudeConnection -notin @('connected','disconnected','partial','unknown','error')){$valid=$false}
  if($valid){
   [object[]]$claude=@()
   if($client.Enabled){$claude=@($value.Claude|Where-Object {$null -ne $_})}
   $client.Snapshot=[PSCustomObject]@{Codex=@($value.Codex|Where-Object {$null -ne $_});Claude=$claude;Unavailable=@($value.Unavailable|Where-Object {$null -ne $_});PartialConnection=@($value.PartialConnection|Where-Object {$null -ne $_});PartialData=@($value.PartialData|Where-Object {$null -ne $_});CodexIncomplete=[bool]$value.CodexIncomplete;ClaudeConnection=$(if($client.Enabled){[string]$value.ClaudeConnection}else{'disconnected'})}
   $client.Fresh=$true;$client.HasRequestStamp=[bool]$result.HasRequestStamp;$client.RequestStamp=[long]$result.RequestStamp;$client.Failed=$false
   $client.PendingStartedAt=[long]0;$client.TimedOut=$false
  }else{Set-LocalSourceClientUnavailable $client}
 }
 $request=[string[]]@('poll',[string]$client.Epoch,$(if($client.Enabled){'true'}else{'false'}),$language)
 if(-not $client.Owner.Request($request,$selectionRevision)){Set-LocalSourceClientUnavailable $client}
 elseif($client.PendingStartedAt -eq 0){$client.PendingStartedAt=$now}
 return $client.Snapshot
}
