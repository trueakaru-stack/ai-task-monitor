$ErrorActionPreference='Stop'
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
$name='AITaskMonitor.Test.'+[Guid]::NewGuid().ToString('N')
$controller=New-ExternalProviderController -PipeName $name
try{
 Assert (@(Read-ManagedExternalProviderSnapshot -Controller $controller -AllowedProviders @()).Count -eq 0) 'An empty allowlist created tasks.'
 Assert ($null -eq $controller.Channel) 'A channel started without a connected source.'
 [void]@(Read-ManagedExternalProviderSnapshot -Controller $controller -AllowedProviders @('opencode'))
 Assert ($null -ne $controller.Channel) 'The connected source did not start its channel.'
 $firstChannel=$controller.Channel
 Send $name '{"version":1,"provider":"opencode","session":"one","kind":"active"}'
 $deadline=[DateTime]::UtcNow.AddSeconds(3)
 do {
  $tasks=@(Read-ManagedExternalProviderSnapshot -Controller $controller -AllowedProviders @('opencode'))
  if(@($tasks|Where-Object Id -eq 'opencode:one').Count){break}
  Start-Sleep -Milliseconds 20
 }while([DateTime]::UtcNow -lt $deadline)
 Assert (@($tasks|Where-Object {$_.Id -eq 'opencode:one' -and $_.Active}).Count -eq 1) 'The controller did not map a fresh event into a task.'
 Assert (@(Read-ManagedExternalProviderSnapshot -Controller $controller -AllowedProviders @()).Count -eq 0) 'A disconnected source retained tasks.'
 Assert ($firstChannel.IsStopped -and $null -eq $controller.Channel -and $null -eq $controller.Store) 'Disconnect did not stop the receiver and clear state.'
 $tasks=@(Read-ManagedExternalProviderSnapshot -Controller $controller -AllowedProviders @('opencode'))
 Assert ($tasks.Count -eq 0) 'A task reappeared after reconnect without a fresh event.'
 $secondChannel=$controller.Channel
}finally{Stop-ExternalProviderController $controller}
Assert ($secondChannel.IsStopped) 'The receiver was not stopped during shutdown.'
Write-Output 'External provider controller: lazy startup, task mapping, disconnect, reconnect and shutdown verified.'
