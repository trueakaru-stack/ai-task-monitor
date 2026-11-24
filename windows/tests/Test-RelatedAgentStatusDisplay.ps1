$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'The synthetic WPF check requires STA.'}
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 Add-Type -AssemblyName PresentationFramework
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The application source did not parse.'}
 $definitions=foreach($name in @('Prop','Related-AgentStatus','Related-AgentFingerprint','Add-RelatedAgentList','Add-RelatedAgentContent','Add-CompactTask')){
  $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
  if($null -eq $node){throw "Missing production function: $name"};$node.Extent.Text
 }
 . ([scriptblock]::Create(($definitions -join "`n")))
 function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
 function Tr([string]$value){return $value}
 function Text([string]$value,[double]$size,[string]$color,[string]$weight='Normal'){$block=[Windows.Controls.TextBlock]::new();$block.Text=$value;return $block}
 function New-TaskTitleLine($task,[double]$margin,[bool]$fixedHeight){return [Windows.Controls.TextBlock]::new()}
 function Compact-ProgressLabel($task){return ''}
 function Compact-ExtraAgentStepLabel($task){return ''}
 function Compact-AgentStepLabel($task){return ''}
 function Localized-CompactTaskActivity($task){return 'Working'}
 function New-ActivityIndicator([bool]$active){return [Windows.Controls.Border]::new()}
 function Plan-StatusNote($task){return ''}
 function Add-LoopWarning($panel,$task,[bool]$compact){}
 function Add-ConditionalHint($block,[string]$text,[string]$mode='line'){}
 $script:palette=[PSCustomObject]@{Primary='#222222';Activity='#555555';Muted='#777777'}
 $script:compactShowProviderLabels=$false;$script:relatedAgentsExpanded=@{};$script:previewHintTarget=$null
 $PreviewActiveTasks=-1;$CompactMode=$true;$compactTasksPanel=[Windows.Controls.StackPanel]::new()
 $task=[PSCustomObject]@{Id='synthetic';Provider='codex';Active=$true;ProgressKind='none';Progress=$null;RelatedAgentCount=2;RelatedAgentCountUnconfirmed=$false;RelatedAgentsUnconfirmed=$false;RelatedAgents=@();Steps=@()}
 foreach($case in @(
  @{language='en';count=$true;status=$false;text='Agent count unconfirmed'},
  @{language='en';count=$true;status=$true;text='Agent count and status unconfirmed'},
  @{language='en';count=$false;status=$true;text='Agent status unconfirmed'},
  @{language='ru';count=$true;status=$false;text='Число агентов не подтверждено'},
  @{language='ru';count=$true;status=$true;text='Число и статус агентов не подтверждены'},
  @{language='ru';count=$false;status=$true;text='Статус агентов не подтверждён'}
 )){
  $script:resolvedLanguage=$case.language;$task.RelatedAgentCountUnconfirmed=$case.count;$task.RelatedAgentsUnconfirmed=$case.status
  $full=[Windows.Controls.StackPanel]::new();Add-RelatedAgentContent $full $task $false
  $compactTasksPanel.Children.Clear();Add-CompactTask $task
  $compactStatus=@($compactTasksPanel.Children[0].Children[2].Children|Where-Object {$_.Tag -ceq 'related-agent-status'})
  Require ($full.Children.Count -eq 1 -and $full.Children[0].Text -ceq $case.text -and
   $compactStatus.Count -eq 1 -and $compactStatus[0].Text -ceq $case.text) 'Compact and full views did not distinguish count uncertainty from agent status.'
 }
 $task.RelatedAgentsUnconfirmed=$false;$task.RelatedAgentCountUnconfirmed=$false
 $before=Related-AgentFingerprint $task
 $task.RelatedAgentCountUnconfirmed=$true
 Require ((Related-AgentFingerprint $task) -cne $before) 'Changing only count uncertainty did not invalidate rendering.'
 $task.RelatedAgentCount=0
 Require (-not (Related-AgentStatus $task)) 'Uncertainty was displayed for a zero count.'
 Write-Output 'Synthetic compact and full views: count and status uncertainty are distinct in both languages.'
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
