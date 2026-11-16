$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:RUNNER_OS -cne 'Windows' -or $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0') {
    throw 'This synthetic test requires a disposable hosted Windows runner.'
}
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$runnerRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
if (-not $tempRoot.StartsWith($runnerRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'The test temp path is not isolated.' }
$root = [IO.Path]::GetFullPath((Join-Path $tempRoot ('aitm-codex-passive-' + [guid]::NewGuid().ToString('N'))))
if (-not $root.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
[void][IO.Directory]::CreateDirectory($root)
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The monitor source failed to parse.'}
$names=@('Prop','Tr','Localized-TaskTitle','Localized-TaskActivity','Lock-State','Find-PriorLifecycle','Thread-State','Codex-Uncertain','Session-File',
 'Session-Workspace','Progress-Files','Manual-Tasks','Read-TailText','Codex-Plan','Codex-Activity','Read-ObservedCodexTail','Codex-ObservedActivity',
 'Plan-Progress','Codex-IndexCandidates','Codex-UnindexedCandidates','Codex-Tasks','Unconfirmed-Tasks','Source-Snapshot')
$definitions=foreach($name in $names){
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
 if($null -eq $node){throw "Missing monitor function: $name"}
 $node.Extent.Text
}
$lockNode=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Lock-State'},$true)
if($lockNode.Extent.Text -match '\[IO\.File\]::Open|FileStream|CreateFile|LockFile|ReadAll'){throw 'The lock metadata probe must not open or lock the writer file.'}
$initializers=foreach($name in @('$script:translations','$script:sessionFiles','$script:sessionDates','$script:sessionDiscovery')){
 $nodes=@($ast.FindAll({param($item) $item -is [Management.Automation.Language.AssignmentStatementAst] -and $item.Left.Extent.Text -ceq $name},$true))
 if($nodes.Count -ne 1){throw "Unexpected initializer: $name"};$nodes[0].Extent.Text
}
$checks=@'
$fixture=$args[0]
$codexHome=Join-Path $fixture 'profile'
$sessionIndex=Join-Path $codexHome 'session_index.jsonl'
$sessionsDirectory=Join-Path $codexHome 'sessions'
$lockDirectory=Join-Path $codexHome 'thread-writer-locks'
[void][IO.Directory]::CreateDirectory($sessionsDirectory)
[void][IO.Directory]::CreateDirectory($lockDirectory)
$script:lifecycleState=@{};$script:observedCodex=@{};$script:planCache=@{};$script:planConfirmations=@{}
$script:lastCodexTasks=@();$script:lastClaudeTasks=@();$script:codexSourcePartial=$false
$script:codexCloudModulesAvailable=$false;$script:externalProviderModulesAvailable=$false
$script:monitorStartedUtc=[DateTime]::UtcNow.AddSeconds(-10)
$script:fixtureNow=[DateTime]::UtcNow
$script:fixtureDay=Join-Path (Join-Path (Join-Path $sessionsDirectory ([string]$script:fixtureNow.Year)) $script:fixtureNow.Month.ToString('00')) $script:fixtureNow.Day.ToString('00')
[void][IO.Directory]::CreateDirectory($script:fixtureDay)
$ProgressFile='';$ClaudeEventFile=''
function Claude-ConnectionState {return 'disconnected'}
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Write-Event([string]$path,[string]$type,[string]$turn){
 $event=@{timestamp=[DateTime]::UtcNow.ToString('o');type='event_msg';payload=@{type=$type;turn_id=$turn}}|ConvertTo-Json -Compress
 [IO.File]::AppendAllText($path,($event+"`n"),[Text.UTF8Encoding]::new($false))
}
function Write-Index([object[]]$records){
 $lines=@($records|ForEach-Object {$_|ConvertTo-Json -Compress})
 [IO.File]::WriteAllText($sessionIndex,(($lines -join "`n")+"`n"),[Text.UTF8Encoding]::new($false))
}
function Record([string]$id){return @{id=$id;thread_name=('Synthetic '+$id);updated_at=$script:fixtureNow.ToString('o')}}
function New-Session([string]$id,[string]$turn){
 $path=Join-Path $script:fixtureDay ('rollout-'+$id+'.jsonl')
 $meta=@{timestamp=[DateTime]::UtcNow.ToString('o');type='session_meta';payload=@{id=$id}}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText($path,($meta+"`n"),[Text.UTF8Encoding]::new($false))
 Write-Event $path 'task_started' $turn
 [IO.File]::WriteAllText((Join-Path $lockDirectory ($id+'.lock')),'',[Text.UTF8Encoding]::new($false))
 return $path
}

# A lock entry alone is not a task, and an uncertain source cannot say empty.
Write-Index @((Record 'no-event'))
[IO.File]::WriteAllText((Join-Path $lockDirectory 'no-event.lock'),'')
$empty=Source-Snapshot
Require (@($empty.Tasks).Count -eq 0 -and @($empty.Unavailable) -contains 'Codex' -and @($empty.PartialData) -contains 'Codex') 'Lock presence alone created activity or an empty-state claim.'

# Reproduce the conflicting Windows share mode with a synthetic writer file.
$lock=Join-Path $lockDirectory 'writer.lock'
[IO.File]::WriteAllText($lock,'')
$unsafe=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
try{
 $blocked=$false
 try{$probe=[IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$probe.Dispose()}catch [IO.IOException] {$blocked=$true}
 Require $blocked 'The former conflicting sharing mode did not block the positive control.'
}finally{$unsafe.Dispose()}
Require ((Lock-State $lock) -eq 'present') 'The safe probe did not report metadata presence.'

# A concurrent synthetic writer repeatedly opens the same lock file while the
# actual monitor function checks metadata. No installed agent is started.
$ready=Join-Path $fixture 'writer-ready';$done=Join-Path $fixture 'writer-done';$report=Join-Path $fixture 'writer-report.json'
$worker=@(
 '$path=$env:AITM_TEST_LOCK;$ready=$env:AITM_TEST_READY;$done=$env:AITM_TEST_DONE;$report=$env:AITM_TEST_REPORT'
 '$attempts=0;$blocked=0;$watch=[Diagnostics.Stopwatch]::StartNew()'
 '[IO.File]::WriteAllText($ready,''ready'')'
 'while(-not [IO.File]::Exists($done) -and $watch.ElapsedMilliseconds -lt 20000){'
 ' try{$h=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$h.Dispose();$attempts++}'
 ' catch [IO.IOException]{$blocked++}'
 '}'
 '@{attempts=$attempts;blocked=$blocked}|ConvertTo-Json -Compress|Set-Content -LiteralPath $report -Encoding UTF8'
) -join "`n"
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker))
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$start.Arguments='-NoProfile -NonInteractive -EncodedCommand '+$encoded;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.EnvironmentVariables['AITM_TEST_LOCK']=$lock;$start.EnvironmentVariables['AITM_TEST_READY']=$ready
$start.EnvironmentVariables['AITM_TEST_DONE']=$done;$start.EnvironmentVariables['AITM_TEST_REPORT']=$report
$child=[Diagnostics.Process]::Start($start)
try{
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while(-not [IO.File]::Exists($ready) -and -not $child.HasExited -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require ([IO.File]::Exists($ready)) 'The synthetic writer did not start.'
 for($i=0;$i -lt 1000;$i++){Require ((Lock-State $lock) -eq 'present') 'A concurrent metadata probe failed.'}
 [IO.File]::WriteAllText($done,'done')
 if(-not $child.WaitForExit(25000)){$child.Kill();[void]$child.WaitForExit(5000);throw 'The synthetic writer timed out.'}
 Require ($child.ExitCode -eq 0 -and [IO.File]::Exists($report)) 'The synthetic writer failed.'
 $writerResult=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json
 Require ($writerResult.attempts -gt 0 -and $writerResult.blocked -eq 0) 'The metadata observer blocked a synthetic writer.'
}finally{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(5000)};$child.Dispose()}

$path=New-Session 'task-a' 'turn-a'
$activityRecord=@{timestamp=[DateTime]::UtcNow.ToString('o');type='event_msg';payload=@{type='item_completed';thread_id='task-a';turn_id='turn-a';item=@{type='Reasoning';id='reasoning-1';summary_text=@('Synthetic observed action');raw_content=@()}}}|ConvertTo-Json -Compress -Depth 8
[IO.File]::AppendAllText($path,($activityRecord+"`n"),[Text.UTF8Encoding]::new($false))
$plan=@{plan=@(@{step='Synthetic first';status='in_progress'})}|ConvertTo-Json -Compress -Depth 6
$record=@{type='response_item';payload=@{type='function_call';name='update_plan';arguments=$plan}}|ConvertTo-Json -Compress -Depth 8
[IO.File]::AppendAllText($path,($record+"`n"),[Text.UTF8Encoding]::new($false))
Write-Index @((Record 'task-a'))
$snapshot=Source-Snapshot;$card=@($snapshot.Tasks|Where-Object Id -eq 'task-a')
Require ($card.Count -eq 1 -and -not $card[0].Active -and $card[0].Status -eq 'Статус не подтверждён' -and
 $card[0].ActivityObserved -and $card[0].Activity -eq 'Synthetic observed action' -and
 $null -eq $card[0].Progress -and -not $card[0].PlanConfirmed -and @($card[0].Steps).Count -eq 1) 'A start, message and plan were not retained as unconfirmed.'
$script:resolvedLanguage='ru'
Require ((Localized-TaskActivity $card[0]) -ceq 'Статус не подтверждён. Из журнала: Synthetic observed action') 'The Russian observed-message label is incorrect.'
$script:resolvedLanguage='en'
Require ((Localized-TaskActivity $card[0]) -ceq 'Status unconfirmed. From log: Synthetic observed action') 'The English observed-message label is incorrect.'
[IO.File]::Delete((Join-Path $lockDirectory 'task-a.lock'))
$withoutLock=Source-Snapshot
Require (@($withoutLock.Tasks|Where-Object {$_.Id -eq 'task-a' -and -not $_.Active}).Count -eq 1) 'A missing lock was treated as completion.'
Write-Event $path 'task_complete' ''
$unmatched=Source-Snapshot
Require (@($unmatched.Tasks|Where-Object Id -eq 'task-a').Count -eq 1) 'A terminal without a matching turn hid a previously seen task.'

$pathB=New-Session 'task-b' 'turn-b'
Write-Index @((Record 'task-b'))
$changedIndex=Source-Snapshot
$second=@($changedIndex.Tasks|Where-Object Id -eq 'task-b')
Require ($second.Count -eq 1 -and -not $second[0].ActivityObserved -and $second[0].Activity -eq 'Статус не подтверждён') 'A task without an associated message must show only the unconfirmed status.'
Require (@($changedIndex.Tasks|Where-Object {$_.Id -eq 'task-a' -and -not $_.Active}).Count -eq 1) 'An observed task vanished when its index entry disappeared.'
Write-Event $pathB 'task_complete' 'turn-b'
$completed=Source-Snapshot
Require (@($completed.Tasks|Where-Object Id -eq 'task-b').Count -eq 0 -and @($completed.PartialData) -contains 'Codex') 'A matched terminal or the incomplete-source warning was mishandled.'

# Paginated ItemCompleted carries thread and turn identity. Legacy commentary
# is displayed only as a record from a verified session file, not as a turn.
$paginatedId='00000000-0000-0000-0000-000000000101';$paginatedTurn='00000000-0000-0000-0000-000000000102'
$paginated=New-Session $paginatedId $paginatedTurn
$paginatedItem=@{timestamp=[DateTime]::UtcNow.ToString('o');type='event_msg';payload=@{type='item_completed';thread_id=$paginatedId;turn_id=$paginatedTurn;item=@{type='Reasoning';id='reasoning-1';summary_text=@('Paginated observation');raw_content=@()}}}|ConvertTo-Json -Compress -Depth 8
[IO.File]::AppendAllText($paginated,($paginatedItem+"`n"),[Text.UTF8Encoding]::new($false))
$legacyId='00000000-0000-0000-0000-000000000201';$legacyTurn='00000000-0000-0000-0000-000000000202'
$legacy=New-Session $legacyId $legacyTurn
$legacyItem=@{timestamp=[DateTime]::UtcNow.ToString('o');type='event_msg';payload=@{type='agent_message';phase='commentary';message='Legacy message from log'}}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($legacy,($legacyItem+"`n"),[Text.UTF8Encoding]::new($false))
Write-Index @((Record $paginatedId),(Record $legacyId))
$both=Source-Snapshot
$paged=@($both.Tasks|Where-Object Id -eq $paginatedId);$legacyCard=@($both.Tasks|Where-Object Id -eq $legacyId)
Require ($paged.Count -eq 1 -and $paged[0].ActivityObserved -and $paged[0].Activity -eq 'Paginated observation' -and -not $paged[0].Active) 'A paginated item with matching thread and turn was not shown as observed.'
Require ($legacyCard.Count -eq 1 -and $legacyCard[0].ActivityObserved -and $legacyCard[0].Activity -eq 'Legacy message from log' -and -not $legacyCard[0].Active) 'A completed legacy commentary was not shown as an unconfirmed log observation.'
$pendingLegacy=@{timestamp=[DateTime]::UtcNow.AddHours(-1).ToString('o');type='event_msg';payload=@{type='agent_message';phase='commentary';message='Delayed legacy message'}}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($legacy,$pendingLegacy,[Text.UTF8Encoding]::new($false))
$pendingSnapshot=Source-Snapshot;$pendingCard=@($pendingSnapshot.Tasks|Where-Object Id -eq $legacyId)
Require ($pendingCard.Count -eq 1 -and $pendingCard[0].Activity -eq 'Legacy message from log') 'An incomplete final line was treated as a finished commentary.'
[IO.File]::AppendAllText($legacy,"`n",[Text.UTF8Encoding]::new($false))
$delayedSnapshot=Source-Snapshot;$delayedCard=@($delayedSnapshot.Tasks|Where-Object Id -eq $legacyId)
Require ($delayedCard.Count -eq 1 -and $delayedCard[0].Activity -eq 'Delayed legacy message' -and -not $delayedCard[0].Active -and $delayedCard[0].Status -eq 'Статус не подтверждён') 'A delayed completed record was misrepresented or lost.'
$wrongId='00000000-0000-0000-0000-000000000301';$wrongTurn='00000000-0000-0000-0000-000000000302'
$wrongPath=New-Session $wrongId $wrongTurn
$wrongMeta=@{type='session_meta';payload=@{id='different-session'}}|ConvertTo-Json -Compress
[IO.File]::WriteAllText($wrongPath,($wrongMeta+"`n"),[Text.UTF8Encoding]::new($false))
Write-Event $wrongPath 'task_started' $wrongTurn
[IO.File]::AppendAllText($wrongPath,($legacyItem+"`n"),[Text.UTF8Encoding]::new($false))
Write-Index @((Record $wrongId))
$wrongCard=@((Source-Snapshot).Tasks|Where-Object Id -eq $wrongId)
Require ($wrongCard.Count -eq 1 -and -not $wrongCard[0].ActivityObserved) 'A message from a different session was displayed.'

# A start outside the last index rows is still found from lock metadata.
$oldPath=New-Session 'historical-lock' 'turn-old'
$records=@((Record 'historical-lock'))
for($i=0;$i -lt 60;$i++){$records+=,(Record ('quiet-'+$i))}
Write-Index $records
$older=Source-Snapshot
Require (@($older.Tasks|Where-Object {$_.Id -eq 'historical-lock' -and -not $_.Active}).Count -eq 1) 'A present lock outside the latest 50 rows was missed.'

# A long turn with its boundary in the bounded earlier window remains unknown.
$long=Join-Path $script:fixtureDay 'rollout-long-turn.jsonl'
$writer=[IO.StreamWriter]::new($long,$false,[Text.UTF8Encoding]::new($false))
try{
 $writer.WriteLine('{"timestamp":"'+[DateTime]::UtcNow.AddHours(-1).ToString('o')+'","type":"event_msg","payload":{"type":"task_started","turn_id":"long-turn"}}')
 for($i=0;$i -lt 52;$i++){$writer.WriteLine('{"type":"response_item","payload":{"text":"'+('x'*65536)+'"}}')}
 $writer.WriteLine('{"timestamp":"'+[DateTime]::UtcNow.ToString('o')+'","type":"event_msg","payload":{"type":"item_completed","turn_id":"long-turn"}}')
}finally{$writer.Dispose()}
[IO.File]::WriteAllText((Join-Path $lockDirectory 'long-turn.lock'),'')
Write-Index @((Record 'long-turn'))
[void](Codex-IndexCandidates)
$longState=Thread-State 'long-turn'
Require ($longState.State -eq 'unknown' -and $longState.HasStartMarker -and (Codex-Uncertain 'long-turn' $longState)) 'A bounded long turn was not retained as unconfirmed.'

# Unindexed CLI sessions must not require a writer-lock file or a recent write.
$noIndexId='10000000-0000-0000-0000-000000000001'
$noIndexTurn='10000000-0000-0000-0000-000000000002'
$filenameTime=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH-mm-ss',[Globalization.CultureInfo]::InvariantCulture)
$noIndexPath=Join-Path $script:fixtureDay ('rollout-'+$filenameTime+'-'+$noIndexId+'.jsonl')
$noIndexMeta=@{timestamp=[DateTime]::UtcNow.ToString('o');type='session_meta';payload=@{id=$noIndexId;source='exec'}}|ConvertTo-Json -Compress
[IO.File]::WriteAllText($noIndexPath,($noIndexMeta+"`n"),[Text.UTF8Encoding]::new($false))
Write-Event $noIndexPath 'task_started' $noIndexTurn
[IO.File]::AppendAllText($noIndexPath,($legacyItem+"`n"),[Text.UTF8Encoding]::new($false))
[IO.File]::SetLastWriteTimeUtc($noIndexPath,[DateTime]::UtcNow.AddMinutes(-10))
$badId='10000000-0000-0000-0000-000000000003'
$badPath=Join-Path $script:fixtureDay ('rollout-'+$filenameTime+'-'+$badId+'.jsonl')
[IO.File]::WriteAllText($badPath,($noIndexMeta+"`n"),[Text.UTF8Encoding]::new($false))
$partialId='10000000-0000-0000-0000-000000000004'
$partialPath=Join-Path $script:fixtureDay ('rollout-'+$filenameTime+'-'+$partialId+'.jsonl')
[IO.File]::WriteAllText($partialPath,'{"type":"session_meta"',[Text.UTF8Encoding]::new($false))
$duplicateId='10000000-0000-0000-0000-000000000005'
$duplicateMeta=@{type='session_meta';payload=@{id=$duplicateId}}|ConvertTo-Json -Compress
$duplicatePath=Join-Path $script:fixtureDay ('rollout-'+$filenameTime+'-'+$duplicateId+'.jsonl')
$alternatePath=Join-Path $script:fixtureDay ('rollout-'+$filenameTime+'-'+$duplicateId+'_20000000-0000-0000-0000-000000000001.jsonl')
foreach($path in @($duplicatePath,$alternatePath)){[IO.File]::WriteAllText($path,($duplicateMeta+"`n"),[Text.UTF8Encoding]::new($false))}
$savedIndex=Join-Path $codexHome 'index-for-fixture.jsonl'
[IO.File]::Move($sessionIndex,$savedIndex)
$script:lastCodexTasks=@();$script:observedCodex=@{};$script:unindexedScan=$null
try{
 $discovered=@(Codex-UnindexedCandidates)
 Require (@($discovered|Where-Object id -eq $noIndexId).Count -eq 1 -and
  @($discovered|Where-Object {$_.id -in @($badId,$partialId,$duplicateId)}).Count -eq 0 -and
  $script:unindexedScan.CheckedFiles -le 256 -and $script:unindexedScan.BytesRead -le 4194304) 'Invalid, incomplete, ambiguous or oversized discovery was accepted.'
 $noIndex=Source-Snapshot
 $card=@($noIndex.Tasks|Where-Object Id -eq $noIndexId)
 Require ($card.Count -eq 1 -and -not $card[0].Active -and $card[0].Status -eq 'Статус не подтверждён' -and
  $card[0].TitleGenerated -and $card[0].Title -ceq 'Задача Codex' -and $card[0].ActivityObserved -and
  @($noIndex.PartialData) -contains 'Codex') 'An unindexed CLI session was lost, confirmed, or not marked partial.'
 $script:resolvedLanguage='en'
 Require ((Localized-TaskTitle $card[0]) -ceq 'Codex task') 'The generated Codex title was not translated.'
 $userTitle=[PSCustomObject]@{Provider='codex';Title='Задача Codex';TitleGenerated=$false}
 Require ((Localized-TaskTitle $userTitle) -ceq 'Задача Codex') 'A user-provided Codex title was translated.'
 $script:resolvedLanguage='ru'
 Require ((Localized-TaskTitle $card[0]) -ceq 'Задача Codex') 'The generated Russian Codex title was changed.'
}finally{[IO.File]::Move($savedIndex,$sessionIndex)}
Write-Index @((Record $paginatedId))
$combined=Source-Snapshot
Require (@($combined.Tasks|Where-Object Id -eq $paginatedId).Count -eq 1 -and
 @($combined.Tasks|Where-Object Id -eq $noIndexId).Count -eq 1) 'An existing index hid an unindexed session or its indexed neighbor.'
Write-Event $noIndexPath 'task_complete' $noIndexTurn
$finished=Source-Snapshot
Require (@($finished.Tasks|Where-Object Id -eq $noIndexId).Count -eq 0) 'A matching terminal event did not hide an unindexed task.'

# Oversized and incomplete indices cannot be returned as complete empty lists.
$script:lastCodexTasks=@($older.Tasks)
[IO.File]::WriteAllText($sessionIndex,('x'*16777217),[Text.UTF8Encoding]::new($false))
$tooLarge=Source-Snapshot
Require (@($tooLarge.Unavailable) -contains 'Codex' -and @($tooLarge.Tasks|Where-Object Id -eq 'historical-lock').Count -eq 1) 'An oversized index lost the previously visible task or hid the source error.'
[IO.File]::WriteAllText($sessionIndex,'{"id":"unfinished"}',[Text.UTF8Encoding]::new($false))
$partial=Source-Snapshot
Require (@($partial.Unavailable) -contains 'Codex') 'An incomplete index was treated as a complete snapshot.'
Write-Output ('Codex passive: writer sharing positive control, '+$writerResult.attempts+' concurrent opens, evidence, completion, historical lookup and bounded failures verified.')
'@
& ([scriptblock]::Create(($initializers -join "`n")+"`n"+($definitions -join "`n")+"`n"+$checks)) $root
