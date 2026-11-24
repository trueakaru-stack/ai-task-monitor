$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
. (Join-Path $app 'DiagnosticPolicy.ps1')
. (Join-Path $app 'DiagnosticStore.ps1')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Poll($owner,[string[]]$request){
 Require ($owner.Request($request)) 'The synthetic diagnostic request was rejected.'
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds -lt 20000){$result=$owner.TryReceive();if($null -ne $result){Require $result.Success 'The synthetic diagnostic worker failed.';return $result.Value};Start-Sleep -Milliseconds 10}
 throw 'The synthetic diagnostic worker did not respond.'
}
function Failure([int]$number,[string]$command,[DateTimeOffset]$time){
 return @{timestamp=$time.ToString('o');type='event_msg';payload=@{type='item_completed';item=@{type='CommandExecution';id=('failure-'+$number);status='failed';exit_code=1;command=@('synthetic-tool',$command);cwd='synthetic-private-directory'}}}|ConvertTo-Json -Depth 8 -Compress
}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-diagnostic-worker-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic diagnostic fixture.'
[void][IO.Directory]::CreateDirectory($root);$owner=$null
try{
 $codex=Join-Path $root 'codex';$sessions=Join-Path $codex 'sessions';$profile=Join-Path $root 'profile';$data=Join-Path $root 'data';$journal=Join-Path $root 'diagnostics'
 foreach($directory in @($sessions,$profile,$data)){[void][IO.Directory]::CreateDirectory($directory)}
 $id='60000000-0000-0000-0000-000000000001';$path=Join-Path $sessions ('rollout-2026-11-24T12-00-00-'+$id+'.jsonl')
 $now=[DateTimeOffset]::UtcNow;$utf8=[Text.UTF8Encoding]::new($false)
 $records=@(1..5|ForEach-Object {Failure $_ 'private-one' ($now.AddSeconds(-10+$_))})
 [IO.File]::WriteAllText($path,(($records -join "`n")+"`n"),$utf8)
 $configuration=[string[]]@('AITM-DIAGNOSTIC-1',$codex,$profile,$data,$journal,$now.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $app 'DiagnosticWorker.ps1'),$configuration)
 $request=[string[]]@('poll',('tasks:codex,'+$id+',active'))
 $result=Poll $owner $request
 Require (-not $result.Failed -and @($result.Warnings).Count -eq 1 -and $result.Warnings[0].Warning -and -not $result.Warnings[0].Dismissed -and
  $result.Warnings[0].Token -cmatch '^[a-f0-9]{32}$') 'The worker did not read the synthetic diagnostic warning.'
 $token=[string]$result.Warnings[0].Token;$dismissId=[Guid]::NewGuid().ToString('N')
 $dismiss=[string[]]@('poll',('tasks:codex,'+$id+',active'),('dismiss:'+$id+','+$token+','+$dismissId))
 $result=Poll $owner $dismiss
 Require (-not $result.Failed -and @($result.DismissAck) -ccontains $dismissId -and @($result.Warnings).Count -eq 1 -and $result.Warnings[0].Dismissed) 'The worker did not apply and acknowledge the synthetic dismissal.'
 $more=@(6..10|ForEach-Object {Failure $_ 'private-two' ([DateTimeOffset]::UtcNow)})
 [IO.File]::AppendAllText($path,(($more -join "`n")+"`n"),$utf8)
 $result=Poll $owner $request
 Require (-not $result.Failed -and @($result.Warnings).Count -eq 1 -and -not $result.Warnings[0].Dismissed -and $result.Warnings[0].Token -cne $token) 'A new warning inherited a previous dismissal.'
 $staleDismiss=[Guid]::NewGuid().ToString('N')
 $result=Poll $owner ([string[]]@('poll',('tasks:codex,'+$id+',active'),('dismiss:'+$id+','+$token+','+$staleDismiss)))
 Require (@($result.DismissAck) -ccontains $staleDismiss -and -not $result.Warnings[0].Dismissed) 'A stale dismissal hid a new warning.'
 $clear=[Guid]::NewGuid().ToString('N');$clearRequest=[string[]]@('poll',('tasks:codex,'+$id+',active'),('clear:'+$clear))
 $result=Poll $owner $clearRequest
 Require (-not $result.Failed -and $result.ClearAck -ceq $clear -and @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 0) 'The worker did not clear and acknowledge the synthetic journal.'
 $sentinel=[PSCustomObject]@{version=1;time=[DateTimeOffset]::UtcNow.ToString('o');source='codex';task=('a'*64);type='tool_started';id=('c'*64)}
 Write-DiagnosticEvent -Directory $journal -Event $sentinel -Now ([DateTimeOffset]::UtcNow)
 $result=Poll $owner $clearRequest
 Require ($result.ClearAck -ceq $clear -and @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 1) 'Replaying a clear removed later journal events.'
 . (Join-Path $app 'DiagnosticClient.ps1')
 function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
 $client=New-DiagnosticClient $owner;$observations=@([PSCustomObject]@{Provider='codex';Id=$id;State='active'})
 $clock=[Diagnostics.Stopwatch]::StartNew()
 do{Get-DiagnosticClientUpdate $client $observations @();if($client.Fresh){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 $key='codex:'+$id
 Require ($client.Fresh -and $client.Warnings.ContainsKey($key) -and -not $client.Warnings[$key].Dismissed) 'The diagnostic client did not receive the current warning.'
 $operation=Queue-DiagnosticDismiss $client $id ([string]$client.Warnings[$key].Token)
 Require ($client.Warnings[$key].Dismissed -and $client.PendingDismissals.ContainsKey($id)) 'The client did not preserve a pending dismissal.'
 $clock.Restart()
 do{Get-DiagnosticClientUpdate $client $observations @();if(-not $client.PendingDismissals.ContainsKey($id)){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require (-not $client.PendingDismissals.ContainsKey($id) -and $client.Warnings[$key].Dismissed) 'The diagnostic client lost or failed to acknowledge the dismissal.'
 $queuedClear=Queue-DiagnosticClear $client
 Require ((Queue-DiagnosticClear $client) -ceq $queuedClear) 'A pending clear was duplicated.'
 $clock.Restart();$clearCompleted=$false
 do{Get-DiagnosticClientUpdate $client $observations @();if($client.LastClearCompleted){$clearCompleted=$true;break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($clearCompleted -and -not $client.PendingClear -and @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 0) 'The diagnostic client did not wait for clear acknowledgement.'
 $raw=[IO.File]::ReadAllText((Join-Path $journal 'diagnostic-events-v1.jsonl'))
 Require (-not $raw.Contains('private-one') -and -not $raw.Contains('private-two') -and -not $raw.Contains($id)) 'The synthetic journal exposed a command or raw task identifier.'
 # A malformed record must not kill the owner permanently: an explicit clear
 # is allowed to repair it, and is acknowledged before normal polling resumes.
 $owner.Dispose();$clock.Restart();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require $owner.CanReplace 'The first synthetic diagnostic owner did not stop.'
 [IO.File]::AppendAllText((Join-Path $journal 'diagnostic-events-v1.jsonl'),"{invalid`n",$utf8)
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $app 'DiagnosticWorker.ps1'),$configuration)
 $broken=Poll $owner ([string[]]@('poll'))
 Require ($broken.Failed -and -not $owner.HasExited) 'A malformed journal did not leave the diagnostic owner available for recovery.'
 $repairId=[Guid]::NewGuid().ToString('N')
 $repaired=Poll $owner ([string[]]@('poll',('clear:'+$repairId)))
 Require (-not $repaired.Failed -and $repaired.ClearAck -ceq $repairId -and
  @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 0) 'The synthetic journal did not recover after explicit clear.'
 Write-Output 'Diagnostic worker: synthetic task observation, warning identity, dismissal, idempotent clear and journal privacy verified.'
}finally{
 if($null -ne $owner){$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic diagnostic worker did not close.'}}
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic diagnostic cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
