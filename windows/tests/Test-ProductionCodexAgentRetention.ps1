$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public sealed class SyntheticRetentionDatabase : IDisposable {
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] p,out IntPtr d,int f,IntPtr v);
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_exec(IntPtr d,byte[] s,IntPtr cb,IntPtr a,IntPtr e);
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_close_v2(IntPtr d);
 private IntPtr db;
 private static byte[] Utf8(string value){return Encoding.UTF8.GetBytes(value+"\0");}
 public SyntheticRetentionDatabase(string path){
  if(sqlite3_open_v2(Utf8(path),out db,2|4|0x8000,IntPtr.Zero)!=0)throw new Exception("Synthetic database open failed.");
  Execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE threads(id TEXT PRIMARY KEY,name TEXT,title TEXT,rollout_path TEXT,history_mode TEXT,archived INTEGER);");
 }
 public void Execute(string sql){if(sqlite3_exec(db,Utf8(sql),IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0)throw new Exception("Synthetic database command failed.");}
 public void Dispose(){if(db!=IntPtr.Zero){sqlite3_close_v2(db);db=IntPtr.Zero;}}
}
'@
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Quote-Sql([string]$value){return "'"+$value.Replace("'","''")+"'"}
function Poll($owner,[string]$epoch){
 Require ($owner.Request([string[]]@('poll',$epoch,'true','en'))) 'The synthetic production poll was rejected.'
 $deadline=[Diagnostics.Stopwatch]::StartNew()
 while($deadline.ElapsedMilliseconds -lt 20000){$result=$owner.TryReceive();if($null -ne $result){Require $result.Success 'The synthetic production worker failed.';return $result.Value};Start-Sleep -Milliseconds 10}
 throw 'The synthetic production worker did not respond.'
}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-retention-worker-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic fixture directory.'
[void][IO.Directory]::CreateDirectory($root)
$owner=$null;$database=$null
try{
 $app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'));$codex=Join-Path $root 'codex';$profile=Join-Path $root 'profile';$data=Join-Path $root 'data'
 $now=[DateTime]::Now;$utc=[DateTime]::UtcNow;$dated=Join-Path (Join-Path (Join-Path (Join-Path $codex 'sessions') $now.ToString('yyyy')) $now.ToString('MM')) $now.ToString('dd')
 $locks=Join-Path $codex 'thread-writer-locks';[void][IO.Directory]::CreateDirectory($dated);[void][IO.Directory]::CreateDirectory($locks);[void][IO.Directory]::CreateDirectory($profile);[void][IO.Directory]::CreateDirectory($data)
 $parentId='50000000-0000-0000-0000-000000000001';$childId='50000000-0000-0000-0000-000000000002'
 $parentPath=Join-Path $dated ('rollout-'+$now.ToString('yyyy-MM-ddTHH-mm-ss')+'-'+$parentId+'.jsonl')
 $childPath=Join-Path $dated ('rollout-'+$now.ToString('yyyy-MM-ddTHH-mm-ss')+'-'+$childId+'.jsonl')
 $parentMeta=@{type='session_meta';payload=@{id=$parentId;source='cli';thread_source='user';cwd=$root}}|ConvertTo-Json -Depth 10 -Compress
 $spawn=@{parent_thread_id=$parentId;agent_nickname='reader';agent_path='/root/reader'}
 $childMeta=@{type='session_meta';payload=@{id=$childId;thread_source='subagent';parent_thread_id=$parentId;agent_nickname='reader';agent_path='/root/reader';source=@{subagent=@{thread_spawn=$spawn}}}}|ConvertTo-Json -Depth 10 -Compress
 $parentStart=@{type='event_msg';timestamp=$utc.ToString('o');payload=@{type='task_started';turn_id='parent-turn'}}|ConvertTo-Json -Depth 6 -Compress
 $childStart=@{type='event_msg';timestamp=$utc.ToString('o');payload=@{type='task_started';turn_id='child-turn'}}|ConvertTo-Json -Depth 6 -Compress
 $utf8=[Text.UTF8Encoding]::new($false)
 [IO.File]::WriteAllText($parentPath,($parentMeta+"`n"+$parentStart+"`n"),$utf8);[IO.File]::WriteAllText($childPath,($childMeta+"`n"+$childStart+"`n"),$utf8)
 $parentIndex=@{id=$parentId;thread_name='Synthetic parent';updated_at=$now.ToString('o')}|ConvertTo-Json -Compress
 $childIndex=@{id=$childId;thread_name='Synthetic child';updated_at=$now.ToString('o')}|ConvertTo-Json -Compress
 $index=Join-Path $codex 'session_index.jsonl';[IO.File]::WriteAllText($index,($parentIndex+"`n"+$childIndex+"`n"),$utf8)
 foreach($id in @($parentId,$childId)){[IO.File]::WriteAllText((Join-Path $locks ($id+'.lock')),'',$utf8)}
 $database=[SyntheticRetentionDatabase]::new((Join-Path $codex 'state_5.sqlite'))
 foreach($row in @(@($parentId,'Synthetic parent',$parentPath),@($childId,'Synthetic child',$childPath))){
  $values=@((Quote-Sql $row[0]),(Quote-Sql $row[1]),"''",(Quote-Sql $row[2]),"'paginated'",'0') -join ','
  $database.Execute('INSERT INTO threads VALUES('+$values+');')
 }
 $config=[string[]]@('AITM-LOCAL-SOURCE-1',$codex,$profile,$data,'','',$utc.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $app 'LocalSourceWorker.ps1'),$config);$epoch=[Guid]::NewGuid().ToString('N')
 $deadline=[Diagnostics.Stopwatch]::StartNew();$parent=$null
 do{
  $snapshot=Poll $owner $epoch
  $parents=@($snapshot.Codex|Where-Object {[string]$_.Id -ceq $parentId -and $null -ne $_.PSObject.Properties['RelatedAgentCount'] -and $_.RelatedAgentCount -eq 1})
  if($parents.Count){$parent=$parents[0];break}
  Start-Sleep -Milliseconds 150
 }while($deadline.ElapsedMilliseconds -lt 15000)
 if($null -eq $parent){
  . (Join-Path $app 'LocalSourceCore.ps1')
  Initialize-LocalSourceReader -CodexHome $codex -ProfileRoot $profile -DataDirectory $data -MonitorStartedUtc ($utc.AddMinutes(-1))
  $script:resolvedLanguage='en'
  foreach($pass in 1..20){[void](Local-SourceSnapshot);Start-Sleep -Milliseconds 100}
  try{
   $evidence=Update-CodexAgentRetention -State $script:codexAgentRetention -Tasks @($script:lastCodexTasks) -Links $script:codexGroupLinks -SourcePartial $true
   $details=@($script:codexGroupLinks.Keys|ForEach-Object{$ref=$script:codexGroupLinks[$_];([string]$_)+' root='+[bool](Prop $ref 'IsRoot' $false)+' conflict='+[bool](Prop $ref 'Conflict' $false)+' identity='+[bool](Prop $ref 'IdentityToken' '')}) -join '; '
   Write-Output ('Synthetic-only evidence: links='+$details+'; groups='+@($evidence.Groups).Count+'; raw='+@($script:lastCodexTasks).Count)
  }catch{Write-Output ('Synthetic-only retention error: '+$_.Exception.Message)}
 }
 $syntheticSummary=@($snapshot.Codex|ForEach-Object {([string]$_.Id)+' identity='+[bool]$_.ActivityIdentity+' agents='+$(if($null -ne $_.PSObject.Properties['RelatedAgentCount']){[string]$_.RelatedAgentCount}else{'missing'})}) -join '; '
 Require ($null -ne $parent -and [string]$parent.ActivityIdentity -and @($parent.RelatedAgents).Count -eq 1 -and
  [string]$parent.RelatedAgents[0].ActivityIdentity -and $parent.RelatedAgentCountUnconfirmed -and @($parent.RelatedAgentIds) -ccontains $childId) ('Verified synthetic rollout identities and links did not reach the production worker count: '+$syntheticSummary+'; errors='+(@($snapshot.Unavailable)-join ','))
 $complete=@{type='event_msg';timestamp=[DateTime]::UtcNow.ToString('o');payload=@{type='task_complete';turn_id='child-turn'}}|ConvertTo-Json -Depth 6 -Compress
 [IO.File]::AppendAllText($childPath,($complete+"`n"),$utf8)
 $deadline.Restart();$afterTurn=$null
 do{
  $snapshot=Poll $owner $epoch
  $parents=@($snapshot.Codex|Where-Object {[string]$_.Id -ceq $parentId -and $null -ne $_.PSObject.Properties['RelatedAgentCount']})
  if($parents.Count -and $parents[0].RelatedAgentsUnconfirmed){$afterTurn=$parents[0];break}
  Start-Sleep -Milliseconds 150
 }while($deadline.ElapsedMilliseconds -lt 15000)
 Require ($null -ne $afterTurn -and $afterTurn.RelatedAgentCount -eq 1 -and @($afterTurn.RelatedAgentIds) -ccontains $childId -and
  -not $afterTurn.RelatedAgents[0].Active) 'A finished synthetic turn removed or falsely confirmed the related agent.'
 # Remove the child only from the disposable synthetic profile. The parent and
 # its previously verified relation remain visible with uncertain status.
 [IO.File]::WriteAllText($index,($parentIndex+"`n"),$utf8)
 $database.Execute('DELETE FROM threads WHERE id='+(Quote-Sql $childId)+';')
 [IO.File]::Move($childPath,(Join-Path $root 'hidden-synthetic-child.txt'))
 $deadline.Restart();$afterLoss=$null
 do{
  $snapshot=Poll $owner $epoch
  $parents=@($snapshot.Codex|Where-Object {[string]$_.Id -ceq $parentId -and $null -ne $_.PSObject.Properties['RelatedAgentCount']})
  if($parents.Count -and $parents[0].RelatedAgentCount -eq 1 -and $parents[0].RelatedAgentsUnconfirmed -and
   $null -eq $parents[0].RelatedAgents[0].PSObject.Properties['ActivityIdentity']){$afterLoss=$parents[0];break}
  Start-Sleep -Milliseconds 150
 }while($deadline.ElapsedMilliseconds -lt 15000)
 Require ($null -ne $afterLoss -and @($afterLoss.RelatedAgentIds) -ccontains $childId) 'A lost synthetic child was silently removed or claimed to be current.'
 Write-Output 'Production Codex agent retention: verified synthetic SQLite links and file identities, completed turn and missing record preserved.'
}finally{
 foreach($name in @('codexTitleReader','codexRolloutReader','codexRecentEventObserver','codexRootEvidenceReader')){
  $item=Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
  if($null -ne $item -and $null -ne $item.Value){$item.Value.Dispose()}
 }
 if($null -ne $owner){$owner.Dispose();$deadline=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $deadline.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic worker did not close cleanly.'}}
 if($null -ne $database){$database.Dispose()}
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic fixture cleanup target.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
