$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$priorStart=[Environment]::GetEnvironmentVariable('AITM_CLEAR_ACK_START','Process');$priorRelease=[Environment]::GetEnvironmentVariable('AITM_CLEAR_ACK_RELEASE','Process')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -Path (Join-Path $app 'LocalReadOwner.cs')
. (Join-Path $app 'DiagnosticPolicy.ps1');. (Join-Path $app 'DiagnosticStore.ps1');. (Join-Path $app 'DiagnosticClient.ps1')
function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-clear-ack-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic clear acknowledgement directory.'
[void][IO.Directory]::CreateDirectory($root)
$startName='Local\AITMClearAckStart-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMClearAckRelease-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName);$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
$owner=$null
try{
 $work=Join-Path $root 'worker';$codex=Join-Path $root 'codex';$sessions=Join-Path $codex 'sessions';$profile=Join-Path $root 'profile';$data=Join-Path $root 'data';$journal=Join-Path $root 'journal'
 foreach($path in @($work,$sessions,$profile,$data)){[void][IO.Directory]::CreateDirectory($path)}
 foreach($name in @('LocalSourceCore.ps1','CodexAgentRetention.ps1','CodexAgentRetentionAdapter.ps1','CodexTitlesCore.cs','CodexRecentEventObserver.cs','ClaudeReaderCore.ps1','DiagnosticPolicy.ps1','DiagnosticStore.ps1','LoopDetection.ps1','DiagnosticCollector.ps1','DiagnosticRuntime.ps1')){Copy-Item -LiteralPath (Join-Path $app $name) -Destination (Join-Path $work $name)}
 $source=[IO.File]::ReadAllText((Join-Path $app 'DiagnosticWorker.ps1'))
 $needle="   `$phase='update'"
 $gate='if(-not (Get-Variable -Scope Script -Name syntheticAckGate -ErrorAction SilentlyContinue)){$script:syntheticAckGate=$true;$s=[Threading.EventWaitHandle]::OpenExisting($env:AITM_CLEAR_ACK_START);$r=[Threading.EventWaitHandle]::OpenExisting($env:AITM_CLEAR_ACK_RELEASE);try{[void]$s.Set();if(-not $r.WaitOne(30000)){throw "Synthetic acknowledgement gate timed out."}}finally{$s.Dispose();$r.Dispose()}}'
 Require ($source.Contains($needle)) 'The production diagnostic poll could not be gated in the synthetic copy.'
 [IO.File]::WriteAllText((Join-Path $work 'DiagnosticWorker.ps1'),$source.Replace($needle,('   '+$gate+[Environment]::NewLine+$needle)),[Text.UTF8Encoding]::new($false))
 $env:AITM_CLEAR_ACK_START=$startName;$env:AITM_CLEAR_ACK_RELEASE=$releaseName
 $now=[DateTimeOffset]::UtcNow
 $old=[PSCustomObject]@{version=1;time=$now.ToString('o');source='codex';task=('a'*64);type='tool_started';id=('b'*64)}
 Write-DiagnosticEvent -Directory $journal -Event $old -Now $now
 $configuration=[string[]]@('AITM-DIAGNOSTIC-1',$codex,$profile,$data,$journal,$now.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $work 'DiagnosticWorker.ps1'),$configuration)
 $client=New-DiagnosticClient $owner;$task=[PSCustomObject]@{Provider='codex';Id='60000000-0000-0000-0000-000000000001';State='active'}
 [void](Queue-DiagnosticClear $client);$clock=[Diagnostics.Stopwatch]::StartNew();$ack=$false
 do{Get-DiagnosticClientUpdate $client @($task) @();if($client.LastClearCompleted){$ack=$true;break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($ack -and -not $client.Error -and -not $client.PendingClear -and -not $client.Fresh -and $client.Frames.Count -eq 1) ('The clear was not acknowledged separately from its task frame; stage='+$owner.Stage+'; failure='+$owner.FailureStage)
 Require ($started.WaitOne(10000) -and -not $release.WaitOne(0) -and @(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow)).Count -eq 0) 'A subsequent poll was not independently blocked after the acknowledged clear.'
 [void]$release.Set();$clock.Restart()
 do{Get-DiagnosticClientUpdate $client @($task) @();if($client.Fresh){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 $events=@(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow))
 Require ($client.Fresh -and @($events|Where-Object {$_.type -ceq 'task_observed'}).Count -eq 1) ('The deferred task observation was lost after the clear; fresh='+$client.Fresh+'; error='+$client.Error+'; stage='+$client.FailureStage+'; kind='+$client.FailureKind+'; event_count='+$events.Count+'; observed_count='+@($events|Where-Object {$_.type -ceq 'task_observed'}).Count+'; frames='+$client.Frames.Count)
 Write-Output 'Production diagnostic clear: acknowledgement precedes a separately blocked poll, whose task frame is retained.'
}finally{
 [void]$release.Set()
 if($null -ne $owner){$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic acknowledgement owner did not stop.'}}
 $started.Dispose();$release.Dispose()
 [Environment]::SetEnvironmentVariable('AITM_CLEAR_ACK_START',$priorStart,'Process');[Environment]::SetEnvironmentVariable('AITM_CLEAR_ACK_RELEASE',$priorRelease,'Process')
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic clear acknowledgement cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
