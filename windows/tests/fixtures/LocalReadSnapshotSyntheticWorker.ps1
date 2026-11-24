param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SnapshotSyntheticServerIdentity {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\app'))
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
try{
 $pipe.Connect(5000)
 $server=[uint32]0
 if(-not [SnapshotSyntheticServerIdentity]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected synthetic server.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $initialized=$false;$lastEpoch=''
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid synthetic frame.'}
  $bytes=$reader.ReadBytes($length)
  if($bytes.Length -ne $length){throw 'Incomplete synthetic frame.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  if(-not $initialized){
   $fixture=[IO.Path]::GetFullPath([string]$message.Configuration[0])
   $temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
   if(-not $fixture.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or
      -not [IO.Path]::GetFileName($fixture).StartsWith('aitm-local-source-',[StringComparison]::Ordinal) -or
      -not [IO.File]::Exists((Join-Path $fixture '.synthetic-source'))){throw 'A synthetic source fixture is required.'}
   $source=Join-Path $appRoot 'CodexProgress.ps1'
   $tokens=$null;$errors=$null
   $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
   if($errors.Count){throw 'The monitor source did not parse.'}
   $names=@('Prop','Lock-State','Find-PriorLifecycle','Thread-State','Codex-Uncertain','Update-CodexRolloutPaths',
    'Confirm-CodexTerminal','Session-File','Session-Workspace','Progress-Files','Manual-Tasks','Read-TailText',
    'Codex-Plan','Codex-TurnStartIndex','Codex-ContainsIdentifier','Codex-CurrentToolActivity','Codex-FigmaCompleted',
    'Codex-FirstFigmaCompletion','Codex-Activity','Read-ObservedCodexTail','Codex-ObservedActivity','Plan-Progress',
    'Codex-IndexCandidates','Codex-SubagentMetadata','Codex-ReadSubagentMetadata','Codex-UnindexedCandidates',
    'Group-CodexTasks','Codex-Tasks','Claude-Tasks','Unconfirmed-Tasks','Local-SourceSnapshot')
   $definitions=foreach($name in $names){
    $nodes=@($ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw 'A synthetic source function was missing or ambiguous.'}
    $definition=$nodes[0].Extent.Text
    if($name -ceq 'Codex-IndexCandidates'){$definition=$definition.Replace('function Codex-IndexCandidates {','function Codex-IndexCandidates-Actual {')}
    $definition
   }
   $initializers=foreach($name in @('$script:sessionFiles','$script:sessionDates','$script:sessionDiscovery')){
    $nodes=@($ast.FindAll({param($item) $item -is [Management.Automation.Language.AssignmentStatementAst] -and $item.Left.Extent.Text -ceq $name},$true))
    if($nodes.Count -ne 1){throw 'A synthetic source initializer was missing or ambiguous.'}
    $nodes[0].Extent.Text
   }
   . ([scriptblock]::Create(($initializers -join [Environment]::NewLine)+[Environment]::NewLine+($definitions -join [Environment]::NewLine)))
   function Claude-ConnectionState {return $script:fixtureConnection}
   function Codex-IndexCandidates {
    if($script:fixtureShouldFail){throw 'Synthetic Codex read failure.'}
    if($script:fixtureShouldBlock){
     $started=[Threading.EventWaitHandle]::OpenExisting($script:fixtureStartName)
     $release=[Threading.EventWaitHandle]::OpenExisting($script:fixtureReleaseName)
     try{[void]$started.Set();[void]$release.WaitOne()}finally{$started.Dispose();$release.Dispose()}
     $script:fixtureShouldBlock=$false
    }
    return @(Codex-IndexCandidates-Actual)
   }
   $native=@($ast.FindAll({param($item) $item -is [Management.Automation.Language.StringConstantExpressionAst] -and $item.Value -like '*namespace AITaskMonitor.CodexTitles*'},$true))
   if($native.Count -ne 1){throw 'The synthetic Codex reader was missing or ambiguous.'}
   Add-Type -TypeDefinition $native[0].Value
   Add-Type -Path (Join-Path $appRoot 'CodexRecentEventObserver.cs')
   . (Join-Path $appRoot 'ClaudeReaderCore.ps1')
   $codexHome=Join-Path $fixture 'codex';$sessionIndex=Join-Path $codexHome 'session_index.jsonl'
   $sessionsDirectory=Join-Path $codexHome 'sessions';$lockDirectory=Join-Path $codexHome 'thread-writer-locks'
   $claudeEventPath=Join-Path $fixture 'claude-events.jsonl';$claudeLegacyEventPath=''
   $ProgressFile='';$ClaudeEventFile=''
   $script:sessionIndexLookup=@{};$script:planCache=@{};$script:planConfirmations=@{}
   $script:lifecycleState=@{};$script:observedCodex=@{};$script:monitorStartedUtc=[DateTime]::UtcNow.AddMinutes(-5)
   $script:lastCodexTasks=@();$script:lastClaudeTasks=@();$script:codexSourcePartial=$false
   $script:codexRolloutPaths=@{};$script:codexRolloutSnapshot=$null;$script:codexObservedStarts=@{};$script:codexTerminalChecks=@{}
   $script:codexTitleReader=[AITaskMonitor.CodexTitles.Reader]::new()
   $script:codexRolloutReader=[AITaskMonitor.CodexTitles.RolloutReader]::new()
   $script:codexRecentEventObserver=[AITaskMonitor.CodexObservation.CodexRecentEventObserver]::new($sessionsDirectory)
   $script:codexRootEvidenceReader=[AITaskMonitor.CodexObservation.CodexRootEvidenceReader]::new($codexHome)
   $script:fixtureStartName=[string]$message.Configuration[1];$script:fixtureReleaseName=[string]$message.Configuration[2]
   $initialized=$true
  }
  $request=$message.Request
  $epoch=[string]$request[1]
  if($lastEpoch -and $epoch -cne $lastEpoch -and $null -ne (Get-Variable -Scope Script -Name claudeReaderSession -ErrorAction SilentlyContinue) -and $null -ne $script:claudeReaderSession){
   $script:claudeReaderSession.MarkSourceLoss()
  }
  $lastEpoch=$epoch
  $script:resolvedLanguage=[string]$request[3]
  $script:fixtureConnection=[string]$request[2]
  $script:fixtureShouldBlock=[string]$request[0] -ceq 'block'
  $script:fixtureShouldFail=[string]$request[0] -ceq 'fail-codex'
  $result=Local-SourceSnapshot
  $xml=[Management.Automation.PSSerializer]::Serialize($result,24)
  $response=[Text.UTF8Encoding]::new($false,$true).GetBytes($xml)
  if($response.Length -le 0 -or $response.Length -gt 16777216){throw 'Invalid synthetic result.'}
  $writer.Write([int]$response.Length);$writer.Write($response);$writer.Flush()
 }
}finally{
 foreach($name in @('codexTitleReader','codexRolloutReader','codexRecentEventObserver','codexRootEvidenceReader')){
  $variable=Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
  if($null -ne $variable -and $null -ne $variable.Value){try{$variable.Value.Dispose()}catch{}}
 }
 $pipe.Dispose()
}
