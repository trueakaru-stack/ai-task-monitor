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
$names=@('Prop','Tr','Localized-TaskTitle','Localized-TaskActivity','Source-WarningText','Lock-State','Find-PriorLifecycle','Thread-State','Codex-Uncertain','Session-File',
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

# A new profile can have no sessions directory. Losing a directory after a
# visible task is different and must preserve the card with a read warning.
$originalHome=$codexHome;$originalIndex=$sessionIndex;$originalSessions=$sessionsDirectory;$originalLocks=$lockDirectory
$originalUnindexed=Get-Variable -Scope Script -Name unindexedPaths -ErrorAction SilentlyContinue
try{
 $codexHome=Join-Path $fixture 'fresh-codex-profile'
 $sessionIndex=Join-Path $codexHome 'session_index.jsonl'
 $sessionsDirectory=Join-Path $codexHome 'sessions'
 $lockDirectory=Join-Path $codexHome 'thread-writer-locks'
 [void][IO.Directory]::CreateDirectory($codexHome)
 $script:lastCodexTasks=@();$script:unindexedPaths=@{};$script:unindexedScan=$null
 $fresh=Source-Snapshot
 Require (@($fresh.Tasks).Count -eq 0 -and $fresh.CodexIncomplete -and @($fresh.PartialData) -cnotcontains 'Codex') 'A fresh profile without sessions was reported as a read failure.'
 $day=Join-Path (Join-Path (Join-Path $sessionsDirectory ([DateTime]::UtcNow.ToString('yyyy'))) ([DateTime]::UtcNow.ToString('MM'))) ([DateTime]::UtcNow.ToString('dd'))
 [void][IO.Directory]::CreateDirectory($day)
 [void][IO.Directory]::CreateDirectory($lockDirectory)
 $freshId='30000000-0000-0000-0000-000000000001'
 $freshPath=Join-Path $day ('rollout-'+[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH-mm-ss')+'-'+$freshId+'.jsonl')
 $freshMeta=@{type='session_meta';payload=@{id=$freshId}}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText($freshPath,($freshMeta+"`n"),[Text.UTF8Encoding]::new($false))
 Write-Event $freshPath 'task_started' 'fresh-turn'
 [IO.File]::WriteAllText((Join-Path $lockDirectory ($freshId+'.lock')),'',[Text.UTF8Encoding]::new($false))
 $freshActive=Source-Snapshot
 Require (@($freshActive.Tasks|Where-Object {$_.Id -eq $freshId -and -not $_.Active}).Count -eq 1) 'The new profile did not show its first synthetic task.'
 $moved=$sessionsDirectory+'.moved'
 [IO.Directory]::Move($sessionsDirectory,$moved)
 $lost=Source-Snapshot
 Require (@($lost.PartialData) -ccontains 'Codex' -and @($lost.Tasks|Where-Object {$_.Id -eq $freshId -and -not $_.Active}).Count -eq 1) 'A missing sessions directory lost its prior task or warning.'
 [IO.Directory]::Move($moved,$sessionsDirectory)
 $returned=Source-Snapshot
 Require ($returned.CodexIncomplete -and @($returned.PartialData) -cnotcontains 'Codex' -and @($returned.Tasks|Where-Object Id -eq $freshId).Count -eq 1) 'The restored sessions directory did not recover.'
 Write-Index @((Record $freshId))
 $script:lastCodexTasks=@()
 [IO.Directory]::Move($sessionsDirectory,$moved)
 $indexedMissing=Source-Snapshot
 Require (@($indexedMissing.PartialData) -ccontains 'Codex') 'An index with a missing sessions directory hid the read failure.'
}finally{
 if($null -ne $script:unindexedCursor -and $null -ne $script:unindexedCursor.Enumerator){try{$script:unindexedCursor.Enumerator.Dispose()}catch{}}
 $codexHome=$originalHome;$sessionIndex=$originalIndex;$sessionsDirectory=$originalSessions;$lockDirectory=$originalLocks
 $script:lastCodexTasks=@();$script:unindexedPaths=if($null -ne $originalUnindexed){$originalUnindexed.Value}else{@{}}
 $script:unindexedScan=$null;$script:unindexedCursor=$null
}

# A lock entry alone is not a task, and an uncertain source cannot say empty.
Write-Index @((Record 'no-event'))
[IO.File]::WriteAllText((Join-Path $lockDirectory 'no-event.lock'),'')
$empty=Source-Snapshot
Require (@($empty.Tasks).Count -eq 0 -and @($empty.Unavailable) -contains 'Codex' -and $empty.CodexIncomplete) 'Lock presence alone created activity or an empty-state claim.'

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
Require (@($completed.Tasks|Where-Object Id -eq 'task-b').Count -eq 0 -and $completed.CodexIncomplete) 'A matched terminal or the incomplete-source warning was mishandled.'

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
 Require (@($noIndex.Tasks|Where-Object Id -eq $noIndexId).Count -eq 0 -and
  $noIndex.CodexIncomplete) 'An old unobserved, unlocked rollout was treated as an active task.'
 [IO.File]::AppendAllText($noIndexPath,($legacyItem+"`n"),[Text.UTF8Encoding]::new($false))
 $noIndex=Source-Snapshot
 $card=@($noIndex.Tasks|Where-Object Id -eq $noIndexId)
 Require ($card.Count -eq 1 -and -not $card[0].Active -and $card[0].Status -eq 'Статус не подтверждён' -and
  $card[0].TitleGenerated -and $card[0].Title -ceq 'Задача Codex' -and $card[0].ActivityObserved -and
  $noIndex.CodexIncomplete) 'An unindexed CLI session was lost, confirmed, or not marked partial.'
 $script:resolvedLanguage='en'
 Require ((Localized-TaskTitle $card[0]) -ceq 'Codex task') 'The generated Codex title was not translated.'
 $userTitle=[PSCustomObject]@{Provider='codex';Title='Задача Codex';TitleGenerated=$false}
 Require ((Localized-TaskTitle $userTitle) -ceq 'Задача Codex') 'A user-provided Codex title was translated.'
 $script:resolvedLanguage='ru'
 Require ((Localized-TaskTitle $card[0]) -ceq 'Задача Codex') 'The generated Russian Codex title was changed.'
 Require ((Source-WarningText @('Codex') @() @() $true) -ceq 'Список задач Codex может быть неполным' -and
  (Source-WarningText @('Codex') @() @('Codex') $false) -ceq 'Часть данных недоступна: Codex') 'Codex coverage and read failures were conflated in Russian.'
 $script:resolvedLanguage='en'
 Require ((Source-WarningText @('Codex') @() @() $true) -ceq 'The Codex task list may be incomplete' -and
  (Source-WarningText @('Codex') @() @('Codex') $false) -ceq 'Some data is unavailable: Codex') 'Codex coverage and read failures were conflated in English.'
 $script:resolvedLanguage='ru'
 $originalHome=$codexHome;$originalIndex=$sessionIndex
 try{
  $codexHome=Join-Path $fixture 'missing-codex-home'
  $sessionIndex=Join-Path $codexHome 'session_index.jsonl'
  $gone=Source-Snapshot
  Require (@($gone.Unavailable) -contains 'Codex' -and @($gone.Tasks|Where-Object {$_.Id -eq $noIndexId -and -not $_.Active}).Count -eq 1) 'A vanished Codex home hid previously visible tasks.'
 }finally{$codexHome=$originalHome;$sessionIndex=$originalIndex}
 $script:unindexedScan=$null
 [void](Source-Snapshot)
 $hiddenPath=$noIndexPath+'.fixture-hidden'
 $scanTick=$script:sessionDiscovery.LastScanTicks
 [IO.File]::Move($noIndexPath,$hiddenPath)
 try{
  Require ((Session-File $noIndexId) -ceq '' -and $script:sessionDiscovery.LastScanTicks -eq $scanTick) 'A missing unindexed file triggered an unbounded recursive scan.'
 }finally{[IO.File]::Move($hiddenPath,$noIndexPath)}
 $longId='10000000-0000-0000-0000-000000000006'
 $longTurn='10000000-0000-0000-0000-000000000007'
 $longUnindexed=Join-Path $script:fixtureDay ('rollout-'+$filenameTime+'-'+$longId+'.jsonl')
 $longMeta=@{type='session_meta';payload=@{id=$longId;source='exec'}}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText($longUnindexed,($longMeta+"`n"),[Text.UTF8Encoding]::new($false))
 Write-Event $longUnindexed 'task_started' $longTurn
 $filler='{"type":"event_msg","payload":{"type":"token_count","padding":"'+('x'*700000)+'"}}'+"`n"
 for($i=0;$i -lt 4;$i++){[IO.File]::AppendAllText($longUnindexed,$filler,[Text.UTF8Encoding]::new($false))}
 $script:unindexedScan=$null
 $longSnapshot=Source-Snapshot
 Require (@($longSnapshot.Tasks|Where-Object {$_.Id -eq $longId -and -not $_.Active -and $_.Status -eq 'Статус не подтверждён'}).Count -eq 1) 'A large freshly updated rollout without a lock lost its bounded start marker.'
}finally{[IO.File]::Move($savedIndex,$sessionIndex)}
Write-Index @((Record $paginatedId))
$combined=Source-Snapshot
Require (@($combined.Tasks|Where-Object Id -eq $paginatedId).Count -eq 1 -and
 @($combined.Tasks|Where-Object Id -eq $noIndexId).Count -eq 1) 'An existing index hid an unindexed session or its indexed neighbor.'
[IO.File]::WriteAllText($sessionIndex,'{"id":"incomplete"}',[Text.UTF8Encoding]::new($false))
$brokenIndex=Source-Snapshot
Require (@($brokenIndex.Unavailable) -contains 'Codex' -and
 @($brokenIndex.Tasks|Where-Object {$_.Id -eq $noIndexId -and -not $_.Active}).Count -eq 1 -and
 @($brokenIndex.Tasks|Where-Object {$_.Id -eq $paginatedId -and -not $_.Active}).Count -eq 1) 'A damaged index hid previously visible tasks or its warning.'
Write-Index @((Record $paginatedId))
Write-Event $noIndexPath 'task_complete' $noIndexTurn
$finished=Source-Snapshot
Require (@($finished.Tasks|Where-Object Id -eq $noIndexId).Count -eq 0) 'A matching terminal event did not hide an unindexed task.'

# Exercise both discovery limits with synthetic directories.
$originalSessionsDirectory=$sessionsDirectory
try{
 $budgetRoot=Join-Path $fixture 'bounded-file-count'
 $budgetDay=Join-Path (Join-Path (Join-Path $budgetRoot ([DateTime]::UtcNow.ToString('yyyy'))) ([DateTime]::UtcNow.ToString('MM'))) ([DateTime]::UtcNow.ToString('dd'))
 [void][IO.Directory]::CreateDirectory($budgetDay)
 $ids=@{}
 for($i=0;$i -lt 300;$i++){
  $id=[Guid]::NewGuid().ToString()
  $path=Join-Path $budgetDay ('rollout-'+$filenameTime+'-'+$id+'.jsonl')
  $ids[$path]=$id
  [IO.File]::WriteAllText($path,("{}`n"),[Text.UTF8Encoding]::new($false))
 }
 $order=@([IO.Directory]::EnumerateFiles($budgetDay,'rollout-*.jsonl',[IO.SearchOption]::TopDirectoryOnly))
 $laterPath=[string]$order[270];$laterId=[string]$ids[$laterPath]
 $laterMeta=@{type='session_meta';payload=@{id=$laterId}}|ConvertTo-Json -Compress
 [IO.File]::WriteAllText($laterPath,($laterMeta+"`n"),[Text.UTF8Encoding]::new($false))
 Write-Event $laterPath 'task_started' 'later-turn'
 [IO.File]::WriteAllText((Join-Path $lockDirectory ($laterId+'.lock')),'',[Text.UTF8Encoding]::new($false))
 $sessionsDirectory=$budgetRoot;$script:unindexedScan=$null
 $none=@(Codex-UnindexedCandidates)
 Require ($none.Count -eq 0 -and $script:unindexedScan.CheckedFiles -eq 256 -and $script:unindexedScan.BytesRead -le 4194304) 'The file-count budget was not enforced.'
 $writer=[IO.File]::Open($laterPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{[void]$writer.Seek(0,[IO.SeekOrigin]::End);$writer.WriteByte(10)}finally{$writer.Dispose()}
 $script:unindexedScan.Tick=0
 $later=@(Codex-UnindexedCandidates)
 Require (@($later|Where-Object id -eq $laterId).Count -eq 1 -and $script:unindexedScan.CheckedFiles -le 256) 'The next page did not reach a later session.'
 $laterSnapshot=Source-Snapshot
 Require (@($laterSnapshot.Tasks|Where-Object {$_.Id -eq $laterId -and -not $_.Active -and $_.Status -eq 'Статус не подтверждён'}).Count -eq 1) 'A later-page session did not reach the task list unconfirmed.'
 $script:unindexedScan.Tick=0
 $nextSnapshot=Source-Snapshot
 Require (@($nextSnapshot.Tasks|Where-Object {$_.Id -eq $laterId -and -not $_.Active -and $_.Status -eq 'Статус не подтверждён'}).Count -eq 1) 'A prior page lost its visible unconfirmed card.'
 $budgetRoot=Join-Path $fixture 'bounded-byte-count'
 $budgetDay=Join-Path (Join-Path (Join-Path $budgetRoot ([DateTime]::UtcNow.ToString('yyyy'))) ([DateTime]::UtcNow.ToString('MM'))) ([DateTime]::UtcNow.ToString('dd'))
 [void][IO.Directory]::CreateDirectory($budgetDay)
 for($i=0;$i -lt 70;$i++){
  $id=[Guid]::NewGuid().ToString()
  $path=Join-Path $budgetDay ('rollout-'+$filenameTime+'-'+$id+'.jsonl')
  $meta=@{type='session_meta';payload=@{id=$id}}|ConvertTo-Json -Compress
  [IO.File]::WriteAllText($path,($meta+"`n"+('x'*65536)),[Text.UTF8Encoding]::new($false))
 }
 $sessionsDirectory=$budgetRoot;$script:unindexedScan=$null
 [void]@(Codex-UnindexedCandidates)
 Require ($script:unindexedScan.CheckedFiles -le 256 -and $script:unindexedScan.BytesRead -eq 4194304) 'The byte budget was not enforced.'
 $script:unindexedScan.Tick=0
 Require (@(Codex-UnindexedCandidates).Count -gt 0) 'The byte-limited scan did not resume.'
 $badRoot=Join-Path $fixture 'redirected-sessions'
 $badYear=Join-Path $badRoot ([DateTime]::UtcNow.ToString('yyyy'))
 $badMonth=Join-Path $badYear ([DateTime]::UtcNow.ToString('MM'))
 $badDay=Join-Path $badMonth ([DateTime]::UtcNow.ToString('dd'))
 $outside=Join-Path $fixture 'redirected-target'
 foreach($dir in @($badMonth,$outside)){[void][IO.Directory]::CreateDirectory($dir)}
 $null=New-Item -ItemType Junction -Path $badDay -Target $outside
 $sessionsDirectory=$badRoot;$script:unindexedScan=$null
 [void]@(Codex-UnindexedCandidates)
 Require $script:codexDiscoveryFailed 'A redirected dated directory was not reported as a read failure.'
}finally{$sessionsDirectory=$originalSessionsDirectory;$script:unindexedScan=$null}

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
