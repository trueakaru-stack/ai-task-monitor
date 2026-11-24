$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Wait-Result($owner,[int]$milliseconds=20000){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds -lt $milliseconds){$result=$owner.TryReceive();if($null -ne $result){return $result};Start-Sleep -Milliseconds 10}
 throw 'The local source worker did not return a synthetic result.'
}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-production-source-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic source directory.'
[void][IO.Directory]::CreateDirectory($root)
$owner=$null
try{
 $app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
 $codex=Join-Path $root 'codex';$sessions=Join-Path $codex 'sessions';$locks=Join-Path $codex 'thread-writer-locks'
 $profile=Join-Path $root 'profile';$claude=Join-Path $profile '.claude';$data=Join-Path $root 'data'
 [void][IO.Directory]::CreateDirectory($claude);[void][IO.Directory]::CreateDirectory($data)
 $hook=Join-Path $app 'ClaudeTaskHook.ps1'
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& '"+$hook.Replace("'","''")+"'"))
 $command='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
 $hooks=@{}
 foreach($name in @('UserPromptSubmit','PreToolUse','PostToolUse','PostToolUseFailure','TaskCreated','TaskCompleted','SubagentStart','SubagentStop','Stop','StopFailure','SessionEnd')){
  $hooks[$name]=@(@{hooks=@(@{type='command';command=$command})})
 }
 $settings=Join-Path $claude 'settings.json'
 $connected=@{hooks=$hooks;unrelated='keep'}|ConvertTo-Json -Depth 15 -Compress
 [IO.File]::WriteAllText($settings,$connected,[Text.UTF8Encoding]::new($false))
 $now=[DateTime]::Now;$utc=[DateTime]::UtcNow;$id='30000000-0000-0000-0000-000000000001'
 $day=Join-Path (Join-Path (Join-Path $sessions $now.ToString('yyyy')) $now.ToString('MM')) $now.ToString('dd')
 [void][IO.Directory]::CreateDirectory($day);[void][IO.Directory]::CreateDirectory($locks)
 $rollout=Join-Path $day ('rollout-'+$now.ToString('yyyy-MM-ddTHH-mm-ss')+'-'+$id+'.jsonl')
 $meta=@{type='session_meta';payload=@{id=$id;source='cli';thread_source='user';cwd=$root}}|ConvertTo-Json -Depth 8 -Compress
 $turn=@{type='event_msg';timestamp=$utc.ToString('o');payload=@{type='task_started';turn_id='synthetic-turn'}}|ConvertTo-Json -Depth 8 -Compress
 [IO.File]::WriteAllText($rollout,($meta+[Environment]::NewLine+$turn+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
 $index=@{id=$id;thread_name='Synthetic Codex task';updated_at=$now.ToString('o')}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText((Join-Path $codex 'session_index.jsonl'),($index+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $locks ($id+'.lock')),'',[Text.UTF8Encoding]::new($false))
 $event=@{timestamp=$utc.ToString('o');session_id='synthetic-claude';event='UserPromptSubmit';active=$true}|ConvertTo-Json -Compress
 $eventPath=Join-Path $data 'claude-events-v2.jsonl'
 [IO.File]::WriteAllText($eventPath,($event+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
 $beforeSettings=(Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash
 $beforeEvent=(Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash
 $config=[string[]]@('AITM-LOCAL-SOURCE-1',$codex,$profile,$data,'','',$utc.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $app 'LocalSourceWorker.ps1'),$config)
 $epoch=[Guid]::NewGuid().ToString('N')
 $deadline=[Diagnostics.Stopwatch]::StartNew()
 do{
  Require ($owner.Request([string[]]@('poll',$epoch,'true','ru'),[long]11)) 'The source poll was rejected.'
  $snapshot=Wait-Result $owner
  Require ($snapshot.Success -and $snapshot.HasRequestStamp -and $snapshot.RequestStamp -eq 11) 'The source worker failed to read the synthetic profile.'
  $codexTasks=@($snapshot.Value.Codex|Where-Object {[string]$_.Id -ceq $id})
  $claudeTasks=@($snapshot.Value.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-claude'})
  if($codexTasks.Count -eq 1 -and $claudeTasks.Count -eq 1){break}
  Start-Sleep -Milliseconds 150
 }while($deadline.ElapsedMilliseconds -lt 15000)
 Require ($codexTasks.Count -eq 1 -and $claudeTasks.Count -eq 1 -and $snapshot.Value.ClaudeConnection -ceq 'connected') 'The production worker did not surface both synthetic sources.'
 Require ((Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash -ceq $beforeSettings -and (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash -ceq $beforeEvent) 'The production worker changed the synthetic source files.'

 # An externally observed disconnect must hide that source and make its later
 # reappearance unconfirmed, without discarding the other source.
 [IO.File]::WriteAllText($settings,'{"unrelated":"keep"}',[Text.UTF8Encoding]::new($false))
 Require ($owner.Request([string[]]@('poll',$epoch,'true','ru'),[long]12)) 'The disconnect poll was rejected.'
 $disconnected=Wait-Result $owner
 Require ($disconnected.Success -and $disconnected.Value.ClaudeConnection -ceq 'disconnected' -and
  @($disconnected.Value.Claude).Count -eq 0 -and @($disconnected.Value.Codex|Where-Object {[string]$_.Id -ceq $id}).Count -eq 1) 'The production worker did not isolate a disconnected synthetic source.'
 [IO.File]::WriteAllText($settings,$connected,[Text.UTF8Encoding]::new($false))
 Require ($owner.Request([string[]]@('poll',$epoch,'true','en'),[long]13)) 'The reconnect poll was rejected.'
 $reconnected=Wait-Result $owner
 $retained=@($reconnected.Value.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-claude'})
 $unconfirmed=-join @([int[]]@(1057,1090,1072,1090,1091,1089,32,1085,1077,32,1087,1086,1076,1090,1074,1077,1088,1078,1076,1105,1085)|ForEach-Object {[char]$_})
 Require ($reconnected.Success -and $retained.Count -eq 1 -and -not $retained[0].Active -and [string]$retained[0].Status -ceq $unconfirmed) 'The production worker falsely confirmed or lost a reconnected task.'

 [IO.File]::WriteAllText($settings,'{invalid',[Text.UTF8Encoding]::new($false))
 Require ($owner.Request([string[]]@('poll',$epoch,'true','en'),[long]14)) 'The failure poll was rejected.'
 $failed=Wait-Result $owner
 Require ($failed.Success -and @($failed.Value.Unavailable) -ccontains 'Claude Code' -and
  @($failed.Value.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-claude' -and -not $_.Active}).Count -eq 1 -and
  @($failed.Value.Codex|Where-Object {[string]$_.Id -ceq $id}).Count -eq 1) 'A synthetic Claude settings failure lost known tasks.'
 Write-Output 'Production local source worker: synthetic Codex/Claude discovery, read-only source access, disconnect, reconnect, language change and source failure verified.'
}finally{
 if($null -ne $owner){
  $owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
  if(-not $owner.CanReplace){throw 'The synthetic production worker did not close cleanly.'}
 }
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic source cleanup target.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
