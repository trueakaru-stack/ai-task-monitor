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
function Wait-Gate($gate,$owner,[string]$message){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds -lt 15000){if($gate.WaitOne(20)){return};if($owner.HasExited){break}}
 throw ($message+'; stage='+$owner.Stage+'; failed_at='+$owner.FailureStage+'; kind='+$owner.FailureKind)
}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-source-warmup-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic warmup directory.'
[void][IO.Directory]::CreateDirectory($root);$owner=$null;$handles=@()
try{
 $work=Join-Path $root 'worker';$codex=Join-Path $root 'codex';$profile=Join-Path $root 'profile';$data=Join-Path $root 'data'
 foreach($path in @($work,$codex,$profile,$data)){[void][IO.Directory]::CreateDirectory($path)}
 foreach($name in @('LocalSourceCore.ps1','CodexAgentRetention.ps1','CodexAgentRetentionAdapter.ps1','CodexTitlesCore.cs','CodexRecentEventObserver.cs','ClaudeReaderCore.ps1')){Copy-Item -LiteralPath (Join-Path $app $name) -Destination (Join-Path $work $name)}
 $prefix='Local\AITMSourceWarmup-'+[Guid]::NewGuid().ToString('N')
 foreach($key in @('INIT_START','INIT_RELEASE','POLL_START_1','POLL_RELEASE_1','POLL_START_2','POLL_RELEASE_2')){
  $name=$prefix+'-'+$key;[Environment]::SetEnvironmentVariable('AITM_WARM_'+$key,$name,'Process')
  $handles+=@([Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$name))
 }
 $source=[IO.File]::ReadAllText((Join-Path $app 'LocalSourceWorker.ps1'))
 $initNeedle='   Initialize-LocalSourceReader -CodexHome'
 $initGate='$script:syntheticPolls=0;$s=[Threading.EventWaitHandle]::OpenExisting($env:AITM_WARM_INIT_START);$r=[Threading.EventWaitHandle]::OpenExisting($env:AITM_WARM_INIT_RELEASE);try{[void]$s.Set();if(-not $r.WaitOne(30000)){throw "Synthetic init gate timed out."}}finally{$s.Dispose();$r.Dispose()}'
 $readNeedle='$result=Local-SourceSnapshot'
 $readGate='$script:syntheticPolls++;if($script:syntheticPolls -le 2){$n=$script:syntheticPolls;$s=[Threading.EventWaitHandle]::OpenExisting([Environment]::GetEnvironmentVariable("AITM_WARM_POLL_START_"+$n));$r=[Threading.EventWaitHandle]::OpenExisting([Environment]::GetEnvironmentVariable("AITM_WARM_POLL_RELEASE_"+$n));try{[void]$s.Set();if(-not $r.WaitOne(30000)){throw "Synthetic poll gate timed out."}}finally{$s.Dispose();$r.Dispose()}}'
 Require ($source.Contains($initNeedle) -and $source.Contains($readNeedle)) 'The production worker could not be gated in the synthetic copy.'
 $source=$source.Replace($initNeedle,('   '+$initGate+[Environment]::NewLine+$initNeedle)).Replace($readNeedle,($readGate+[Environment]::NewLine+'  '+$readNeedle))
 [IO.File]::WriteAllText((Join-Path $work 'LocalSourceWorker.ps1'),$source,[Text.UTF8Encoding]::new($false))
 $now=[DateTime]::UtcNow;$events=Join-Path $data 'events.jsonl'
 $prompt=@{timestamp=$now.ToString('o');session_id='synthetic-warmup';event='UserPromptSubmit';active=$true}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText($events,($prompt+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
 $config=[string[]]@('AITM-LOCAL-SOURCE-1',$codex,$profile,$data,'',$events,$now.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $work 'LocalSourceWorker.ps1'),$config)
 $client=New-LocalSourceClient $owner 'ru'
 $known=[PSCustomObject]@{Id='synthetic-previous';Provider='codex';Active=$true;Paused=$false;Status='working';Activity='working';Steps=@()}
 $client.Snapshot=[PSCustomObject]@{Codex=@($known);Claude=@();Unavailable=@();PartialConnection=@();PartialData=@();CodexIncomplete=$false;ClaudeConnection='disconnected'}
 [void](Get-LocalSourceClientSnapshot $client 'ru' 1)
 Wait-Gate $handles[0] $owner 'The production worker did not reach initialization.'
 $id=$owner.OwnedProcessId;$generation=$owner.Generation
 $client.PendingStartedAt=[Diagnostics.Stopwatch]::GetTimestamp()-([Diagnostics.Stopwatch]::Frequency*7)
 $uncertain=Get-LocalSourceClientSnapshot $client 'ru' 1
 Require ($client.TimedOut -and $client.WarmupPending -and -not $client.WarmupReady -and -not $client.Fresh -and
  $owner.Generation -eq $generation -and $owner.OwnedProcessId -eq $id -and
  @($uncertain.Codex).Count -eq 1 -and -not $uncertain.Codex[0].Active -and -not $handles[2].WaitOne(0)) 'A slow initialization was confused with a source read or retained a confirmed card.'
 $client.PendingStartedAt=[Diagnostics.Stopwatch]::GetTimestamp()-([Diagnostics.Stopwatch]::Frequency*7)
 [void](Get-LocalSourceClientSnapshot $client 'ru' 1)
 Require ($owner.Generation -eq $generation -and $owner.OwnedProcessId -eq $id -and -not $client.Fresh) 'Repeated initialization timeout created or invalidated a reader.'
 [void](Get-LocalSourceClientSnapshot $client 'en' 2);Set-LocalSourceClientConnection $client $false
 Require (@($client.Snapshot.Claude).Count -eq 0 -and $client.Snapshot.ClaudeConnection -ceq 'disconnected') 'Disabling during initialization did not take effect immediately.'
 Set-LocalSourceClientConnection $client $true;[void](Get-LocalSourceClientSnapshot $client 'en' 9)
 Require ($owner.Generation -ne $generation -and $owner.OwnedProcessId -eq $id -and -not $handles[2].WaitOne(0)) 'The changed settings did not invalidate the old warmup.'
 [void]$handles[1].Set();$clock=[Diagnostics.Stopwatch]::StartNew()
 do{[void](Get-LocalSourceClientSnapshot $client 'en' 9);if($client.WarmupReady){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.WarmupReady -and -not $client.Fresh -and $owner.OwnedProcessId -eq $id) 'Initialization acknowledgement was treated as a source snapshot.'
 Wait-Gate $handles[2] $owner 'The separately timed source read did not start.'
 $generation=$owner.Generation;$client.PendingStartedAt=[Diagnostics.Stopwatch]::GetTimestamp()-([Diagnostics.Stopwatch]::Frequency*7)
 $uncertain=Get-LocalSourceClientSnapshot $client 'en' 9
 Require ($client.TimedOut -and -not $client.Fresh -and $owner.Generation -ne $generation -and
  @($uncertain.Codex).Count -eq 1 -and -not $uncertain.Codex[0].Active) 'An aged real source read was not invalidated.'
 [void]$handles[3].Set();Wait-Gate $handles[4] $owner 'A fresh replacement poll did not follow the delayed source read.'
 $uncertain=Get-LocalSourceClientSnapshot $client 'en' 9
 Require (-not $client.Fresh -and @($uncertain.Codex).Count -eq 1 -and -not $uncertain.Codex[0].Active -and
  $owner.OwnedProcessId -eq $id) 'A delayed source result was presented as fresh or another worker was started.'
 [void]$handles[5].Set();$clock.Restart()
 do{$result=Get-LocalSourceClientSnapshot $client 'en' 9;if($client.Fresh){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.Fresh -and $client.HasRequestStamp -and $client.RequestStamp -eq 9 -and
  @($result.Claude|Where-Object {[string]$_.Id -ceq 'claude:synthetic-warmup' -and $_.Active}).Count -eq 1 -and $owner.OwnedProcessId -eq $id) 'The fresh source read did not complete after initialization.'
 Write-Output 'Production source warmup: separate initialization, settings changes, stale poll rejection and one owner verified.'
}finally{
 foreach($handle in $handles){[void]$handle.Set()}
 if($null -ne $owner){$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic warmup owner did not stop.'}}
 foreach($handle in $handles){$handle.Dispose()}
 foreach($key in @('INIT_START','INIT_RELEASE','POLL_START_1','POLL_RELEASE_1','POLL_START_2','POLL_RELEASE_2')){[Environment]::SetEnvironmentVariable('AITM_WARM_'+$key,$null,'Process')}
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic warmup cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
