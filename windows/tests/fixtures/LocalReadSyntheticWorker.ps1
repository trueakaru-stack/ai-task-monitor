param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
try{Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SyntheticPipeServerIdentity {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
}catch{exit 110}
try{$pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)}catch{exit 111}
try {
 try{$pipe.Connect(5000)}catch{
  $failure=$_.Exception.GetBaseException()
  if($failure -is [TimeoutException]){exit 112}
  if($failure -is [UnauthorizedAccessException]){exit 113}
  if($failure -is [IO.IOException]){exit 114}
  exit 115
 }
 $server=[uint32]0
 if(-not [SyntheticPipeServerIdentity]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected synthetic server.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $sequence=0
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic frame.'}
  $bytes=$reader.ReadBytes($length)
  if($bytes.Length -ne $length){throw 'Incomplete synthetic frame.'}
  $xml=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
  $message=[Management.Automation.PSSerializer]::Deserialize($xml)
  $sequence++
  if([string]$message.Request[0] -ceq 'block'){
   $started=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[0])
   $release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[1])
   [void]$started.Set()
   [void]$release.WaitOne()
   $started.Dispose();$release.Dispose()
  }
  $result=[PSCustomObject]@{Sequence=$sequence;Kind=[string]$message.Request[0];Language=[string]$message.Request[1];Connected=([string]$message.Request[2] -ceq 'true');IsError=([string]$message.Request[0] -ceq 'error')}
  $resultXml=[Management.Automation.PSSerializer]::Serialize($result,24)
  $resultBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($resultXml)
  $writer.Write([int]$resultBytes.Length)
  $writer.Write($resultBytes)
  $writer.Flush()
 }
}finally{$pipe.Dispose()}
