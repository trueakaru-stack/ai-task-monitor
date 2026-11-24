param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
try{Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SyntheticClientServerIdentity {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
}catch{exit 110}
try{$pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)}catch{exit 111}
try{
 try{$pipe.Connect(5000)}catch{
  $failure=$_.Exception.GetBaseException()
  if($failure -is [TimeoutException]){exit 112}
  if($failure -is [UnauthorizedAccessException]){exit 113}
  if($failure -is [IO.IOException]){exit 114}
  exit 115
 }
 $server=[uint32]0
 if(-not [SyntheticClientServerIdentity]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected synthetic owner.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $first=$true;$terminal=$false
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic request.'}
  $bytes=$reader.ReadBytes($length);if($bytes.Length -ne $length){throw 'Incomplete synthetic request.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  $injectFailure=$false
  if($first){
   $first=$false;$start=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[0]);$release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[1])
   try{[void]$start.Set();[void]$release.WaitOne()}finally{$start.Dispose();$release.Dispose()}
  }elseif(@($message.Configuration).Count -ge 4){
   $block=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[2])
   try{
    if($block.WaitOne(0)){
     [void]$block.Reset();$start=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[0]);$release=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[1]);$terminalMode=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[3])
     try{
      [void]$start.Set();[void]$release.WaitOne()
      if($terminalMode.WaitOne(0)){$terminal=$true}else{$injectFailure=$true}
     }finally{$start.Dispose();$release.Dispose();$terminalMode.Dispose()}
    }
   }finally{$block.Dispose()}
  }
  $request=@($message.Request);$language=[string]$request[3];$enabled=[string]$request[2] -ceq 'true'
  $now=[DateTime]::UtcNow
  $codex=[PSCustomObject]@{Id='synthetic-codex';Provider='codex';ProviderName='Codex';Title='Codex '+$language;Active=$true;Paused=$false;Status='working';Activity='Working';Steps=@();Progress=$null;ProgressKind='none';Started=$now.AddMinutes(-3);Updated=$now;StartKey='first'}
  $claude=[PSCustomObject]@{Id='claude:synthetic';Provider='claude';ProviderName='Claude Code';Title='Claude '+$language;Active=$true;Paused=$false;Status='working';Activity='Working';Steps=@();Progress=$null;ProgressKind='none';Started=$now.AddMinutes(-2);Updated=$now;StartKey='second'}
  $result=[PSCustomObject]@{Codex=@($codex);Claude=@($claude);Unavailable=@();PartialConnection=@();PartialData=@();CodexIncomplete=$false;ClaudeConnection=$(if($enabled){'connected'}else{'disconnected'})}
  if(@($message.Configuration).Count -ge 5 -and [string]$message.Configuration[4] -ceq 'focus'){
   $newTask=$codex.PSObject.Copy();$newTask.Id='synthetic-new';$newTask.Title='New task';$newTask.StartKey='new';$newTask.Started=$now.AddMinutes(-1)
   $result.Codex+=@($newTask)
   $extra=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[5])
   try{if($extra.WaitOne(0)){$later=$codex.PSObject.Copy();$later.Id='synthetic-later';$later.Title='Later task';$later.StartKey='later';$later.Started=$now;$result.Codex+=@($later)}}finally{$extra.Dispose()}
  }
  if($terminal){$result.Codex=@()}
  if(-not $enabled){$result.Claude=@()}
  if($injectFailure){$result.Unavailable=@('Codex');$result.PartialData=@('Codex')}
  if(@($message.Configuration).Count -ge 7){
   $afterSnapshot=[Threading.EventWaitHandle]::OpenExisting([string]$message.Configuration[6])
   try{
    if($afterSnapshot.WaitOne(0)){
     [void]$afterSnapshot.Reset();$startName=if(@($message.Configuration).Count -ge 9){[string]$message.Configuration[7]}else{[string]$message.Configuration[0]};$releaseName=if(@($message.Configuration).Count -ge 9){[string]$message.Configuration[8]}else{[string]$message.Configuration[1]}
     $start=[Threading.EventWaitHandle]::OpenExisting($startName);$release=[Threading.EventWaitHandle]::OpenExisting($releaseName)
     try{[void]$start.Set();[void]$release.WaitOne()}finally{$start.Dispose();$release.Dispose()}
    }
   }finally{$afterSnapshot.Dispose()}
  }
  $response=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($result,24))
  $writer.Write([int]$response.Length);$writer.Write($response);$writer.Flush()
 }
}finally{$pipe.Dispose()}
