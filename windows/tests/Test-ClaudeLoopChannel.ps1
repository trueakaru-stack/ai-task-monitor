$ErrorActionPreference='Stop'
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path (Join-Path $appRoot 'ClaudeLoopChannel.cs') -ReferencedAssemblies 'System.Web.Extensions'
. (Join-Path $appRoot 'ClaudeLoopClient.ps1')
if((Get-ClaudeLoopPipeName) -cne [AITaskMonitor.ClaudeLoop.Channel]::UserPipeName()){throw 'The hook and monitor disagree on the current-user channel.'}
$testRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-claude-channel-'+[guid]::NewGuid().ToString('N'))))
$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $testRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test directory.'}
[void][IO.Directory]::CreateDirectory($testRoot)
$oldLocal=$env:LOCALAPPDATA;$oldProfile=$env:USERPROFILE;$oldAudit=$env:AI_TASK_MONITOR_AUDIT
$pipeName='AITM.Test.Claude.'+[guid]::NewGuid().ToString('N')
$channel=$null
try{
 $env:LOCALAPPDATA=$testRoot;$env:USERPROFILE=$testRoot;$env:AI_TASK_MONITOR_AUDIT='1'
 $channel=[AITaskMonitor.ClaudeLoop.Channel]::new($pipeName)
 $securityField=[AITaskMonitor.ClaudeLoop.Channel].GetField('security',[Reflection.BindingFlags]'NonPublic,Instance')
 $rules=@($securityField.GetValue($channel).GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))
 $permitted=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18')
 if($rules.Count -ne 2 -or @($rules|Where-Object {$_.IdentityReference.Value -cnotin $permitted -or $_.AccessControlType -ne 'Allow'}).Count -ne 0){throw 'The channel permissions exceed the current-user and SYSTEM boundary.'}
 $duplicateRejected=$false
 try{$second=[AITaskMonitor.ClaudeLoop.Channel]::new($pipeName);$second.Dispose()}catch{$duplicateRejected=$true}
 if(-not $duplicateRejected){throw 'Two monitors accepted the same local channel.'}
 $hook=Join-Path $appRoot 'ClaudeTaskHook.ps1'
 $secret='SYNTHETIC_SECRET_COMMAND_54D2'
 $secretError='SYNTHETIC_SECRET_ERROR_21AB'
 $cwd=Join-Path $testRoot 'SYNTHETIC_PRIVATE_PROJECT'
 function Invoke-Hook([string]$kind,[string]$id,[string]$session='session-a',[string]$command=$secret,[string]$tool='Bash',[bool]$interrupt=$false,[string]$errorText="Exit code 7`n$secretError"){
  $payload=[ordered]@{session_id=$session;hook_event_name=$kind;tool_name=$tool;tool_use_id=$id;cwd=$cwd;tool_input=@{command=$command};is_interrupt=$interrupt;error=$errorText}
  $json=$payload|ConvertTo-Json -Depth 5 -Compress
  $output=@($json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook -LoopTestPipe $pipeName)
  if($LASTEXITCODE -ne 0 -or $output.Count -ne 0){throw 'The hook produced output or failed.'}
  $watch=[Diagnostics.Stopwatch]::StartNew()
  do{
   $batch=$channel.Drain()
   if($batch.Gap){throw 'The local channel dropped a synthetic event.'}
   if($batch.Events.Count -gt 0){
    if($batch.Events.Count -ne 1){throw 'Unexpected event batch.'}
    return $batch.Events[0]
   }
   Start-Sleep -Milliseconds 20
  }while($watch.ElapsedMilliseconds -lt 2000)
  throw 'A synthetic hook event did not reach the monitor.'
 }
 $start=Invoke-Hook 'PreToolUse' 'tool-1'
 $failure=Invoke-Hook 'PostToolUseFailure' 'tool-1'
 if($start.Kind -cne 'start' -or $failure.Kind -cne 'failed' -or $failure.ExitCode -ne 7 -or $start.Fingerprint -cne $failure.Fingerprint){throw 'Matching command events were not sanitized and matched.'}
 if($failure.Fingerprint -cnotmatch '^[a-f0-9]{64}$' -or $null -ne $failure.PSObject.Properties['Command'] -or $null -ne $failure.PSObject.Properties['Cwd']){throw 'The event exposes unsanitized input.'}
 $different=Invoke-Hook 'PreToolUse' 'tool-2' 'session-a' ($secret+'-different')
 if($different.Fingerprint -ceq $start.Fingerprint){throw 'Different commands have the same fingerprint.'}
 $otherShell=Invoke-Hook 'PreToolUse' 'tool-3' 'session-a' $secret 'PowerShell'
 if($otherShell.Fingerprint -ceq $start.Fingerprint){throw 'Different shells have the same fingerprint.'}
 $unknown=Invoke-Hook 'PostToolUseFailure' 'tool-4' 'session-a' $secret 'Bash' $false 'shell could not start'
 if($unknown.Kind -cne 'reset' -or $unknown.Fingerprint){throw 'An unstructured error must reset the sequence.'}
 $interrupted=Invoke-Hook 'PostToolUseFailure' 'tool-5' 'session-a' $secret 'Bash' $true
 if($interrupted.Kind -cne 'reset'){throw 'An interrupted command must reset the sequence.'}
 $edit=Invoke-Hook 'PostToolUse' 'tool-6' 'session-a' $secret 'Edit'
 if($edit.Kind -cne 'edit'){throw 'An observed file edit must reset the sequence.'}
 $other=Invoke-Hook 'PreToolUse' 'tool-7' 'session-b'
 if($other.SessionId -cne 'session-b'){throw 'Concurrent sessions were not separated.'}

 $malformed=[IO.Pipes.NamedPipeClientStream]::new('.',$pipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
 try{
  $malformed.Connect(1000)
  $unusedKey=New-Object byte[] 32
  $received=0
  while($received -lt $unusedKey.Length){
   $read=$malformed.ReadAsync($unusedKey,$received,$unusedKey.Length-$received)
   if(-not $read.Wait(2000) -or $read.Result -le 0){throw 'The malformed-frame test could not receive the handshake.'}
   $received+=$read.Result
  }
  $badLength=[BitConverter]::GetBytes([int]5000)
  $malformed.Write($badLength,0,$badLength.Length)
  $malformed.Flush()
 }finally{$malformed.Dispose();[Array]::Clear($unusedKey,0,$unusedKey.Length)}
 $watch=[Diagnostics.Stopwatch]::StartNew()
 do{
  $batch=$channel.Drain()
  if($batch.Gap){break}
  Start-Sleep -Milliseconds 20
 }while($watch.ElapsedMilliseconds -lt 2000)
 if(-not $batch.Gap -or $batch.Events.Count -ne 0){throw 'An oversized frame must clear the pending sequence and report a gap.'}

 $wireName='AITM.Test.Wire.'+[guid]::NewGuid().ToString('N')
 $wire=[IO.Pipes.NamedPipeServerStream]::new($wireName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
 $process=$null
 try{
  $pending=$wire.BeginWaitForConnection($null,$null)
  $startInfo=New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
  $startInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$hook+'" -LoopTestPipe '+$wireName
  $startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true;$startInfo.RedirectStandardInput=$true
  $process=[Diagnostics.Process]::Start($startInfo)
  $wirePayload=@{session_id='wire-session';hook_event_name='PreToolUse';tool_name='Bash';tool_use_id='wire-tool';cwd=$cwd;tool_input=@{command=$secret};error=$secretError}|ConvertTo-Json -Depth 5 -Compress
  $process.StandardInput.WriteLine($wirePayload);$process.StandardInput.Close()
  if(-not $pending.AsyncWaitHandle.WaitOne(5000)){throw 'The synthetic client did not connect.'}
  $wire.EndWaitForConnection($pending)
  $testKey=New-Object byte[] 32
  for($i=0;$i -lt $testKey.Length;$i++){$testKey[$i]=[byte]($i+1)}
  $wire.Write($testKey,0,$testKey.Length)
  $prefix=New-Object byte[] 4
  $read=$wire.ReadAsync($prefix,0,4)
  if(-not $read.Wait(2000) -or $read.Result -ne 4){throw 'The synthetic client did not send a frame.'}
  $length=[BitConverter]::ToInt32($prefix,0)
  if($length -le 0 -or $length -gt 4096){throw 'The synthetic client sent an invalid frame.'}
  $bytes=New-Object byte[] $length;$offset=0
  while($offset -lt $length){
   $read=$wire.ReadAsync($bytes,$offset,$length-$offset)
   if(-not $read.Wait(2000) -or $read.Result -le 0){throw 'The synthetic client sent an incomplete frame.'}
   $offset+=$read.Result
  }
  $wireText=[Text.Encoding]::UTF8.GetString($bytes)
  foreach($sensitive in @($secret,$secretError,$cwd,'"command"','"cwd"','"error"')){
   if($wireText.Contains($sensitive)){throw 'The local channel exposed raw command, path or error text.'}
  }
  $wireEvent=$wireText|ConvertFrom-Json
  if($wireEvent.fingerprint -cnotmatch '^[a-f0-9]{64}$'){throw 'The local channel did not send a keyed fingerprint.'}
  if(-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0){throw 'The synthetic hook client did not exit cleanly.'}
 }finally{
  $wire.Dispose()
  if($null -ne $process){$process.Dispose()}
 }
 $log=Join-Path $testRoot 'CodexTaskProgress\claude-events-v2.jsonl'
 $stored=[IO.File]::ReadAllText($log)
 foreach($sensitive in @($secret,$secretError,$cwd,$start.Fingerprint,$failure.Fingerprint)){
  if($stored.Contains($sensitive)){throw 'Sensitive input or a command fingerprint was persisted.'}
 }
 $channel.Dispose()
 if(-not $channel.IsStopped){throw 'The channel worker did not stop.'}
 $channel=$null
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $payload=@{session_id='session-a';hook_event_name='PreToolUse';tool_name='Bash';tool_use_id='offline';cwd=$cwd;tool_input=@{command=$secret}}|ConvertTo-Json -Depth 5 -Compress
 $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook -LoopTestPipe $pipeName | Out-Null
 $watch.Stop()
 if($LASTEXITCODE -ne 0 -or $watch.ElapsedMilliseconds -gt 5000){throw 'An absent monitor blocked or failed the hook.'}
 $channel=[AITaskMonitor.ClaudeLoop.Channel]::new($pipeName)
 $fresh=Invoke-Hook 'PreToolUse' 'new-run'
 if($fresh.Fingerprint -ceq $start.Fingerprint){throw 'A restarted monitor reused the fingerprinting key.'}
 $channel.Dispose()
 if(-not $channel.IsStopped){throw 'The channel could not reopen and stop.'}
 $channel=$null
 Write-Output 'Claude loop channel: isolated hook events, fingerprints, privacy and clean shutdown verified.'
}finally{
 if($null -ne $channel){$channel.Dispose()}
 $env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldProfile;$env:AI_TASK_MONITOR_AUDIT=$oldAudit
 if(Test-Path -LiteralPath $testRoot){
  $resolved=(Resolve-Path -LiteralPath $testRoot).Path
  if($resolved -ne $testRoot -or -not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
