param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
try{
 $pipe.Connect(5000)
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class DiagnosticQueueServerIdentity {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
 $server=[uint32]0
 if(-not [DiagnosticQueueServerIdentity]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected synthetic owner.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true);$first=$true
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic frame.'}
  $bytes=$reader.ReadBytes($length);if($bytes.Length -ne $length){throw 'Incomplete synthetic frame.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  if($first){
   $first=$false;$started=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[0]);$release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[1])
   try{[void]$started.Set();[void]$release.WaitOne()}finally{$started.Dispose();$release.Dispose()}
  }
  $tasks=@($message.Request|Where-Object {[string]$_ -clike 'tasks:*'}) -join '|'
  $clear=@($message.Request|Where-Object {[string]$_ -clike 'clear:*'}|ForEach-Object {$_.Substring(6)})
  $clearAck=if($clear.Count){[string]$clear[0]}else{''}
  [IO.File]::AppendAllText([string]$message.Configuration[2],($tasks+'|clear='+$clearAck+"`n"),[Text.UTF8Encoding]::new($false))
  $result=[PSCustomObject]@{Failed=$false;Warnings=@();ClearAck=$clearAck;DismissAck=@()}
  $payload=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($result,24))
  $writer.Write([int]$payload.Length);$writer.Write($payload);$writer.Flush()
 }
}finally{$pipe.Dispose()}
