param([switch]$RequireSymbolicLink)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\ClaudeRetention.cs'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path $source -ReferencedAssemblies System.Web.Extensions
Add-Type -TypeDefinition @'
using System.Threading;
using System.Runtime.InteropServices;
public static class RetentionFixtureLock {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 [return:MarshalAs(UnmanagedType.I1)]
 private static extern bool CreateSymbolicLink(string link,string target,int flags);
 public static bool CreateFileLink(string link,string target) { return CreateSymbolicLink(link,target,2); }
 public static Thread Start(string name,ManualResetEvent ready,ManualResetEvent release) {
  var thread=new Thread(()=>{using(var mutex=new Mutex(false,name)){mutex.WaitOne();ready.Set();release.WaitOne();mutex.ReleaseMutex();}});
  thread.IsBackground=true;thread.Start();return thread;
 }
}
'@
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-retention-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
$data=Join-Path $root 'data';$backups=Join-Path $root 'claude'
[void][IO.Directory]::CreateDirectory($data);[void][IO.Directory]::CreateDirectory($backups)
$mutex='Local\AITM.Test.Retention.'+[Guid]::NewGuid().ToString('N')
$now=[DateTimeOffset]::Parse('2026-11-04T12:00:00Z')
function Event([DateTimeOffset]$time,[string]$id,[int]$padding=0) {
    return (@{timestamp=$time.ToString('o');session_id=$id;event='PreToolUse';active=$true;task_subject=('x'*$padding)}|ConvertTo-Json -Compress)
}
try {
    $legacy=Join-Path $data 'claude-events.jsonl';$current=Join-Path $data 'claude-events-v2.jsonl'
    $old=Event ($now.AddDays(-8)) 'old';$fresh=Event ($now.AddDays(-1)) 'fresh'
    [IO.File]::WriteAllText($legacy,$old+"`n"+$fresh+"`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($current,(Event $now 'new')+"`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $data 'unrelated.jsonl'),'preserve')
    $result=[AITaskMonitor.Claude.Retention]::Clean($data,$backups,$now,7,1000000,$mutex)
    if($result -ne 'ok' -or [IO.File]::ReadAllText($legacy).Contains('"old"') -or -not [IO.File]::ReadAllText($legacy).Contains('"fresh"')){throw 'Age retention did not remove only expired events.'}
    if([IO.File]::ReadAllText((Join-Path $data 'unrelated.jsonl')) -cne 'preserve'){throw 'An unrelated file was changed.'}

    $lines=for($i=0;$i -lt 80;$i++){Event ($now.AddMinutes($i-100)) ('bulk-'+$i) 20000}
    [IO.File]::WriteAllLines($legacy,[string[]]$lines,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($current,(Event $now 'newest')+"`n",[Text.UTF8Encoding]::new($false))
    [void][AITaskMonitor.Claude.Retention]::Clean($data,$backups,$now,7,1000000,$mutex)
    $total=(Get-Item -LiteralPath $legacy).Length+(Get-Item -LiteralPath $current).Length
    if($total -gt 1000000 -or -not [IO.File]::ReadAllText($current).Contains('"newest"') -or [IO.File]::ReadAllText($legacy).Contains('"bulk-0"')){throw 'Combined event size limit did not keep newest events.'}

    [IO.File]::WriteAllText($legacy,'{"timestamp":"bad"}'+"`n",[Text.UTF8Encoding]::new($false))
    $beforeLegacy=(Get-FileHash -LiteralPath $legacy).Hash;$beforeCurrent=(Get-FileHash -LiteralPath $current).Hash
    $failed=$false
    try{[void][AITaskMonitor.Claude.Retention]::Clean($data,$backups,$now,7,1000000,$mutex)}catch{$failed=$true}
    if(-not $failed -or (Get-FileHash -LiteralPath $legacy).Hash -ne $beforeLegacy -or (Get-FileHash -LiteralPath $current).Hash -ne $beforeCurrent){throw 'Invalid events must prevent cleanup without rewriting either file.'}

    $backup1=Join-Path $backups 'settings.json.codex-tasks-backup-20261020-100000-0000001'
    $backup2=Join-Path $backups 'settings.json.codex-tasks-backup-20261021-100000-0000002'
    $foreign=Join-Path $backups 'settings.json.codex-tasks-backup-foreign'
    [IO.File]::WriteAllText($backup1,'old');[IO.File]::WriteAllText($backup2,'newest');[IO.File]::WriteAllText($foreign,'preserve')
    [IO.File]::SetLastWriteTimeUtc($backup1,$now.AddDays(-40).UtcDateTime)
    [IO.File]::SetLastWriteTimeUtc($backup2,$now.AddDays(-31).UtcDateTime)
    [IO.File]::WriteAllText($legacy,$fresh+"`n",[Text.UTF8Encoding]::new($false))
    [void][AITaskMonitor.Claude.Retention]::Clean($data,$backups,$now,7,1000000,$mutex)
    if((Test-Path -LiteralPath $backup1) -or -not (Test-Path -LiteralPath $backup2) -or -not (Test-Path -LiteralPath $foreign)){throw 'Backup retention did not preserve the newest and unrelated files.'}

    $ready=[Threading.ManualResetEvent]::new($false);$release=[Threading.ManualResetEvent]::new($false)
    $thread=[RetentionFixtureLock]::Start($mutex,$ready,$release)
    try {
        if(-not $ready.WaitOne(3000)){throw 'The test mutex was not acquired.'}
        $before=(Get-FileHash -LiteralPath $legacy).Hash
        if([AITaskMonitor.Claude.Retention]::Clean($data,$backups,$now,7,1000000,$mutex) -ne 'busy' -or (Get-FileHash -LiteralPath $legacy).Hash -ne $before){throw 'A busy event log must remain unchanged.'}
    } finally {$release.Set()|Out-Null;[void]$thread.Join(3000);$ready.Dispose();$release.Dispose()}

    $unsafe=Join-Path $root 'unsafe';[void][IO.Directory]::CreateDirectory($unsafe)
    $target=Join-Path $root 'protected.jsonl';[IO.File]::WriteAllText($target,$old+"`n",[Text.UTF8Encoding]::new($false))
    $link=Join-Path $unsafe 'claude-events.jsonl';$supported=$false
    $supported=[RetentionFixtureLock]::CreateFileLink($link,$target)
    if(-not $supported -and $RequireSymbolicLink){throw 'The symbolic-link fixture could not be created.'}
    if($supported){
        $before=(Get-FileHash -LiteralPath $target).Hash;$failed=$false
        try{[void][AITaskMonitor.Claude.Retention]::Clean($unsafe,$backups,$now,7,1000000,$mutex)}catch{$failed=$true}
        if(-not $failed -or (Get-FileHash -LiteralPath $target).Hash -ne $before){throw 'A symbolic-link event file must not be followed or changed.'}
    }else{Write-Output 'Claude retention symbolic-link fixture skipped.'}
    $tokens=$null;$parseErrors=$null
    $hookAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\ClaudeTaskHook.ps1'),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'The Claude hook could not be parsed.'}
    foreach($name in @('Event-SizeLimit','Assert-EventPathSafe','Rotate-EventLog')){
        $definition=$hookAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        if($null -eq $definition){throw "Missing hook function: $name"};Invoke-Expression $definition.Extent.Text
    }
    if($supported){
        $failed=$false;try{Assert-EventPathSafe $link}catch{$failed=$true}
        if(-not $failed){throw 'The hook must reject a linked event file.'}
        [IO.File]::Delete($target)
        $failed=$false;try{Assert-EventPathSafe $link}catch{$failed=$true}
        if(-not $failed){throw 'The hook must reject a broken linked event file.'}
    }
    if((Event-SizeLimit $data) -ne 10000000){throw 'The hook default size is incorrect.'}
    [IO.File]::WriteAllText((Join-Path $data 'settings.json'),'{"claudeMaximumMB":1}',[Text.UTF8Encoding]::new($false))
    if((Event-SizeLimit $data) -ne 1000000){throw 'The hook ignored the chosen size.'}
    [IO.File]::WriteAllLines($current,[string[]]$lines,[Text.UTF8Encoding]::new($false))
    Rotate-EventLog $current (Event-SizeLimit $data)
    if((Get-Item -LiteralPath $current).Length -gt 1000000 -or -not [IO.File]::ReadAllText($current).Contains('bulk-79')){throw 'Hook rotation did not keep the newest events within the chosen size.'}
    [IO.File]::WriteAllText((Join-Path $data 'settings.json'),'{bad',[Text.UTF8Encoding]::new($false))
    if((Event-SizeLimit $data) -ne 0){throw 'Invalid settings must disable hook rotation.'}
    Write-Output 'Claude retention: age, combined size, malformed input, busy locks, newest backup and foreign files verified.'
} finally {
    if(Test-Path -LiteralPath $root){$resolved=(Resolve-Path -LiteralPath $root).Path;if($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup path.'};Remove-Item -LiteralPath $resolved -Recurse -Force}
}
