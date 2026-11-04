param([string]$ApplicationDirectory='')
$ErrorActionPreference='Stop'
$appRoot=if($ApplicationDirectory){[IO.Path]::GetFullPath($ApplicationDirectory)}else{[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))}
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path (Join-Path $appRoot 'ClaudeLoopChannel.cs') -ReferencedAssemblies 'System.Web.Extensions'
Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class AITMDelayedPipeClose {
    public static Thread Start(IDisposable stream, int milliseconds) {
        Thread worker = new Thread(() => { Thread.Sleep(milliseconds); stream.Dispose(); });
        worker.IsBackground = true;
        worker.Start();
        return worker;
    }
}
'@
. (Join-Path $appRoot 'ClaudeLoopClient.ps1')

$name='AITM.Test.Contention.'+[guid]::NewGuid().ToString('N')
$channel=$null
$blocker=$null
$closeWorker=$null
$oldAudit=$env:AI_TASK_MONITOR_AUDIT
$oldChannelAudit=$env:AI_TASK_MONITOR_AUDIT_CHANNEL
try {
 $env:AI_TASK_MONITOR_AUDIT='1'
 $env:AI_TASK_MONITOR_AUDIT_CHANNEL='1'
 $event=[PSCustomObject]@{
  session_id='contention-session';hook_event_name='PreToolUse';tool_name='Bash';tool_use_id='contention-tool'
  cwd='synthetic-private-project';tool_input=[PSCustomObject]@{command='synthetic-private-command'}
 }
 # Warm up the client before timing the deliberately occupied channel.
 $env:AI_TASK_MONITOR_AUDIT_CHANNEL='0'
 $offlineWatch=[Diagnostics.Stopwatch]::StartNew()
 Send-ClaudeLoopEvent $event ('AITM.Test.Absent.'+[guid]::NewGuid().ToString('N'))
 $offlineWatch.Stop()
 if($offlineWatch.ElapsedMilliseconds -gt 500){throw 'A missing monitor delayed the hook unnecessarily.'}
 $env:AI_TASK_MONITOR_AUDIT_CHANNEL='1'
 $channel=[AITaskMonitor.ClaudeLoop.Channel]::new($name)
 $blocker=[IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
 $blocker.Connect(1000)
 $key=New-Object byte[] 32
 $offset=0
 while($offset -lt $key.Length){
  $read=$blocker.ReadAsync($key,$offset,$key.Length-$offset)
  if(-not $read.Wait(2000) -or $read.Result -le 0){throw 'The occupied-channel fixture did not receive its handshake.'}
  $offset+=$read.Result
 }
 [Array]::Clear($key,0,$key.Length)
 $closeWorker=[AITMDelayedPipeClose]::Start($blocker,180)
 Send-ClaudeLoopEvent $event $name
 if(-not $closeWorker.Join(3000)){throw 'The occupied-channel fixture did not close.'}
 $blocker=$null
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $delivered=$false
 $sawGap=$false
 do {
  $batch=$channel.Drain()
  if($batch.Gap){$sawGap=$true}
  foreach($item in $batch.Events){
   if($item.SessionId -ceq 'contention-session' -and $item.ToolId -ceq 'contention-tool' -and $item.Kind -ceq 'start'){$delivered=$true}
  }
  if(-not $delivered){Start-Sleep -Milliseconds 15}
 } while(-not $delivered -and $watch.ElapsedMilliseconds -lt 2000)
 if(-not $sawGap){throw 'The interrupted connection was not reported as a gap.'}
 if(-not $delivered){throw 'A valid hook event was lost while the local channel was temporarily occupied.'}
 $stalledName='AITM.Test.Stalled.'+[guid]::NewGuid().ToString('N')
 $stalledOwner=[Threading.Mutex]::new($false,'Local\'+$stalledName+'.owner')
 try {
  $env:AI_TASK_MONITOR_AUDIT_CHANNEL='0'
  $stalledWatch=[Diagnostics.Stopwatch]::StartNew()
  Send-ClaudeLoopEvent $event $stalledName
  $stalledWatch.Stop()
  if($stalledWatch.ElapsedMilliseconds -lt 400 -or $stalledWatch.ElapsedMilliseconds -gt 2000){throw 'The unresponsive monitor did not respect the bounded connection wait.'}
 } finally {$stalledOwner.Dispose()}
 Write-Output 'Claude loop transport: a temporarily occupied local channel recovers without dropping the next hook event.'
 Write-Output 'Claude loop transport: absent and unresponsive monitors keep the hook wait bounded.'
} finally {
 if($null -ne $blocker){$blocker.Dispose()}
 if($null -ne $closeWorker){[void]$closeWorker.Join(3000)}
 if($null -ne $channel){$channel.Dispose()}
 $env:AI_TASK_MONITOR_AUDIT=$oldAudit
 $env:AI_TASK_MONITOR_AUDIT_CHANNEL=$oldChannelAudit
}
