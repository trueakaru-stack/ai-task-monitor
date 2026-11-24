$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$priorProfile=[Environment]::GetEnvironmentVariable('USERPROFILE','Process')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName PresentationFramework
$retentionSource=[IO.File]::ReadAllText((Join-Path $app 'ClaudeRetention.cs'))
$productionMutex='"Local\\CodexTasksClaudeEvents"'
$syntheticMutex='"Local\\AITM.Test.Retention.Gate.'+[Guid]::NewGuid().ToString('N')+'"'
if([regex]::Matches($retentionSource,[regex]::Escape($productionMutex)).Count -ne 1){throw 'The synthetic retention mutex could not be isolated.'}
Add-Type -TypeDefinition ($retentionSource.Replace($productionMutex,$syntheticMutex)) -ReferencedAssemblies System.Web.Extensions
Add-Type -TypeDefinition @'
using System;
using System.Linq;
using System.Reflection;
using System.Threading;
public static class SyntheticRetentionCommit {
 static readonly Type Target=AppDomain.CurrentDomain.GetAssemblies().Select(a=>a.GetType("AITaskMonitor.Claude.Retention")).First(t=>t!=null);
 static readonly MethodInfo Commit=Target.GetMethod("Commit",BindingFlags.NonPublic|BindingFlags.Static);
 static readonly FieldInfo Generation=Target.GetField("generation",BindingFlags.NonPublic|BindingFlags.Static);
 static readonly FieldInfo Worker=Target.GetField("worker",BindingFlags.NonPublic|BindingFlags.Static);
 public static Exception Failure;
 public static bool SecondCancelled,SecondCommitted;
 public static int CurrentGeneration { get { return (int)Generation.GetValue(null); } }
 public static bool WorkerStarted { get { return Worker.GetValue(null)!=null; } }
 public static Thread Hold(int expected,ManualResetEvent entered,ManualResetEvent release) {
  var thread=new Thread(()=>{
   try {
    Commit.Invoke(null,new object[]{expected,new Action(()=>{entered.Set();release.WaitOne();})});
    try { Commit.Invoke(null,new object[]{expected,new Action(()=>{SecondCommitted=true;})}); }
    catch(TargetInvocationException error) { if(error.InnerException is OperationCanceledException)SecondCancelled=true;else throw; }
   }
   catch(Exception error) { Failure=error; }
  });
  thread.IsBackground=true;thread.Start();return thread;
 }
 public static string CommitAt(int expected) {
  bool ran=false;
  try { Commit.Invoke(null,new object[]{expected,new Action(()=>{ran=true;})}); }
  catch(TargetInvocationException error) { if(error.InnerException is OperationCanceledException)return "cancelled";throw; }
  return ran?"ran":"not-run";
 }
}
'@
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The synthetic retention UI functions could not be parsed.'}
$definitions=foreach($name in @('Save-DisplayPreference','Load-ClaudeRetentionSettings','Save-ClaudeRetentionPreference','New-JournalComboItem','Update-JournalComboHint','Update-ClaudeRetentionSettings','Schedule-ClaudeRetention','Save-ClaudeRetentionControls')){
 $node=$ast.Find({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name},$true)
 if($null -eq $node){throw ('Missing production retention function: '+$name)};$node.Extent.Text
}
. ([scriptblock]::Create(($definitions -join [Environment]::NewLine)))
function Tr([string]$text){return $text}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-retention-gate-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic retention directory.'
if([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)){throw 'The synthetic retention directory already exists.'}
[void][IO.Directory]::CreateDirectory($root)
$entered=[Threading.ManualResetEvent]::new($false);$release=[Threading.ManualResetEvent]::new($false);$thread=$null
try{
 if(([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'The synthetic retention root is linked.'}
 $profile=[IO.Path]::GetFullPath((Join-Path $root 'profile'));$backup=[IO.Path]::GetFullPath((Join-Path $profile '.claude'))
 $rootPrefix=$root.TrimEnd('\')+'\'
 if(-not $profile.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or
    -not $backup.StartsWith(($profile.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic retention profile.'}
 [void][IO.Directory]::CreateDirectory($backup)
 foreach($path in @($profile,$backup)){if(([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A synthetic retention directory is linked.'}}
 [Environment]::SetEnvironmentVariable('USERPROFILE',$profile,'Process')
 if([IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude')) -cne $backup){throw 'The synthetic retention backup path was not selected.'}
 $dataDirectory=Join-Path $root 'data';[void][IO.Directory]::CreateDirectory($dataDirectory)
 $script:settingsPath=Join-Path $root 'settings.json'
 [IO.File]::WriteAllText($script:settingsPath,'{"claudeRetentionDays":7,"claudeMaximumMB":10}',[Text.UTF8Encoding]::new($false))
 $script:claudeRetentionAvailable=$true;$script:retentionPolicyInvalidated=$false;$script:nextClaudeRetention=[DateTime]::MinValue
 $script:updatingClaudeRetentionControls=$false;$script:claudeRetentionUiError='';$script:resolvedLanguage='ru'
 $claudeRetentionDaysCombo=[Windows.Controls.ComboBox]::new();$claudeRetentionSizeCombo=[Windows.Controls.ComboBox]::new();$claudeRetentionError=[Windows.Controls.TextBlock]::new()
 Update-ClaudeRetentionSettings
 $PreviewActiveTasks=-1;$SnapshotFile=''
 $originalGeneration=[SyntheticRetentionCommit]::CurrentGeneration
 $thread=[SyntheticRetentionCommit]::Hold($originalGeneration,$entered,$release)
 Require ($entered.WaitOne(5000)) 'The synthetic production commit did not hold the gate.'
 $clock=[Diagnostics.Stopwatch]::StartNew();Schedule-ClaudeRetention;$status=[AITaskMonitor.Claude.Retention]::Status;$clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 1000 -and $status -ceq 'busy' -and $script:nextClaudeRetention -gt [DateTime]::UtcNow) 'The real timer waited for a blocked retention commit or did not schedule a retry.'
 [IO.File]::WriteAllText($script:settingsPath,'{bad',[Text.UTF8Encoding]::new($false))
 $clock.Restart();Schedule-ClaudeRetention;$clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 1000 -and -not $script:retentionPolicyInvalidated -and
  [SyntheticRetentionCommit]::CurrentGeneration -ne $originalGeneration) 'The real timer waited or did not immediately invalidate later commits while the gate was held.'
 [IO.File]::WriteAllText($script:settingsPath,'{"claudeRetentionDays":7,"claudeMaximumMB":10}',[Text.UTF8Encoding]::new($false))
 $claudeRetentionDaysCombo.SelectedIndex=19;$combo=$claudeRetentionDaysCombo
 $expectedError=-join @([int[]]@(1053,1077,32,1091,1076,1072,1083,1086,1089,1100,32,1089,1086,1093,1088,1072,1085,1080,1090,1100,32,1085,1072,1089,1090,1088,1086,1081,1082,1080,32,1093,1088,1072,1085,1077,1085,1080,1103,32,67,108,97,117,100,101,32,67,111,100,101)|ForEach-Object {[char]$_})
 $clock.Restart();Save-ClaudeRetentionControls 'claudeRetentionDays' $combo;$clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 1000 -and (Load-ClaudeRetentionSettings).Days -eq 7 -and
  $script:claudeRetentionUiError -ceq $expectedError -and $claudeRetentionError.Text -ceq $expectedError -and
  $claudeRetentionError.Visibility -eq 'Visible' -and [int]$combo.SelectedItem.Tag -eq 7) 'A new policy was saved, falsely confirmed or not restored during an old commit.'
 [void]$release.Set();Require ($thread.Join(5000) -and $null -eq [SyntheticRetentionCommit]::Failure -and
  [SyntheticRetentionCommit]::SecondCancelled -and -not [SyntheticRetentionCommit]::SecondCommitted) 'A second old-policy commit ran after the invalid policy was observed.'
 $events=Join-Path $dataDirectory 'claude-events-v2.jsonl';$now=[DateTime]::UtcNow
 $old=@{timestamp=$now.AddDays(-25).ToString('o');session_id='synthetic-old25';event='PreToolUse';active=$true}|ConvertTo-Json -Compress
 $withinNew=@{timestamp=$now.AddDays(-10).ToString('o');session_id='synthetic-within20';event='PreToolUse';active=$true}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText($events,($old+[Environment]::NewLine+$withinNew+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
 $combo.SelectedIndex=19;Save-ClaudeRetentionControls 'claudeRetentionDays' $combo
 Require ((Load-ClaudeRetentionSettings).Days -eq 20 -and -not $script:claudeRetentionUiError -and
  [int]$combo.SelectedItem.Tag -eq 20 -and $claudeRetentionError.Visibility -eq 'Collapsed' -and
  [SyntheticRetentionCommit]::CurrentGeneration -ne $originalGeneration -and
  [SyntheticRetentionCommit]::CommitAt($originalGeneration) -ceq 'cancelled' -and [SyntheticRetentionCommit]::WorkerStarted) 'The new policy did not cancel and reschedule the previous retention generation.'
 $clock.Restart();do{$status=[AITaskMonitor.Claude.Retention]::Status;if($status -cne 'busy'){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 $written=[IO.File]::ReadAllText($events)
 Require ($status -ceq 'ok' -and -not $written.Contains('synthetic-old25') -and $written.Contains('synthetic-within20')) 'The rescheduled worker did not apply the new synthetic retention policy.'
 Write-Output 'Production Claude retention: blocked commit, nonblocking timer and policy change cancellation verified.'
}finally{
 try{
  [void]$release.Set();if($null -ne $thread){[void]$thread.Join(5000)};[AITaskMonitor.Claude.Retention]::WaitForStop(5000);$entered.Dispose();$release.Dispose()
  if([AITaskMonitor.Claude.Retention]::Status -ceq 'busy'){throw 'The synthetic retention worker has not stopped.'}
  $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
  if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic retention cleanup.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }finally{
  [Environment]::SetEnvironmentVariable('USERPROFILE',$priorProfile,'Process')
  if(-not [string]::Equals($priorProfile,[Environment]::GetEnvironmentVariable('USERPROFILE','Process'),[StringComparison]::Ordinal)){throw 'The process profile was not restored.'}
  if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
 }
}
