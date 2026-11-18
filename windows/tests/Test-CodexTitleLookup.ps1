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
 $mainBefore=(Get-FileHash -LiteralPath $dbPath -Algorithm SHA256).Hash
 $walBefore=(Get-FileHash -LiteralPath ($dbPath+'-wal') -Algorithm SHA256).Hash
 $ids=[string[]]@('modern','legacy','empty','future','unicode','missing')
 $names=[AITaskMonitor.CodexTitles.Reader]::ReadNow($fixture,$ids)
 Require ($names.Count -eq 3 -and $names['modern'] -ceq 'Modern name' -and $names['legacy'] -ceq 'Legacy title' -and $names['unicode'] -ceq ([string]::Concat([char[]](1055,1088,1080,1074,1077,1090)))) 'Exact-id lookup, history mode or Unicode is incorrect.'
 Require ((Get-FileHash -LiteralPath $dbPath -Algorithm SHA256).Hash -ceq $mainBefore -and (Get-FileHash -LiteralPath ($dbPath+'-wal') -Algorithm SHA256).Hash -ceq $walBefore) 'Read-only lookup changed the database or WAL.'
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
 Require (([AITaskMonitor.CodexTitles.Reader]::ReadNow($missing,$ids)).Count -eq 0 -and -not [IO.File]::Exists((Join-Path $missing 'state_5.sqlite'))) 'A missing database did not use the fallback.'
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
