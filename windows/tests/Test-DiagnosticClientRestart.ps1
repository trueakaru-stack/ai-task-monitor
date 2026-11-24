$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -Path (Join-Path $app 'LocalReadOwner.cs')
. (Join-Path $app 'DiagnosticPolicy.ps1');. (Join-Path $app 'DiagnosticStore.ps1');. (Join-Path $app 'DiagnosticClient.ps1')
function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-diagnostic-restart-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic restart directory.'
[void][IO.Directory]::CreateDirectory($root)
$startName='Local\AITMRestartStart-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMRestartRelease-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName);$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
$owner=$null;$client=$null
try{
 $journal=Join-Path $root 'journal';$trace=Join-Path $root 'synthetic-clear.txt';$worker=Join-Path $PSScriptRoot 'fixtures\DiagnosticRestartWorker.ps1'
 $now=[DateTimeOffset]::UtcNow
 $old=[PSCustomObject]@{version=1;time=$now.ToString('o');source='codex';task=('a'*64);type='tool_started';id=('b'*64)}
 Write-DiagnosticEvent -Directory $journal -Event $old -Now $now
 $config=[string[]]@('hold-clear',$journal,$app,$startName,$releaseName,$trace)
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,$config)
 $newConfig=[string[]]@('normal',$journal,$app,$startName,$releaseName,$trace)
 $factory={return [AITaskMonitor.LocalReadOwner.Owner]::new($worker,$newConfig)}.GetNewClosure()
 $client=New-DiagnosticClient $owner $factory;$client.RetryDelayMilliseconds=1
 $tasks=@([PSCustomObject]@{Provider='codex';Id='synthetic';State='active'})
 $clear=Queue-DiagnosticClear $client
 Get-DiagnosticClientUpdate $client $tasks @()
 Require ($started.WaitOne(15000)) 'The synthetic worker did not complete clear before the gate.'
 Require ($client.PendingClearSent -and @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 0) 'The synthetic clear did not run before its acknowledgement.'
 $ownedId=$owner.OwnedProcessId;Require ($ownedId -gt 0) 'The synthetic owned process identity is unavailable.'
 $owned=[Diagnostics.Process]::GetProcessById($ownedId)
 try{$owned.Kill();Require ($owned.WaitForExit(10000)) 'The synthetic owned worker did not exit.'}finally{$owned.Dispose()}
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require $owner.CanReplace 'The synthetic owner cleanup was not confirmed.'
 $sentinel=[PSCustomObject]@{version=1;time=[DateTimeOffset]::UtcNow.ToString('o');source='codex';task=('a'*64);type='tool_started';id=('c'*64)}
 Write-DiagnosticEvent -Directory $journal -Event $sentinel -Now ([DateTimeOffset]::UtcNow)
 $clock.Restart()
 do{Get-DiagnosticClientUpdate $client $tasks @();if($client.Fresh -and $client.Owner -ne $owner){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and $client.Owner -ne $owner -and $client.LastClearUncertain -and -not $client.PendingClear -and $client.Gap) 'The client did not recover with an unconfirmed clear and incomplete journal.'
 $events=@(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow))
 Require ($events.Count -eq 1 -and $events[0].id -ceq ('c'*64) -and @([IO.File]::ReadAllLines($trace)).Count -eq 1) 'The restarted worker repeated an uncertain clear.'
 $unsafe=[PSCustomObject]@{HasExited=$true;CanReplace=$false};$blocked=New-DiagnosticClient $unsafe $factory;$blocked.RetryDelayMilliseconds=0
 Repair-DiagnosticClientOwner $blocked ([Diagnostics.Stopwatch]::GetTimestamp())
 Require ($blocked.Owner -eq $unsafe -and $blocked.RetryCount -eq 0) 'A replacement started without confirmed cleanup.'
 $blocked.RetryCount=4;$blocked.StableMilliseconds=30000;$tick=[Diagnostics.Stopwatch]::GetTimestamp()
 Confirm-DiagnosticOwnerFresh $blocked $tick
 Confirm-DiagnosticOwnerFresh $blocked ($tick+[Diagnostics.Stopwatch]::Frequency*4)
 Confirm-DiagnosticOwnerFresh $blocked ($tick+[Diagnostics.Stopwatch]::Frequency*8)
 Confirm-DiagnosticOwnerFresh $blocked ($tick+[Diagnostics.Stopwatch]::Frequency*12)
 Confirm-DiagnosticOwnerFresh $blocked ($tick+[Diagnostics.Stopwatch]::Frequency*16)
 Confirm-DiagnosticOwnerFresh $blocked ($tick+[Diagnostics.Stopwatch]::Frequency*20)
 Confirm-DiagnosticOwnerFresh $blocked ($tick+[Diagnostics.Stopwatch]::Frequency*24)
 Confirm-DiagnosticOwnerFresh $blocked ($tick+[Diagnostics.Stopwatch]::Frequency*29)
 Require ($blocked.RetryCount -eq 4) 'The retry limit reset before stable operation.'
 Confirm-DiagnosticOwnerFresh $blocked ($tick+[Diagnostics.Stopwatch]::Frequency*30)
 Require ($blocked.RetryCount -eq 0) 'A stable owner did not restore the retry allowance.'
 $client.Owner.Dispose();$clock.Restart();while(-not $client.Owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require $client.Owner.CanReplace 'The replacement owner did not stop before the timeout check.'
 [void]$started.Reset();[void]$release.Reset()
 $timeoutTrace=Join-Path $root 'synthetic-timeout-clear.txt'
 $timeoutConfig=[string[]]@('hold-clear',$journal,$app,$startName,$releaseName,$timeoutTrace)
 $timeoutOwner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,$timeoutConfig);$client=New-DiagnosticClient $timeoutOwner
 [void](Queue-DiagnosticClear $client);Get-DiagnosticClientUpdate $client $tasks @()
 Require ($started.WaitOne(15000)) 'The synthetic timeout clear did not reach its gate.'
 Write-DiagnosticEvent -Directory $journal -Event $sentinel -Now ([DateTimeOffset]::UtcNow)
 $client.PendingStartedAt=[Diagnostics.Stopwatch]::GetTimestamp()-[Diagnostics.Stopwatch]::Frequency
 $client.TimeoutMilliseconds=10;Get-DiagnosticClientUpdate $client $tasks @()
 Require ($client.LastClearUncertain -and -not $client.PendingClear) 'A timed-out clear was left for automatic replay.'
 $client.TimeoutMilliseconds=6000
 [void]$release.Set();$clock.Restart()
 do{Get-DiagnosticClientUpdate $client $tasks @();if($client.Fresh){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 10000)
 Require ($client.Fresh -and @([IO.File]::ReadAllLines($timeoutTrace)).Count -eq 1 -and @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 1) 'A timed-out clear was replayed or removed a later event.'
 $client.Owner.Dispose();$clock.Restart();while(-not $client.Owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require $client.Owner.CanReplace 'The timeout owner did not stop before the failed-clear check.'
 $failedTrace=Join-Path $root 'synthetic-failed-clear.txt'
 $failedConfig=[string[]]@('fail-clear',$journal,$app,$startName,$releaseName,$failedTrace)
 $failedOwner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,$failedConfig);$client=New-DiagnosticClient $failedOwner
 [void](Queue-DiagnosticClear $client);$clock.Restart()
 do{Get-DiagnosticClientUpdate $client $tasks @();if($client.LastClearUncertain){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.LastClearUncertain -and -not $client.PendingClear -and -not $client.Owner.HasExited) 'A failed clear was left for automatic replay.'
 Write-DiagnosticEvent -Directory $journal -Event $sentinel -Now ([DateTimeOffset]::UtcNow)
 $clock.Restart();do{Get-DiagnosticClientUpdate $client $tasks @();Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 300)
 Require (@([IO.File]::ReadAllLines($failedTrace)).Count -eq 1 -and @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 1) 'A failed clear was replayed or removed a later event.'
 $failedOwner.Dispose();$clock.Restart();while(-not $failedOwner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require $failedOwner.CanReplace 'The failed-clear synthetic owner did not stop.'
 $badAckTrace=Join-Path $root 'synthetic-failed-ack.txt'
 $badAckConfig=[string[]]@('fail-with-ack',$journal,$app,$startName,$releaseName,$badAckTrace)
 $badAckOwner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,$badAckConfig);$client=New-DiagnosticClient $badAckOwner
 [void](Queue-DiagnosticClear $client);$clock.Restart();$completed=$false
 do{Get-DiagnosticClientUpdate $client $tasks @();if($client.LastClearCompleted){$completed=$true};if($client.LastClearUncertain){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.LastClearUncertain -and -not $client.PendingClear -and -not $completed) 'A failed response with a matching clear acknowledgement was presented as success.'
 Write-DiagnosticEvent -Directory $journal -Event $sentinel -Now ([DateTimeOffset]::UtcNow)
 $clock.Restart();do{Get-DiagnosticClientUpdate $client $tasks @();Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 300)
 Require (@([IO.File]::ReadAllLines($badAckTrace)).Count -eq 1 -and @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 1) 'A failed response with a clear acknowledgement was replayed.'
 Write-Output 'Diagnostic restart: unacknowledged, timed-out and failed clears were not replayed; later events survived.'
}finally{
 [void]$release.Set()
 if($null -ne $client -and $null -ne $client.Owner -and $client.Owner -ne $owner){$client.Owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $client.Owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $client.Owner.CanReplace){throw 'The replacement synthetic owner did not stop.'}}
 if($null -ne $owner -and -not $owner.HasExited){$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The first synthetic owner did not stop.'}}
 $started.Dispose();$release.Dispose()
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic restart cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
