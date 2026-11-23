$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
Add-Type -Path (Join-Path $PSScriptRoot '..\app\CodexRecentEventObserver.cs') -ErrorAction Stop
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The application source did not parse.'}
$names=@('Prop','Lock-State','Find-PriorLifecycle','Read-TailText','Thread-State','Update-CodexRolloutPaths','Confirm-CodexTerminal','Session-File','Codex-Uncertain','Group-CodexTasks','Codex-Tasks','Unconfirmed-Tasks','Source-Snapshot')
$definitions=foreach($name in $names){
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if($null -eq $function){throw "Missing function: $name"};$function.Extent.Text
}
$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $prefix ('aitm-rollout-resolution-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture root.'}
[void][IO.Directory]::CreateDirectory($root)
$checks=@'
$fixture=$args[0]
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$unconfirmed=-join @(1057,1090,1072,1090,1091,1089,32,1085,1077,32,1087,1086,1076,1090,1074,1077,1088,1078,1076,1105,1085|ForEach-Object {[char]$_})
function Codex-IndexCandidates{return @($script:fixtureSessions)}
function Codex-UnindexedCandidates([bool]$HasIndexedHistory){return @()}
function Codex-ReadSubagentMetadata([string]$id){return $null}
function Manual-Tasks($sessions){if($script:fixtureOldManual){return @{'long-observer'=[PSCustomObject]@{title='Old title';paused=$true;progress=100}}};return @{}}
function Codex-Plan([string]$id){if($id -eq 'long-observer'){throw 'Old plan must not be read for an event-only observation.'};return @()}
function Codex-ObservedActivity([string]$id,[string]$startKey){return 'Synthetic activity'}
function Claude-ConnectionState{return 'disconnected'}
$codexHome=$fixture;$sessionIndex=Join-Path $fixture 'session_index.jsonl';$ClaudeEventFile=''
[IO.File]::WriteAllText($sessionIndex,'')
$sessionsDirectory=Join-Path $fixture 'sessions';$dated=Join-Path $sessionsDirectory '2026\11\23';$lockDirectory=Join-Path $fixture 'thread-writer-locks'
[void][IO.Directory]::CreateDirectory($dated);[void][IO.Directory]::CreateDirectory($lockDirectory)
[IO.File]::WriteAllText((Join-Path $lockDirectory 'fixture.lock'),'')
$script:resolvedLanguage='en';$script:codexCloudModulesAvailable=$false;$script:externalProviderModulesAvailable=$false
$script:fixtureSessions=@([PSCustomObject]@{id='fixture';thread_name='Synthetic task';updated_at='revision'})
$script:lastClaudeTasks=@();$script:lastCodexTasks=@();$script:codexDiscoveryFailed=$false
$script:sessionDiscovery=@{Gate=[object]::new();Files=@{};DatedMisses=@{};RolloutMisses=@{};IndexVersions=@{};RetrySeconds=5;HotUntilTicks=0}
$script:sessionDates=@{};$script:unindexedPaths=@{};$script:lifecycleState=@{};$script:planCache=@{};$script:planConfirmations=@{};$script:observedCodex=@{}
$script:codexRolloutPaths=@{};$script:codexObservedStarts=@{};$script:codexTerminalChecks=@{};$script:codexRolloutSnapshot=$null
$script:monitorStartedUtc=[DateTime]::UtcNow.AddMinutes(-1);$script:refreshCount=0
$script:codexRolloutReader=[PSCustomObject]@{}
$script:codexRolloutReader|Add-Member ScriptMethod Snapshot {param($fixtureHome,$ids,$revisions) return $script:fixtureSnapshot}
$script:codexRolloutReader|Add-Member ScriptMethod RefreshSoon {param($id) $script:refreshCount++}
$old=Join-Path $dated 'rollout-2026-11-23T10-00-00-fixture.jsonl'
$new=Join-Path $dated 'rollout-2026-11-23T11-00-00-fixture_20000000-0000-0000-0000-000000000001.jsonl'
$next=Join-Path $dated 'rollout-2026-11-23T12-00-00-fixture_20000000-0000-0000-0000-000000000002.jsonl'
function Write-Event([string]$path,[string]$type,[string]$turn){
 $event=@{timestamp=[DateTime]::UtcNow.ToString('o');type='event_msg';payload=@{type=$type;turn_id=$turn}}|ConvertTo-Json -Compress
 [IO.File]::AppendAllText($path,($event+"`n"),[Text.UTF8Encoding]::new($false))
}
foreach($path in @($old,$new,$next)){[IO.File]::WriteAllText($path,"{}`n",[Text.UTF8Encoding]::new($false))}
Write-Event $old 'task_started' 'old'
Write-Event $new 'task_started' 'new'
Write-Event $next 'task_started' 'next'
$script:sessionDates['fixture']=$dated
$script:sessionDiscovery.Files['fixture']=$old
$script:fixtureSnapshot=[PSCustomObject]@{Paths=@{};CheckedTicks=@{}}
$legacy=Source-Snapshot
Require (@($legacy.Tasks).Count -eq 1 -and -not $legacy.Tasks[0].Active -and (Session-File 'fixture') -ceq $old) 'A legacy unconfirmed task was lost while the database was unavailable.'
Write-Event $old 'turn_aborted' 'old'
$pending=Source-Snapshot
Require (@($pending.Tasks).Count -eq 1 -and -not $script:codexTerminated.ContainsKey('fixture')) 'A fallback terminal was accepted without a verified current path.'
$script:fixtureSnapshot=[PSCustomObject]@{Paths=@{fixture=$new};CheckedTicks=@{fixture=[Diagnostics.Stopwatch]::GetTimestamp()}}
$current=Source-Snapshot
Require (@($current.Tasks).Count -eq 1 -and -not $current.Tasks[0].Active -and (Session-File 'fixture') -ceq $new -and -not $script:sessionDiscovery.Files.ContainsKey('fixture')) 'The verified replacement rollout was not selected.'
Require ($script:codexObservedStarts['fixture'].Path -ceq $new) 'The selected rollout start was not observed.'
Write-Event $new 'task_complete' 'new'
$script:fixtureSnapshot=[PSCustomObject]@{Paths=@{};CheckedTicks=@{}}
$lost=Source-Snapshot
Require (@($lost.Tasks).Count -eq 1 -and -not $lost.Tasks[0].Active -and $lost.CodexIncomplete -and
 [string]$lost.Tasks[0].Status -ceq $unconfirmed -and -not $lost.Tasks[0].ActivityObserved -and
 [string]$lost.Tasks[0].Activity -ceq $unconfirmed -and -not $script:codexTerminated.ContainsKey('fixture') -and
 (Session-File 'fixture') -ceq $old -and $script:codexObservedStarts['fixture'].Path -ceq $new) 'The outage did not retain a neutral, unconfirmed card for the observed rollout.'
$hidden=$old+'.hidden'
[IO.File]::Move($old,$hidden)
try{
 [void]$script:sessionDiscovery.Files.Remove('fixture');[void]$script:sessionDiscovery.DatedMisses.Remove('fixture')
 $emptyFallback=Source-Snapshot
 Require (@($emptyFallback.Tasks).Count -eq 1 -and $emptyFallback.CodexIncomplete -and -not (Session-File 'fixture') -and
  $script:codexObservedStarts['fixture'].Path -ceq $new) 'The outage discarded the observed rollout when no fallback path existed.'
}finally{[IO.File]::Move($hidden,$old)}
$script:fixtureSnapshot=[PSCustomObject]@{Paths=@{fixture=$new};CheckedTicks=@{fixture=[Diagnostics.Stopwatch]::GetTimestamp()}}
$pending=Source-Snapshot
Require (@($pending.Tasks).Count -eq 1 -and -not $script:codexTerminated.ContainsKey('fixture')) 'A terminal during a database outage was accepted as confirmed.'
$script:fixtureSnapshot.CheckedTicks['fixture']=[Diagnostics.Stopwatch]::GetTimestamp()
$confirmed=Source-Snapshot
Require (@($confirmed.Tasks).Count -eq 1 -and -not $confirmed.Tasks[0].Active -and
 [string]$confirmed.Tasks[0].Status -ceq $unconfirmed -and -not $script:codexTerminated.ContainsKey('fixture')) 'A database lookup incorrectly confirmed an ambiguous ending.'
Write-Event $new 'task_started' 'new-again'
$null=Source-Snapshot
$script:lifecycleState[$new]=@{};$script:planCache[$new]=@{};$script:planConfirmations['fixture']=$true
$script:fixtureSnapshot=[PSCustomObject]@{Paths=@{fixture=$next};CheckedTicks=@{fixture=[Diagnostics.Stopwatch]::GetTimestamp()}}
$null=Source-Snapshot
Require (-not $script:lifecycleState.ContainsKey($new) -and -not $script:planCache.ContainsKey($new) -and
 -not $script:planConfirmations.ContainsKey('fixture') -and $script:codexObservedStarts['fixture'].Path -ceq $next) 'Changing paths retained the old task state.'

# An outage for one task must not prevent another task from progressing.
$neighbor=Join-Path $dated 'rollout-2026-11-23T10-00-00-neighbor.jsonl'
[IO.File]::WriteAllText($neighbor,"{}`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $lockDirectory 'neighbor.lock'),'')
Write-Event $neighbor 'task_started' 'neighbor-first'
$script:fixtureSessions+=@([PSCustomObject]@{id='neighbor';thread_name='Synthetic neighbor';updated_at='revision'})
$script:sessionDates['neighbor']=$dated
$script:fixtureSnapshot=[PSCustomObject]@{Paths=@{fixture=$next;neighbor=$neighbor};CheckedTicks=@{fixture=[Diagnostics.Stopwatch]::GetTimestamp();neighbor=[Diagnostics.Stopwatch]::GetTimestamp()}}
$both=Source-Snapshot
Require (@($both.Tasks).Count -eq 2 -and @($both.Tasks|Where-Object Id -eq 'neighbor').Count -eq 1) 'The independent neighboring task was not initially visible.'
Write-Event $neighbor 'task_started' 'neighbor-next'
$script:fixtureSnapshot=[PSCustomObject]@{Paths=@{neighbor=$neighbor};CheckedTicks=@{neighbor=[Diagnostics.Stopwatch]::GetTimestamp()}}
$during=Source-Snapshot
$healthy=@($during.Tasks|Where-Object Id -eq 'neighbor')
Require (@($during.Tasks|Where-Object Id -eq 'fixture').Count -eq 1 -and $healthy.Count -eq 1 -and $healthy[0].StartKey -ceq 'turn:neighbor-next') 'A neighboring task stopped progressing during an outage.'
Write-Event $neighbor 'turn_aborted' 'neighbor-first'
$foreignTurn=Source-Snapshot
$foreignCard=@($foreignTurn.Tasks|Where-Object Id -eq 'neighbor')
Require ($foreignCard.Count -eq 1 -and $foreignCard[0].StartKey -ceq 'turn:neighbor-next' -and
 $foreignCard[0].ActivityObserved -and -not $script:codexUnconfirmedEndings.ContainsKey('neighbor')) 'A terminal from a different turn was treated as the current ending.'
Write-Event $neighbor 'task_complete' ''
$uncertainEnd=Source-Snapshot
$uncertainCard=@($uncertainEnd.Tasks|Where-Object Id -eq 'neighbor')
Require ($uncertainCard.Count -eq 1 -and -not $uncertainCard[0].Active -and
 [string]$uncertainCard[0].Status -ceq $unconfirmed -and [string]$uncertainCard[0].Activity -ceq $unconfirmed -and
 -not $uncertainCard[0].ActivityObserved -and -not $script:codexTerminated.ContainsKey('neighbor')) 'An ending without turn identity was not retained neutrally.'
Write-Event $neighbor 'task_started' 'neighbor-later'
$later=Source-Snapshot
$laterCard=@($later.Tasks|Where-Object Id -eq 'neighbor')
Require ($laterCard.Count -eq 1 -and $laterCard[0].StartKey -ceq 'turn:neighbor-later' -and
 [string]$laterCard[0].Status -ceq $unconfirmed) 'A newer observed turn did not become visible as unconfirmed.'
$paths=@{fixture=$next;neighbor=$neighbor};$ticks=@{fixture=[Diagnostics.Stopwatch]::GetTimestamp();neighbor=[Diagnostics.Stopwatch]::GetTimestamp()}
for($i=0;$i -lt 24;$i++){
 $retiredId='retired'+$i
 $retiredPath=Join-Path $dated ('rollout-2026-11-23T10-00-00-'+$retiredId+'.jsonl')
 [IO.File]::WriteAllText($retiredPath,"{}`n",[Text.UTF8Encoding]::new($false))
 Write-Event $retiredPath 'task_started' 'already-finished'
 Write-Event $retiredPath 'task_complete' 'already-finished'
 $script:fixtureSessions+=@([PSCustomObject]@{id=$retiredId;thread_name='Completed history';updated_at='revision'})
 $paths[$retiredId]=$retiredPath;$ticks[$retiredId]=[Diagnostics.Stopwatch]::GetTimestamp()
}
$script:fixtureSnapshot=[PSCustomObject]@{Paths=$paths;CheckedTicks=$ticks}
foreach($pass in 1..2){
 $withHistory=Source-Snapshot
 Require (@($withHistory.Tasks|Where-Object {([string]$_.Id).StartsWith('retired')}).Count -eq 0) 'Unobserved completed history created task cards.'
}

# The start of this synthetic turn is more than 16 MiB behind the tail.
$longId='long-observer';$longPath=Join-Path $dated 'rollout-2026-11-23T10-00-00-long-observer.jsonl'
[IO.File]::WriteAllText($longPath,('{"type":"session_meta","payload":{"id":"'+$longId+'"}}' + "`n"),[Text.UTF8Encoding]::new($false))
Write-Event $longPath 'task_started' 'long-before-baseline'
$row='{"type":"response_item","payload":{"type":"synthetic","text":"'+('x'*4096)+'"}}' + "`n"
$padding=[Text.Encoding]::UTF8.GetBytes(($row*64))
$stream=[IO.File]::Open($longPath,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
try{for($i=0;$i -lt 68;$i++){$stream.Write($padding,0,$padding.Length)}}finally{$stream.Dispose()}
$oldItem=@{type='event_msg';payload=@{type='item_completed';thread_id=$longId;turn_id='historical';item=@{type='Synthetic'}}}|ConvertTo-Json -Compress -Depth 5
[IO.File]::AppendAllText($longPath,($oldItem+"`n"),[Text.UTF8Encoding]::new($false))
Write-Event $longPath 'task_complete' ''
Require (([IO.FileInfo]::new($longPath)).Length -gt 16MB) 'The long synthetic journal was not large enough.'
$script:fixtureSessions=@([PSCustomObject]@{id=$longId;thread_name='Current task title';updated_at='revision'})
$script:fixtureSnapshot=[PSCustomObject]@{Paths=@{$longId=$longPath};CheckedTicks=@{$longId=[Diagnostics.Stopwatch]::GetTimestamp()}}
$script:lastCodexTasks=@();$script:codexObservedStarts=@{};$script:observedCodex=@{};$script:lifecycleState=@{}
$script:codexRolloutPaths=@{};$script:fixtureOldManual=$false
$script:codexRecentEventObserver=[AITaskMonitor.CodexObservation.CodexRecentEventObserver]::new($sessionsDirectory)
try{
 $beforeBaseline=Source-Snapshot
 Require (@($beforeBaseline.Tasks).Count -eq 0) 'Historical activity created a long-task card before baseline.'
 $clock=[Diagnostics.Stopwatch]::StartNew()
 do{$observed=$script:codexRecentEventObserver.Snapshot($longId,$longPath);if($observed.BaselineReady){break};Start-Sleep -Milliseconds 40}while($clock.ElapsedMilliseconds -lt 10000)
 Require ($observed.BaselineReady -and -not $observed.HasEvent -and @((Source-Snapshot).Tasks).Count -eq 0) 'The baseline accepted an old event.'
 $wrongItem=@{type='event_msg';payload=@{type='item_completed';thread_id='another-thread';turn_id='new';item=@{type='Synthetic'}}}|ConvertTo-Json -Compress -Depth 5
 [IO.File]::AppendAllText($longPath,($wrongItem+"`n"),[Text.UTF8Encoding]::new($false))
 $previousCheck=$observed.CheckCount;$clock.Restart()
 do{$observed=$script:codexRecentEventObserver.Snapshot($longId,$longPath);if($observed.CheckCount -gt $previousCheck){break};Start-Sleep -Milliseconds 40}while($clock.ElapsedMilliseconds -lt 10000)
 Require (-not $observed.HasEvent -and @((Source-Snapshot).Tasks).Count -eq 0) 'An event from another thread created a card.'
 $newItem=@{type='event_msg';payload=@{type='item_completed';thread_id=$longId;turn_id='new';item=@{type='Synthetic'}}}|ConvertTo-Json -Compress -Depth 5
 [IO.File]::AppendAllText($longPath,($newItem+"`n"),[Text.UTF8Encoding]::new($false))
 $clock.Restart()
 do{$observed=$script:codexRecentEventObserver.Snapshot($longId,$longPath);if($observed.HasEvent){break};Start-Sleep -Milliseconds 40}while($clock.ElapsedMilliseconds -lt 10000)
 Require ($observed.HasEvent) ("A new verified synthetic item was not observed (checks=$($observed.CheckCount), ready=$($observed.BaselineReady)).")
 $script:fixtureOldManual=$true
 $longTask=Source-Snapshot;$card=@($longTask.Tasks|Where-Object Id -eq $longId)
 $state=Thread-State $longId
 Require ($card.Count -eq 1 -and -not $card[0].Active -and -not $card[0].Paused -and
  [string]$card[0].Title -ceq 'Current task title' -and [string]$card[0].Status -ceq $unconfirmed -and
  [string]$card[0].Activity -ceq $unconfirmed -and -not $card[0].ActivityObserved -and
  $null -eq $card[0].Progress -and @($card[0].Steps).Count -eq 0 -and
  -not $state.HasStartMarker -and -not $script:codexObservedStarts.ContainsKey($longId)) 'An event-only card implied a start, activity or progress.'
}finally{$script:codexRecentEventObserver.Dispose();$script:codexRecentEventObserver=$null}

# Exercise the real source pipeline with verified direct and nested references.
$parentId='60000000-0000-0000-0000-000000000001';$firstId='60000000-0000-0000-0000-000000000002'
$secondId='60000000-0000-0000-0000-000000000003';$nestedId='60000000-0000-0000-0000-000000000004'
$ids=@($parentId,$firstId,$secondId,$nestedId);$paths=@{};$ticks=@{};$script:fixtureSessions=@()
foreach($id in $ids){
 $path=Join-Path $dated ('rollout-2026-11-23T10-00-00-'+$id+'.jsonl')
 [IO.File]::WriteAllText($path,"{}`n",[Text.UTF8Encoding]::new($false));Write-Event $path 'task_started' ('turn-'+$id)
 $paths[$id]=$path;$ticks[$id]=[Diagnostics.Stopwatch]::GetTimestamp()
 $script:fixtureSessions+=@([PSCustomObject]@{id=$id;thread_name=$(if($id -eq $parentId){'Verified parent'}else{'Agent'});updated_at='revision'})
}
$references=@{};$references[$firstId]=[PSCustomObject]@{ParentThreadId=$parentId;AgentNickname='one'}
$references[$secondId]=[PSCustomObject]@{ParentThreadId=$parentId;AgentNickname='two'}
$references[$nestedId]=[PSCustomObject]@{ParentThreadId=$firstId;AgentNickname='nested'}
$script:fixtureSnapshot=[PSCustomObject]@{Paths=$paths;CheckedTicks=$ticks;ParentReferences=$references}
$script:fixtureOldManual=$false;$script:lastCodexTasks=@();$script:codexObservedStarts=@{};$script:observedCodex=@{};$script:lifecycleState=@{};$script:codexRolloutPaths=@{}
$grouped=Source-Snapshot
Require (@($grouped.Tasks).Count -eq 1 -and $grouped.Tasks[0].Id -ceq $parentId -and
 $grouped.Tasks[0].RelatedAgentCount -eq 3 -and $grouped.Tasks[0].RelatedAgentsUnconfirmed -and
 @($grouped.Tasks[0].RelatedAgents).Count -eq 3 -and [string]$grouped.Tasks[0].Title -ceq 'Verified parent') 'The source pipeline did not group verified nested agents.'
Require (@($script:lastCodexTasks).Count -eq 4) 'Grouping discarded the raw records needed for source recovery.'
$script:fixtureSnapshot=[PSCustomObject]@{Paths=$paths;CheckedTicks=$ticks;ParentReferences=@{}}
$unverified=Source-Snapshot
Require (@($unverified.Tasks).Count -eq 4) 'Tasks were grouped without verified links or were lost when verification disappeared.'
Write-Output 'Codex rollout resolution: unconfirmed endings, long-task observation and verified source grouping passed.'
'@
try{& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks)) $root}
finally{
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path;$attributes=[IO.File]::GetAttributes($resolved)
  if($resolved -cne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or ($attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe fixture cleanup.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
