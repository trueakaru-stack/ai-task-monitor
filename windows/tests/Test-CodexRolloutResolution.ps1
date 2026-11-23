$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The application source did not parse.'}
$names=@('Prop','Lock-State','Find-PriorLifecycle','Read-TailText','Thread-State','Update-CodexRolloutPaths','Confirm-CodexTerminal','Session-File','Codex-Uncertain','Codex-Tasks','Unconfirmed-Tasks','Source-Snapshot')
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
function Codex-IndexCandidates{return @($script:fixtureSessions)}
function Codex-UnindexedCandidates([bool]$HasIndexedHistory){return @()}
function Codex-ReadSubagentMetadata([string]$id){return $null}
function Manual-Tasks($sessions){return @{}}
function Codex-Plan([string]$id){return @()}
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
 (Session-File 'fixture') -ceq $old -and $script:codexObservedStarts['fixture'].Path -ceq $new) 'The outage did not retain the observed rollout when the old file was found.'
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
Require (@($pending.Tasks).Count -eq 1 -and -not $script:codexTerminated.ContainsKey('fixture') -and $script:refreshCount -gt 0) 'A terminal during a database outage was accepted before rechecking.'
$script:fixtureSnapshot.CheckedTicks['fixture']=[Diagnostics.Stopwatch]::GetTimestamp()
$confirmed=Source-Snapshot
Require (@($confirmed.Tasks).Count -eq 0 -and $script:codexTerminated.ContainsKey('fixture')) 'A rechecked terminal for the observed turn was not accepted.'
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
Write-Output 'Codex rollout resolution: legacy fallback, changed paths, outage recovery, matching terminal and independent neighboring task verified.'
'@
try{& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks)) $root}
finally{
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path;$attributes=[IO.File]::GetAttributes($resolved)
  if($resolved -cne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or ($attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe fixture cleanup.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
