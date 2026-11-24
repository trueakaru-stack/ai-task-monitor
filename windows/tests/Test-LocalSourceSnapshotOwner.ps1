$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'The synthetic WPF check requires STA.'}
Add-Type -AssemblyName PresentationFramework
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Wait-Result($owner,[int]$milliseconds=20000){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds -lt $milliseconds){$result=$owner.TryReceive();if($null -ne $result){return $result};Start-Sleep -Milliseconds 10}
 throw 'The synthetic source owner did not return a result.'
}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-local-source-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic source directory.'
[void][IO.Directory]::CreateDirectory($root)
$startName='Local\AITMSourceStart-'+[Guid]::NewGuid().ToString('N')
$releaseName='Local\AITMSourceRelease-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName)
$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
$owner=$null
try{
 [IO.File]::WriteAllText((Join-Path $root '.synthetic-source'),'synthetic',[Text.UTF8Encoding]::new($false))
 $codexHome=Join-Path $root 'codex';$sessions=Join-Path $codexHome 'sessions';$locks=Join-Path $codexHome 'thread-writer-locks'
 $now=[DateTime]::Now;$utc=[DateTime]::UtcNow;$id='30000000-0000-0000-0000-000000000001'
 $day=Join-Path (Join-Path (Join-Path $sessions $now.ToString('yyyy')) $now.ToString('MM')) $now.ToString('dd')
 [void][IO.Directory]::CreateDirectory($day);[void][IO.Directory]::CreateDirectory($locks)
 $rollout=Join-Path $day ('rollout-'+$now.ToString('yyyy-MM-ddTHH-mm-ss')+'-'+$id+'.jsonl')
 $meta=@{type='session_meta';payload=@{id=$id;source='cli';thread_source='user';cwd=$root}}|ConvertTo-Json -Depth 8 -Compress
 $turn=@{type='event_msg';timestamp=$utc.ToString('o');payload=@{type='task_started';turn_id='synthetic-turn'}}|ConvertTo-Json -Depth 8 -Compress
 [IO.File]::WriteAllText($rollout,($meta+[Environment]::NewLine+$turn+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
 $index=@{id=$id;thread_name='Synthetic Codex task';updated_at=$now.ToString('o')}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText((Join-Path $codexHome 'session_index.jsonl'),($index+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $locks ($id+'.lock')),'',[Text.UTF8Encoding]::new($false))
 $event=@{timestamp=$utc.ToString('o');session_id='synthetic-claude';event='UserPromptSubmit';active=$true}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText((Join-Path $root 'claude-events.jsonl'),($event+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))

 $fixture=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\LocalReadSnapshotSyntheticWorker.ps1'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($fixture,[string[]]@($root,$startName,$releaseName))
 $snapshot=$null;$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{
  Require ($owner.Request([string[]]@('snapshot','epoch-one','connected','ru'))) 'The synthetic source request was rejected.'
  $snapshot=Wait-Result $owner
  Require $snapshot.Success 'The source owner failed before returning the synthetic snapshot.'
  $codex=@($snapshot.Value.Codex|Where-Object {[string]$_.Id -ceq $id})
  $claude=@($snapshot.Value.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-claude'})
  if($codex.Count -eq 1 -and $claude.Count -eq 1){break}
  Start-Sleep -Milliseconds 150
 }while($deadline.ElapsedMilliseconds -lt 15000)
 Require ($codex.Count -eq 1 -and $claude.Count -eq 1) 'The real source functions did not surface both synthetic tasks.'
 Require ($owner.Request([string[]]@('fail-codex','epoch-one','connected','ru'))) 'The injected source failure request was rejected.'
 $failedSource=Wait-Result $owner
 $fallback=@($failedSource.Value.Codex|Where-Object {[string]$_.Id -ceq $id})
 Require ($failedSource.Success -and $fallback.Count -eq 1 -and -not $fallback[0].Active -and
  @($failedSource.Value.Unavailable) -ccontains 'Codex' -and
  @($failedSource.Value.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-claude'}).Count -eq 1) 'An injected Codex failure lost prior data or the other source.'
 Require ($owner.Request([string[]]@('snapshot','epoch-one','connected','ru'))) 'The synthetic recovery request was rejected.'
 $recovered=Wait-Result $owner
 Require ($recovered.Success -and @($recovered.Value.Codex|Where-Object {[string]$_.Id -ceq $id}).Count -eq 1) 'The synthetic Codex source did not recover.'

 $source=Join-Path $PSScriptRoot '..\app\CodexProgress.ps1';$tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The monitor source did not parse.'}
 $definitions=foreach($name in @('Prop','Brush','Text','Localized-TaskTitle','Localized-TaskActivity','Localized-CompactTaskActivity',
  'Plan-StatusNote','Progress-Label','Get-LoopWarning','Add-LoopWarning','Add-ConditionalHint','New-ActivityIndicator','New-TaskTitleLine',
  'Active-PlanStepIndex','Compact-AgentStepLabel','Compact-ProgressLabel','Compact-ExtraAgentStepLabel','Related-AgentStatus','New-RelatedAgentToggle',
  'Compact-VisibleTasks','Compact-ShowProviderLabels','Compact-HasHiddenAgentTasks','Prioritize-Tasks','Source-WarningText','Compact-Height',
  'Add-CompactTask','Add-CompactDot','Sync-CompactDots','Render-CompactTasks')){
  $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
  if($null -eq $node){throw 'A real compact function was not found.'};$node.Extent.Text
 }
 . ([scriptblock]::Create(($definitions -join [Environment]::NewLine)))
 function Tr([string]$value){return $value}
 function Move-CompactWindow {}
 $window=[PSCustomObject]@{Height=0.0;Resources=@{CompactDotStyle=[Windows.Style]::new([Windows.Controls.Button])}}
 $compactDotsPanel=[Windows.Controls.StackPanel]::new();$compactTasksPanel=[Windows.Controls.StackPanel]::new()
 $compactMoreText=[Windows.Controls.TextBlock]::new()
 $script:palette=[PSCustomObject]@{Scroll='#888888';Primary='#222222';Activity='#333333';Muted='#777777'};$script:accentHex='#0066CC'
 $script:resolvedLanguage='ru';$script:isCompact=$true;$script:motionEnabled=$false
 $script:sourceErrors=@();$script:sourcePartialConnections=@();$script:sourcePartialData=@();$script:sourceCodexIncomplete=$false
 $script:diagnosticRuntime=$null;$script:claudeLoopStates=@{};$script:previewHintTarget=$null
 $script:taskPriority=@{};$script:taskPriorityCounter=0;$script:monitorStartedUtc=[DateTime]::UtcNow.AddMinutes(-5)
 $script:selectionRevision=0
 $PreviewRelatedAgents=$false;$CompactMode=$true;$PreviewActiveTasks=-1;$PreviewLoopWarning=$false
 $script:lastAllTasks=@($codex[0],$claude[0]);$script:compactTaskId=[string]$codex[0].Id
 Render-CompactTasks $script:lastAllTasks
 Require ($compactDotsPanel.Children.Count -eq 2) 'The synthetic source tasks did not create two real compact dots.'

 $issuedRevision=$script:selectionRevision
 Require ($owner.Request([string[]]@('block','epoch-one','connected','ru'),[long]$issuedRevision)) 'The gated source request was rejected.'
 Require ($started.WaitOne(10000)) 'The source read did not reach its synthetic blocking gate.'
 $dot=@($compactDotsPanel.Children|Where-Object {[string]$_.Tag -ceq [string]$claude[0].Id})[0]
 # Simulate an input-revision counter owned by the future UI integration.
 # The dot's first listener is the unchanged production handler.
 $dot.Add_Click({$script:selectionRevision++})
 $click=[Diagnostics.Stopwatch]::StartNew()
 $dot.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 $click.Stop()
 Require ($script:compactTaskId -ceq [string]$claude[0].Id -and -not $release.WaitOne(0) -and $null -eq $owner.TryReceive()) 'The actual compact handler could not select the synthetic Claude task while real source code was gated.'
 Require ($script:selectionRevision -eq $issuedRevision+1) 'The synthetic manual selection revision did not advance.'

 # This harness models the future publish contract; the production updater is
 # not changed by this test. A late snapshot may reorder cards but cannot steal
 # a still-visible selection made after its request was issued.
 function Publish-SyntheticSnapshot($tasks,[int]$requestRevision){
  $manualId=[string]$script:compactTaskId
  $prioritized=Prioritize-Tasks $tasks $script:lastAllTasks $manualId
  if($script:selectionRevision -ne $requestRevision -and
     @(Compact-VisibleTasks $prioritized.Tasks|Where-Object {[string]$_.Id -ceq $manualId}).Count -gt 0){$prioritized.SelectedId=$manualId}
  $script:lastAllTasks=@($prioritized.Tasks);$script:compactTaskId=[string]$prioritized.SelectedId
  Render-CompactTasks $script:lastAllTasks
 }
 $newTime=[DateTime]::Now
 $newTask=[PSCustomObject]@{Id='synthetic-new-one';Title='New task';Provider='synthetic';ProviderName='Synthetic';Active=$true;Paused=$false;Status='active';Activity='Working';ProgressKind='none';Progress=$null;Steps=@();StartKey='new-one';Started=$newTime;Updated=$newTime}
 [void]$release.Set()
 $late=Wait-Result $owner
 Require ($late.Success -and $late.Generation -eq $owner.Generation -and $late.HasRequestStamp -and $late.RequestStamp -eq $issuedRevision) 'The first gated snapshot failed.'
 Publish-SyntheticSnapshot (@($late.Value.Codex)+@($late.Value.Claude)+@($newTask)) $late.RequestStamp
 Require ($script:compactTaskId -ceq [string]$claude[0].Id) 'A late snapshot stole the manual task selection.'

 $nextRevision=$script:selectionRevision
 Require ($owner.Request([string[]]@('snapshot','epoch-one','connected','ru'),[long]$nextRevision)) 'The next synthetic source request was rejected.'
 $nextSnapshot=Wait-Result $owner
 Require ($nextSnapshot.Success -and $nextSnapshot.HasRequestStamp -and $nextSnapshot.RequestStamp -eq $nextRevision) 'The next synthetic snapshot failed.'
 $laterTime=$newTime.AddSeconds(1)
 $laterTask=[PSCustomObject]@{Id='synthetic-new-two';Title='Later task';Provider='synthetic';ProviderName='Synthetic';Active=$true;Paused=$false;Status='active';Activity='Working';ProgressKind='none';Progress=$null;Steps=@();StartKey='new-two';Started=$laterTime;Updated=$laterTime}
 Publish-SyntheticSnapshot (@($nextSnapshot.Value.Codex)+@($nextSnapshot.Value.Claude)+@($newTask,$laterTask)) $nextSnapshot.RequestStamp
 Require ($script:compactTaskId -ceq 'synthetic-new-two') 'A new task after the applied snapshot did not take focus.'

 [void]$started.Reset();[void]$release.Reset()
 Require ($owner.Request([string[]]@('block','epoch-one','connected','ru'))) 'The second gated source request was rejected.'
 Require ($started.WaitOne(10000)) 'The second source read did not reach its synthetic blocking gate.'
 $owner.Invalidate()
 Require ($owner.Request([string[]]@('snapshot','epoch-two','disconnected','en'))) 'The synthetic disconnect was rejected.'
 Require ($owner.Request([string[]]@('snapshot','epoch-two','connected','en'))) 'The synthetic reconnect was rejected.'
 [void]$release.Set()
 $after=Wait-Result $owner
 Require ($after.Success -and $after.Generation -eq $owner.Generation) 'An old-generation result was published.'
 $retained=@($after.Value.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-claude'})
 $unconfirmed=-join @([int[]]@(1057,1090,1072,1090,1091,1089,32,1085,1077,32,1087,1086,1076,1090,1074,1077,1088,1078,1076,1105,1085)|ForEach-Object {[char]$_})
 Require ($retained.Count -eq 1 -and -not $retained[0].Active -and [string]$retained[0].Status -ceq $unconfirmed) 'The source epoch transition falsely confirmed or lost the previous Claude task.'
 Require (@($after.Value.Codex|Where-Object {[string]$_.Id -ceq $id}).Count -eq 1) 'The Codex task was lost during the source epoch transition.'

 $owner.Invalidate()
 Require ($owner.Request([string[]]@('snapshot','epoch-three','disconnected','ru'))) 'The explicit synthetic disconnect was rejected.'
 $disconnected=Wait-Result $owner
 Require ($disconnected.Success -and @($disconnected.Value.Claude).Count -eq 0 -and
  @($disconnected.Value.Codex|Where-Object {[string]$_.Id -ceq $id}).Count -eq 1) 'Explicit disconnect did not hide Claude while retaining Codex.'
 $owner.Invalidate()
 Require ($owner.Request([string[]]@('snapshot','epoch-four','connected','en'))) 'The explicit synthetic reconnect was rejected.'
 $reconnected=Wait-Result $owner
 $retained=@($reconnected.Value.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-claude'})
 Require ($reconnected.Success -and $retained.Count -eq 1 -and -not $retained[0].Active -and
  [string]$retained[0].Status -ceq $unconfirmed) 'Explicit reconnect did not conservatively retain the prior Claude task.'
 Write-Output ('Local synthetic source owner: actual Codex and Claude functions, real compact handler while the Codex read is gated ({0} ms), stamped selection preservation, later new-task focus, stale-result rejection and conservative Claude epoch transition verified.' -f $click.ElapsedMilliseconds)
}finally{
 [void]$release.Set()
 if($null -ne $owner){
  $owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
  if(-not $owner.CanReplace){throw 'The synthetic source owner did not close cleanly.'}
 }
 $started.Dispose();$release.Dispose()
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic source cleanup target.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
