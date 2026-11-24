$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -Path (Join-Path $app 'LocalReadOwner.cs')
. (Join-Path $app 'LocalSourceClient.ps1')
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'LocalSourceCore.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The synthetic source functions could not be parsed.'}
$definitions=foreach($name in @('Prop','Unconfirmed-Tasks')){
 $node=$ast.Find({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name},$true)
 if($null -eq $node){throw 'A synthetic fallback function is missing.'};$node.Extent.Text
}
. ([scriptblock]::Create(($definitions -join [Environment]::NewLine)))
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Get-SyntheticSourceStages {return (($stageHandles.Keys|Sort-Object|ForEach-Object {$_+'='+$stageHandles[$_].WaitOne(0)}) -join '; ')}
function Event([string]$id,[string]$event,[DateTime]$time,[object]$active,[string]$phase=''){
 $data=@{timestamp=$time.ToString('o');session_id=$id;event=$event;active=$active}
 if($phase){$data.stage_version=1;$data.stage_phase=$phase}
 return ($data|ConvertTo-Json -Compress)
}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-claude-gap-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic Claude gap directory.'
[void][IO.Directory]::CreateDirectory($root);$owner=$null;$stageHandles=@{}
$priorStagePrefix=[Environment]::GetEnvironmentVariable('AITM_GAP_STAGE_PREFIX','Process')
try{
 $work=Join-Path $root 'worker';[void][IO.Directory]::CreateDirectory($work)
 foreach($name in @('LocalSourceCore.ps1','CodexAgentRetention.ps1','CodexAgentRetentionAdapter.ps1','CodexTitlesCore.cs','CodexRecentEventObserver.cs','ClaudeReaderCore.ps1')){Copy-Item -LiteralPath (Join-Path $app $name) -Destination (Join-Path $work $name)}
 $stagePrefix='Local\AITMClaudeGapStages-'+[Guid]::NewGuid().ToString('N');$env:AITM_GAP_STAGE_PREFIX=$stagePrefix
 foreach($name in @('CONNECTED','PID_DONE','CORE_BEGIN','CORE_END','INIT_BEGIN','TITLES_BEGIN','TITLES_END','OBSERVER_BEGIN','OBSERVER_END','CLAUDE_BEGIN','CLAUDE_END','INIT_END','ACK_BEGIN','ACK_END','POLL_BEGIN','POLL_END','CAUGHT')){
  $stageHandles[$name]=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,($stagePrefix+'-'+$name))
 }
 $corePath=Join-Path $work 'LocalSourceCore.ps1';$core=[IO.File]::ReadAllText($corePath)
 foreach($pair in @(
  @(' if(-not (''AITaskMonitor.CodexTitles.Reader'' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot ''CodexTitlesCore.cs'') -ErrorAction Stop}','TITLES'),
  @(' if(-not (''AITaskMonitor.CodexObservation.CodexRecentEventObserver'' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot ''CodexRecentEventObserver.cs'') -ErrorAction Stop}','OBSERVER'),
  @(' . (Join-Path $PSScriptRoot ''ClaudeReaderCore.ps1'')','CLAUDE')
 )){
  Require ($core.Contains($pair[0])) 'A synthetic reader initialization stage could not be instrumented.'
  $core=$core.Replace($pair[0],(' Set-GapStage "'+$pair[1]+'_BEGIN"'+[Environment]::NewLine+$pair[0]+[Environment]::NewLine+' Set-GapStage "'+$pair[1]+'_END"'))
 }
 [IO.File]::WriteAllText($corePath,$core,[Text.UTF8Encoding]::new($true))
 $source=[IO.File]::ReadAllText((Join-Path $app 'LocalSourceWorker.ps1'))
 $header='$ErrorActionPreference=''Stop''';$coreNeedle='   . (Join-Path $PSScriptRoot ''LocalSourceCore.ps1'')'
 $initNeedle='   Initialize-LocalSourceReader -CodexHome';$ackNeedle='$writer.Write([int]$payload.Length);$writer.Write($payload);$writer.Flush()'
 Require ($source.Contains($header) -and $source.Contains($coreNeedle) -and $source.Contains($initNeedle) -and $source.Contains($ackNeedle)) 'The synthetic worker stages could not be instrumented.'
 $source=$source.Replace($header,($header+[Environment]::NewLine+'function Set-GapStage([string]$name){$e=[Threading.EventWaitHandle]::OpenExisting($env:AITM_GAP_STAGE_PREFIX+"-"+$name);try{[void]$e.Set()}finally{$e.Dispose()}}'))
 $source=$source.Replace('$pipe.Connect(5000)','$pipe.Connect(5000);Set-GapStage "CONNECTED"').Replace('$identityVerified=$true','$identityVerified=$true;Set-GapStage "PID_DONE"')
 $source=$source.Replace($coreNeedle,('   Set-GapStage "CORE_BEGIN"'+[Environment]::NewLine+$coreNeedle+[Environment]::NewLine+'   Set-GapStage "CORE_END"'))
 $source=$source.Replace($initNeedle,('   Set-GapStage "INIT_BEGIN"'+[Environment]::NewLine+$initNeedle)).Replace('   $initialized=$true','   Set-GapStage "INIT_END";$initialized=$true')
 $source=$source.Replace($ackNeedle,('Set-GapStage "ACK_BEGIN";'+$ackNeedle+';Set-GapStage "ACK_END"'))
 $source=$source.Replace('$result=Local-SourceSnapshot',('Set-GapStage "POLL_BEGIN"'+[Environment]::NewLine+'  $result=Local-SourceSnapshot'))
 $source=$source.Replace('$xml=[Management.Automation.PSSerializer]::Serialize($result,24)',('Set-GapStage "POLL_END"'+[Environment]::NewLine+'  $xml=[Management.Automation.PSSerializer]::Serialize($result,24)'))
 $source=$source.Replace(' # Source paths and task content must not be emitted to a console or log.',(' Set-GapStage "CAUGHT"'+[Environment]::NewLine+' # Source paths and task content must not be emitted to a console or log.'))
 $needle='$xml=[Management.Automation.PSSerializer]::Serialize($result,24)'
 $gate='if($env:AITM_GAP_DELAY -ceq "true" -and $script:claudeReaderSession.SourceUncertain -and -not (Get-Variable -Scope Script -Name syntheticGapHeld -ErrorAction SilentlyContinue)){$script:syntheticGapHeld=$true;$started=[Threading.EventWaitHandle]::OpenExisting($env:AITM_GAP_STARTED);$release=[Threading.EventWaitHandle]::OpenExisting($env:AITM_GAP_RELEASE);try{[void]$started.Set();if(-not $release.WaitOne(30000)){throw "Synthetic gap gate timed out."}}finally{$started.Dispose();$release.Dispose()}}'
 Require ($source.Contains($needle)) 'The production source worker could not be gated in the synthetic copy.'
 [IO.File]::WriteAllText((Join-Path $work 'LocalSourceWorker.ps1'),$source.Replace($needle,$gate+[Environment]::NewLine+'  '+$needle),[Text.UTF8Encoding]::new($false))
 foreach($mode in @('direct','delayed')){
  foreach($stage in $stageHandles.Values){[void]$stage.Reset()}
  $fixture=Join-Path $root $mode;$codex=Join-Path $fixture 'codex';$profile=Join-Path $fixture 'profile';$data=Join-Path $fixture 'data'
  foreach($directory in @($codex,$profile,$data)){[void][IO.Directory]::CreateDirectory($directory)}
  $startName='Local\AITMClaudeGapStart-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMClaudeGapRelease-'+[Guid]::NewGuid().ToString('N')
  $started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName);$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
  try{
   $env:AITM_GAP_STARTED=$startName;$env:AITM_GAP_RELEASE=$releaseName;$env:AITM_GAP_DELAY=if($mode -ceq 'delayed'){'true'}else{'false'}
   $eventPath=Join-Path $data 'events.jsonl';$now=[DateTime]::UtcNow;$utf8=[Text.UTF8Encoding]::new($false)
   $prompt=Event 'synthetic-a' 'UserPromptSubmit' $now.AddSeconds(-5) $true
   $stop=Event 'synthetic-a' 'Stop' $now.AddSeconds(-1) $false 'stop_clear'
   $gap=@{timestamp=$now.ToString('o');stage_version=1;stage_phase='source_uncertain'}|ConvertTo-Json -Compress
   [IO.File]::WriteAllText($eventPath,($prompt+[Environment]::NewLine),$utf8)
   $config=[string[]]@('AITM-LOCAL-SOURCE-1',$codex,$profile,$data,'',$eventPath,$now.AddMinutes(-1).ToString('o'))
   $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $work 'LocalSourceWorker.ps1'),$config)
   $client=New-LocalSourceClient $owner 'ru';$clock=[Diagnostics.Stopwatch]::StartNew()
   do{$snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0;if($client.Fresh -and @($snapshot.Claude).Count -eq 1){break};Start-Sleep -Milliseconds 15}while($clock.ElapsedMilliseconds -lt 15000)
   Require ($client.Fresh -and @($snapshot.Claude).Count -eq 1 -and $snapshot.Claude[0].Active) ('The synthetic Claude baseline failed: mode='+$mode+'; elapsed_ms='+$clock.ElapsedMilliseconds+'; owner='+$owner.Stage+'; failure='+$owner.FailureStage+'; kind='+$owner.FailureKind+'; warmup_ready='+$client.WarmupReady+'; warmup_pending='+$client.WarmupPending+'; timed_out='+$client.TimedOut+'; polling='+$owner.IsPolling+'; pending='+$owner.HasPendingRequest+'; result='+$owner.HasResult+'; '+(Get-SyntheticSourceStages))
   foreach($stage in @('CONNECTED','PID_DONE','CORE_BEGIN','CORE_END','INIT_BEGIN','TITLES_BEGIN','TITLES_END','OBSERVER_BEGIN','OBSERVER_END','CLAUDE_BEGIN','CLAUDE_END','INIT_END','ACK_BEGIN','ACK_END','POLL_BEGIN','POLL_END')){
    Require ($stageHandles[$stage].WaitOne(0)) ('A synthetic source stage was not observed: '+$stage)
   }
   $promptB=Event 'synthetic-b' 'UserPromptSubmit' $now.AddSeconds(-4) $true;$splitB=[int]($promptB.Length/2)
   $firstStop=Event 'synthetic-a' 'Stop' $now.AddSeconds(-3) $false 'stop_clear'
   [IO.File]::AppendAllText($eventPath,($firstStop+[Environment]::NewLine+$promptB.Substring(0,$splitB)),$utf8);$clock.Restart()
   do{$snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0;if($client.Fresh -and @($snapshot.PartialData) -ccontains 'Claude Code'){break};Start-Sleep -Milliseconds 15}while($clock.ElapsedMilliseconds -lt 15000)
   $firstCard=@($snapshot.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-a'})
   Require ($client.Fresh -and $firstCard.Count -eq 1 -and -not $firstCard[0].Active -and @($snapshot.Claude).Count -eq 1 -and @($snapshot.PartialData) -ccontains 'Claude Code') 'An incomplete new Claude record did not mark the already visible list as partial.'
   [IO.File]::AppendAllText($eventPath,($promptB.Substring($splitB)+[Environment]::NewLine),$utf8);$clock.Restart()
   do{$snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0;if($client.Fresh -and @($snapshot.Claude).Count -eq 1 -and [string]$snapshot.Claude[0].Id -ceq 'claude:synthetic-b' -and $snapshot.Claude[0].Active -and @($snapshot.PartialData) -cnotcontains 'Claude Code'){break};Start-Sleep -Milliseconds 15}while($clock.ElapsedMilliseconds -lt 15000)
   Require ($client.Fresh -and @($snapshot.Claude).Count -eq 1 -and [string]$snapshot.Claude[0].Id -ceq 'claude:synthetic-b' -and $snapshot.Claude[0].Active -and @($snapshot.PartialData) -cnotcontains 'Claude Code') 'A completed record did not resolve the partial state and the confirmed stop.'
   $resume=Event 'synthetic-a' 'UserPromptSubmit' $now.AddSeconds(-2) $true
   [IO.File]::AppendAllText($eventPath,($resume+[Environment]::NewLine),$utf8);$clock.Restart()
   do{$snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0;if($client.Fresh -and @($snapshot.Claude).Count -eq 2 -and @($snapshot.Claude|Where-Object {$_.Active}).Count -eq 2){break};Start-Sleep -Milliseconds 15}while($clock.ElapsedMilliseconds -lt 15000)
   Require ($client.Fresh -and @($snapshot.Claude|Where-Object {$_.Active}).Count -eq 2) 'A fresh Claude prompt did not restore the synthetic task.'
   [IO.File]::AppendAllText($eventPath,($stop+[Environment]::NewLine+$gap+[Environment]::NewLine),$utf8)
   $clock.Restart()
   if($mode -ceq 'delayed'){
    do{[void](Get-LocalSourceClientSnapshot $client 'ru' 0);Start-Sleep -Milliseconds 15}while(-not $started.WaitOne(0) -and $clock.ElapsedMilliseconds -lt 15000)
    Require ($started.WaitOne(0)) ('The real synthetic source did not reach its late-response gate; owner='+$owner.Stage+'; failure='+$owner.FailureStage)
    $client.PendingStartedAt=[Diagnostics.Stopwatch]::GetTimestamp()-[Diagnostics.Stopwatch]::Frequency
    $client.TimeoutMilliseconds=10;$timeout=Get-LocalSourceClientSnapshot $client 'ru' 0;$client.TimeoutMilliseconds=6000
    $timeoutCards=@($timeout.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-a'})
    Require ($timeoutCards.Count -eq 1 -and -not $timeoutCards[0].Active -and @($timeout.Claude|Where-Object {$_.Active}).Count -eq 0) 'A timed-out Claude card was not retained as unconfirmed.'
    [void]$release.Set();$clock.Restart()
   }
   do{
    $snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0
    if($client.Fresh -and @($snapshot.Unavailable) -ccontains 'Claude Code'){break}
    Start-Sleep -Milliseconds 15
   }while($clock.ElapsedMilliseconds -lt 15000)
   $cards=@($snapshot.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-a'})
   Require ($client.Fresh -and @($snapshot.Unavailable) -ccontains 'Claude Code' -and @($snapshot.PartialData) -ccontains 'Claude Code' -and $cards.Count -eq 1 -and -not $cards[0].Active) ('The production worker lost a prior Claude card or did not report partial source data: mode='+$mode)
   Set-LocalSourceClientConnection $client $false;$clock.Restart()
   do{$snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0;if($client.Fresh -and $snapshot.ClaudeConnection -ceq 'disconnected'){break};Start-Sleep -Milliseconds 15}while($clock.ElapsedMilliseconds -lt 15000)
   Require ($client.Fresh -and @($snapshot.Claude).Count -eq 0 -and @($snapshot.Unavailable) -cnotcontains 'Claude Code' -and @($snapshot.PartialData) -cnotcontains 'Claude Code') 'A disabled Claude source still showed a partial-source warning.'
   Set-LocalSourceClientConnection $client $true;$clock.Restart()
   do{$snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0;if($client.Fresh -and @($snapshot.Unavailable) -ccontains 'Claude Code'){break};Start-Sleep -Milliseconds 15}while($clock.ElapsedMilliseconds -lt 15000)
   $cards=@($snapshot.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-a'})
   Require ($client.Fresh -and @($snapshot.PartialData) -ccontains 'Claude Code' -and $cards.Count -eq 1 -and -not $cards[0].Active) 'Reconnecting Claude lost the known source gap or falsely confirmed the old card.'
  }finally{
   [void]$release.Set()
   if($null -ne $owner){$owner.Dispose();$wait=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $wait.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic Claude gap owner did not stop.'};$owner=$null}
   $started.Dispose();$release.Dispose()
  }
 }
 $fixture=Join-Path $root 'partial';$codex=Join-Path $fixture 'codex';$profile=Join-Path $fixture 'profile';$data=Join-Path $fixture 'data'
 foreach($directory in @($codex,$profile,$data)){[void][IO.Directory]::CreateDirectory($directory)}
 $env:AITM_GAP_DELAY='false';$eventPath=Join-Path $data 'events.jsonl';$now=[DateTime]::UtcNow;$utf8=[Text.UTF8Encoding]::new($false)
 $prompt=Event 'synthetic-new' 'UserPromptSubmit' $now.AddSeconds(-1) $true;$split=[int]($prompt.Length/2)
 [IO.File]::WriteAllText($eventPath,$prompt.Substring(0,$split),$utf8)
 $config=[string[]]@('AITM-LOCAL-SOURCE-1',$codex,$profile,$data,'',$eventPath,$now.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $work 'LocalSourceWorker.ps1'),$config)
 $client=New-LocalSourceClient $owner 'ru';$clock=[Diagnostics.Stopwatch]::StartNew()
 do{$snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0;if($client.Fresh -and @($snapshot.PartialData) -ccontains 'Claude Code'){break};Start-Sleep -Milliseconds 15}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and @($snapshot.Claude).Count -eq 0 -and @($snapshot.Unavailable) -ccontains 'Claude Code' -and @($snapshot.PartialData) -ccontains 'Claude Code') 'An incomplete first Claude record was presented as a confirmed empty source.'
 [IO.File]::AppendAllText($eventPath,($prompt.Substring($split)+[Environment]::NewLine),$utf8);$clock.Restart()
 do{$snapshot=Get-LocalSourceClientSnapshot $client 'ru' 0;if($client.Fresh -and @($snapshot.Claude).Count -eq 1 -and @($snapshot.Unavailable) -cnotcontains 'Claude Code'){break};Start-Sleep -Milliseconds 15}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and @($snapshot.Claude).Count -eq 1 -and $snapshot.Claude[0].Active -and @($snapshot.PartialData) -cnotcontains 'Claude Code') 'A completed Claude record did not restore the normal source status.'
 Write-Output 'Production Claude source: global gaps, delayed response, disable/reconnect and incomplete first record verified.'
}finally{
 if($null -ne $owner){$owner.Dispose();$wait=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $wait.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic partial Claude owner did not stop.'}}
 Remove-Item Env:\AITM_GAP_STARTED,Env:\AITM_GAP_RELEASE,Env:\AITM_GAP_DELAY -ErrorAction SilentlyContinue
 [Environment]::SetEnvironmentVariable('AITM_GAP_STAGE_PREFIX',$priorStagePrefix,'Process')
 foreach($stage in $stageHandles.Values){$stage.Dispose()}
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic Claude gap cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
