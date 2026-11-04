$ErrorActionPreference='Stop'
$app=Join-Path $PSScriptRoot '../app/CodexProgress.ps1'
$setup=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app/Configure-OpenCodeIntegration.ps1'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($app,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Application source could not be parsed.'}
$definitions=foreach($name in @('Prop','Unconfirmed-Tasks','Unconfirmed-ExternalTasks','Source-Snapshot')){
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if($null -eq $function){throw "Missing function: $name"}
 $function.Extent.Text
}
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-opencode-pipeline-'+[Guid]::NewGuid().ToString('N'))))
$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test directory.'}
[void][IO.Directory]::CreateDirectory($root)
$checks=@'
. $args[0]
. $args[1]
$script:fixtureSetup=$args[2];$script:fixtureHome=$args[3]
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Codex-Tasks {return [PSCustomObject]@{Id='codex:one';Active=$true;Status='working'}}
function Claude-ConnectionState {return 'connected'}
function Claude-Tasks {return [PSCustomObject]@{Id='claude:one';Active=$true;Status='working'}}
function Get-OpenCodeConnectionState {
 return (& {param($path,$homePath) . $path -Mode State -FixtureHome $homePath -ReturnStateToCaller} $script:fixtureSetup $script:fixtureHome)
}
function Set-FixtureConnection([string]$mode){
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
 $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$script:fixtureSetup+'" -Mode '+$mode+' -FixtureHome "'+$script:fixtureHome+'"'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $process=[Diagnostics.Process]::Start($start)
 try{
  if(-not $process.WaitForExit(5000)){$process.Kill();throw 'Fixture connection timed out.'}
  $errorOutput=$process.StandardError.ReadToEnd()
  Assert ($process.ExitCode -eq 0) ('Fixture connection failed: '+$errorOutput)
 }finally{$process.Dispose()}
}
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
$ClaudeEventFile='';$script:lastCodexTasks=@();$script:lastClaudeTasks=@();$script:lastExternalTasks=@()
$script:externalProviderModulesAvailable=$true;$script:externalProviderController=New-ExternalProviderController -PipeName $name
$script:lastOpenCodeConnected=$false;$script:resolvedLanguage='en'
try{
 Set-FixtureConnection 'Install'
 $initial=Source-Snapshot
 Assert (@($initial.Tasks).Count -eq 2 -and $null -ne $script:externalProviderController.Channel) 'The source did not start alongside existing sources.'
 Send $name '{"version":1,"provider":"opencode","session":"one","kind":"tool_started","call":"c1","action":"command"}'
 Send $name '{"version":1,"provider":"opencode","session":"one","kind":"plan","steps":[{"title":"First","status":"done"},{"title":"Second","status":"active"}]}'
 $deadline=[DateTime]::UtcNow.AddSeconds(3)
 do{
  $snapshot=Source-Snapshot
  $external=@($snapshot.Tasks|Where-Object Id -eq 'opencode:one')
  if($external.Count -and $external[0].Steps.Count -eq 2){break}
  Start-Sleep -Milliseconds 20
 }while([DateTime]::UtcNow -lt $deadline)
 Assert ($external.Count -eq 1 -and $external[0].Active -and $external[0].Progress -eq 50 -and $external[0].Title -eq 'OpenCode task') 'The real event pipeline did not produce an accurate task and plan.'
 Assert (@($snapshot.Tasks).Count -eq 3 -and $snapshot.Unavailable.Count -eq 0) 'Existing tasks were disturbed by the new source.'
 $channel=$script:externalProviderController.Channel
 Set-FixtureConnection 'Remove'
 $disconnected=Source-Snapshot
 Assert (@($disconnected.Tasks).Count -eq 2 -and $channel.IsStopped -and $null -eq $script:externalProviderController.Channel) 'Disconnect did not remove the task and stop the channel.'
}finally{Stop-ExternalProviderController $script:externalProviderController}
Write-Output 'OpenCode source pipeline: isolated connect, real pipe events, plan, coexistence and disconnect verified.'
'@
try{
 & ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks)) (Join-Path $PSScriptRoot '../app/integrations/ProviderEventView.ps1') (Join-Path $PSScriptRoot '../app/integrations/ProviderRuntime.ps1') $setup $root
}finally{
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
