param([switch]$ExitProbe,[switch]$PreResumeProbe)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'The synthetic button check requires STA.'}
Add-Type -AssemblyName PresentationFramework
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class LocalReadTestRelay {
 public static void Relay(ManualResetEventSlim release, EventWaitHandle childRelease) {
  Thread thread=new Thread(delegate() { release.Wait(); try { childRelease.Set(); } catch (ObjectDisposedException) { } });
  thread.IsBackground=true; thread.Start();
 }
 public static void Watchdog(ManualResetEventSlim release, int milliseconds) {
  Thread thread=new Thread(delegate() { Thread.Sleep(milliseconds); try { release.Set(); } catch (ObjectDisposedException) { } });
  thread.IsBackground=true; thread.Start();
 }
}
'@
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Wait-Result($owner,[int]$milliseconds=10000){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds -lt $milliseconds){$result=$owner.TryReceive();if($null -ne $result){return $result};Start-Sleep -Milliseconds 10}
 throw 'The synthetic transport did not return a result.'
}
function Wait-HasResult($owner,[int]$milliseconds=10000){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner.HasResult -and $clock.ElapsedMilliseconds -lt $milliseconds){Start-Sleep -Milliseconds 10}
 Require $owner.HasResult 'The synthetic transport did not make a result available.'
}
function Wait-Exit($owner,[int]$milliseconds=10000,[string]$name='unknown'){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt $milliseconds){Start-Sleep -Milliseconds 10}
 Require $owner.HasExited 'The synthetic transport thread did not exit.'
 Require (-not $owner.CleanupFailed) ('Cleanup could not confirm the synthetic worker exit: '+$name+' ('+$owner.CleanupFailureCode+')')
 Require $owner.CanReplace 'The synthetic owner was not safe to replace after cleanup.'
}
function Wait-ProcessGone([int]$id,[int]$milliseconds=5000){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds -lt $milliseconds){if($null -eq (Get-Process -Id $id -ErrorAction SilentlyContinue)){return};Start-Sleep -Milliseconds 10}
 throw 'The synthetic worker process remained after disposal.'
}
function New-TestGates {
 $startName='Local\AITaskMonitorSyntheticStart-'+[Guid]::NewGuid().ToString('N')
 $releaseName='Local\AITaskMonitorSyntheticRelease-'+[Guid]::NewGuid().ToString('N')
 return [PSCustomObject]@{
  StartedName=$startName;ReleaseName=$releaseName
  Started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName)
  Release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
  LocalRelease=[Threading.ManualResetEventSlim]::new($false)
 }
}
$workerPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\LocalReadSyntheticWorker.ps1'))
if($ExitProbe -or $PreResumeProbe){
 $probeGates=New-TestGates
 $probeConfig=[string[]]@($probeGates.StartedName,$probeGates.ReleaseName)
 $probeOwner=if($PreResumeProbe){[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$probeConfig,$false,$true)}else{[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$probeConfig)}
 Require ($probeOwner.Request([string[]]@('block','ru','true'))) 'The exit probe request was rejected.'
 if($PreResumeProbe){
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not $probeOwner.IsBeforeResume -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
  Require ($probeOwner.IsBeforeResume -and -not $probeGates.Started.WaitOne(0)) 'The actual owner did not stop before resuming its worker.'
 }else{Require ($probeGates.Started.WaitOne(10000)) 'The exit probe did not enter its synthetic blocked read.'}
 Write-Output ('WORKER:'+$probeOwner.OwnedProcessId)
 # Deliberately omit Dispose and leave the synthetic read blocked. The OS must
 # close the job handle when this owner process exits.
 return
}
$source=Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The production monitor source did not parse.'}
$definitions=foreach($name in @('Prop','Brush','Text','Localized-TaskTitle','Localized-TaskActivity','Localized-CompactTaskActivity',
 'Plan-StatusNote','Progress-Label','Get-LoopWarning','Add-LoopWarning','Add-ConditionalHint','New-ActivityIndicator','New-TaskTitleLine',
 'Active-PlanStepIndex','Compact-AgentStepLabel','Compact-ProgressLabel','Compact-ExtraAgentStepLabel','Related-AgentStatus','New-RelatedAgentToggle',
 'Compact-VisibleTasks','Compact-ShowProviderLabels','Compact-HasHiddenAgentTasks','Source-WarningText','Compact-Height',
 'Add-CompactTask','Add-CompactDot','Sync-CompactDots','Render-CompactTasks')){
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
 if($null -eq $node){throw "Missing production function: $name"};$node.Extent.Text
}
. ([scriptblock]::Create(($definitions -join "`n")))
function Tr([string]$value){return $value}
function Move-CompactWindow {}
# The click handler, compact rendering and WPF controls are production code.
# The host is a synthetic in-memory object: no window is shown or laid out.
$window=[PSCustomObject]@{Height=0.0;Resources=@{CompactDotStyle=[Windows.Style]::new([Windows.Controls.Button])}}
$compactDotsPanel=[Windows.Controls.StackPanel]::new()
$compactTasksPanel=[Windows.Controls.StackPanel]::new();$compactMoreText=[Windows.Controls.TextBlock]::new()
$script:palette=[PSCustomObject]@{Scroll='#888888';Primary='#222222';Activity='#333333';Muted='#777777'};$script:accentHex='#0066CC'
$script:resolvedLanguage='en';$script:isCompact=$true;$script:motionEnabled=$false
$script:sourceErrors=@();$script:sourcePartialConnections=@();$script:sourcePartialData=@();$script:sourceCodexIncomplete=$false
$script:diagnosticRuntime=$null;$script:claudeLoopStates=@{};$script:previewHintTarget=$null
$PreviewRelatedAgents=$false;$CompactMode=$true;$PreviewActiveTasks=-1;$PreviewLoopWarning=$false
$script:compactTaskId='first'
$script:lastAllTasks=@(
 [PSCustomObject]@{Id='first';Title='First';Provider='synthetic';ProviderName='Synthetic';Active=$true;Status='active';Activity='Checking';ProgressKind='none';Progress=$null;Steps=@()},
 [PSCustomObject]@{Id='second';Title='Second';Provider='synthetic';ProviderName='Synthetic';Active=$true;Status='active';Activity='Working';ProgressKind='none';Progress=$null;Steps=@()}
)
Render-CompactTasks $script:lastAllTasks
$initialCard=$compactTasksPanel.Children[0]
Require ([Windows.Automation.AutomationProperties]::GetName($initialCard.Children[0].Children[0]) -ceq 'First') 'The initial real compact rendering is incorrect.'

$gates=New-TestGates
[LocalReadTestRelay]::Relay($gates.LocalRelease,$gates.Release)
$config=[string[]]@($gates.StartedName,$gates.ReleaseName)
$owner=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$config)
$config[0]='changed-after-construction'
try{
 Require ($owner.Request([string[]]@('block','ru','true'),[long]10)) 'The first synthetic request was rejected.'
 Require ($gates.Started.WaitOne(10000)) 'The synthetic worker did not enter the blocked read.'
 [LocalReadTestRelay]::Watchdog($gates.LocalRelease,8000)
 $childId=$owner.OwnedProcessId
 Require ($childId -gt 0 -and $owner.IsPolling) 'The single worker is not polling.'
 foreach($index in 1..50){Require ($owner.Request([string[]]@('obsolete','ru','true'),[long]20)) 'A repeated refresh was rejected.'}
 Require ($owner.HasPendingRequest -and $owner.OwnedProcessId -eq $childId) 'Refresh requests started another worker.'

 $dot=@($compactDotsPanel.Children|Where-Object {[string]$_.Tag -ceq 'second'})[0]
 $clickClock=[Diagnostics.Stopwatch]::StartNew()
 $dot.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 $clickClock.Stop()
 $switchedCard=$compactTasksPanel.Children[0]
 Require ($script:compactTaskId -ceq 'second' -and -not [object]::ReferenceEquals($initialCard,$switchedCard) -and
  [Windows.Automation.AutomationProperties]::GetName($switchedCard.Children[0].Children[0]) -ceq 'Second' -and
  -not $gates.LocalRelease.IsSet -and $null -eq $owner.TryReceive()) 'The real task-dot handler and compact rendering did not respond before the synthetic read was released.'

 $oldGeneration=$owner.Generation
 $owner.Invalidate()
 Require ($owner.Generation -ne $oldGeneration -and -not $owner.HasPendingRequest) 'Disconnect or language invalidation did not clear stale pending work.'
 $latestRequest=[string[]]@('latest','en','false')
 Require ($owner.Request($latestRequest,[long]30)) 'The new generation was not accepted.'
 $latestRequest[1]='changed-after-request'
 Require (-not $gates.LocalRelease.IsSet -and $null -eq $owner.TryReceive()) 'A stale result was published before the blocked read finished.'
 $gates.LocalRelease.Set()
 $result=Wait-Result $owner
 Require ($result.Success -and $result.Generation -eq $owner.Generation -and $result.Value.Sequence -eq 2 -and
  $result.Value.Kind -ceq 'latest' -and $result.Value.Language -ceq 'en' -and -not $result.Value.Connected -and
  $result.HasRequestStamp -and $result.RequestStamp -eq 30) 'A stale, incorrectly localized or uncoalesced result was published.'
}finally{
 $gates.LocalRelease.Set()
 $owner.Dispose()
}
Wait-Exit $owner -name 'normal'
Wait-ProcessGone $childId

# An unread terminal result or source error cannot be overwritten by a newer
# request. New requests may coalesce, but the current result is delivered first.
$orderedGates=New-TestGates
$orderedConfig=[string[]]@($orderedGates.StartedName,$orderedGates.ReleaseName)
$ordered=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$orderedConfig)
try{
 Require ($ordered.Request([string[]]@('terminal','ru','true'),[long]100)) 'The terminal request was rejected.'
 Wait-HasResult $ordered
 Require ($ordered.Request([string[]]@('error','en','false'),[long]101)) 'The pending error request was rejected.'
 Require ($ordered.HasPendingRequest -and -not $ordered.IsPolling) 'The unread result did not hold back the next poll.'
 $terminal=$ordered.TryReceive()
 Require ($terminal.Success -and $terminal.Value.Sequence -eq 1 -and $terminal.Value.Kind -ceq 'terminal' -and $terminal.RequestStamp -eq 100) 'The unread terminal result was overwritten.'
 Wait-HasResult $ordered
 Require ($ordered.Request([string[]]@('after-error','en','true'),[long]102)) 'The request after error was rejected.'
 $errorResult=$ordered.TryReceive()
 Require ($errorResult.Success -and $errorResult.Value.Sequence -eq 2 -and $errorResult.Value.IsError -and $errorResult.RequestStamp -eq 101) 'The unread source error was overwritten.'
 $afterError=Wait-Result $ordered
 Require ($afterError.Success -and $afterError.Value.Sequence -eq 3 -and $afterError.Value.Kind -ceq 'after-error' -and $afterError.RequestStamp -eq 102) 'The queued request did not follow the error result.'
 $orderedId=$ordered.OwnedProcessId
}finally{$ordered.Dispose()}
Wait-Exit $ordered -name 'ordered'
Wait-ProcessGone $orderedId

# Repeated pending refreshes coalesce along with their own revision; the
# completion must be paired with the request that actually ran.
$coalescedGates=New-TestGates
$coalesced=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,[string[]]@($coalescedGates.StartedName,$coalescedGates.ReleaseName))
try{
 Require ($coalesced.Request([string[]]@('block','ru','true'),[long]1)) 'The coalescing test request was rejected.'
 Require ($coalescedGates.Started.WaitOne(10000)) 'The coalescing test did not block its first read.'
 Require ($coalesced.Request([string[]]@('obsolete','ru','true'),[long]2)) 'The first pending revision was rejected.'
 Require ($coalesced.Request([string[]]@('latest','en','true'),[long]3)) 'The latest pending revision was rejected.'
 [void]$coalescedGates.Release.Set()
 $first=Wait-Result $coalesced
 $last=Wait-Result $coalesced
 Require ($first.Success -and $first.RequestStamp -eq 1 -and $first.Value.Sequence -eq 1 -and
  $last.Success -and $last.RequestStamp -eq 3 -and $last.Value.Sequence -eq 2 -and
  $last.Value.Kind -ceq 'latest') 'The coalesced result did not retain the revision of the executed request.'
 $coalescedId=$coalesced.OwnedProcessId
}finally{[void]$coalescedGates.Release.Set();$coalesced.Dispose()}
Wait-Exit $coalesced -name 'coalesced'
Wait-ProcessGone $coalescedId

# Exercise the ACL and PID check on the actual owner, with an unrelated process
# connecting before the intentionally delayed legitimate synthetic worker.
$delayName='Local\AITaskMonitorSyntheticDelay-'+[Diagnostics.Process]::GetCurrentProcess().Id
$delayGate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$delayName)
$rogueGates=New-TestGates
$delayedWorker=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\LocalReadDelayedWorker.ps1'))
$rogueScript=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures\LocalReadRogueClient.ps1'))
$rogueOwner=[AITaskMonitor.LocalReadOwner.Owner]::new($delayedWorker,[string[]]@($rogueGates.StartedName,$rogueGates.ReleaseName))
$rogue=$null
try {
 Require ($rogueOwner.Request([string[]]@('block','ru','true'))) 'The unauthorized-client test request was rejected.'
 $fields=[Reflection.BindingFlags]'Instance,NonPublic'
 $nameField=$rogueOwner.GetType().GetField('pipeName',$fields)
 $pipeField=$rogueOwner.GetType().GetField('pipe',$fields)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds -lt 5000 -and ($rogueOwner.OwnedProcessId -le 0 -or -not $nameField.GetValue($rogueOwner))){Start-Sleep -Milliseconds 10}
 $pipeName=[string]$nameField.GetValue($rogueOwner)
 $actualPipe=$pipeField.GetValue($rogueOwner)
 Require ($pipeName -and $null -ne $actualPipe) 'The actual owner did not start its synthetic pipe.'
 $rules=@($actualPipe.GetAccessControl().GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 $current=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $network=[Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::NetworkSid,$null).Value
 Require (@($rules|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -cne $current}).Count -eq 0 -and
  @($rules|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -ceq $current}).Count -eq 1 -and
  @($rules|Where-Object {$_.AccessControlType -eq 'Deny' -and $_.IdentityReference.Value -ceq $network}).Count -eq 1) 'The actual owner pipe ACL grants unexpected principals.'
 $exe=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe
 $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$rogueScript+'" -PipeName "'+$pipeName+'"'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $rogue=[Diagnostics.Process]::Start($start)
 $failure=Wait-Result $rogueOwner
 Require (-not $failure.Success -and -not $rogueGates.Started.WaitOne(0)) 'An unrelated synthetic client was accepted or received source configuration.'
 Require ($rogue.WaitForExit(5000) -and $rogue.ExitCode -eq 0 -and $rogue.StandardOutput.ReadToEnd().Trim() -ceq 'NO_DATA') 'The unrelated synthetic client was not cleanly rejected.'
 $delayedId=$rogueOwner.OwnedProcessId
}finally{
 $rogueOwner.Dispose();$delayGate.Dispose()
 if($null -ne $rogue){if(-not $rogue.HasExited){$rogue.Kill();[void]$rogue.WaitForExit(3000)};$rogue.Dispose()}
}
Wait-Exit $rogueOwner -name 'rogue'
Wait-ProcessGone $delayedId

# Fail closed when job assignment fails: the worker is not sent the synthetic
# source configuration and is killed without ever reaching the blocked read.
$rejectedGates=New-TestGates
$rejectedConfig=[string[]]@($rejectedGates.StartedName,$rejectedGates.ReleaseName)
$rejected=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$rejectedConfig,$true)
try{
 [void]$rejected.Request([string[]]@('block','ru','true'))
 $failed=Wait-Result $rejected
 Require (-not $failed.Success -and -not $rejectedGates.Started.WaitOne(0) -and
  $rejected.FailureStage -ceq 'verify-job' -and $rejected.FailureKind -ceq 'InvalidOperationException' -and
  $rejected.FailureHResult -ne 0) 'A worker read after a failed job assignment or its safe failure details were lost.'
}finally{$rejected.Dispose()}
Wait-Exit $rejected -name 'rejected'
if($rejected.OwnedProcessId -gt 0){Wait-ProcessGone $rejected.OwnedProcessId}

# Closing the owner while its already-assigned worker is suspended must return
# without running that worker and must eventually confirm process cleanup.
$suspendedGates=New-TestGates
$suspended=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,[string[]]@($suspendedGates.StartedName,$suspendedGates.ReleaseName),$false,$true)
try{
 Require ($suspended.Request([string[]]@('block','ru','true'))) 'The suspended test request was rejected.'
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not $suspended.IsBeforeResume -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require ($suspended.IsBeforeResume -and -not $suspendedGates.Started.WaitOne(0)) 'The synthetic owner did not pause before resuming its worker.'
 $suspendedId=$suspended.OwnedProcessId
 $suspended.Dispose()
 Require (-not $suspendedGates.Started.WaitOne(0)) 'The suspended synthetic worker executed during disposal.'
}finally{$suspended.Dispose()}
Wait-Exit $suspended -name 'suspended'
Wait-ProcessGone $suspendedId

# Race window close against creation and resource handoff. Every worker that
# actually starts must be gone before the owner can be replaced.
foreach($delay in @(0,1,2,5,10,20)){
 $raceGates=New-TestGates
 $racing=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,[string[]]@($raceGates.StartedName,$raceGates.ReleaseName))
 try{
  Require ($racing.Request([string[]]@('block','ru','true'))) 'A startup-race request was rejected.'
  if($delay -gt 0){Start-Sleep -Milliseconds $delay}
  $racing.Dispose()
 }finally{$racing.Dispose()}
 Wait-Exit $racing -name ('startup-race-'+$delay)
 if($racing.OwnedProcessId -gt 0){Wait-ProcessGone $racing.OwnedProcessId}
}

# Disposal is nonblocking even while the worker is stuck; the job releases only
# this worker, without requiring the synthetic source to unblock itself.
$closingGates=New-TestGates
$closingConfig=[string[]]@($closingGates.StartedName,$closingGates.ReleaseName)
$closing=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$closingConfig)
Require ($closing.Request([string[]]@('block','ru','true'))) 'The closing test request was rejected.'
Require ($closingGates.Started.WaitOne(10000)) 'The closing test did not start its blocked read.'
[LocalReadTestRelay]::Watchdog($closingGates.LocalRelease,8000)
$closingId=$closing.OwnedProcessId
$closing.Dispose()
Require (-not $closingGates.LocalRelease.IsSet -and $null -eq $closing.TryReceive()) 'Disposal waited for the blocked worker or exposed its data.'
Wait-Exit $closing -name 'closing'
Wait-ProcessGone $closingId

# Exercise host-process exit without calling Dispose while the worker is stuck
# and while the actual owner is paused after job verification but before Resume.
$exe=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=$exe
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($probeFlag in @('-ExitProbe','-PreResumeProbe')){
$start.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" '+$probeFlag
$probe=[Diagnostics.Process]::Start($start)
$probeWorkerId=0
try{
 if(-not $probe.WaitForExit(15000)){$probe.Kill();[void]$probe.WaitForExit(3000);throw 'The owner process remained alive during its blocked read.'}
 $probeOutput=$probe.StandardOutput.ReadToEnd()
 $match=[regex]::Match($probeOutput,'WORKER:(\d+)')
 if($probe.ExitCode -ne 0 -or -not $match.Success){throw 'The blocked-worker exit probe failed.'}
 $probeWorkerId=[int]$match.Groups[1].Value
 Wait-ProcessGone $probeWorkerId
}finally{
 if($probeWorkerId -gt 0){
  $entry=Get-CimInstance Win32_Process -Filter ('ProcessId='+$probeWorkerId) -ErrorAction SilentlyContinue
  if($null -ne $entry -and $entry.Name -ieq 'powershell.exe' -and $entry.CommandLine -like ('*'+$workerPath+'*') -and $entry.CommandLine -like ('*-ParentId '+$probe.Id+'*')){
   $remaining=Get-Process -Id $probeWorkerId -ErrorAction SilentlyContinue
   if($null -ne $remaining){$remaining.Kill()}
  }
 }
 $probe.Dispose()
}
}

Write-Output ('Local read owner: real dot handler and in-memory compact rendering while read blocked ({0} ms); coalescing, ordered terminal/error results, actual ACL and unauthorized PID, generation, language, disconnect, rejected job and owner exit before resume or while blocked passed on synthetic data.' -f $clickClock.ElapsedMilliseconds)
