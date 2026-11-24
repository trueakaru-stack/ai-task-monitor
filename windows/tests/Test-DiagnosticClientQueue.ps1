$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
. (Join-Path $PSScriptRoot '..\app\DiagnosticClient.ps1')
function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Stop-Owner($owner){$owner.Dispose();$watch=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};Require $owner.CanReplace 'The synthetic diagnostic owner did not stop.'}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-diagnostic-queue-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic queue directory.'
[void][IO.Directory]::CreateDirectory($root)
$startName='Local\AITMQueueStart-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMQueueRelease-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName);$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
$env:AITM_QUEUE_STAGE_BEGIN='Local\AITMQueueBegin-'+[Guid]::NewGuid().ToString('N')
$env:AITM_QUEUE_STAGE_CONNECTED='Local\AITMQueueConnected-'+[Guid]::NewGuid().ToString('N')
$env:AITM_QUEUE_STAGE_COMPILED='Local\AITMQueueCompiled-'+[Guid]::NewGuid().ToString('N')
$stageBegin=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$env:AITM_QUEUE_STAGE_BEGIN)
$stageConnected=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$env:AITM_QUEUE_STAGE_CONNECTED)
$stageCompiled=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$env:AITM_QUEUE_STAGE_COMPILED)
$owner=$null
try{
 $trace=Join-Path $root 'synthetic-order.txt';$worker=Join-Path $PSScriptRoot 'fixtures\DiagnosticQueueWorker.ps1'
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,[string[]]@($startName,$releaseName,$trace))
 $client=New-DiagnosticClient $owner
 $base=[PSCustomObject]@{Provider='codex';Id='base';State='active'};$brief=[PSCustomObject]@{Provider='codex';Id='brief';State='active'}
 Get-DiagnosticClientUpdate $client @($base) @()
 Require ($started.WaitOne(10000)) ('The synthetic diagnostic worker did not reach its gate: entered={0}; connected={1}; compiled={2}; owner={3}; failure={4}.' -f $stageBegin.WaitOne(0),$stageConnected.WaitOne(0),$stageCompiled.WaitOne(0),$owner.Stage,$owner.FailureStage)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 Get-DiagnosticClientUpdate $client @($base,$brief) @()
 Get-DiagnosticClientUpdate $client @($base) @()
 $clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 500 -and $client.Frames.Count -eq 3 -and -not $release.WaitOne(0)) 'The client blocked or coalesced a brief task while the worker was busy.'
 [void]$release.Set();$clock.Restart()
 do{Get-DiagnosticClientUpdate $client @($base) @();Start-Sleep -Milliseconds 15;$lines=if([IO.File]::Exists($trace)){@([IO.File]::ReadAllLines($trace))}else{@()}}while($lines.Count -lt 3 -and $clock.ElapsedMilliseconds -lt 10000)
 Require ($lines.Count -ge 3 -and $lines[0] -cnotmatch 'brief' -and $lines[1] -cmatch 'brief' -and $lines[2] -cnotmatch 'brief') ('The diagnostic worker did not receive the brief task between its surrounding snapshots: '+($lines -join '|')+'; error='+$client.Error+'; queued='+$client.Frames.Count)
 Stop-Owner $owner;$owner=$null
 [void]$started.Reset();[void]$release.Reset()
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,[string[]]@($startName,$releaseName,$trace));$client=New-DiagnosticClient $owner
 Get-DiagnosticClientUpdate $client @($base) @()
 Require ($started.WaitOne(10000)) 'The synthetic overflow worker did not reach its gate.'
 for($index=0;$index -lt 100;$index++){
  $item=[PSCustomObject]@{Provider='codex';Id=('synthetic-'+$index);State='active'}
  Get-DiagnosticClientUpdate $client @($base,$item) @()
 }
 Require ($client.Gap -and $client.Frames.Count -le 64 -and -not $release.WaitOne(0)) 'A bounded queue overflow was not marked as incomplete.'
 Stop-Owner $owner;$owner=$null
 [void]$started.Reset();[void]$release.Reset();[IO.File]::WriteAllText($trace,'')
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,[string[]]@($startName,$releaseName,$trace));$client=New-DiagnosticClient $owner
 Get-DiagnosticClientUpdate $client @($base) @()
 Require ($started.WaitOne(10000)) 'The synthetic clear-barrier worker did not reach its gate.'
 Get-DiagnosticClientUpdate $client @($base,$brief) @()
 $clear=Queue-DiagnosticClear $client
 $after=[PSCustomObject]@{Provider='codex';Id='after';State='active'}
 Get-DiagnosticClientUpdate $client @($after) @()
 [void]$release.Set();$clock.Restart();$ack=$false
 do{
  Get-DiagnosticClientUpdate $client @($after) @();if($client.LastClearCompleted){$ack=$true}
  Start-Sleep -Milliseconds 15
  $lines=if([IO.File]::Exists($trace)){@([IO.File]::ReadAllLines($trace))}else{@()}
 }while(( -not $ack -or $lines.Count -lt 2) -and $clock.ElapsedMilliseconds -lt 10000)
 Require ($ack -and $lines.Count -ge 2 -and $lines[0] -cmatch 'base' -and $lines[1] -cmatch 'after' -and
  $lines[1].Contains('clear='+$clear) -and @($lines|Where-Object {$_ -cmatch 'brief'}).Count -eq 0) 'The clear barrier replayed an earlier snapshot or lost a later one.'
 Stop-Owner $owner;$owner=$null
 [void]$started.Reset();[void]$release.Reset()
 $secondStartName='Local\AITMQueueSecondStart-'+[Guid]::NewGuid().ToString('N');$secondReleaseName='Local\AITMQueueSecondRelease-'+[Guid]::NewGuid().ToString('N')
 $secondStarted=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$secondStartName)
 $secondRelease=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$secondReleaseName)
 try{
  $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,[string[]]@($startName,$releaseName,$trace,$secondStartName,$secondReleaseName));$client=New-DiagnosticClient $owner
  Get-DiagnosticClientUpdate $client @($base) @();Require ($started.WaitOne(10000)) 'The first synthetic warning did not reach its gate.'
  Get-DiagnosticClientUpdate $client @($after) @();[void]$release.Set();$clock.Restart()
  do{Get-DiagnosticClientUpdate $client @($after) @();Start-Sleep -Milliseconds 10}while(-not $secondStarted.WaitOne(0) -and $clock.ElapsedMilliseconds -lt 10000)
  Require ($secondStarted.WaitOne(0) -and $client.Warnings.Count -eq 0 -and -not $client.Fresh) 'A warning from an older snapshot was presented as current.'
  [void]$secondRelease.Set();$clock.Restart()
  do{Get-DiagnosticClientUpdate $client @($after) @();if($client.Fresh){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 10000)
  Require ($client.Fresh -and $client.Warnings.Count -eq 0) 'The latest synthetic warning state did not replace the older state.'
 }finally{[void]$secondRelease.Set();$secondStarted.Dispose();$secondRelease.Dispose()}
 Write-Output 'Diagnostic queue: brief tasks, bounded overflow, clear barrier and stale warnings were verified.'
}finally{
 [void]$release.Set();if($null -ne $owner){Stop-Owner $owner};$started.Dispose();$release.Dispose()
 $stageBegin.Dispose();$stageConnected.Dispose();$stageCompiled.Dispose()
 Remove-Item Env:\AITM_QUEUE_STAGE_BEGIN,Env:\AITM_QUEUE_STAGE_CONNECTED,Env:\AITM_QUEUE_STAGE_COMPILED -ErrorAction SilentlyContinue
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic queue cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
