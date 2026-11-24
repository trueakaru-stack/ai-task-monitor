param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SyntheticPipeServerIdentity {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
try {
 $pipe.Connect(5000)
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
  if([string]$message.Request.Kind -ceq 'block'){
   $started=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration.Started)
   $release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration.Release)
   [void]$started.Set()
   [void]$release.WaitOne()
   $started.Dispose();$release.Dispose()
  }
  $result=[PSCustomObject]@{Sequence=$sequence;Kind=[string]$message.Request.Kind;Language=[string]$message.Request.Language;Connected=[bool]$message.Request.Connected}
  $resultXml=[Management.Automation.PSSerializer]::Serialize($result,24)
  $resultBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($resultXml)
  $writer.Write([int]$resultBytes.Length)
  $writer.Write($resultBytes)
  $writer.Flush()
 }
}finally{$pipe.Dispose()}
