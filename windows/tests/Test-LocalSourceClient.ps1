$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
. (Join-Path $PSScriptRoot '..\app\LocalSourceClient.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The application source did not parse.'}
$definitions=foreach($name in @('Prop','Unconfirmed-Tasks')){
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
 if($null -eq $node){throw 'A production fallback function is missing.'};$node.Extent.Text
}
. ([scriptblock]::Create(($definitions -join "`n")))
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Wait-SyntheticGate($owner,$gate,[string]$message){
 $deadline=[Diagnostics.Stopwatch]::StartNew()
 while($deadline.ElapsedMilliseconds -lt 15000){
  if($gate.WaitOne(50)){return}
  if($owner.FailureStage -or $owner.HasExited){break}
 }
 throw ($message+'; stage='+$owner.Stage+'; failed_at='+$owner.FailureStage+'; kind='+$owner.FailureKind+
  '; hresult='+$owner.FailureHResult+'; polling='+$owner.IsPolling+'; pending='+$owner.HasPendingRequest+
  '; worker_started='+($owner.OwnedProcessId -gt 0)+'; exited='+$owner.HasExited+
  '; startup_exit_known='+$owner.HasStartupExitCode+'; startup_exit_code='+$owner.StartupExitCode+'; cleanup_failed='+$owner.CleanupFailed)
}
function Wait-Idle($owner){
 $deadline=[Diagnostics.Stopwatch]::StartNew()
 while($deadline.ElapsedMilliseconds -lt 10000){
  if($owner.HasResult){[void]$owner.TryReceive()}
  if(-not $owner.IsPolling -and -not $owner.HasPendingRequest -and -not $owner.HasResult){return}
  Start-Sleep -Milliseconds 10
 }
 throw 'The synthetic owner did not reach idle.'
}
$prefix='Local\AITaskMonitorClient-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-started'))
$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-release'))
$block=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-block'))
$terminal=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-terminal'))
$afterSnapshot=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-after'))
$afterStarted=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-after-started'))
$afterRelease=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($prefix+'-after-release'))
$worker=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\LocalReadClientWorker.ps1'))
$owner=[AITaskMonitor.LocalReadOwner.Owner]::new($worker,[string[]]@(($prefix+'-started'),($prefix+'-release'),($prefix+'-block'),($prefix+'-terminal'),'normal','unused',($prefix+'-after'),($prefix+'-after-started'),($prefix+'-after-release')))
try{
 $client=New-LocalSourceClient $owner 'ru'
 $client.TimeoutMilliseconds=350
 $clock=[Diagnostics.Stopwatch]::StartNew();$initial=Get-LocalSourceClientSnapshot $client 'ru' 0;$clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 1000 -and @($initial.Codex).Count -eq 0) 'The initial client poll waited for the source.'
 Wait-SyntheticGate $owner $started 'The synthetic source did not block.'
 $workerId=$owner.OwnedProcessId;Start-Sleep -Milliseconds 450
 $initialTimeout=Get-LocalSourceClientSnapshot $client 'ru' 0
 Require ($client.TimedOut -and @($initialTimeout.Codex).Count -eq 0 -and @($initialTimeout.Unavailable) -ccontains 'Codex' -and
  $owner.OwnedProcessId -eq $workerId -and $owner.IsPolling) 'A first blocked poll was treated as current or spawned another worker.'
 $client.TimeoutMilliseconds=6000
 $oldEpoch=$client.Epoch
 [void](Get-LocalSourceClientSnapshot $client 'en' 1)
 Set-LocalSourceClientConnection $client $false
 Require ($client.Epoch -cne $oldEpoch -and @($client.Snapshot.Claude).Count -eq 0) 'The disconnected source was not invalidated immediately.'
 Set-LocalSourceClientConnection $client $true
 [void](Get-LocalSourceClientSnapshot $client 'en' 2)
 Require (-not $release.WaitOne(0) -and -not $client.Fresh) 'An old result was published while the source was blocked.'
 [void]$release.Set();$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 10;$current=Get-LocalSourceClientSnapshot $client 'en' 2}while(-not $client.Fresh -and $deadline.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and $client.HasRequestStamp -and $client.RequestStamp -eq 2 -and
  @($current.Codex).Count -eq 1 -and $current.Codex[0].Title -ceq 'Codex en' -and
  @($current.Claude).Count -eq 1 -and $current.Claude[0].Title -ceq 'Claude en') 'An invalidated response or request revision escaped the client.'
 $paused=$current.Codex[0].PSObject.Copy();$paused.Id='synthetic-paused';$paused.Active=$false;$paused.Paused=$true;$paused.Status='paused';$paused.Activity='Old paused work'
 $waiting=$current.Claude[0].PSObject.Copy();$waiting.Id='claude:waiting';$waiting.Active=$false;$waiting.Paused=$false;$waiting.Status='waiting';$waiting.Activity='Old waiting work'
 $failedClient=New-LocalSourceClient $owner 'en'
 $failedClient.Snapshot=[PSCustomObject]@{Codex=@($current.Codex)+@($paused);Claude=@($current.Claude)+@($waiting);Unavailable=@();PartialConnection=@();PartialData=@();CodexIncomplete=$false;ClaudeConnection='connected'}

 # The UI does not tick while a completed snapshot waits for delivery. The
 # first call after it becomes old must reject it before looking at results.
 Wait-Idle $owner;[void]$afterStarted.Reset();[void]$afterRelease.Reset();[void]$afterSnapshot.Set();$client.TimeoutMilliseconds=350
 [void](Get-LocalSourceClientSnapshot $client 'en' 3)
 Wait-SyntheticGate $owner $afterStarted 'The synthetic response did not pause after snapshot creation.'
 Start-Sleep -Milliseconds 450;[void]$afterRelease.Set();$deadline=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner.HasResult -and $deadline.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require $owner.HasResult 'The synthetic aged response never reached the owner.'
 $aged=Get-LocalSourceClientSnapshot $client 'en' 3
 Require ($client.TimedOut -and -not $client.Fresh -and @($aged.Codex).Count -eq 1 -and -not $aged.Codex[0].Active) 'An aged unread response falsely confirmed the snapshot.'
 $client.TimeoutMilliseconds=6000;$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 10;$current=Get-LocalSourceClientSnapshot $client 'en' 3}while(-not $client.Fresh -and $deadline.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and -not $client.TimedOut -and @($current.Codex).Count -eq 1 -and $current.Codex[0].Active) 'The source did not recover after discarding an aged snapshot.'

 # A second read can block after the first timeout. Its late answer must also
 # be invalidated, while the same owner remains the only source reader.
 Wait-Idle $owner;[void]$started.Reset();[void]$release.Reset();[void]$afterStarted.Reset();[void]$afterRelease.Reset()
 [void]$block.Set();[void]$afterSnapshot.Set();$client.TimeoutMilliseconds=350
 [void](Get-LocalSourceClientSnapshot $client 'en' 3)
 Wait-SyntheticGate $owner $started 'The first repeated synthetic read did not block.'
 Start-Sleep -Milliseconds 450;[void](Get-LocalSourceClientSnapshot $client 'en' 3)
 Require ($client.TimedOut -and $owner.OwnedProcessId -eq $workerId) 'The first repeated read did not time out safely.'
 $firstGeneration=$owner.Generation;[void]$release.Set()
 Wait-SyntheticGate $owner $afterStarted 'The second repeated synthetic read did not block.'
 Start-Sleep -Milliseconds 450;$secondLate=Get-LocalSourceClientSnapshot $client 'en' 3
 Require ($client.TimedOut -and $owner.Generation -ne $firstGeneration -and -not $client.Fresh -and
  @($secondLate.Codex).Count -eq 1 -and -not $secondLate.Codex[0].Active -and $owner.OwnedProcessId -eq $workerId) 'The second timeout did not invalidate its own late result.'
 $client.TimeoutMilliseconds=6000;[void]$afterRelease.Set();$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 10;$current=Get-LocalSourceClientSnapshot $client 'en' 3}while(-not $client.Fresh -and $deadline.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and -not $client.TimedOut -and $current.Codex[0].Active) 'The source did not recover from consecutive timeouts.'

 # A later hung read also invalidates its eventual old response without starting
 # a parallel worker; existing active cards remain visible but unconfirmed.
 Wait-Idle $owner;[void]$started.Reset();[void]$release.Reset();[void]$block.Set();$client.TimeoutMilliseconds=350
 [void](Get-LocalSourceClientSnapshot $client 'en' 3)
 Wait-SyntheticGate $owner $started 'The later synthetic read did not block.'
 Start-Sleep -Milliseconds 450
 $late=Get-LocalSourceClientSnapshot $client 'en' 3
 Require ($client.TimedOut -and $owner.OwnedProcessId -eq $workerId -and $owner.IsPolling -and
  @($late.Codex).Count -eq 1 -and -not $late.Codex[0].Active -and @($late.Claude).Count -eq 1 -and -not $late.Claude[0].Active) 'A hung refresh retained a false active status or spawned another worker.'
 $client.TimeoutMilliseconds=6000;[void]$release.Set();$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 10;$current=Get-LocalSourceClientSnapshot $client 'en' 3}while(-not $client.Fresh -and $deadline.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and -not $client.TimedOut -and @($current.Codex).Count -eq 1 -and $current.Codex[0].Active -and
  @($current.Unavailable).Count -eq 0) 'The timed-out response was applied before a fresh read completed.'

 # The one response containing a transient error is invalidated by a language
 # change. Until the next successful read, previously active cards must be
 # explicitly unconfirmed rather than retaining a false active status.
 Wait-Idle $owner;[void]$started.Reset();[void]$release.Reset();[void]$block.Set()
 [void](Get-LocalSourceClientSnapshot $client 'en' 3)
 Wait-SyntheticGate $owner $started 'The synthetic error read did not block.'
 $uncertain=Get-LocalSourceClientSnapshot $client 'ru' 4
 Require (-not $uncertain.Codex[0].Active -and -not $uncertain.Claude[0].Active -and
  @($uncertain.Unavailable) -ccontains 'Codex') 'Language invalidation falsely confirmed a card while the error response was pending.'
 [void]$release.Set();$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 10;$current=Get-LocalSourceClientSnapshot $client 'ru' 4}while(-not $client.Fresh -and $deadline.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and @($current.Codex).Count -eq 1 -and $current.Codex[0].Active -and $current.Codex[0].Title -ceq 'Codex ru' -and
  @($current.Unavailable).Count -eq 0) ('The current read did not safely supersede the invalidated error: fresh='+$client.Fresh+'; count='+@($current.Codex).Count+'; active='+$(if(@($current.Codex).Count){$current.Codex[0].Active}else{'none'})+'; title='+$(if(@($current.Codex).Count){$current.Codex[0].Title}else{'none'})+'; unavailable='+(@($current.Unavailable)-join ','))

 # A terminal observed only by the invalidated request survives in the source
 # owner's state and must be reflected by the following current-language read.
 Wait-Idle $owner;[void]$started.Reset();[void]$release.Reset();[void]$terminal.Set();[void]$block.Set()
 [void](Get-LocalSourceClientSnapshot $client 'ru' 5)
 Wait-SyntheticGate $owner $started 'The synthetic terminal read did not block.'
 $uncertain=Get-LocalSourceClientSnapshot $client 'en' 6
 Require (@($uncertain.Codex).Count -eq 1 -and -not $uncertain.Codex[0].Active) 'A task stayed active while its terminal result was invalidated.'
 [void]$release.Set();$deadline=[Diagnostics.Stopwatch]::StartNew()
 do{Start-Sleep -Milliseconds 10;$current=Get-LocalSourceClientSnapshot $client 'en' 6}while(-not $client.Fresh -and $deadline.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and @($current.Codex).Count -eq 0 -and @($current.Claude).Count -eq 1) 'The later read lost the terminal state maintained by the source owner.'

 $owner.Dispose();$deadline=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner.HasExited -and $deadline.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require ($owner.CanReplace) 'The synthetic owner did not exit cleanly.'
 $failed=Get-LocalSourceClientSnapshot $failedClient 'en' 7
 Require ($failedClient.Failed -and @($failed.Unavailable) -ccontains 'Codex' -and @($failed.Unavailable) -ccontains 'Claude Code' -and
  @($failed.Codex).Count -eq 2 -and @($failed.Codex|Where-Object {$_.Active -or $_.Paused}).Count -eq 0 -and
  @($failed.Claude).Count -eq 2 -and @($failed.Claude|Where-Object {$_.Active -or $_.Paused}).Count -eq 0 -and
  @($failed.Codex|Where-Object {$_.Id -ceq 'synthetic-paused' -and $_.Activity -cne 'Old paused work'}).Count -eq 1 -and
  @($failed.Claude|Where-Object {$_.Id -ceq 'claude:waiting' -and $_.Activity -cne 'Old waiting work'}).Count -eq 1) 'Worker failure lost active, paused or waiting tasks, or presented stale actions as current.'
 Write-Output 'Local source client: nonblocking poll, stale invalidation, reconnect, request revision and failure fallback verified.'
}finally{
 [void]$release.Set();[void]$afterRelease.Set();$owner.Dispose();$started.Dispose();$release.Dispose();$block.Dispose();$terminal.Dispose();$afterSnapshot.Dispose();$afterStarted.Dispose();$afterRelease.Dispose()
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
