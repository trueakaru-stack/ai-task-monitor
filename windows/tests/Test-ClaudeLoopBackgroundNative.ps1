$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 Add-Type -AssemblyName System.Web.Extensions
 Add-Type -Path @((Join-Path $PSScriptRoot '..\app\ClaudeLoopChannel.cs'),(Join-Path $PSScriptRoot '..\app\ClaudeLoopBackground.cs')) -ReferencedAssemblies System.Web.Extensions
 . (Join-Path $PSScriptRoot '..\app\ClaudeLoopClient.ps1')
 function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
 function Wait-Ready($owner){$deadline=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.IsReady -and $deadline.ElapsedMilliseconds -lt 10000){if($owner.HasError){throw 'Synthetic native channel startup failed.'};Start-Sleep -Milliseconds 10};Require $owner.IsReady 'Synthetic native channel did not become ready.'}
 function Send-Synthetic($owner,[string]$pipe,[string]$tool){
  $event=[PSCustomObject]@{session_id='synthetic-session';hook_event_name='PreToolUse';tool_name='Bash';tool_use_id=$tool;cwd='synthetic-directory';tool_input=[PSCustomObject]@{command='synthetic-command'}}
  Send-ClaudeLoopEvent $event $pipe
  $deadline=[Diagnostics.Stopwatch]::StartNew()
  do{
   $batch=$owner.Drain()
   if($batch.Gap){throw 'The synthetic native channel reported a gap.'}
   if(@($batch.Events).Count){return $batch.Events[0]}
   Start-Sleep -Milliseconds 10
  }while($deadline.ElapsedMilliseconds -lt 5000)
  throw 'The synthetic hook event did not reach the background owner.'
 }
 $pipe='AITM.Test.Background.'+[Guid]::NewGuid().ToString('N')
 $owner=[AITaskMonitor.ClaudeLoop.BackgroundChannel]::new($pipe)
 try{
  $owner.SetEnabled($true);Wait-Ready $owner
  $first=Send-Synthetic $owner $pipe 'first'
  Require ($first.Kind -ceq 'start' -and $first.SessionId -ceq 'synthetic-session' -and $first.Fingerprint -cmatch '^[a-f0-9]{64}$') 'The native channel did not pass a sanitized synthetic event.'
  $owner.SetEnabled($false);$owner.SetEnabled($true);Wait-Ready $owner
  $second=Send-Synthetic $owner $pipe 'second'
  Require ($second.Kind -ceq 'start' -and $second.Fingerprint -cne $first.Fingerprint) 'Reconnect reused a prior channel key or lost the event.'
  Write-Output 'Native Claude loop background: synthetic hook delivery and reconnection verified over a unique local pipe.'
 }finally{$owner.Dispose()}
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
