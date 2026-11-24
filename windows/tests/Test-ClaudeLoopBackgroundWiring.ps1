$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'The synthetic WPF check requires STA.'}
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 Add-Type -AssemblyName PresentationFramework,System.Web.Extensions
 Add-Type -Path @((Join-Path $PSScriptRoot '..\app\ClaudeLoopChannel.cs'),(Join-Path $PSScriptRoot '..\app\ClaudeLoopBackground.cs'),(Join-Path $PSScriptRoot 'fixtures\SyntheticClaudeLoopSource.cs')) -ReferencedAssemblies System.Web.Extensions
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The application source did not parse.'}
 $definitions=foreach($name in @('Prop','Brush','Text','Localized-TaskTitle','Localized-TaskActivity','Localized-CompactTaskActivity',
  'Plan-StatusNote','Progress-Label','Get-LoopWarning','Add-LoopWarning','Add-ConditionalHint','New-ActivityIndicator','New-TaskTitleLine',
  'Active-PlanStepIndex','Compact-AgentStepLabel','Compact-ProgressLabel','Compact-ExtraAgentStepLabel','Related-AgentStatus','New-RelatedAgentToggle',
  'Compact-VisibleTasks','Compact-ShowProviderLabels','Compact-HasHiddenAgentTasks','Source-WarningText','Compact-Height',
  'Add-CompactTask','Add-CompactDot','Sync-CompactDots','Render-CompactTasks','Sync-ClaudeLoopChannel')){
  $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
  if($null -eq $node){throw "Missing production function: $name"};$node.Extent.Text
 }
 . ([scriptblock]::Create(($definitions -join "`n")))
 function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
 function Tr([string]$value){return $value}
 function Move-CompactWindow {}
 $window=[PSCustomObject]@{Height=0.0;Resources=@{CompactDotStyle=[Windows.Style]::new([Windows.Controls.Button])}}
 $compactDotsPanel=[Windows.Controls.StackPanel]::new();$compactTasksPanel=[Windows.Controls.StackPanel]::new();$compactMoreText=[Windows.Controls.TextBlock]::new()
 $script:palette=[PSCustomObject]@{Scroll='#888888';Primary='#222222';Activity='#333333';Muted='#777777'};$script:accentHex='#0066CC'
 $script:resolvedLanguage='en';$script:isCompact=$true;$script:motionEnabled=$false;$script:previewHintTarget=$null
 $script:sourceErrors=@();$script:sourcePartialConnections=@();$script:sourcePartialData=@();$script:sourceCodexIncomplete=$false
 $script:diagnosticRuntime=[PSCustomObject]@{Settings=[PSCustomObject]@{LoopThreshold=5;LoopWindowMinutes=10}}
 $script:claudeLoopStates=@{};$script:claudeLoopError='';$script:claudeLoopModulesAvailable=$true;$script:compactSelectionRevision=[long]0
 $PreviewRelatedAgents=$false;$CompactMode=$true;$PreviewActiveTasks=-1;$PreviewLoopWarning=$false;$PreviewClaudeLoopPipe='AITM.Test.synthetic'
 $script:compactTaskId='first';$script:lastAllTasks=@(
  [PSCustomObject]@{Id='first';Title='First';Provider='synthetic';ProviderName='Synthetic';Active=$true;Status='active';Activity='Checking';ProgressKind='none';Progress=$null;Steps=@()},
  [PSCustomObject]@{Id='second';Title='Second';Provider='synthetic';ProviderName='Synthetic';Active=$true;Status='active';Activity='Working';ProgressKind='none';Progress=$null;Steps=@()}
 )
 $controller=[SyntheticClaudeLoopController]::new();$factory=[Delegate]::CreateDelegate([Func[AITaskMonitor.ClaudeLoop.ILoopSource]],$controller,'Create')
 $script:claudeLoopChannel=[AITaskMonitor.ClaudeLoop.BackgroundChannel]::new($factory,350)
 try{
  Render-CompactTasks $script:lastAllTasks
  $clock=[Diagnostics.Stopwatch]::StartNew();Sync-ClaudeLoopChannel;$clock.Stop()
  Require ($clock.ElapsedMilliseconds -lt 1000 -and $controller.CreateEntered.Wait(10000)) 'Production synchronization waited for channel startup.'
  $dot=@($compactDotsPanel.Children|Where-Object {[string]$_.Tag -ceq 'second'})[0]
  $clock.Restart();$dot.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$clock.Stop()
  Require ($clock.ElapsedMilliseconds -lt 1000 -and $script:compactTaskId -ceq 'second' -and -not $controller.CreateRelease.IsSet) 'The real task-dot handler waited for the blocked Claude channel.'
  $script:claudeLoopStates['old']=[PSCustomObject]@{Warning=$true}
  Start-Sleep -Milliseconds 450;Sync-ClaudeLoopChannel
  Require ($script:claudeLoopError -and $script:claudeLoopStates.Count -eq 0) 'A stuck channel hid its unavailable state or retained a stale warning.'
  $controller.CreateRelease.Set();$deadline=[Diagnostics.Stopwatch]::StartNew()
  while(-not $script:claudeLoopChannel.IsReady -and $deadline.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
  Require $script:claudeLoopChannel.IsReady 'The synthetic channel did not recover from startup.'
  $controller.HoldNextDrain();Require ($controller.DrainEntered.Wait(10000)) 'The synthetic receiver did not block while draining.'
  $script:claudeLoopStates['old']=[PSCustomObject]@{Warning=$true}
  Start-Sleep -Milliseconds 450;Sync-ClaudeLoopChannel
  Require ($script:claudeLoopError -and $script:claudeLoopStates.Count -eq 0 -and $controller.Created -eq 1) 'A blocked Drain retained a stale warning or started another channel.'
  $script:sourceErrors=@('Claude Code');$clock.Restart();Sync-ClaudeLoopChannel;$clock.Stop()
  Require ($clock.ElapsedMilliseconds -lt 1000 -and -not $script:claudeLoopChannel.IsReady) 'Disconnect waited for the blocked Claude channel.'
  Write-Output ('Claude loop wiring: production sync and compact dot stayed responsive during blocked channel startup ('+$clock.ElapsedMilliseconds+' ms disconnect).')
 }finally{$controller.CreateRelease.Set();$controller.DrainRelease.Set();$controller.DisposeRelease.Set();$script:claudeLoopChannel.Dispose()}
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
