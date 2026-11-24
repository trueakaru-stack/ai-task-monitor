$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -Path (Join-Path $app 'LocalReadOwner.cs')
. (Join-Path $app 'DiagnosticPolicy.ps1');. (Join-Path $app 'DiagnosticStore.ps1');. (Join-Path $app 'DiagnosticClient.ps1')
function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Failure([string]$id,[DateTimeOffset]$time){
 return @{timestamp=$time.ToString('o');type='event_msg';payload=@{type='item_completed';item=@{type='CommandExecution';id=$id;status='failed';exit_code=1;command=@('synthetic-tool');cwd='synthetic'}}}|ConvertTo-Json -Depth 8 -Compress
}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-clear-boundary-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic clear fixture.'
[void][IO.Directory]::CreateDirectory($root)
$startName='Local\AITMClearStart-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMClearRelease-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName);$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
$owner=$null
try{
 $work=Join-Path $root 'worker';$codex=Join-Path $root 'codex';$sessions=Join-Path $codex 'sessions';$profile=Join-Path $root 'profile';$data=Join-Path $root 'data';$journal=Join-Path $root 'journal'
 foreach($directory in @($work,$sessions,$profile,$data)){[void][IO.Directory]::CreateDirectory($directory)}
 foreach($name in @('LocalSourceCore.ps1','CodexAgentRetention.ps1','CodexAgentRetentionAdapter.ps1','CodexTitlesCore.cs','CodexRecentEventObserver.cs','ClaudeReaderCore.ps1','DiagnosticPolicy.ps1','DiagnosticStore.ps1','LoopDetection.ps1','DiagnosticCollector.ps1','DiagnosticRuntime.ps1')){Copy-Item -LiteralPath (Join-Path $app $name) -Destination (Join-Path $work $name)}
 $source=[IO.File]::ReadAllText((Join-Path $app 'DiagnosticWorker.ps1'))
 $original='$resolver={param($id) return (Session-File $id)}'
 $gated='$resolver={param($id) if(-not (Get-Variable -Scope Script -Name clearGatePassed -ErrorAction SilentlyContinue)){$script:clearGatePassed=$true;$gateStarted=[Threading.EventWaitHandle]::OpenExisting($env:AITM_CLEAR_STARTED);$gateRelease=[Threading.EventWaitHandle]::OpenExisting($env:AITM_CLEAR_RELEASE);try{[void]$gateStarted.Set();if(-not $gateRelease.WaitOne(30000)){throw "Synthetic clear gate timed out."}}finally{$gateStarted.Dispose();$gateRelease.Dispose()}};return (Session-File $id)}'
 Require ($source.Contains($original)) 'The production resolver could not be gated in the synthetic copy.'
 [IO.File]::WriteAllText((Join-Path $work 'DiagnosticWorker.ps1'),$source.Replace($original,$gated),[Text.UTF8Encoding]::new($false))
 $env:AITM_CLEAR_STARTED=$startName;$env:AITM_CLEAR_RELEASE=$releaseName
 $id1='60000000-0000-0000-0000-000000000001';$id2='60000000-0000-0000-0000-000000000002'
 $path1=Join-Path $sessions ('rollout-2026-11-24T12-00-00-'+$id1+'.jsonl');$path2=Join-Path $sessions ('rollout-2026-11-24T12-00-00-'+$id2+'.jsonl')
 $now=[DateTimeOffset]::UtcNow;$utf8=[Text.UTF8Encoding]::new($false)
 [IO.File]::WriteAllText($path1,((Failure 'first-old' $now.AddSeconds(-10))+[Environment]::NewLine),$utf8)
 [IO.File]::WriteAllText($path2,((Failure 'second-old' $now.AddSeconds(-10))+[Environment]::NewLine),$utf8)
 $configuration=[string[]]@('AITM-DIAGNOSTIC-1',$codex,$profile,$data,$journal,$now.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $work 'DiagnosticWorker.ps1'),$configuration)
 $client=New-DiagnosticClient $owner;$first=[PSCustomObject]@{Provider='codex';Id=$id1;State='active'};$second=[PSCustomObject]@{Provider='codex';Id=$id2;State='active'}
 Get-DiagnosticClientUpdate $client @($first) @()
 Require ($started.WaitOne(15000)) 'The synthetic production reader did not reach its gate.'
 Get-DiagnosticClientUpdate $client @($first,$second) @()
 [void](Queue-DiagnosticClear $client)
 Get-DiagnosticClientUpdate $client @($first,$second) @()
 [void]$release.Set();$clock=[Diagnostics.Stopwatch]::StartNew();$ack=$false
 do{Get-DiagnosticClientUpdate $client @($first,$second) @();if($client.LastClearCompleted){$ack=$true;break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($ack -and -not $client.Error) ('The production worker did not finish the synthetic clear; stage={0}; kind={1}.' -f $client.FailureStage,$client.FailureKind)
 $events=@(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow))
 Require (@($events|Where-Object type -eq 'tool_failed').Count -eq 0) 'An event from before the clear returned to the journal.'
 [IO.File]::AppendAllText($path2,((Failure 'second-new' ([DateTimeOffset]::UtcNow))+[Environment]::NewLine),$utf8)
 $clock.Restart()
 do{Get-DiagnosticClientUpdate $client @($first,$second) @();Start-Sleep -Milliseconds 10;$events=@(Read-DiagnosticEvents -Directory $journal -Now ([DateTimeOffset]::UtcNow))}while(@($events|Where-Object type -eq 'tool_failed').Count -lt 1 -and $clock.ElapsedMilliseconds -lt 15000)
 $failedCount=@($events|Where-Object type -eq 'tool_failed').Count
 Require ($failedCount -eq 1) ('A new event after the clear was lost or an old event returned; count={0}; error={1}; stage={2}; kind={3}.' -f $failedCount,$client.Error,$client.FailureStage,$client.FailureKind)
 Write-Output 'Diagnostic clear boundary: the production worker excluded old events and retained a new event after delayed reading.'
}finally{
 [void]$release.Set()
 if($null -ne $owner){$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic clear owner did not stop.'}}
 $started.Dispose();$release.Dispose()
 Remove-Item Env:\AITM_CLEAR_STARTED,Env:\AITM_CLEAR_RELEASE -ErrorAction SilentlyContinue
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic clear cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
