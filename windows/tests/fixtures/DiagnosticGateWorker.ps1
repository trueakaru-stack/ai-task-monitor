param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class DiagnosticGateServerIdentity {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
try{
 $pipe.Connect(5000);$server=[uint32]0
 if(-not [DiagnosticGateServerIdentity]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected synthetic owner.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $sequence=0
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic request.'}
  $bytes=$reader.ReadBytes($length);if($bytes.Length -ne $length){throw 'Incomplete synthetic request.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  $sequence++
  $started=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[0]);$release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[1])
  try{[void]$started.Set();[void]$release.WaitOne()}finally{$started.Dispose();$release.Dispose()}
  $warning=[PSCustomObject]@{Key='codex:first';Warning=$true;Dismissed=$false;Threshold=$(if($sequence -eq 1){5}else{8});WindowMinutes=10;Token=([Guid]::NewGuid().ToString('N'))}
  $result=[PSCustomObject]@{Failed=$false;Warnings=@($warning);ClearAck='';DismissAck=@()}
  $payload=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($result,24))
  $writer.Write([int]$payload.Length);$writer.Write($payload);$writer.Flush()
 }
}finally{$pipe.Dispose()}
