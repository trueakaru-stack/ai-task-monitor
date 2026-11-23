$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$text=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $source))
$match=[regex]::Match($text,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if(-not $match.Success){throw 'The rollout reader source was not found.'}
Add-Type -TypeDefinition $match.Groups[1].Value -ErrorAction Stop
Add-Type -Path (Join-Path $PSScriptRoot '..\app\CodexRecentEventObserver.cs') -ErrorAction Stop
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public sealed class SyntheticRolloutDatabase : IDisposable {
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] p,out IntPtr d,int f,IntPtr v);
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_exec(IntPtr d,byte[] s,IntPtr cb,IntPtr a,IntPtr e);
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_close_v2(IntPtr d);
 private IntPtr db;
 private static byte[] Utf8(string value){return Encoding.UTF8.GetBytes(value+"\0");}
 public SyntheticRolloutDatabase(string path){
  if(sqlite3_open_v2(Utf8(path),out db,2|4|0x8000,IntPtr.Zero)!=0)throw new Exception("Synthetic database open failed.");
  Execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,history_mode TEXT,archived INTEGER);");
 }
 public void Execute(string sql){if(sqlite3_exec(db,Utf8(sql),IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0)throw new Exception("Synthetic database command failed.");}
 public void Dispose(){if(db!=IntPtr.Zero){sqlite3_close_v2(db);db=IntPtr.Zero;}}
}
'@
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Quote-Sql([string]$value){return "'"+$value.Replace("'","''")+"'"}
function Hash-File([string]$path){
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$hash=[Security.Cryptography.SHA256]::Create()
 try{return [Convert]::ToBase64String($hash.ComputeHash($stream))}finally{$hash.Dispose();$stream.Dispose()}
}
function Write-FixtureSession([string]$folder,[string]$id,[string]$suffix='',[int]$padding=0,[string]$owner=''){
 $path=Join-Path $folder ('rollout-2026-11-23T10-00-00-'+$id+$suffix+'.jsonl')
 if(-not $owner){$owner=$id}
 $metadata=@{type='session_meta';payload=@{id=$owner;synthetic_padding=('x'*$padding)}}|ConvertTo-Json -Compress -Depth 6
 [IO.File]::WriteAllText($path,($metadata+"`n"),[Text.UTF8Encoding]::new($false));return $path
}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-rollout-fixture-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic fixture root.'}
[void][IO.Directory]::CreateDirectory($root)
$database=$null;$reader=$null
try{
 $fixtureRoot=Join-Path $root 'profile';$folder=Join-Path $fixtureRoot 'sessions\2026\11\23'
 [void][IO.Directory]::CreateDirectory($folder)
 $firstId='10000000-0000-0000-0000-000000000001';$wrongId='10000000-0000-0000-0000-000000000002';$hugeId='10000000-0000-0000-0000-000000000003'
 $first=Write-FixtureSession $folder $firstId '_20000000-0000-0000-0000-000000000001' 70000
 $wrong=Write-FixtureSession $folder $wrongId '' 0 $firstId
 $huge=Write-FixtureSession $folder $hugeId '' 1048600
 $dbPath=Join-Path $fixtureRoot 'state_5.sqlite';$database=[SyntheticRolloutDatabase]::new($dbPath)
 foreach($row in @(@($firstId,('\\?\'+$first)),@($wrongId,$wrong),@($hugeId,$huge))){
  $database.Execute(('INSERT INTO threads VALUES('+(@((Quote-Sql $row[0]),(Quote-Sql $row[1]),"'paginated'",'0') -join ',')+');'))
 }
 Require ([IO.File]::Exists($dbPath+'-wal') -and [IO.File]::Exists($dbPath+'-shm')) 'Synthetic WAL sidecars are missing.'
 $dbHash=Hash-File $dbPath;$walHash=Hash-File ($dbPath+'-wal')
 $result=[AITaskMonitor.CodexTitles.RolloutReader]::ReadNow($fixtureRoot,[string[]]@($firstId,$wrongId,$hugeId))
 Require ($result.Success -and $result.Paths[$firstId] -ceq $first -and -not $result.Paths.ContainsKey($wrongId) -and -not $result.Paths.ContainsKey($hugeId)) 'Extended path, owner or bounded header validation failed.'
 Require ((Hash-File $dbPath) -ceq $dbHash -and (Hash-File ($dbPath+'-wal')) -ceq $walHash) 'The reader changed the fixture database or WAL.'
 $rootCases=@(
  @{source='cli';thread='user';root=$true},
  @{source='vscode';thread='agent_created_thread';root=$true},
  @{source='exec';thread='user';root=$true},
  @{source='mcp';thread='user';root=$true},
  @{source=$null;thread='user';root=$false},
  @{source='unknown';thread='user';root=$false},
  @{source=@{unexpected='value'};thread='user';root=$false},
  @{source='vscode';thread='subagent';root=$false},
  @{source='vscode';thread='unknown';root=$false},
  @{source='vscode';thread=$null;root=$false}
 )
 $rootIds=[Collections.Generic.List[string]]::new()
 for($case=0;$case -lt $rootCases.Count;$case++){
  $rootId='12000000-0000-0000-0000-{0:D12}' -f $case;$rootIds.Add($rootId)
  $rootPath=Write-FixtureSession $folder $rootId
  $rootPayload=@{id=$rootId}
  if($null -ne $rootCases[$case].source){$rootPayload.source=$rootCases[$case].source}
  if($null -ne $rootCases[$case].thread){$rootPayload.thread_source=$rootCases[$case].thread}
  $rootHeader=@{type='session_meta';payload=$rootPayload}|ConvertTo-Json -Compress -Depth 6
  [IO.File]::WriteAllText($rootPath,($rootHeader+"`n"),[Text.UTF8Encoding]::new($false))
  $database.Execute(('INSERT INTO threads VALUES('+(@((Quote-Sql $rootId),(Quote-Sql $rootPath),"'paginated'",'0') -join ',')+');'))
 }
 $rootResult=[AITaskMonitor.CodexTitles.RolloutReader]::ReadNow($fixtureRoot,$rootIds.ToArray())
 for($case=0;$case -lt $rootCases.Count;$case++){
  $rootId=$rootIds[$case];$rootRef=$rootResult.ParentReferences[$rootId]
  Require ($rootResult.Paths.ContainsKey($rootId) -and $null -ne $rootRef -and [bool]$rootRef.IsRoot -eq [bool]$rootCases[$case].root -and [bool]$rootRef.Conflict -ne [bool]$rootCases[$case].root) 'Root-source classification was not conservative.'
 }
 $childId='10000000-0000-0000-0000-000000000004';$badChild='10000000-0000-0000-0000-000000000005';$partialChild='10000000-0000-0000-0000-000000000006'
 $child=Write-FixtureSession $folder $childId;$bad=Write-FixtureSession $folder $badChild;$partial=Write-FixtureSession $folder $partialChild
 $spawn=@{parent_thread_id=$firstId;agent_nickname='reader';agent_path='/root/reader'}
 $childMetadata=@{type='session_meta';payload=@{id=$childId;thread_source='subagent';parent_thread_id=$firstId;agent_nickname='reader';agent_path='/root/reader';source=@{subagent=@{thread_spawn=$spawn}}}}|ConvertTo-Json -Compress -Depth 8
 [IO.File]::WriteAllText($child,($childMetadata+"`n"),[Text.UTF8Encoding]::new($false))
 $capture=[AITaskMonitor.CodexTitles.RolloutReader].GetMethod('CaptureParentIdentity',[Reflection.BindingFlags]'Static,NonPublic')
 $oldBytes=[Text.UTF8Encoding]::new($false).GetBytes($childMetadata)
 $captureArgs=[object[]]::new(3);$captureArgs[0]=[string]$child;$captureArgs[1]=[string]$childId;$captureArgs[2]=[byte[]]$oldBytes
 $originalToken=[string]$capture.Invoke($null,$captureArgs)
 Require ([bool]$originalToken -and $originalToken -ceq [AITaskMonitor.CodexObservation.CodexRecentEventObserver]::CaptureHeaderIdentity($child,$childId)) 'A matching header did not establish identity.'
 $swappedMetadata=@{type='session_meta';payload=@{id=$childId;thread_source='subagent';parent_thread_id=$wrongId;agent_nickname='reader';agent_path='/root/reader';source=@{subagent=@{thread_spawn=@{parent_thread_id=$wrongId;agent_nickname='reader';agent_path='/root/reader'}}}}}|ConvertTo-Json -Compress -Depth 8
 $swap=Join-Path $folder 'synthetic-replacement.tmp'
 [IO.File]::WriteAllText($swap,($swappedMetadata+"`n"),[Text.UTF8Encoding]::new($false))
 [IO.File]::Delete($child);[IO.File]::Move($swap,$child)
 $swappedToken=[string]$capture.Invoke($null,$captureArgs)
 Require (-not $swappedToken -and [bool][AITaskMonitor.CodexObservation.CodexRecentEventObserver]::CaptureHeaderIdentity($child,$childId)) 'A header from one file was paired with another file identity.'
 [IO.File]::WriteAllText($child,($childMetadata+"`n"),[Text.UTF8Encoding]::new($false))
 $badMetadata=@{type='session_meta';payload=@{id=$badChild;parent_thread_id=$firstId;agent_nickname='reader';agent_path='/root/reader';source=@{subagent=@{thread_spawn=@{parent_thread_id=$wrongId;agent_nickname='reader';agent_path='/root/reader'}}}}}|ConvertTo-Json -Compress -Depth 8
 [IO.File]::WriteAllText($bad,($badMetadata+"`n"),[Text.UTF8Encoding]::new($false))
 $partialMetadata=@{type='session_meta';payload=@{id=$partialChild;source=@{subagent=@{}}}}|ConvertTo-Json -Compress -Depth 8
 [IO.File]::WriteAllText($partial,($partialMetadata+"`n"),[Text.UTF8Encoding]::new($false))
 foreach($row in @(@($childId,$child),@($badChild,$bad),@($partialChild,$partial))){$database.Execute(('INSERT INTO threads VALUES('+(@((Quote-Sql $row[0]),(Quote-Sql $row[1]),"'paginated'",'0') -join ',')+');'))}
 $links=[AITaskMonitor.CodexTitles.RolloutReader]::ReadNow($fixtureRoot,[string[]]@($childId,$badChild,$partialChild))
 Require ($links.Success -and $links.Paths.ContainsKey($childId) -and $links.ParentReferences[$childId].ParentThreadId -ceq $firstId -and
 -not $links.ParentReferences[$childId].Conflict -and $links.Paths.ContainsKey($badChild) -and $links.ParentReferences[$badChild].Conflict -and
 $links.ParentReferences[$partialChild].Conflict) 'Verified parent metadata or conflicting metadata was misclassified.'
 $duplicateIds=New-Object 'Collections.Generic.List[string]'
 foreach($field in @('id','parent_thread_id','agent_nickname','agent_path','nested_parent','nested_nickname','nested_path')){
  $duplicateId='11000000-0000-0000-0000-{0:D12}' -f $duplicateIds.Count;$duplicateIds.Add($duplicateId)
  $duplicatePath=Write-FixtureSession $folder $duplicateId
  $header='{"type":"session_meta","payload":{"id":"'+$duplicateId+'","parent_thread_id":"'+$firstId+'","agent_nickname":"reader","agent_path":"/root/reader","source":{"subagent":{"thread_spawn":{"parent_thread_id":"'+$firstId+'","agent_nickname":"reader","agent_path":"/root/reader"}}}}}'
  $key=switch($field){'nested_parent'{'parent_thread_id'} 'nested_nickname'{'agent_nickname'} 'nested_path'{'agent_path'} default{$field}}
  $actual=if($key -eq 'id'){$duplicateId}elseif($key -eq 'parent_thread_id'){$firstId}elseif($key -eq 'agent_nickname'){'reader'}else{'/root/reader'}
  $other=if($key -in @('id','parent_thread_id')){$wrongId}elseif($key -eq 'agent_nickname'){'other'}else{'/root/other'}
  $needle='"'+$key+'":"'+$actual+'"';$position=if($field.StartsWith('nested_')){$header.LastIndexOf($needle)}else{$header.IndexOf($needle)}
  if($position -lt 0){throw 'Synthetic duplicate field was not located.'}
  $replacement='"'+$key+'":"'+$other+'",'+$needle
  $header=$header.Substring(0,$position)+$replacement+$header.Substring($position+$needle.Length)
  [IO.File]::WriteAllText($duplicatePath,($header+"`n"),[Text.UTF8Encoding]::new($false))
  $database.Execute(('INSERT INTO threads VALUES('+(@((Quote-Sql $duplicateId),(Quote-Sql $duplicatePath),"'paginated'",'0') -join ',')+');'))
 }
 $duplicates=[AITaskMonitor.CodexTitles.RolloutReader]::ReadNow($fixtureRoot,$duplicateIds.ToArray())
 foreach($duplicateId in $duplicateIds){Require ($duplicates.Paths.ContainsKey($duplicateId) -and $duplicates.ParentReferences[$duplicateId].Conflict) 'A duplicate identity field was trusted for grouping or hid the separate session.'}
 $metaReader=[AITaskMonitor.CodexTitles.RolloutReader]::new();$metaWatch=[Diagnostics.Stopwatch]::StartNew()
 try{
  do{$meta=$metaReader.Snapshot($fixtureRoot,[string[]]@($childId,$badChild));if($meta.ParentReferences.Count -eq 2){break};Start-Sleep -Milliseconds 25}while($metaWatch.ElapsedMilliseconds -lt 10000)
  Require ($meta.ParentReferences[$childId].ParentThreadId -ceq $firstId -and $meta.ParentReferences[$badChild].Conflict) 'The background reader did not publish verified parent links.'
 }finally{$metaReader.Dispose()}
 $normalizer=[AITaskMonitor.CodexTitles.RolloutReader].GetMethod('NormalizeLocal',[Reflection.BindingFlags]'Static,NonPublic')
 $rejected=$false;try{$null=$normalizer.Invoke($null,@('\\?\UNC\server\share\session'))}catch{$rejected=$true}
 Require $rejected 'An extended UNC path was accepted.'
 $missing=[AITaskMonitor.CodexTitles.RolloutReader]::ReadNow((Join-Path $root 'missing'),[string[]]@($firstId))
 Require (-not $missing.Success -and $missing.Paths.Count -eq 0) 'A missing database did not use the fallback.'

 # A delayed result for an old revision must not establish a current path.
 $reader=[AITaskMonitor.CodexTitles.RolloutReader]::new()
 $private=[Reflection.BindingFlags]'Instance,NonPublic';$readerType=$reader.GetType()
 $never=[Threading.Tasks.TaskCompletionSource[AITaskMonitor.CodexTitles.RolloutSnapshot]]::new()
 $oldRequest=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase);$oldRequest[$firstId]='old'
 $readerType.GetField('home',$private).SetValue($reader,$fixtureRoot)
 $readerType.GetField('pendingHome',$private).SetValue($reader,$fixtureRoot)
 $readerType.GetField('pendingIds',$private).SetValue($reader,$oldRequest)
 $readerType.GetField('pending',$private).SetValue($reader,$never.Task)
 $readerType.GetField('pendingStarted',$private).SetValue($reader,[Diagnostics.Stopwatch]::GetTimestamp())
 $watch=[Diagnostics.Stopwatch]::StartNew();$null=$reader.Snapshot($fixtureRoot,[string[]]@($firstId),[string[]]@('new'))
 Require ($watch.ElapsedMilliseconds -lt 300) 'A pending worker blocked the caller.'
 $stale=[AITaskMonitor.CodexTitles.RolloutSnapshot]::new();$stale.Success=$true;$stale.Paths[$firstId]='C:\synthetic\stale.jsonl';$stale.StartedTicks=[Diagnostics.Stopwatch]::GetTimestamp()
 $never.SetResult($stale)
 $value=$reader.Snapshot($fixtureRoot,[string[]]@($firstId),[string[]]@('new'))
 Require (-not $value.Paths.ContainsKey($firstId)) 'An old revision was accepted.'
 $watch.Restart()
 do{$value=$reader.Snapshot($fixtureRoot,[string[]]@($firstId),[string[]]@('new'));if($value.Paths.ContainsKey($firstId)){break};Start-Sleep -Milliseconds 25}while($watch.ElapsedMilliseconds -lt 10000)
 Require ($value.Paths[$firstId] -ceq $first) 'The new revision was not eventually resolved.'
 $reader.Dispose();$reader=$null

 # More than 256 IDs must progress even as an unrelated page changes at the real two-second poll interval.
 $ids=New-Object 'Collections.Generic.List[string]'
 for($i=0;$i -lt 256;$i++){
  $id='30000000-0000-0000-0000-{0:D12}' -f $i;$ids.Add($id)
  $database.Execute(('INSERT INTO threads VALUES('+(@((Quote-Sql $id),(Quote-Sql $wrong),"'paginated'",'1') -join ',')+');'))
 }
 $lastId='39999999-0000-0000-0000-999999999999';$ids.Add($lastId)
 $last=Write-FixtureSession $folder $lastId
 $database.Execute(('INSERT INTO threads VALUES('+(@((Quote-Sql $lastId),(Quote-Sql $last),"'paginated'",'0') -join ',')+');'))
 $reader=[AITaskMonitor.CodexTitles.RolloutReader]::new();$watch.Restart();$iteration=0
 do{
  $current=[string[]]@($ids.ToArray()+$(if(($iteration%4) -ge 2){@('49999999-0000-0000-0000-999999999999')}else{@()}))
  $revisions=[string[]]@($current|ForEach-Object {'revision'})
  $value=$reader.Snapshot($fixtureRoot,$current,$revisions)
  if($value.Paths.ContainsKey($lastId)){break}
  $iteration++;Start-Sleep -Milliseconds 2000
 }while($watch.ElapsedMilliseconds -lt 25000)
 Require ($value.Paths.ContainsKey($lastId) -and $value.Paths[$lastId] -ceq $last) 'A later ID starved when the candidate page changed.'
 Write-Output 'Codex rollout reader: SQLite/WAL, Windows paths, owner validation, changed revisions and fair 257-ID scheduling verified.'
}finally{
 if($null -ne $reader){$reader.Dispose()}
 if($null -ne $database){$database.Dispose()}
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path;$attributes=[IO.File]::GetAttributes($resolved)
  if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or ($attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe fixture cleanup.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
