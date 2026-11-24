$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'The synthetic WPF check requires STA.'}
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -AssemblyName PresentationFramework
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
. (Join-Path $PSScriptRoot '..\app\LocalSourceClient.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The application source did not parse.'}
$definitions=foreach($name in @('Prop','Brush','Text','Localized-TaskTitle','Localized-TaskActivity','Localized-CompactTaskActivity',
 'Plan-StatusNote','Progress-Label','Get-LoopWarning','Add-LoopWarning','Add-ConditionalHint','New-ActivityIndicator','New-TaskTitleLine',
 'Active-PlanStepIndex','Compact-AgentStepLabel','Compact-ProgressLabel','Compact-ExtraAgentStepLabel','Related-AgentStatus','New-RelatedAgentToggle',
 'Compact-VisibleTasks','Compact-ShowProviderLabels','Compact-HasHiddenAgentTasks','Prioritize-Tasks','Resolve-CurrentTaskOrder','Source-WarningText','Compact-Height',
 'Add-CompactTask','Add-CompactDot','Sync-CompactDots','Render-CompactTasks','Unconfirmed-Tasks','Source-Snapshot')){
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
 if($null -eq $node){throw "Missing production function: $name"};$node.Extent.Text
}
. ([scriptblock]::Create(($definitions -join "`n")))
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Tr([string]$value){return $value}
function Move-CompactWindow {}
function Local-SourceSnapshot {throw 'The UI attempted to read a source synchronously.'}
function Wait-Idle($owner){
 $deadline=[Diagnostics.Stopwatch]::StartNew()
 while($deadline.ElapsedMilliseconds -lt 10000){
  if($owner.HasResult){[void]$owner.TryReceive()}
  if(-not $owner.IsPolling -and -not $owner.HasPendingRequest -and -not $owner.HasResult){return}
  Start-Sleep -Milliseconds 10
 }
 throw 'The synthetic owner did not reach idle.'
}
$prefix='Local\AITaskMonitorWiring-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-started'))
$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-release'))
$block=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-block'))
$terminal=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-terminal'))
$extra=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-extra'))
$worker=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\LocalReadClientWorker.ps1'))
$owner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,[string[]]@(($prefix+'-started'),($prefix+'-release'),($prefix+'-block'),($prefix+'-terminal'),'focus',($prefix+'-extra')))
try{
 $window=[PSCustomObject]@{Height=0.0;Resources=@{CompactDotStyle=[Windows.Style]::new([Windows.Controls.Button])}}
 $compactDotsPanel=[Windows.Controls.StackPanel]::new();$compactTasksPanel=[Windows.Controls.StackPanel]::new();$compactMoreText=[Windows.Controls.TextBlock]::new()
 $script:palette=[PSCustomObject]@{Scroll='#888888';Primary='#222222';Activity='#333333';Muted='#777777'};$script:accentHex='#0066CC'
 $script:resolvedLanguage='en';$script:isCompact=$true;$script:motionEnabled=$false;$script:previewHintTarget=$null
 $script:sourceErrors=@();$script:sourcePartialConnections=@();$script:sourcePartialData=@();$script:sourceCodexIncomplete=$false
 $script:diagnosticRuntime=$null;$script:claudeLoopStates=@{};$script:compactSelectionRevision=[long]0
 $script:taskPriority=@{};$script:taskPriorityCounter=0;$script:monitorStartedUtc=[DateTime]::UtcNow.AddMinutes(-10)
 $script:externalProviderModulesAvailable=$false;$script:codexCloudModulesAvailable=$false
 $PreviewRelatedAgents=$false;$CompactMode=$true;$PreviewActiveTasks=-1;$PreviewLoopWarning=$false
 $script:localSourceClient=New-LocalSourceClient $owner 'en'
 $now=[DateTime]::UtcNow
 $first=[PSCustomObject]@{Id='synthetic-codex';Provider='codex';ProviderName='Codex';Title='Codex en';Active=$true;Paused=$false;Status='working';Activity='Working';Steps=@();Progress=$null;ProgressKind='none';Started=$now.AddMinutes(-3);Updated=$now;StartKey='first'}
 $second=[PSCustomObject]@{Id='claude:synthetic';Provider='claude';ProviderName='Claude Code';Title='Claude en';Active=$true;Paused=$false;Status='working';Activity='Working';Steps=@();Progress=$null;ProgressKind='none';Started=$now.AddMinutes(-2);Updated=$now;StartKey='second'}
 $script:localSourceClient.Snapshot=[PSCustomObject]@{Codex=@($first);Claude=@($second);Unavailable=@();PartialConnection=@();PartialData=@();CodexIncomplete=$false;ClaudeConnection='connected'}
 $script:compactTaskId=$first.Id;$script:lastAllTasks=@($first,$second)
 [void](Prioritize-Tasks $script:lastAllTasks @() $script:compactTaskId)
 Render-CompactTasks $script:lastAllTasks
 $cached=Source-Snapshot
 Require (@($cached.Tasks).Count -eq 2 -and $started.WaitOne(10000)) 'The production source path did not start a blocked background poll.'
 $dot=@($compactDotsPanel.Children|Where-Object {[string]$_.Tag -ceq $second.Id})[0]
 $clock=[Diagnostics.Stopwatch]::StartNew();$dot.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$clock.Stop()
 Require ($script:compactTaskId -ceq $second.Id -and $script:compactSelectionRevision -eq 1 -and
  -not $release.WaitOne(0) -and $clock.ElapsedMilliseconds -lt 1000) 'The production dot handler waited for the blocked source.'
 [void]$release.Set();$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 10;$read=Source-Snapshot}while(-not $script:localSourceClient.Fresh -and $deadline.ElapsedMilliseconds -lt 15000)
 Require ($script:localSourceClient.Fresh -and @($read.Tasks).Count -eq 3) 'The delayed source response was not published.'
 $ordered=Resolve-CurrentTaskOrder @($read.Tasks) $script:lastAllTasks $script:compactTaskId $script:localSourceClient $script:compactSelectionRevision
 Require ($ordered.SelectedId -ceq $second.Id) 'A delayed production result stole the manual task selection.'
 $script:lastAllTasks=@($ordered.Tasks);$script:compactTaskId=[string]$ordered.SelectedId
 Wait-Idle $owner;[void]$extra.Set();[void](Source-Snapshot);$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 10;$read=Source-Snapshot}while((-not $script:localSourceClient.Fresh -or @($read.Tasks).Count -lt 4) -and $deadline.ElapsedMilliseconds -lt 15000)
 $ordered=Resolve-CurrentTaskOrder @($read.Tasks) $script:lastAllTasks $script:compactTaskId $script:localSourceClient $script:compactSelectionRevision
 Require ($script:localSourceClient.Fresh -and $ordered.SelectedId -ceq 'synthetic-later') 'A later newly started task did not receive the expected selection.'
 Write-Output ('Production local wiring: real source function, task-dot handler and selection ordering checked while a synthetic reader was blocked ('+$clock.ElapsedMilliseconds+' ms).')
}finally{
 [void]$release.Set();$owner.Dispose();$started.Dispose();$release.Dispose();$block.Dispose();$terminal.Dispose();$extra.Dispose()
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
