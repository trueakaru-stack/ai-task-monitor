$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'The synthetic WPF check requires STA.'}
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -AssemblyName PresentationFramework
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
. (Join-Path $PSScriptRoot '..\app\DiagnosticClient.ps1')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
Require ($errors.Count -eq 0) 'The production UI source did not parse.'
$definitions=foreach($name in @('Prop','Brush','Text','Localized-TaskTitle','Localized-TaskActivity','Localized-CompactTaskActivity',
 'Plan-StatusNote','Progress-Label','Get-LoopWarning','Add-LoopWarning','Add-ConditionalHint','New-ActivityIndicator','New-TaskTitleLine',
 'Active-PlanStepIndex','Compact-AgentStepLabel','Compact-ProgressLabel','Compact-ExtraAgentStepLabel','Related-AgentStatus','New-RelatedAgentToggle',
 'Compact-VisibleTasks','Compact-ShowProviderLabels','Compact-HasHiddenAgentTasks','Source-WarningText','Compact-Height',
 'Add-CompactTask','Add-CompactDot','Sync-CompactDots','Render-CompactTasks','Related-AgentFingerprint','Refresh-Diagnostics','Save-LoopControls','Update-View')){
 $node=$ast.Find({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name},$true)
 if($null -eq $node){throw ('Missing production function: '+$name)};$node.Extent.Text
}
. ([scriptblock]::Create(($definitions -join "`n")))
$tickNodes=@($ast.FindAll({param($item)$item -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
 $item.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $item.Expression.VariablePath.UserPath -ceq 'timer' -and
 [string]$item.Member.Value -ceq 'Add_Tick'},$true))
Require ($tickNodes.Count -eq 1 -and $tickNodes[0].Arguments.Count -eq 1) 'The actual timer callback was not identified.'
$tick=$tickNodes[0].Arguments[0].ScriptBlock.GetScriptBlock()
function Tr([string]$value){return $value}
function Move-CompactWindow {}
function Refresh-SystemTheme {}
function Refresh-ActivityMotion {}
function Schedule-ClaudeRetention {$script:scheduled++}
function Invoke-UpdateCheckTick {}
function Save-DiagnosticSettings {param($Directory,[int]$LoopThreshold,[int]$LoopWindowMinutes);$script:savedThreshold=$LoopThreshold}
function Get-DiagnosticSettings {param($Directory);return [PSCustomObject]@{LoopThreshold=8;LoopWindowMinutes=10}}
function Update-LoopSettings {}
function Session-File([string]$id){throw 'The UI must not synchronously read a diagnostic session.'}
function Thread-State([string]$id){throw 'The UI must not synchronously read a diagnostic state.'}
function Source-Snapshot {$script:snapshots++;return [PSCustomObject]@{Tasks=$script:syntheticTasks;Unavailable=@();PartialConnection=@();PartialData=@();CodexIncomplete=$false}}
function Resolve-CurrentTaskOrder($tasks,$previous,[string]$selectedId,$client,[long]$selectionRevision){return [PSCustomObject]@{Tasks=@($tasks);SelectedId=$selectedId}}
function Sync-ClaudeLoopChannel {}
function Render-ProviderTabs($tasks) {}
function Filtered-Tasks($tasks){return $tasks}
function Render-CurrentTasks($tasks,$allTasks){Render-CompactTasks $allTasks}
$window=[PSCustomObject]@{Height=0.0;Resources=@{CompactDotStyle=[Windows.Style]::new([Windows.Controls.Button]);SourceActionStyle=[Windows.Style]::new([Windows.Controls.Button]);KeyboardFocusStyle=$null}}
$compactDotsPanel=[Windows.Controls.StackPanel]::new();$compactTasksPanel=[Windows.Controls.StackPanel]::new();$compactMoreText=[Windows.Controls.TextBlock]::new();$tasksPanel=[Windows.Controls.StackPanel]::new()
$script:palette=[PSCustomObject]@{Scroll='#888888';Primary='#222222';Activity='#333333';Muted='#777777';Secondary='#777777'};$script:accentHex='#0066CC'
$script:resolvedLanguage='en';$script:isCompact=$true;$script:motionEnabled=$false;$script:previewHintTarget=$null
$script:sourceErrors=@();$script:sourcePartialConnections=@();$script:sourcePartialData=@();$script:sourceCodexIncomplete=$false
$script:diagnosticRuntime=[PSCustomObject]@{LoopStates=@{};Settings=[PSCustomObject]@{LoopThreshold=5;LoopWindowMinutes=10}};$script:diagnosticError='';$script:journalUiError='';$script:journalFingerprint=''
$script:diagnosticDirectory='synthetic';$script:updatingLoopControls=$false;$script:loopUiError='';$script:savedThreshold=0
$loopThresholdCombo=[PSCustomObject]@{SelectedItem=[PSCustomObject]@{Tag=8}};$loopWindowCombo=[PSCustomObject]@{SelectedItem=[PSCustomObject]@{Tag=10}}
$script:claudeLoopStates=@{};$script:showingSettings=$false;$script:showingJournal=$false;$script:compactSelectionRevision=[long]0
$script:compactTaskId='first';$script:selectedProvider='all';$script:fingerprint='';$script:scheduled=0;$script:snapshots=0
$PreviewRelatedAgents=$false;$CompactMode=$true;$PreviewActiveTasks=-1;$PreviewLoopWarning=$false;$SnapshotFile=''
$now=[DateTime]::Now
$script:syntheticTasks=@(
 [PSCustomObject]@{Id='first';Title='First';Provider='codex';ProviderName='Codex';Active=$true;Paused=$false;Status='active';Activity='Checking';ProgressKind='none';Progress=$null;Steps=@();Started=$now;Updated=$now},
 [PSCustomObject]@{Id='second';Title='Second';Provider='claude';ProviderName='Claude Code';Active=$true;Paused=$false;Status='active';Activity='Working';ProgressKind='none';Progress=$null;Steps=@();Started=$now;Updated=$now}
)
$script:lastAllTasks=@($script:syntheticTasks);$script:lastTasks=@()
$startName='Local\AITMDiagnosticStart-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMDiagnosticRelease-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName)
$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
$owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $PSScriptRoot 'fixtures\DiagnosticGateWorker.ps1'),[string[]]@($startName,$releaseName))
$script:diagnosticClient=New-DiagnosticClient $owner
try{
 & $tick
 $watch=[Diagnostics.Stopwatch]::StartNew();$entered=$false
 while($watch.ElapsedMilliseconds -lt 10000){if($started.WaitOne(50)){$entered=$true;break};if($owner.FailureStage){break}}
 Require $entered ('The synthetic diagnostic reader did not block; stage='+$owner.Stage+'; failure='+$owner.FailureStage+'; kind='+$owner.FailureKind+'; code='+$owner.FailureHResult)
 Require ($compactDotsPanel.Children.Count -eq 2 -and $script:snapshots -eq 1 -and $script:scheduled -eq 1) 'The actual timer did not reach diagnostic refresh and compact rendering.'
 $clock=[Diagnostics.Stopwatch]::StartNew();& $tick;$clock.Stop();$tickMs=$clock.ElapsedMilliseconds
 Require ($tickMs -lt 1000 -and -not $release.WaitOne(0) -and $script:snapshots -eq 2 -and $script:scheduled -eq 2) 'The timer waited for a blocked diagnostic read.'
 $dot=@($compactDotsPanel.Children|Where-Object {[string]$_.Tag -ceq 'second'})[0]
 $clock.Restart();$dot.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 1000 -and $script:compactTaskId -ceq 'second' -and -not $release.WaitOne(0)) 'The actual compact dot waited for the blocked diagnostic read.'
 $oldGeneration=$owner.Generation;Save-LoopControls
 Require ($script:savedThreshold -eq 8 -and $owner.Generation -ne $oldGeneration -and $script:diagnosticRuntime.LoopStates.Count -eq 0) 'Saving a new threshold did not invalidate the outstanding old warning.'
 [void]$release.Set();$clock.Restart()
 while(($owner.IsPolling -or $owner.HasPendingRequest) -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require ($null -eq $owner.TryReceive()) 'A response with the previous diagnostic settings survived invalidation.'
 $clock.Restart()
 do{& $tick;if($script:diagnosticClient.Fresh){break};Start-Sleep -Milliseconds 20}while($clock.ElapsedMilliseconds -lt 10000)
 Require ($script:diagnosticClient.Fresh -and -not $script:diagnosticError -and $script:compactTaskId -ceq 'second' -and
  $script:diagnosticClient.Warnings.ContainsKey('codex:first') -and $script:diagnosticClient.Warnings['codex:first'].Threshold -eq 8) 'The diagnostic client failed to recover with the updated threshold or changed the selected task.'
 Write-Output ('Actual timer callback and compact dot: synthetic source snapshot, real UI update and blocked diagnostic worker verified ('+$tickMs+' ms timer).')
}finally{
 [void]$release.Set();$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 $started.Dispose();$release.Dispose()
 if(-not $owner.CanReplace){throw 'The synthetic diagnostic owner did not close safely.'}
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
