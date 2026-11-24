# Bridge retained, verified identities to the existing grouping. No source
# reads, UI objects, or mutations of supplied tasks and links occur here.
function Select-CodexRetentionLinks($links,$retention) {
 $effective=@{};$eligible=@{};$acceptedMembers=@{}
 if($null -ne $links){foreach($id in $links.Keys){$effective[$id]=$links[$id]}}
 foreach($group in @($retention.Groups)){
  if([bool]$group.CanAttach){
   $eligible[[string]$group.RootId]=$true
   foreach($member in @($group.Members)){$acceptedMembers[[string]$member.Id]=$true}
  }
  else{$effective[[string]$group.RootId]=[PSCustomObject]@{Conflict=$true}}
 }
 # Never display a count which the retention state did not first accept.
 # Otherwise a newly grouped, incompletely verified child could disappear at
 # the next poll without any evidence that the agent was closed.
 foreach($id in @($effective.Keys)){
  if([bool](Prop $effective[$id] 'IsRoot' $false) -and -not $eligible.ContainsKey([string]$id)){$effective[$id]=[PSCustomObject]@{Conflict=$true}}
  elseif(-not [bool](Prop $effective[$id] 'IsRoot' $false) -and -not $acceptedMembers.ContainsKey([string]$id)){$effective[$id]=[PSCustomObject]@{Conflict=$true}}
 }
 return $effective
}

function Apply-CodexAgentRetention($grouped,$raw,$retention) {
 $rawById=@{}
 foreach($task in @($raw)){
  $id=[string](Prop $task 'Id' '')
  if($id -and -not $rawById.ContainsKey($id)){$rawById[$id]=$task}
 }
 $groupsById=@{}
 foreach($group in @($retention.Groups)){if([bool]$group.CanAttach){$groupsById[[string]$group.RootId]=$group}}
 foreach($task in @($grouped)){
  $id=[string](Prop $task 'Id' '')
  if([string](Prop $task 'Provider' '') -cne 'codex' -or [string](Prop $task 'Source' '') -ceq 'Codex Cloud' -or -not $groupsById.ContainsKey($id)){$task;continue}
  $group=$groupsById[$id];$members=New-Object 'Collections.Generic.List[object]';$ids=New-Object 'Collections.Generic.List[string]';$unconfirmed=$false
  foreach($member in @($group.Members)){
   $memberId=[string]$member.Id;[void]$ids.Add($memberId)
   $candidate=if($rawById.ContainsKey($memberId)){$rawById[$memberId]}else{$null}
   if([bool]$member.Current -and $null -ne $candidate -and [string](Prop $candidate 'ActivityIdentity' '') -ceq [string]$member.IdentityToken){
    $members.Add($candidate)
   }else{
    $members.Add([PSCustomObject]@{Id=$memberId;Provider='codex';ProviderName='Codex';Title=[string]$member.Title;AgentNickname=[string]$member.AgentNickname;Active=$false;Paused=$false;Status='Статус не подтверждён';Activity='Статус не подтверждён';ActivityGenerated=$true;Steps=@();Progress=$null;ProgressKind='none';PlanConfirmed=$false})
    $unconfirmed=$true
   }
   if([bool]$member.StatusUnconfirmed){$unconfirmed=$true}
  }
  $copy=$task.PSObject.Copy()
  $copy|Add-Member -NotePropertyMembers @{RelatedAgentCount=$ids.Count;RelatedAgentsUnconfirmed=$unconfirmed;RelatedAgentIds=$ids.ToArray();RelatedAgents=$members.ToArray();RelatedAgentCountUnconfirmed=$true} -Force
  $copy
 }
}
