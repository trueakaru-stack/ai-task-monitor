param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
if($env:AITM_QUEUE_STAGE_BEGIN){$stage=[Threading.EventWaitHandle]::OpenExisting($env:AITM_QUEUE_STAGE_BEGIN);try{[void]$stage.Set()}finally{$stage.Dispose()}}
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
try{
 $pipe.Connect(5000)
 if($env:AITM_QUEUE_STAGE_CONNECTED){$stage=[Threading.EventWaitHandle]::OpenExisting($env:AITM_QUEUE_STAGE_CONNECTED);try{[void]$stage.Set()}finally{$stage.Dispose()}}
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class DiagnosticQueueServerIdentity {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
 if($env:AITM_QUEUE_STAGE_COMPILED){$stage=[Threading.EventWaitHandle]::OpenExisting($env:AITM_QUEUE_STAGE_COMPILED);try{[void]$stage.Set()}finally{$stage.Dispose()}}
 $server=[uint32]0
 if(-not [DiagnosticQueueServerIdentity]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected synthetic owner.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true);$first=$true;$sequence=0
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic frame.'}
  $bytes=$reader.ReadBytes($length);if($bytes.Length -ne $length){throw 'Incomplete synthetic frame.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  $sequence++
  if($first){
   $first=$false;$started=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[0]);$release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[1])
   try{[void]$started.Set();[void]$release.WaitOne()}finally{$started.Dispose();$release.Dispose()}
  }
  $tasks=@($message.Request|Where-Object {[string]$_ -clike 'tasks:*'}) -join '|'
  $clear=@($message.Request|Where-Object {[string]$_ -clike 'clear:*'}|ForEach-Object {$_.Substring(6)})
  $clearAck=if($clear.Count){[string]$clear[0]}else{''}
  [IO.File]::AppendAllText([string]$message.Configuration[2],($tasks+'|clear='+$clearAck+"`n"),[Text.UTF8Encoding]::new($false))
  if($sequence -eq 2 -and @($message.Configuration).Count -ge 5){
   $secondStarted=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[3]);$secondRelease=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[4])
   try{[void]$secondStarted.Set();[void]$secondRelease.WaitOne()}finally{$secondStarted.Dispose();$secondRelease.Dispose()}
  }
  $warnings=New-Object 'Collections.Generic.List[object]'
  if($tasks -cmatch 'codex,base,active' -and $tasks -cnotmatch 'brief'){$warnings.Add([PSCustomObject]@{Key='codex:base';Warning=$true;Dismissed=$false;Threshold=5;WindowMinutes=10;Token=('a'*32)})}
  $result=[PSCustomObject]@{Failed=$false;Warnings=$warnings.ToArray();ClearAck=$clearAck;DismissAck=@()}
  $payload=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($result,24))
  $writer.Write([int]$payload.Length);$writer.Write($payload);$writer.Flush()
 }
}finally{$pipe.Dispose()}
