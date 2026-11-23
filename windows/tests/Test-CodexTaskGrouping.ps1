$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The monitor source did not parse.'}
$names=@('Prop','Group-CodexTasks','Localized-TaskTitle','Localized-TaskActivity','Related-AgentActivity','Related-AgentStatus','Related-AgentFingerprint','Prioritize-Tasks')
$definitions=foreach($name in $names){
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
 if($null -eq $node){throw "Missing function: $name"};$node.Extent.Text
}
$checks=@'
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Tr([string]$text){return $text}
function Task([string]$id,[string]$title,[bool]$active=$false,[string]$provider='codex',[string]$source='local'){
 return [PSCustomObject]@{Id=$id;Title=$title;TitleGenerated=$false;Provider=$provider;ProviderName=$provider;Source=$source;Active=$active;Paused=$false;Status=$(if($active){'running'}else{'unknown'});Activity='parent activity';Progress=55;ProgressKind='exact';ProgressBasis='task';PlanConfirmed=$true;Steps=@([PSCustomObject]@{title='step';status='active'});Updated=[DateTime]::UtcNow;Started=[DateTime]::UtcNow;StartKey='turn'}
}
$p='10000000-0000-0000-0000-000000000001';$c1='10000000-0000-0000-0000-000000000002';$c2='10000000-0000-0000-0000-000000000003'
$grand='10000000-0000-0000-0000-000000000004';$done='10000000-0000-0000-0000-000000000005'
$parent=Task $p 'Parent' $true;$first=Task $c1 'First';$second=Task $c2 'Second';$nested=Task $grand 'Nested';$finished=Task $done 'Finished'
$finished|Add-Member NoteProperty TerminalConfirmed $true
$links=@{};$links[$p]=[PSCustomObject]@{IsRoot=$true};$links[$c1]=[PSCustomObject]@{ParentThreadId=$p};$links[$c2]=[PSCustomObject]@{ParentThreadId=$p};$links[$grand]=[PSCustomObject]@{ParentThreadId=$c1};$links[$done]=[PSCustomObject]@{ParentThreadId=$c1}
$titles=@{};$titles[$p]='Parent'
foreach($ordered in @(@($parent,$first,$second,$nested,$finished,$second),@($second,$finished,$nested,$parent,$first,$second))){
 $grouped=@(Group-CodexTasks $ordered $links $titles)
 Require ($grouped.Count -eq 1 -and $grouped[0].Id -ceq $p -and $grouped[0].RelatedAgentCount -eq 3 -and $grouped[0].RelatedAgentsUnconfirmed) 'Nested, completed or duplicate agents were counted incorrectly.'
 Require ($grouped[0].Active -and $grouped[0].Status -ceq 'running' -and $grouped[0].Activity -ceq 'parent activity' -and
  $grouped[0].Progress -eq 55 -and $grouped[0].PlanConfirmed -and @($grouped[0].Steps).Count -eq 1 -and
  @($grouped[0].RelatedAgents).Count -eq 3) 'Grouping changed parent data or discarded its related agent records.'
}
$through='10000000-0000-0000-0000-000000000006';$links[$through]=[PSCustomObject]@{ParentThreadId=$done}
$throughCompleted=@(Group-CodexTasks @($parent,$first,$finished,(Task $through 'Descendant')) $links $titles)
Require ($throughCompleted.Count -eq 1 -and $throughCompleted[0].RelatedAgentCount -eq 2) 'A completed intermediate agent hid its observed descendant or was counted itself.'
$script:taskPriority=@{};$script:taskPriorityCounter=0;$script:monitorStartedUtc=[DateTime]::UtcNow.AddMinutes(-1)
$other=Task '90000000-0000-0000-0000-000000000001' 'Other task' $true
$selected=Prioritize-Tasks @($other,$grouped[0]) @($first,$other) $c1
Require ($selected.SelectedId -ceq $p) 'A selected child did not transfer selection to its parent group.'
$firstFingerprint=Related-AgentFingerprint $grouped[0]
$grouped[0].RelatedAgents[0].Activity='A newer observed action'
Require ((Related-AgentFingerprint $grouped[0]) -cne $firstFingerprint) 'Changing a related agent action did not invalidate the display fingerprint.'
$lastFingerprint=Related-AgentFingerprint $grouped[0]
$grouped[0].RelatedAgents[0]|Add-Member NoteProperty ActivityIsLast $true -Force
Require ((Related-AgentFingerprint $grouped[0]) -cne $lastFingerprint) 'Marking a related action as last did not invalidate the display fingerprint.'
$unconfirmed=-join @(1057,1090,1072,1090,1091,1089,32,1085,1077,32,1087,1086,1076,1090,1074,1077,1088,1078,1076,1105,1085|ForEach-Object {[char]$_})
$lastPrefix=-join @(1055,1086,1089,1083,1077,1076,1085,1077,1077,58,32|ForEach-Object {[char]$_})
$unknownAction=[PSCustomObject]@{Provider='codex';Status=$unconfirmed;Active=$false;Paused=$false;ActivityObserved=$true;Activity='Observed action'}
$activeAction=[PSCustomObject]@{Provider='codex';Status='running';Active=$true;Paused=$false;ActivityObserved=$false;Activity='Current action'}
Require ((Related-AgentActivity $unknownAction $true) -ceq ($lastPrefix+'Observed action') -and
 (Related-AgentActivity $unknownAction $false) -ceq ($unconfirmed+'. '+$lastPrefix+'Observed action') -and
 (Related-AgentActivity $activeAction $true) -ceq 'Current action') 'Mixed current and unconfirmed agent actions were labelled incorrectly.'
$activeAgent=Task $c1 'Active agent' $true
$pausedAgent=Task $c2 'Paused agent';$pausedAgent.Paused=$true;$pausedAgent.Status='paused'
$mixedKnown=@(Group-CodexTasks @($parent,$activeAgent,$pausedAgent) $links $titles)
Require ($mixedKnown.Count -eq 1 -and $mixedKnown[0].RelatedAgentCount -eq 2 -and -not $mixedKnown[0].RelatedAgentsUnconfirmed) 'A confirmed paused agent was marked unconfirmed.'
$mixedMissingParent=@(Group-CodexTasks @($activeAgent,$pausedAgent) $links $titles)
Require ($mixedMissingParent.Count -eq 1 -and -not $mixedMissingParent[0].Active -and -not $mixedMissingParent[0].RelatedAgentsUnconfirmed) 'An unknown parent made confirmed agent statuses unconfirmed.'
$mixedUnknown=@(Group-CodexTasks @($parent,$activeAgent,$pausedAgent,$nested) $links $titles)
Require ($mixedUnknown.Count -eq 1 -and $mixedUnknown[0].RelatedAgentsUnconfirmed) 'An actually unknown agent did not mark the group unconfirmed.'
$script:resolvedLanguage='en'
Require ((Localized-TaskTitle $grouped[0]) -ceq 'Parent (3 agents)' -and (Related-AgentStatus $grouped[0]) -ceq 'Agent status unconfirmed') 'The English count or uncertainty label is incorrect.'
$single=$grouped[0].PSObject.Copy();$single.RelatedAgentCount=1
Require ((Localized-TaskTitle $single) -ceq 'Parent (1 agent)') 'English singular is incorrect.'
$script:resolvedLanguage='ru'
$agent=-join @(1072,1075,1077,1085,1090|ForEach-Object {[char]$_})
$agentsFew=$agent+([char]1072);$agentsMany=$agent+([char]1086)+([char]1074)
foreach($entry in @(@(1,$agent),@(2,$agentsFew),@(5,$agentsMany),@(11,$agentsMany),@(21,$agent),@(22,$agentsFew))){
 $sample=$grouped[0].PSObject.Copy();$sample.RelatedAgentCount=$entry[0];$sample.RelatedAgentsUnconfirmed=$false
 Require ((Localized-TaskTitle $sample) -ceq ('Parent ('+$entry[0]+' '+$entry[1]+')')) 'Russian agent count inflection is incorrect.'
}
$missing=@(Group-CodexTasks @($first,$nested) $links $titles)
Require ($missing.Count -eq 1 -and $missing[0].Id -ceq $p -and $missing[0].Title -ceq 'Parent' -and
 -not $missing[0].Active -and $missing[0].RelatedAgentCount -eq 2 -and $null -eq $missing[0].Progress) 'A missing parent was attributed an active state or lost its verified title.'
$guardianTitles=@{};$guardianTitles[$p]='Guardian review'
$guardian=@(Group-CodexTasks @($first,$nested) $links $guardianTitles)
Require ($guardian.Count -eq 1 -and $guardian[0].Title -cne 'Guardian review' -and $guardian[0].TitleGenerated -and
 @($guardian[0].RelatedAgents).Count -eq 2) 'An internal Guardian title was exposed or visible descendants were lost.'
$otherParent='20000000-0000-0000-0000-000000000001';$otherChild='20000000-0000-0000-0000-000000000002'
$links[$otherParent]=[PSCustomObject]@{IsRoot=$true};$links[$otherChild]=[PSCustomObject]@{ParentThreadId=$otherParent};$titles[$otherParent]='Parent'
$different=@(Group-CodexTasks @($parent,$first,(Task $otherParent 'Parent' $true),(Task $otherChild 'Other')) $links $titles)
Require ($different.Count -eq 2 -and @($different|Where-Object RelatedAgentCount -eq 1).Count -eq 2) 'Unrelated parents were merged by matching title.'
$cloud=Task $p 'Cloud title' $false 'codex' 'Codex Cloud';$claude=Task $p 'Claude title' $false 'claude' 'Claude Code'
$isolated=@(Group-CodexTasks @($parent,$first,$cloud,$claude) $links $titles)
Require ($isolated.Count -eq 3 -and @($isolated|Where-Object Source -eq 'Codex Cloud').Count -eq 1 -and
 @($isolated|Where-Object Provider -eq 'claude').Count -eq 1) 'Another provider or cloud task was absorbed.'
$cycleA='30000000-0000-0000-0000-000000000001';$cycleB='30000000-0000-0000-0000-000000000002';$desc='30000000-0000-0000-0000-000000000003'
$cycle=@{};$cycle[$cycleA]=[PSCustomObject]@{ParentThreadId=$cycleB};$cycle[$cycleB]=[PSCustomObject]@{ParentThreadId=$cycleA};$cycle[$desc]=[PSCustomObject]@{ParentThreadId=$cycleA}
$cycleResult=@(Group-CodexTasks @((Task $cycleA 'A'),(Task $cycleB 'B'),(Task $desc 'C')) $cycle @{})
Require ($cycleResult.Count -eq 3 -and @($cycleResult|Where-Object {$null -ne $_.PSObject.Properties['RelatedAgentCount']}).Count -eq 0) 'A cycle hid a descendant.'
$conflict=@{};$conflict[$cycleA]=[PSCustomObject]@{Conflict=$true};$conflict[$desc]=[PSCustomObject]@{ParentThreadId=$cycleA}
$conflictResult=@(Group-CodexTasks @((Task $cycleA 'A'),(Task $desc 'C')) $conflict @{})
Require ($conflictResult.Count -eq 2) 'An invalid link hid a descendant.'
$incomplete=@{};$incomplete[$grand]=[PSCustomObject]@{ParentThreadId=$c1}
$incompleteTitles=@{};$incompleteTitles[$c1]='Missing intermediate'
$unresolved=@(Group-CodexTasks @($nested) $incomplete $incompleteTitles)
Require ($unresolved.Count -eq 1 -and $unresolved[0].Id -ceq $grand -and $null -eq $unresolved[0].PSObject.Properties['RelatedAgentCount']) 'An incomplete chain replaced the descendant with an unverified ancestor.'
$visibleIncomplete=@(Group-CodexTasks @($first,$nested) $incomplete $incompleteTitles)
Require ($visibleIncomplete.Count -eq 2 -and @($visibleIncomplete|Where-Object Id -eq $c1).Count -eq 1 -and @($visibleIncomplete|Where-Object Id -eq $grand).Count -eq 1 -and
 @($visibleIncomplete|Where-Object {$null -ne $_.PSObject.Properties['RelatedAgentCount']}).Count -eq 0) 'A visible intermediate with missing metadata absorbed its descendant.'
$stressTasks=New-Object 'Collections.Generic.List[object]';$stressLinks=@{};$stressTitles=@{}
for($i=0;$i -lt 128;$i++){
 $root='40000000-0000-0000-0000-{0:D12}' -f $i;$stressTasks.Add((Task $root 'Parent' $true));$stressTitles[$root]='Parent'
 $stressLinks[$root]=[PSCustomObject]@{IsRoot=$true}
 for($j=0;$j -lt 3;$j++){$id='50000000-0000-0000-0000-{0:D12}' -f ($i*3+$j);$stressTasks.Add((Task $id 'Child'));$stressLinks[$id]=[PSCustomObject]@{ParentThreadId=$root}}
}
$times=New-Object 'Collections.Generic.List[long]'
foreach($pass in 1..5){
 $clock=[Diagnostics.Stopwatch]::StartNew();$stress=@(Group-CodexTasks $stressTasks.ToArray() $stressLinks $stressTitles);$clock.Stop();$times.Add($clock.ElapsedMilliseconds)
 Require ($stress.Count -eq 128 -and $clock.ElapsedMilliseconds -lt 3000) 'Grouping many tasks exceeded the synthetic responsiveness limit.'
}
$max=($times|Measure-Object -Maximum).Maximum
$chainTasks=New-Object 'Collections.Generic.List[object]';$chainLinks=@{};$chainTitles=@{};$prior=''
for($i=0;$i -lt 257;$i++){
 $id='70000000-0000-0000-0000-{0:D12}' -f $i
 $chainTasks.Add((Task $id 'Chain'))
 if($prior){$chainLinks[$id]=[PSCustomObject]@{ParentThreadId=$prior}}else{$chainTitles[$id]='Chain';$chainLinks[$id]=[PSCustomObject]@{IsRoot=$true}}
 $prior=$id
}
$clock.Restart();$chain=@(Group-CodexTasks $chainTasks.ToArray() $chainLinks $chainTitles);$clock.Stop()
Require ($chain.Count -eq 1 -and $chain[0].RelatedAgentCount -eq 256 -and $clock.ElapsedMilliseconds -lt 1000) 'A deep chain was slow or grouped incorrectly.'
Write-Output ('Codex grouping: verified chains, missing parents, cycles, other sources, translations; 512-task max '+$max+' ms, 257-deep chain '+$clock.ElapsedMilliseconds+' ms.')
'@
& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks))
