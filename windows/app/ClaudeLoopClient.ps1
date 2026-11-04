function Get-ClaudeLoopField($value,[string]$name,$fallback=$null) {
 if($null -ne $value -and $null -ne $value.PSObject.Properties[$name]){return $value.$name}
 return $fallback
}

function Get-ClaudeLoopPipeName {
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$hash=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid))}finally{$sha.Dispose()}
 return 'AITaskMonitor.ClaudeLoop.'+[BitConverter]::ToString($hash,0,12).Replace('-','').ToLowerInvariant()
}

function Send-ClaudeLoopEvent($InputEvent,[string]$PipeOverride='') {
 $auditTransport=($PipeOverride -and $env:AI_TASK_MONITOR_AUDIT -eq '1' -and $env:AI_TASK_MONITOR_AUDIT_CHANNEL -eq '1')
 $phase='validation'
 try{
  $session=[string](Get-ClaudeLoopField $InputEvent 'session_id' '')
  if($session -cnotmatch '^[A-Za-z0-9_-]{1,128}$'){return}
  $eventName=[string](Get-ClaudeLoopField $InputEvent 'hook_event_name' '')
  $toolName=[string](Get-ClaudeLoopField $InputEvent 'tool_name' '')
  $toolId=[string](Get-ClaudeLoopField $InputEvent 'tool_use_id' '')
  $toolInput=Get-ClaudeLoopField $InputEvent 'tool_input'
  $shell=$toolName -cin @('Bash','PowerShell')
  $kind=''
  $exitCode=$null
  if($eventName -cin @('Stop','SessionEnd','StopFailure','UserPromptSubmit')){$kind='stop'}
  elseif($eventName -cin @('PreToolUse','PostToolUse') -and $toolName -cin @('Edit','Write','MultiEdit','NotebookEdit')){$kind='edit'}
  elseif($shell -and $eventName -ceq 'PreToolUse'){$kind='start'}
  elseif($shell -and $eventName -ceq 'PostToolUse'){
   $response=Get-ClaudeLoopField $InputEvent 'tool_response'
   $interrupted=Get-ClaudeLoopField $response 'interrupted' $false
   $kind=if($interrupted -is [bool] -and -not $interrupted){'success'}else{'reset'}
  }elseif($shell -and $eventName -ceq 'PostToolUseFailure'){
   $interrupted=Get-ClaudeLoopField $InputEvent 'is_interrupt' $false
   $errorText=Get-ClaudeLoopField $InputEvent 'error' ''
   $parsed=0
   if($interrupted -is [bool] -and -not $interrupted -and $errorText -is [string] -and
      $errorText -cmatch '\AExit code (-?[0-9]+)(?:\r?\n|$)' -and [int]::TryParse($Matches[1],[ref]$parsed) -and $parsed -ne 0){
    $kind='failed';$exitCode=$parsed
   }else{$kind='reset'}
  }
  if(-not $kind){return}
  $message=[ordered]@{session=$session;tool='';kind=$kind}
  $command=$null;$cwd=$null
  if($kind -cin @('start','failed','success')){
   $command=Get-ClaudeLoopField $toolInput 'command'
   $cwd=Get-ClaudeLoopField $InputEvent 'cwd'
   if($toolId -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $command -isnot [string] -or -not $command -or $command.Length -gt 131072 -or $cwd -isnot [string] -or -not $cwd -or $cwd.Length -gt 32768){
    $message['kind']='reset'
   }else{
    $message['tool']=$toolId
    if($kind -ceq 'failed'){$message['exitCode']=$exitCode}
   }
  }
  $name=if($PipeOverride){$PipeOverride}else{Get-ClaudeLoopPipeName}
  if($name -cnotmatch '^[A-Za-z0-9_.-]{1,120}$'){return}
  $owner=$null
  try{$owner=[Threading.Mutex]::OpenExisting('Local\'+$name+'.owner')}catch{return}finally{if($null -ne $owner){$owner.Dispose()}}
  $key=New-Object byte[] 32
  $body=$null;$packet=$null
  $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
  try{
   $phase='connect'
   $pipe.Connect(600)
   $phase='handshake'
   $offset=0;$watch=[Diagnostics.Stopwatch]::StartNew()
   while($offset -lt $key.Length){
    $remaining=[Math]::Max(0,400-[int]$watch.ElapsedMilliseconds)
    if($remaining -eq 0){if($auditTransport){[Console]::Error.WriteLine('CLAUDE_LOOP_TRANSPORT_FAILURE:handshake:timeout')};return}
    $read=$pipe.ReadAsync($key,$offset,$key.Length-$offset)
    if(-not $read.Wait($remaining) -or $read.Result -le 0){if($auditTransport){[Console]::Error.WriteLine('CLAUDE_LOOP_TRANSPORT_FAILURE:handshake:read')};return}
    $offset+=$read.Result
   }
   if($message['kind'] -cin @('start','failed','success')){
    $canonical='claude'+[char]0+$toolName+[char]0+$cwd.Length+':'+$cwd+$command.Length+':'+$command
    $secretBytes=[Text.Encoding]::UTF8.GetBytes($canonical)
    $hmac=[Security.Cryptography.HMACSHA256]::new($key)
    try{$digest=$hmac.ComputeHash($secretBytes)}finally{$hmac.Dispose();[Array]::Clear($secretBytes,0,$secretBytes.Length)}
    $message['fingerprint']=[BitConverter]::ToString($digest).Replace('-','').ToLowerInvariant()
    [Array]::Clear($digest,0,$digest.Length)
   }
   $body=[Text.Encoding]::UTF8.GetBytes(($message|ConvertTo-Json -Compress -Depth 3))
   if($body.Length -lt 2 -or $body.Length -gt 4096){return}
   $packet=New-Object byte[] ($body.Length+4)
   [Array]::Copy([BitConverter]::GetBytes([int]$body.Length),0,$packet,0,4)
   [Array]::Copy($body,0,$packet,4,$body.Length)
   $phase='write'
   $write=$pipe.WriteAsync($packet,0,$packet.Length)
   if(-not $write.Wait(400) -and $auditTransport){[Console]::Error.WriteLine('CLAUDE_LOOP_TRANSPORT_FAILURE:write:timeout')}
  }finally{
   $pipe.Dispose()
   [Array]::Clear($key,0,$key.Length)
   if($null -ne $body){[Array]::Clear($body,0,$body.Length)}
   if($null -ne $packet){[Array]::Clear($packet,0,$packet.Length)}
  }
 }catch{if($auditTransport){[Console]::Error.WriteLine('CLAUDE_LOOP_TRANSPORT_FAILURE:'+$phase+':'+$_.Exception.GetType().Name)}}
}
