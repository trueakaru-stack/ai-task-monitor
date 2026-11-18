$ErrorActionPreference = 'Stop'
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows') {
    throw 'Title lookup tests require a disposable hosted Windows runner.'
}

$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'))
$text = [IO.File]::ReadAllText($source)
$match = [regex]::Match($text, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'The title reader source was not found.' }
Add-Type -TypeDefinition $match.Groups[1].Value

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public sealed class SyntheticTitleDb : IDisposable {
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]
 static extern int sqlite3_open_v2(byte[] path,out IntPtr db,int flags,IntPtr vfs);
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]
 static extern int sqlite3_exec(IntPtr db,byte[] sql,IntPtr callback,IntPtr arg,IntPtr error);
 [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)]
 static extern int sqlite3_close_v2(IntPtr db);
 private IntPtr db;
 static byte[] Utf8(string value) { return Encoding.UTF8.GetBytes(value+"\0"); }
 public SyntheticTitleDb(string path,string schema) {
  if(sqlite3_open_v2(Utf8(path),out db,2|4|0x8000,IntPtr.Zero)!=0) throw new Exception("Synthetic database open failed.");
  Execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; "+schema);
 }
 public void Execute(string sql) {
  int code=sqlite3_exec(db,Utf8(sql),IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
  if(code!=0) throw new Exception("Synthetic database command failed.");
 }
 public void Dispose(){if(db!=IntPtr.Zero){sqlite3_close_v2(db);db=IntPtr.Zero;}}
}
'@

function Require([bool]$condition,[string]$message) { if(-not $condition){throw $message} }
function SharedHash([string]$path) {
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 $sha=[Security.Cryptography.SHA256]::Create()
 try { return [BitConverter]::ToString($sha.ComputeHash($stream)) } finally { $sha.Dispose();$stream.Dispose() }
}
$tempRoot=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
$fixture=[IO.Path]::GetFullPath((Join-Path $tempRoot ('codex-title-lookup-'+[Guid]::NewGuid().ToString('N'))))
if(-not $fixture.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($fixture)
$writer=$null
$badWriter=$null
$reader=$null
try {
 $dbPath=Join-Path $fixture 'state_5.sqlite'
 $writer=[SyntheticTitleDb]::new($dbPath,'CREATE TABLE threads(id TEXT PRIMARY KEY,name TEXT,title TEXT,history_mode TEXT);')
 $writer.Execute("INSERT INTO threads VALUES('modern','Modern name','Stale title','paginated'),('legacy','Stale name','Legacy title','legacy'),('empty','','Misleading title','paginated'),('future','Unknown name','Unknown title','future'),('unicode',char(1055,1088,1080,1074,1077,1090),'Other','paginated');")
 Require ([IO.File]::Exists($dbPath+'-wal') -and [IO.File]::Exists($dbPath+'-shm')) 'Synthetic WAL sidecars were not created.'
 $mainBefore=SharedHash $dbPath
 $walBefore=SharedHash ($dbPath+'-wal')
 $ids=[string[]]@('modern','legacy','empty','future','unicode','missing')
 $names=[AITaskMonitor.CodexTitles.Reader]::ReadNow($fixture,$ids)
 Require ($names.Count -eq 3 -and $names['modern'] -ceq 'Modern name' -and $names['legacy'] -ceq 'Legacy title' -and $names['unicode'] -ceq ([string]::Concat([char[]](1055,1088,1080,1074,1077,1090)))) 'Exact-id lookup, history mode or Unicode is incorrect.'
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The application did not parse.'}
 $branches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('$codexTitles.ContainsKey($id)')},$true))
 Require ($branches.Count -eq 1) 'The title selection branch was not found.'
 $choose=[scriptblock]::Create('param($title,$titleGenerated,$codexTitles,$id)'+$branches[0].Extent.Text+'; [pscustomobject]@{Title=$title;Generated=$titleGenerated}')
 $indexed=& $choose 'Indexed name' $false $names 'modern'
 $generated=& $choose 'Fallback task' $true $names 'modern'
 $blank=& $choose '' $false $names 'modern'
 $absent=& $choose 'Fallback task' $true $names 'missing'
 Require ($indexed.Title -ceq 'Indexed name' -and -not $indexed.Generated -and $generated.Title -ceq 'Modern name' -and -not $generated.Generated -and $blank.Title -ceq 'Modern name' -and $absent.Title -ceq 'Fallback task' -and $absent.Generated) 'Indexed title precedence or fallback is incorrect.'
 $definitions=foreach($functionName in @('Prop','Codex-Tasks')){
  $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $functionName},$true)
  if($null -eq $node){throw 'A source function is missing.'}
  $node.Extent.Text
 }
 $checks=@'
param($root)
$codexHome=$root
$sessionIndex=Join-Path $root 'synthetic-index.jsonl'
[IO.File]::WriteAllText($sessionIndex,'')
$script:unindexedPaths=@{}
$script:lastCodexTasks=@()
$script:stubTitles=@{guardian='Database title';normal='Conflicting database title';fallback='Database fallback'}
$script:codexTitleReader=[PSCustomObject]@{}
$script:codexTitleReader|Add-Member -MemberType ScriptMethod -Name Snapshot -Value {param($path,$ids) return $script:stubTitles}
function Codex-IndexCandidates {
 return @(
  [PSCustomObject]@{id='guardian';thread_name='Guardian review';titleGenerated=$true;updated_at='2026-01-01'},
  [PSCustomObject]@{id='normal';thread_name='Indexed title';titleGenerated=$false;updated_at='2026-01-01'},
  [PSCustomObject]@{id='fallback';thread_name='Generated title';titleGenerated=$true;updated_at='2026-01-01'}
 )
}
function Codex-UnindexedCandidates([bool]$HasIndexedHistory) { return @() }
function Manual-Tasks($sessions) { return @{} }
function Thread-State($id,$unindexed) { return [PSCustomObject]@{State='unknown';UpdatedUtc=[DateTime]::UtcNow;StartKey='turn';StartedUtc=[DateTime]::UtcNow} }
function Codex-Uncertain($id,$state) { return $true }
function Codex-Plan($id) { return @() }
function Codex-ObservedActivity($id,$startKey) { return 'Synthetic activity' }
$tasks=@(Codex-Tasks)
if(@($tasks|Where-Object Id -eq 'guardian').Count -ne 0){throw 'An internal guardian task became visible.'}
$normal=@($tasks|Where-Object Id -eq 'normal')
$fallback=@($tasks|Where-Object Id -eq 'fallback')
if($normal.Count -ne 1 -or $normal[0].Title -cne 'Indexed title' -or $fallback.Count -ne 1 -or $fallback[0].Title -cne 'Database fallback'){throw 'Conflicting title sources were resolved incorrectly.'}
'@
 & ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks)) $fixture
 Require ((SharedHash $dbPath) -ceq $mainBefore -and (SharedHash ($dbPath+'-wal')) -ceq $walBefore) 'Read-only lookup changed the database or WAL.'
 $writer.Execute("UPDATE threads SET name='Updated name' WHERE id='modern';")
 $names=[AITaskMonitor.CodexTitles.Reader]::ReadNow($fixture,$ids)
 Require ($names['modern'] -ceq 'Updated name') 'A committed WAL update was not observed.'

 $reader=[AITaskMonitor.CodexTitles.Reader]::new()
 $clock=[Diagnostics.Stopwatch]::StartNew()
 $first=$reader.Snapshot($fixture,$ids)
 Require ($clock.ElapsedMilliseconds -lt 250 -and $first.Count -eq 0) 'The initial UI lookup blocked or returned an unobserved value.'
 do {
  Start-Sleep -Milliseconds 20
  $names=$reader.Snapshot($fixture,$ids)
 } while($names.Count -eq 0 -and $clock.ElapsedMilliseconds -lt 3000)
 Require ($names.Count -eq 3 -and $names['modern'] -ceq 'Updated name') 'Background results were not delivered.'

 $missing=Join-Path $fixture 'missing'
 [void][IO.Directory]::CreateDirectory($missing)
 $missingDb=Join-Path $missing 'state_5.sqlite'
 Require (([AITaskMonitor.CodexTitles.Reader]::ReadNow($missing,$ids)).Count -eq 0 -and -not [IO.File]::Exists($missingDb) -and -not [IO.File]::Exists($missingDb+'-wal') -and -not [IO.File]::Exists($missingDb+'-shm')) 'A missing database did not use the fallback.'
 $noSidecarRoot=Join-Path $fixture 'closed-database'
 [void][IO.Directory]::CreateDirectory($noSidecarRoot)
 $noSidecarDb=Join-Path $noSidecarRoot 'state_5.sqlite'
 $closedWriter=[SyntheticTitleDb]::new($noSidecarDb,'CREATE TABLE threads(id TEXT PRIMARY KEY,name TEXT,title TEXT,history_mode TEXT);')
 $closedWriter.Execute("INSERT INTO threads VALUES('modern','Closed name','Closed title','paginated');")
 $closedWriter.Dispose()
 Require (-not [IO.File]::Exists($noSidecarDb+'-wal') -and -not [IO.File]::Exists($noSidecarDb+'-shm')) 'Synthetic closed database kept unexpected sidecars.'
 $closedHash=SharedHash $noSidecarDb
 Require (([AITaskMonitor.CodexTitles.Reader]::ReadNow($noSidecarRoot,$ids)).Count -eq 0 -and -not [IO.File]::Exists($noSidecarDb+'-wal') -and -not [IO.File]::Exists($noSidecarDb+'-shm') -and (SharedHash $noSidecarDb) -ceq $closedHash) 'A closed database or sidecars changed during fallback.'
 $badRoot=Join-Path $fixture 'different-schema'
 [void][IO.Directory]::CreateDirectory($badRoot)
 $badWriter=[SyntheticTitleDb]::new((Join-Path $badRoot 'state_5.sqlite'),'CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT);')
 $badWriter.Execute("INSERT INTO threads VALUES('modern','Wrong schema');")
 Require (([AITaskMonitor.CodexTitles.Reader]::ReadNow($badRoot,$ids)).Count -eq 0) 'An incompatible schema was accepted.'

 $lockedRoot=Join-Path $fixture 'locked'
 [void][IO.Directory]::CreateDirectory($lockedRoot)
 $lockedDb=Join-Path $lockedRoot 'state_5.sqlite'
 [IO.File]::WriteAllText($lockedDb,'synthetic locked file')
 [IO.File]::WriteAllBytes(($lockedDb+'-wal'),[byte[]]@())
 [IO.File]::WriteAllBytes(($lockedDb+'-shm'),[byte[]]@())
 $lock=[IO.File]::Open($lockedDb,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try {
  $clock.Restart()
  Require (([AITaskMonitor.CodexTitles.Reader]::ReadNow($lockedRoot,$ids)).Count -eq 0 -and $clock.ElapsedMilliseconds -lt 1000) 'A locked file did not return a bounded fallback.'
 } finally {$lock.Dispose()}
 Write-Output 'Codex titles: exact identities, both history modes, WAL updates, Unicode, asynchronous delivery, missing/incompatible data and locked file verified.'
} finally {
 if($null -ne $reader){$reader.Dispose()}
 if($null -ne $badWriter){$badWriter.Dispose()}
 if($null -ne $writer){$writer.Dispose()}
 if(Test-Path -LiteralPath $fixture){
  $resolved=(Resolve-Path -LiteralPath $fixture).Path
  if($resolved -cne $fixture -or -not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
