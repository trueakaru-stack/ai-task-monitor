$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 . (Join-Path $PSScriptRoot '..\app\LocalSourceCore.ps1')
 function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
 $unknown=-join @([int[]]@(1057,1090,1072,1090,1091,1089,32,1085,1077,32,1087,1086,1076,1090,1074,1077,1088,1078,1076,1105,1085)|ForEach-Object {[char]$_})
 $script:codexAgentRetention=New-CodexAgentRetention
 $script:lastCodexTasks=@();$script:lastClaudeTasks=@();$script:codexGroupLinks=@{};$script:codexGroupTitles=@{}
 $script:codexSourcePartial=$false;$script:codexDiscoveryFailed=$false;$script:codexTerminated=@{};$script:codexUnconfirmedEndings=@{}
 $ClaudeEventFile='';$script:mode='baseline';$script:claudeFailure=$false
 $paused=[PSCustomObject]@{Id='codex-paused';Provider='codex';Active=$false;Paused=$true;Status='paused';Activity='Old paused action';Steps=@();Progress=$null;ProgressKind='none';PlanConfirmed=$true}
 $waiting=[PSCustomObject]@{Id='codex-waiting';Provider='codex';Active=$false;Paused=$false;Status='waiting';Activity='Old waiting action';Steps=@();Progress=$null;ProgressKind='none';PlanConfirmed=$true}
 $script:fixtureClaude=[PSCustomObject]@{Id='claude:waiting';Provider='claude';Active=$false;Paused=$false;Status='waiting';Activity='Old Claude action';Steps=@();Progress=$null;ProgressKind='none';PlanConfirmed=$true}
 function Codex-Tasks {
  $script:codexTerminated=@{};$script:codexUnconfirmedEndings=@{};$script:codexGroupLinks=@{};$script:codexGroupTitles=@{}
  if($script:mode -ceq 'throw'){throw 'Synthetic Codex failure.'}
  $script:codexSourcePartial=$script:mode -ceq 'partial'
  if($script:mode -ceq 'baseline'){return @($paused,$waiting)}
  return @()
 }
 function Claude-Tasks {if($script:claudeFailure){throw 'Synthetic Claude failure.'};return @($script:fixtureClaude)}
 function Check-Retained($snapshot,[string]$case){
  $all=@($snapshot.Codex)+@($snapshot.Claude)
  Require ($all.Count -eq 3 -and @($snapshot.Unavailable) -ccontains 'Codex' -and @($snapshot.Unavailable) -ccontains 'Claude Code') ($case+': a source or card was lost.')
  foreach($task in $all){
   Require (-not $task.Active -and -not $task.Paused -and $task.Status -ceq $unknown -and $task.Activity -ceq $unknown) ($case+': an old state or action remained confirmed.')
  }
 }
 $baseline=Local-SourceSnapshot -ClaudeConnectionOverride 'connected'
 Require (@($baseline.Codex).Count -eq 2 -and @($baseline.Claude).Count -eq 1) ('The synthetic baseline was not established: Codex='+@($baseline.Codex).Count+' Claude='+@($baseline.Claude).Count+' unavailable='+(@($baseline.Unavailable)-join ','))
 $script:mode='partial';$script:claudeFailure=$true
 $partial=Local-SourceSnapshot -ClaudeConnectionOverride 'connected'
 Check-Retained $partial 'partial read'
 $script:mode='baseline';$script:claudeFailure=$false
 [void](Local-SourceSnapshot -ClaudeConnectionOverride 'connected')
 $script:mode='throw';$script:claudeFailure=$true
 $failed=Local-SourceSnapshot -ClaudeConnectionOverride 'connected'
 Check-Retained $failed 'source exception'
 Write-Output 'Production local snapshot fallback: paused and waiting synthetic Codex/Claude cards survive partial reads and exceptions as unconfirmed.'
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
