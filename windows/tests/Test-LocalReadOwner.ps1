param([switch]$ExitProbe)
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
function Wait-Exit($owner,[int]$milliseconds=10000){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt $milliseconds){Start-Sleep -Milliseconds 10}
 Require $owner.HasExited 'The synthetic transport thread did not exit.'
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
if($ExitProbe){
 $probeGates=New-TestGates
 $probeConfig=[PSCustomObject]@{Started=$probeGates.StartedName;Release=$probeGates.ReleaseName}
 $probeOwner=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$probeConfig)
 Require ($probeOwner.Request([PSCustomObject]@{Kind='block';Language='ru';Connected=$true})) 'The exit probe request was rejected.'
 Require ($probeGates.Started.WaitOne(10000)) 'The exit probe did not enter its synthetic blocked read.'
 Write-Output ('WORKER:'+$probeOwner.OwnedProcessId)
 # Deliberately omit Dispose and leave the synthetic read blocked. The OS must
 # close the job handle when this owner process exits.
 return
}
$source=Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The production monitor source did not parse.'}
$definitions=foreach($name in @('Add-CompactDot','Sync-CompactDots')){
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
 if($null -eq $node){throw "Missing production function: $name"};$node.Extent.Text
}
. ([scriptblock]::Create(($definitions -join "`n")))
function Tr([string]$value){return $value}
function Brush([string]$value){return [Windows.Media.BrushConverter]::new().ConvertFromString($value)}
function Localized-TaskTitle($task,[switch]$BaseOnly){return [string]$task.Title}
# The click handler is production code. Rendering is stubbed so this test does
# not open a window or access real sources; visual layout is not established.
function Render-CompactTasks($tasks){$script:renderCount++;Sync-CompactDots $tasks}
$window=[PSCustomObject]@{Resources=@{CompactDotStyle=[Windows.Style]::new([Windows.Controls.Button])}}
$compactDotsPanel=[Windows.Controls.StackPanel]::new()
$script:palette=[PSCustomObject]@{Scroll='#888888'};$script:accentHex='#0066CC';$script:renderCount=0
$script:compactTaskId='first'
$script:lastAllTasks=@([PSCustomObject]@{Id='first';Title='First'},[PSCustomObject]@{Id='second';Title='Second'})
Sync-CompactDots $script:lastAllTasks

$gates=New-TestGates
[LocalReadTestRelay]::Relay($gates.LocalRelease,$gates.Release)
$config=[PSCustomObject]@{Started=$gates.StartedName;Release=$gates.ReleaseName}
$owner=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$config)
try{
 Require ($owner.Request([PSCustomObject]@{Kind='block';Language='ru';Connected=$true})) 'The first synthetic request was rejected.'
 Require ($gates.Started.WaitOne(10000)) 'The synthetic worker did not enter the blocked read.'
 [LocalReadTestRelay]::Watchdog($gates.LocalRelease,8000)
 $childId=$owner.OwnedProcessId
 Require ($childId -gt 0 -and $owner.IsPolling) 'The single worker is not polling.'
 foreach($index in 1..50){Require ($owner.Request([PSCustomObject]@{Kind='obsolete';Language='ru';Connected=$true})) 'A repeated refresh was rejected.'}
 Require ($owner.HasPendingRequest -and $owner.OwnedProcessId -eq $childId) 'Refresh requests started another worker.'

 $dot=@($compactDotsPanel.Children|Where-Object {[string]$_.Tag -ceq 'second'})[0]
 $dot.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 Require ($script:compactTaskId -ceq 'second' -and $script:renderCount -eq 1 -and -not $gates.LocalRelease.IsSet -and $null -eq $owner.TryReceive()) 'The production task-dot handler did not respond before the synthetic read was released.'

 $oldGeneration=$owner.Generation
 $owner.Invalidate()
 Require ($owner.Generation -ne $oldGeneration -and -not $owner.HasPendingRequest) 'Disconnect or language invalidation did not clear stale pending work.'
 Require ($owner.Request([PSCustomObject]@{Kind='latest';Language='en';Connected=$false})) 'The new generation was not accepted.'
 Require (-not $gates.LocalRelease.IsSet -and $null -eq $owner.TryReceive()) 'A stale result was published before the blocked read finished.'
 $gates.LocalRelease.Set()
 $result=Wait-Result $owner
 Require ($result.Success -and $result.Generation -eq $owner.Generation -and $result.Value.Sequence -eq 2 -and
  $result.Value.Kind -ceq 'latest' -and $result.Value.Language -ceq 'en' -and -not $result.Value.Connected) 'A stale, incorrectly localized or uncoalesced result was published.'
}finally{
 $gates.LocalRelease.Set()
 $owner.Dispose()
}
Wait-Exit $owner
Wait-ProcessGone $childId

# Fail closed when job assignment fails: the worker is not sent the synthetic
# source configuration and is killed without ever reaching the blocked read.
$rejectedGates=New-TestGates
$rejectedConfig=[PSCustomObject]@{Started=$rejectedGates.StartedName;Release=$rejectedGates.ReleaseName}
$rejected=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$rejectedConfig,$true)
try{
 [void]$rejected.Request([PSCustomObject]@{Kind='block';Language='ru';Connected=$true})
 $failed=Wait-Result $rejected
 Require (-not $failed.Success -and -not $rejectedGates.Started.WaitOne(0)) 'A worker read after a failed job assignment.'
}finally{$rejected.Dispose()}
Wait-Exit $rejected
if($rejected.OwnedProcessId -gt 0){Wait-ProcessGone $rejected.OwnedProcessId}

# Disposal is nonblocking even while the worker is stuck; the job releases only
# this worker, without requiring the synthetic source to unblock itself.
$closingGates=New-TestGates
$closingConfig=[PSCustomObject]@{Started=$closingGates.StartedName;Release=$closingGates.ReleaseName}
$closing=[AITaskMonitor.LocalReadOwner.Owner]::new($workerPath,$closingConfig)
Require ($closing.Request([PSCustomObject]@{Kind='block';Language='ru';Connected=$true})) 'The closing test request was rejected.'
Require ($closingGates.Started.WaitOne(10000)) 'The closing test did not start its blocked read.'
[LocalReadTestRelay]::Watchdog($closingGates.LocalRelease,8000)
$closingId=$closing.OwnedProcessId
$closing.Dispose()
Require (-not $closingGates.LocalRelease.IsSet -and $null -eq $closing.TryReceive()) 'Disposal waited for the blocked worker or exposed its data.'
Wait-Exit $closing
Wait-ProcessGone $closingId

# Exercise host-process exit without calling Dispose. The child must be killed
# by the job even when the owner process closes unexpectedly.
$exe=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=$exe
$start.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -ExitProbe'
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
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

Write-Output 'Local read owner: production dot handler with stub rendering, blocked read, coalescing, generation, language, disconnect, rejected job and nonblocking close passed on synthetic data.'
