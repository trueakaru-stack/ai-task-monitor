$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path @((Join-Path $PSScriptRoot '../app/integrations/ProviderEventState.cs'),(Join-Path $PSScriptRoot '../app/integrations/ProviderEventChannel.cs')) -ReferencedAssemblies System.Web.Extensions
. (Join-Path $PSScriptRoot '../app/integrations/ProviderEventView.ps1')
. (Join-Path $PSScriptRoot '../app/integrations/ProviderRuntime.ps1')
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Send([string]$name,[string]$json){
 for($attempt=0;$attempt -lt 3;$attempt++){
  $stream=[IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut)
  try{
   $stream.Connect(2000)
   $bytes=[Text.Encoding]::UTF8.GetBytes($json);$header=[BitConverter]::GetBytes([int]$bytes.Length)
   $stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
   $ack=New-Object byte[] 1;$pending=$stream.BeginRead($ack,0,1,$null,$null)
   if(-not $pending.AsyncWaitHandle.WaitOne(2000)){throw 'Acknowledgement timed out.'}
   if($stream.EndRead($pending) -ne 1 -or $ack[0] -ne 6){throw 'Acknowledgement missing.'}
   return
  }catch{if($attempt -eq 2){throw};Start-Sleep -Milliseconds 10}finally{$stream.Dispose()}
 }
}
function Wait-Task([string]$id,[int]$stepCount=-1){
 $end=[DateTime]::UtcNow.AddSeconds(3)
 while([DateTime]::UtcNow -lt $end){
  $items=@(Read-ExternalProviderSnapshot -Channel $channel -Store $state -AllowedProviders @('opencode','deepseek'))
  $matches=@($items|Where-Object {$_.Id -eq $id -and ($stepCount -lt 0 -or $_.Steps.Count -eq $stepCount)})
  if($matches.Count){return $items}
  Start-Sleep -Milliseconds 20
 }
 throw 'Timed out waiting for a synthetic provider task.'
}
$name='AITaskMonitor.Test.'+[Guid]::NewGuid().ToString('N')
$channel=[AITaskMonitor.ExternalProviders.EventChannel]::new($name)
$state=[AITaskMonitor.ExternalProviders.StateStore]::new()
try{
 [void]@(Read-ExternalProviderSnapshot -Channel $channel -Store $state -AllowedProviders @('opencode','deepseek'))
 Send $name '{"version":1,"provider":"hermes","session":"disabled","kind":"active"}'
 Start-Sleep -Milliseconds 100
 $items=@(Read-ExternalProviderSnapshot -Channel $channel -Store $state -AllowedProviders @('opencode','deepseek'))
 Assert ($items.Count -eq 0) 'A disconnected provider created a task.'
 Send $name '{"version":1,"provider":"opencode","session":"one","kind":"tool_started","call":"c1","action":"command"}'
 $items=@(Wait-Task 'opencode:one')
 Assert ($items[0].Active -and $items[0].Activity) 'The active source action was lost.'
 Send $name '{"version":1,"provider":"opencode","session":"one","kind":"plan","steps":[{"title":"One","status":"done"},{"title":"Two","status":"active"}]}'
 $items=@(Wait-Task 'opencode:one' 2)
 Assert ($items[0].Progress -eq 50 -and $items[0].ProgressBasis -eq 'steps') 'The received plan was not mapped accurately.'
 Send $name '{"version":1,"provider":"deepseek","session":"two","kind":"waiting"}'
 $items=@(Wait-Task 'deepseek:two')
 $waiting=@($items|Where-Object Provider -eq 'deepseek')[0]
 Assert ($waiting.Paused -and -not $waiting.Active -and $waiting.StartKey) 'Approval must remain a separate waiting task.'
 $aged=@(Read-ExternalProviderSnapshot -Channel $channel -Store $state -AllowedProviders @('opencode','deepseek') -Now ([DateTimeOffset]::UtcNow.AddMinutes(31)))
 Assert (@($aged|Where-Object {$_.Active -or $_.Paused}).Count -eq 0) 'Old channel events were treated as current activity.'
 $retained=@(Read-ExternalProviderSnapshot -Channel $channel -Store $state -AllowedProviders @('deepseek'))
 Assert (@($retained|Where-Object Provider -eq 'opencode').Count -eq 0) 'Disconnected provider tasks remained visible.'
 Send $name '{"version":1,"provider":"opencode","session":"while_disconnected","kind":"active"}'
 Send $name '{"version":1,"provider":"deepseek","session":"barrier","kind":"active"}'
 $end=[DateTime]::UtcNow.AddSeconds(3)
 do {
  $retained=@(Read-ExternalProviderSnapshot -Channel $channel -Store $state -AllowedProviders @('deepseek'))
  if(@($retained|Where-Object Id -eq 'deepseek:barrier').Count){break}
  Start-Sleep -Milliseconds 20
 } while([DateTime]::UtcNow -lt $end)
 Assert (@($retained|Where-Object Id -eq 'deepseek:barrier').Count -eq 1) ('Timed out waiting for disconnected-source barrier. '+$channel.DiagnosticCounts)
 $reconnected=@(Read-ExternalProviderSnapshot -Channel $channel -Store $state -AllowedProviders @('opencode','deepseek'))
 Assert (@($reconnected|Where-Object Provider -eq 'opencode').Count -eq 0) 'Old tasks reappeared after reconnecting without a new event.'
 Send $name '{"version":1,"provider":"opencode","session":"fresh","kind":"active"}'
 $reconnected=@(Wait-Task 'opencode:fresh')
 Assert (@($reconnected|Where-Object Id -eq 'opencode:fresh').Count -eq 1) 'A fresh task did not appear after reconnecting.'
}finally{$channel.Dispose()}
Assert ($channel.IsStopped) 'The provider channel did not stop.'
Write-Output 'External provider pipeline: connected-source isolation, multiple tasks, plans, waiting and stale receipt verified.'
