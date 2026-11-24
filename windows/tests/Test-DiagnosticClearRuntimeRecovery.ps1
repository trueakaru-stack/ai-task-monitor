$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -Path (Join-Path $app 'LocalReadOwner.cs')
. (Join-Path $app 'DiagnosticPolicy.ps1');. (Join-Path $app 'DiagnosticStore.ps1');. (Join-Path $app 'DiagnosticClient.ps1')
function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Failure([string]$id,[DateTimeOffset]$time){return @{timestamp=$time.ToString('o');type='event_msg';payload=@{type='item_completed';item=@{type='CommandExecution';id=$id;status='failed';exit_code=1;command=@('synthetic-tool');cwd='synthetic'}}}|ConvertTo-Json -Depth 8 -Compress}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-clear-runtime-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic clear recovery directory.'
[void][IO.Directory]::CreateDirectory($root);$owner=$null
try{
 $codex=Join-Path $root 'codex';$sessions=Join-Path $codex 'sessions';$profile=Join-Path $root 'profile';$data=Join-Path $root 'data';$journal=Join-Path $root 'journal'
 foreach($directory in @($sessions,$profile,$data,$journal)){[void][IO.Directory]::CreateDirectory($directory)}
 $now=[DateTimeOffset]::UtcNow;$utf8=[Text.UTF8Encoding]::new($false);$id='60000000-0000-0000-0000-000000000001'
 $rollout=Join-Path $sessions ('rollout-2026-11-24T12-00-00-'+$id+'.jsonl')
 [IO.File]::WriteAllText($rollout,((Failure 'before-clear' $now.AddSeconds(-10))+[Environment]::NewLine),$utf8)
 # With no key, this recognized header plus malformed record makes the first
 # New-DiagnosticRuntime fail. Explicit clear can still repair the journal.
 [IO.File]::WriteAllText((Join-Path $journal 'diagnostic-events-v1.jsonl'),($script:DiagnosticHeader+[Environment]::NewLine+'{"malformed":true}'+[Environment]::NewLine),$utf8)
 $configuration=[string[]]@('AITM-DIAGNOSTIC-1',$codex,$profile,$data,$journal,$now.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $app 'DiagnosticWorker.ps1'),$configuration)
 Require ($owner.Request([string[]]@('poll'))) 'The synthetic diagnostic setup request was rejected.'
 $clock=[Diagnostics.Stopwatch]::StartNew();$initial=$null
 do{$initial=$owner.TryReceive();if($null -ne $initial){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($null -ne $initial -and $initial.Success -and $initial.Value.Failed -and [string]$initial.Value.FailureStage -ceq 'runtime') 'The synthetic initial runtime failure was not reproduced.'
 $client=New-DiagnosticClient $owner;$task=[PSCustomObject]@{Provider='codex';Id=$id;State='active'}
 [void](Queue-DiagnosticClear $client);$clock.Restart();$ack=$false
 do{Get-DiagnosticClientUpdate $client @($task) @();if($client.LastClearCompleted){$ack=$true;break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($ack -and -not $client.Error) 'The repaired synthetic journal did not acknowledge clear.'
 $clock.Restart();do{Get-DiagnosticClientUpdate $client @($task) @();if($client.Fresh){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and -not $client.Error) 'The synthetic runtime did not recover after clear.'
 $events=@(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow))
 Require (@($events|Where-Object {$_.type -ceq 'tool_failed'}).Count -eq 0) 'A pre-clear event returned after runtime recovery.'
 [IO.File]::AppendAllText($rollout,((Failure 'after-clear' ([DateTimeOffset]::UtcNow))+[Environment]::NewLine),$utf8)
 $clock.Restart();do{Get-DiagnosticClientUpdate $client @($task) @();Start-Sleep -Milliseconds 10;$events=@(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow))}while(@($events|Where-Object {$_.type -ceq 'tool_failed'}).Count -eq 0 -and $clock.ElapsedMilliseconds -lt 15000)
 Require (@($events|Where-Object {$_.type -ceq 'tool_failed'}).Count -eq 1) 'A post-clear event was lost or an older event returned after runtime recovery.'
 Write-Output 'Diagnostic clear recovery: initial runtime failure did not restore a pre-clear event; a new event remained visible.'
}finally{
 if($null -ne $owner){$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic recovery owner did not stop.'}}
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic clear recovery cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
