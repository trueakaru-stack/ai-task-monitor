$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path (Join-Path $PSScriptRoot '../app/integrations/ProviderEventState.cs') -ReferencedAssemblies System.Web.Extensions

function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Clock {
    $ticks = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $frequency = [System.Diagnostics.Stopwatch]::Frequency
    return [long]([math]::Floor($ticks / $frequency) * 1000000000 + (($ticks % $frequency) * (1000000000.0 / $frequency)))
}
function Event([string]$session, [string]$kind, [long]$tick, [long]$epoch, [string]$request = '', [string]$turn = '') {
    $data = [ordered]@{ version = 1; provider = 'hermes'; session = $session; kind = $kind; tick = $tick; epoch = $epoch }
    if ($request) { $data.request = $request }
    if ($turn) { $data.turn = $turn }
    $value = [AITaskMonitor.ExternalProviders.EventParser]::Parse(($data | ConvertTo-Json -Compress))
    Assert ($null -ne $value) 'Synthetic event did not parse.'
    return $value
}
function Status($store, [string]$session, $now) {
    return (@($store.Snapshot($now) | Where-Object Session -eq $session)[0]).Status
}

$now = [DateTimeOffset]::UtcNow
$base = (Clock) - 1000000000
$epoch = $base - 1000
$store = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($store.Apply((Event s started ($base + 1) $epoch '' turn_1), $now)) 'Start was not accepted.'
Assert ($store.Apply((Event s waiting ($base + 2) $epoch a), $now)) 'First request was not accepted.'
Assert ($store.Apply((Event s active ($base + 3) $epoch), $now)) 'Parallel tool was not accepted.'
Assert ((Status $store s $now) -eq 'waiting') 'A completed parallel tool hid an open approval.'
Assert ($store.Apply((Event s waiting ($base + 4) $epoch b), $now)) 'Second request was not accepted.'
Assert ($store.Apply((Event s unknown ($base + 5) $epoch a), $now)) 'First resolution was not accepted.'
Assert ((Status $store s $now) -eq 'waiting') 'One resolution hid another open approval.'
Assert ($store.Apply((Event other started ($base + 1) $epoch '' other_turn), $now)) 'Other session start failed.'
Assert ((Status $store other $now) -eq 'active') 'Another session inherited the waiting state.'
Assert ($store.Apply((Event s unknown ($base + 7) $epoch b), $now)) 'Second resolution was not accepted.'
Assert ((Status $store s $now) -eq 'unknown') 'Resolution invented a confirmed status.'

$reordered = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($reordered.Apply((Event s started ($base + 1) $epoch '' turn_1), $now)) 'Reordered start failed.'
Assert ($reordered.Apply((Event s unknown ($base + 5) $epoch a), $now)) 'Early resolution failed.'
Assert (-not $reordered.Apply((Event s waiting ($base + 2) $epoch a), $now)) 'Old request resurrected after resolution.'
Assert ($reordered.Apply((Event s active ($base + 4) $epoch), $now)) 'Older ordinary event was not examined.'
Assert ((Status $reordered s $now) -eq 'unknown') 'An old tool event revived a resolved request.'

$ended = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($ended.Apply((Event s started ($base + 1) $epoch '' turn_1), $now)) 'Turn start failed.'
Assert ($ended.Apply((Event s idle ($base + 3) $epoch '' turn_1), $now)) 'Turn end failed.'
Assert (-not $ended.Apply((Event s active ($base + 2) $epoch), $now)) 'An older tool event revived a finished turn.'
Assert (@($ended.Snapshot($now)).Count -eq 0) 'Old activity created a task after a known end.'

$conflict = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($conflict.Apply((Event s started ($base + 1) $epoch '' turn_1), $now)) 'Conflicting turn start failed.'
Assert ($conflict.Apply((Event s waiting ($base + 2) $epoch a), $now)) 'Conflicting request failed.'
Assert ($conflict.Apply((Event s idle ($base + 3) $epoch '' turn_1), $now)) 'Conflicting end failed.'
Assert ((Status $conflict s $now) -eq 'unknown') 'An unresolved approval was reported finished.'

$bounded = [AITaskMonitor.ExternalProviders.StateStore]::new()
for ($index = 0; $index -lt 64; $index++) {
    Assert ($bounded.Apply((Event s waiting ($base + 10 + 2 * $index) $epoch ('r' + $index)), $now)) 'Bounded request failed.'
    Assert ($bounded.Apply((Event s unknown ($base + 11 + 2 * $index) $epoch ('r' + $index)), $now)) 'Bounded resolution failed.'
}
Assert ($bounded.Apply((Event s waiting ($base + 500) $epoch overflow), $now)) 'Overflow was not handled.'
Assert ((Status $bounded s $now) -eq 'unknown') 'Request overflow produced a confirmed status.'

$barrier = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($barrier.Apply((Event s started ($base + 1) $epoch '' turn_1), $now)) 'Barrier setup failed.'
Assert ($barrier.Apply((Event s gap ($base + 2) $epoch), $now)) 'Gap failed.'
Assert ((Status $barrier s $now) -eq 'unknown') 'Gap did not invalidate activity.'
Assert (-not $barrier.Apply((Event s started ($base + 1) $epoch '' turn_1), $now)) 'Pre-gap event was accepted.'
$late = Clock
Assert (-not $barrier.Apply((Event s started $late $epoch '' turn_2), $now)) 'Old observer was accepted after a gap.'
Assert ((Status $barrier s $now) -eq 'unknown') 'Existing task must remain unconfirmed after a gap.'
$newEpoch = Clock
Start-Sleep -Milliseconds 2
$newTick = Clock
Assert ($barrier.Apply((Event s started $newTick $newEpoch '' turn_1), $now)) 'New observer did not recover.'
Assert ((Status $barrier s $now) -eq 'active') 'New observer did not restore activity.'
Assert (-not $barrier.Apply((Event s active (Clock) $epoch), $now)) 'Old observer displaced a recovered generation.'

$alreadyRunning = [AITaskMonitor.ExternalProviders.StateStore]::new()
$runningEpoch = Clock; $priorTick = Clock
Start-Sleep -Milliseconds 2
$runningScope = 'f' * 32; $runningSession = $runningScope + '_session'
$alreadyRunning.RetainProviders(@('hermes'))
$alreadyRunning.RetainSessionScopes('hermes', @($runningScope))
Assert (-not $alreadyRunning.Apply((Event $runningSession started $priorTick $runningEpoch '' turn_1), $now)) 'Pre-connection event was accepted.'
foreach ($kind in @('started', 'waiting', 'idle', 'failed', 'interrupted', 'completed', 'unknown')) {
    Start-Sleep -Milliseconds 1
    Assert (-not $alreadyRunning.Apply((Event $runningSession $kind (Clock) $runningEpoch), $now)) 'Old observer event was accepted after startup.'
    Assert (@($alreadyRunning.Snapshot($now)).Count -eq 0) 'Old observer created a task after startup.'
}
Start-Sleep -Milliseconds 2
$restartedEpoch = Clock; $restartedTick = Clock
Assert ($alreadyRunning.Apply((Event $runningSession started $restartedTick $restartedEpoch '' turn_1), $now)) 'Restarted observer was not accepted.'
Assert ((Status $alreadyRunning $runningSession $now) -eq 'active') 'Restarted observer did not restore the real status.'

$newRequest = [AITaskMonitor.ExternalProviders.StateStore]::new()
$requestOldEpoch = Clock
Start-Sleep -Milliseconds 1
$newRequest.RetainProviders(@('hermes'))
Start-Sleep -Milliseconds 1
Assert (-not $newRequest.Apply((Event s active (Clock) $requestOldEpoch), $now)) 'Old observer event was accepted.'
Assert (@($newRequest.Snapshot($now)).Count -eq 0) 'Old observer created a task.'
$requestNewEpoch = Clock; $requestTick = Clock
Assert ($newRequest.Apply((Event s waiting $requestTick $requestNewEpoch request_a), $now)) 'New generation request failed.'
Assert ((Status $newRequest s $now) -eq 'waiting') 'A new generation could not report its real request.'

$terminalOnly = [AITaskMonitor.ExternalProviders.StateStore]::new()
$terminalEpoch = Clock
Start-Sleep -Milliseconds 2
$terminalOnly.RetainProviders(@('hermes'))
Assert (-not $terminalOnly.Apply((Event unseen idle (Clock) $terminalEpoch), $now)) 'Old idle event created an unseen task.'
Assert (@($terminalOnly.Snapshot($now)).Count -eq 0) 'Unseen terminal event appeared in the task list.'

$alreadyClosed = [AITaskMonitor.ExternalProviders.StateStore]::new()
$closedEpoch = Clock; $closedStart = Clock
Assert ($alreadyClosed.Apply((Event s started $closedStart $closedEpoch '' turn_closed), $now)) 'Closed-task setup failed.'
Start-Sleep -Milliseconds 1
Assert ($alreadyClosed.Apply((Event s idle (Clock) $closedEpoch '' turn_closed), $now)) 'Confirmed end failed.'
$alreadyClosed.MarkProviderGap('hermes')
Start-Sleep -Milliseconds 1
Assert (-not $alreadyClosed.Apply((Event s active (Clock) $closedEpoch), $now)) 'Old observer revived a confirmed closed task.'
Assert (@($alreadyClosed.Snapshot($now)).Count -eq 0) 'Confirmed closed task reappeared.'

$duplicate = [AITaskMonitor.ExternalProviders.StateStore]::new()
Start-Sleep -Milliseconds 1
$duplicate.RetainProviders(@('hermes'))
Start-Sleep -Milliseconds 1
$duplicateEpoch = Clock; $duplicateTick = Clock
$duplicateEvent = Event s started $duplicateTick $duplicateEpoch '' turn_duplicate
Assert ($duplicate.Apply($duplicateEvent, $now)) 'New observer activity was not retained.'
Assert ((Status $duplicate s $now) -eq 'active') 'New observer did not establish activity.'
Assert (-not $duplicate.Apply($duplicateEvent, $now.AddMinutes(10))) 'Duplicate event was accepted.'
Assert ((@($duplicate.Snapshot($now.AddMinutes(10)))[0]).Updated -eq $now) 'Duplicate changed the last update time.'

$lateStarted = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($lateStarted.Apply((Event s started ($base + 1) $epoch '' turn_old), $now)) 'Late-start setup failed.'
Assert ($lateStarted.Apply((Event s idle ($base + 2) $epoch '' turn_old), $now)) 'Known turn end failed.'
Assert (-not $lateStarted.Apply((Event s started ($base + 3) $epoch '' turn_old), $now)) 'Late start revived a finished turn.'
Assert (-not $lateStarted.Apply((Event s active ($base + 4) $epoch '' turn_old), $now)) 'Late tool revived a finished turn.'
Assert (-not $lateStarted.Apply((Event s waiting ($base + 5) $epoch request_a turn_old), $now)) 'Late wait revived a finished turn.'
Assert (-not $lateStarted.Apply((Event s idle ($base + 6) $epoch), $now)) 'Unidentified terminal event revived a closed turn.'
Assert (@($lateStarted.Snapshot($now)).Count -eq 0) 'A finished turn reappeared.'

$newTurnUnknown = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($newTurnUnknown.Apply((Event s started ($base + 1) $epoch '' turn_old), $now)) 'Old-turn setup failed.'
Assert ($newTurnUnknown.Apply((Event s idle ($base + 2) $epoch '' turn_old), $now)) 'Old-turn end failed.'
Assert ($newTurnUnknown.Apply((Event s started ($base + 3) $epoch '' turn_new), $now)) 'New turn did not start.'
Assert ($newTurnUnknown.Apply((Event s idle ($base + 4) $epoch), $now)) 'Unidentified terminal was not handled.'
Assert ((Status $newTurnUnknown s $now) -eq 'unknown') 'Unidentified terminal hid a potentially active new turn.'

$terminalFirst = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($terminalFirst.Apply((Event s idle ($base + 2) $epoch '' turn_old), $now)) 'Terminal-first event failed.'
Assert (-not $terminalFirst.Apply((Event s started ($base + 3) $epoch '' turn_old), $now)) 'Terminal-first turn was revived.'
Assert (@($terminalFirst.Snapshot($now)).Count -eq 0) 'Terminal-first turn became active.'

$terminalAfterConnect = [AITaskMonitor.ExternalProviders.StateStore]::new()
$terminalAfterConnect.RetainProviders(@('hermes'))
Start-Sleep -Milliseconds 2
$connectedEpoch = Clock; $connectedTick = Clock
Assert ($terminalAfterConnect.Apply((Event unseen idle $connectedTick $connectedEpoch '' turn_closed), $now)) 'Connected terminal-first event failed.'
Assert (@($terminalAfterConnect.Snapshot($now)).Count -eq 0) 'Connected terminal-first event created a visible task.'
Start-Sleep -Milliseconds 1
Assert (-not $terminalAfterConnect.Apply((Event unseen started (Clock) $connectedEpoch '' turn_closed), $now)) 'Delayed start revived a connected terminal-first turn.'
Assert (@($terminalAfterConnect.Snapshot($now)).Count -eq 0) 'Delayed start made the closed turn visible.'
Start-Sleep -Milliseconds 1
Assert ($terminalAfterConnect.Apply((Event unseen started (Clock) $connectedEpoch '' turn_new), $now)) 'A different new turn was not accepted.'
Assert ((Status $terminalAfterConnect unseen $now) -eq 'active') 'A different new turn did not become active.'

$existingUnknown = [AITaskMonitor.ExternalProviders.StateStore]::new()
$existingUnknown.RetainProviders(@('hermes'))
Start-Sleep -Milliseconds 1
$existingOldEpoch = Clock
Assert ($existingUnknown.Apply((Event s idle (Clock) $existingOldEpoch), $now)) 'Existing unconfirmed task setup failed.'
$existingNewEpoch = Clock; $existingEndTick = Clock
Assert ($existingUnknown.Apply((Event s idle $existingEndTick $existingNewEpoch '' turn_closed), $now)) 'Existing task terminal was not handled.'
Assert ((Status $existingUnknown s $now) -eq 'unknown') 'Terminal-first rule hid an already observed unconfirmed task.'

$terminalArrivesLate = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($terminalArrivesLate.Apply((Event s started ($base + 3) $epoch '' turn_old), $now)) 'Delayed-callback setup failed.'
Assert ($terminalArrivesLate.Apply((Event s idle ($base + 2) $epoch '' turn_old), $now)) 'Older terminal evidence was discarded.'
Assert (-not $terminalArrivesLate.Apply((Event s started ($base + 4) $epoch '' turn_old), $now)) 'Delayed callback revived the closed turn.'
Assert (@($terminalArrivesLate.Snapshot($now)).Count -eq 0) 'Older terminal evidence did not close its turn.'

$differentTurn = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($differentTurn.Apply((Event s started ($base + 1) $epoch '' turn_old), $now)) 'Old turn did not start.'
Assert ($differentTurn.Apply((Event s started ($base + 2) $epoch '' turn_new), $now)) 'New turn did not start.'
Assert ($differentTurn.Apply((Event s idle ($base + 3) $epoch '' turn_old), $now)) 'Old turn end was not recorded.'
Assert ((Status $differentTurn s $now) -eq 'active') 'Old end hid a new active turn.'
Assert (-not $differentTurn.Apply((Event s started ($base + 4) $epoch '' turn_old), $now)) 'Old turn revived after a new turn.'
Assert ((Status $differentTurn s $now) -eq 'active') 'Old turn changed the new turn status.'

$newToolTurn = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($newToolTurn.Apply((Event s started ($base + 1) $epoch '' old), $now)) 'Old tool-turn setup failed.'
Assert ($newToolTurn.Apply((Event s idle ($base + 2) $epoch '' old), $now)) 'Old tool-turn end failed.'
Assert ($newToolTurn.Apply((Event s active ($base + 3) $epoch '' new), $now)) 'New tool activity failed.'
Assert ((Status $newToolTurn s $now) -eq 'active') 'New tool turn was not active.'
Assert ($newToolTurn.Apply((Event s idle ($base + 4) $epoch '' new), $now)) 'New tool turn end failed.'
Assert (@($newToolTurn.Snapshot($now)).Count -eq 0) 'New tool turn did not close.'

$ambiguousTool = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($ambiguousTool.Apply((Event s started ($base + 1) $epoch '' current), $now)) 'Ambiguous tool setup failed.'
Assert ($ambiguousTool.Apply((Event s active ($base + 2) $epoch '' other), $now)) 'Ambiguous tool event failed.'
Assert ((Status $ambiguousTool s $now) -eq 'unknown') 'Tool from an uncorrelated turn was confirmed.'

$noTurn = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($noTurn.Apply((Event s idle ($base + 1) $epoch), $now)) 'Unknown terminal event failed.'
Assert ((Status $noTurn s $now) -eq 'unknown') 'Terminal event without turn was confirmed.'
Assert ($noTurn.Apply((Event s active ($base + 2) $epoch), $now)) 'Ambiguous activity was not handled.'
Assert ((Status $noTurn s $now) -eq 'unknown') 'Activity without a turn was confirmed.'

$turnLimit = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert ($turnLimit.Apply((Event s started ($base + 1) $epoch '' current_turn), $now)) 'Turn-limit setup failed.'
for ($index = 0; $index -lt 65; $index++) {
    Assert ($turnLimit.Apply((Event s idle ($base + 10 + $index) $epoch '' ('past' + $index)), $now)) 'Past turn was not handled.'
}
Assert ((Status $turnLimit s $now) -eq 'unknown') 'Terminal-turn overflow left a confirmed status.'
Assert ($turnLimit.Apply((Event s active ($base + 100) $epoch '' current_turn), $now)) 'Overflow activity was not handled.'
Assert ((Status $turnLimit s $now) -eq 'unknown') 'Overflow allowed confirmed activity.'

$reconnect = [AITaskMonitor.ExternalProviders.StateStore]::new()
$reconnect.RetainProviders(@('hermes'))
$oldEpoch = Clock
Start-Sleep -Milliseconds 2
$oldTick = Clock
Assert ($reconnect.Apply((Event s started $oldTick $oldEpoch '' turn_1), $now)) 'Initial connected start failed.'
$reconnect.RetainProviders(@())
$reconnect.RetainProviders(@('hermes'))
Assert (-not $reconnect.Apply((Event s started (Clock) $oldEpoch '' turn_2), $now)) 'Old observer revived after reconnect.'
Assert (@($reconnect.Snapshot($now)).Count -eq 0) 'Old observer recreated a task after reconnect.'

$scoped = [AITaskMonitor.ExternalProviders.StateStore]::new()
$scopeA = 'a' * 32; $scopeB = 'b' * 32
$sessionA = $scopeA + '_s'; $sessionB = $scopeB + '_s'
$scoped.RetainProviders(@('hermes'))
$scoped.RetainSessionScopes('hermes', @($scopeA, $scopeB))
Start-Sleep -Milliseconds 2
$scopeEpoch = Clock; $scopeTick = Clock
Assert ($scoped.Apply((Event $sessionA started $scopeTick $scopeEpoch '' turn_a), $now)) 'First profile did not start.'
Assert ($scoped.Apply((Event $sessionB started $scopeTick $scopeEpoch '' turn_b), $now)) 'Second profile did not start.'
$scoped.MarkSessionScopesGap('hermes', @($scopeA))
Assert ((Status $scoped $sessionA $now) -eq 'unknown') 'Unavailable profile stayed confirmed.'
Assert ((Status $scoped $sessionB $now) -eq 'active') 'Healthy profile was invalidated.'
Assert (-not $scoped.Apply((Event $sessionA active (Clock) $scopeEpoch), $now)) 'Old unavailable-profile observer was accepted.'
Assert ($scoped.Apply((Event $sessionB active (Clock) $scopeEpoch), $now)) 'Healthy observer was rejected.'
$scoped.MarkSessionScopesGap('hermes', @())
Start-Sleep -Milliseconds 2
$freshEpoch = Clock; $freshTick = Clock
Assert ($scoped.Apply((Event $sessionA started $freshTick $freshEpoch '' turn_fresh), $now)) 'New profile observer did not recover.'
Assert ((Status $scoped $sessionA $now) -eq 'active') 'Recovered profile did not report activity.'
$scoped.RetainSessionScopes('hermes', @($scopeB))
$scoped.RetainSessionScopes('hermes', @($scopeA, $scopeB))
Assert (-not $scoped.Apply((Event $sessionA active (Clock) $freshEpoch), $now)) 'Removed profile revived from an old observer.'

$asyncScope = [AITaskMonitor.ExternalProviders.StateStore]::new()
$asyncScope.RetainProviders(@('hermes'))
$preScanEpoch = Clock
Start-Sleep -Milliseconds 1
$asyncScope.RetainSessionScopes('hermes', @($scopeA))
Assert (-not $asyncScope.Apply((Event $sessionA started (Clock) $preScanEpoch '' before_scan), $now)) 'Hermes started before scope authorization was accepted.'
Assert (@($asyncScope.Snapshot($now)).Count -eq 0) 'Pre-scan observer created a task.'
Start-Sleep -Milliseconds 1
$postScanEpoch = Clock; $postScanTick = Clock
Assert ($asyncScope.Apply((Event $sessionA started $postScanTick $postScanEpoch '' after_scan), $now)) 'Hermes started after scope authorization was rejected.'
Assert ((Status $asyncScope $sessionA $now) -eq 'active') 'Post-scan observer did not report activity.'

$unsupported = [AITaskMonitor.ExternalProviders.EventParser]::Parse('{"version":1,"provider":"hermes","session":"s","kind":"active"}')
$legacy = [AITaskMonitor.ExternalProviders.StateStore]::new()
Assert (-not $legacy.Apply($unsupported, $now)) 'Event without a monotonic timestamp was accepted.'
Assert (@($legacy.Snapshot($now)).Count -eq 0) 'Untimed event created a task.'
foreach ($invalid in @(
    '{"version":1,"provider":"hermes","session":"s","kind":"waiting","tick":true,"epoch":1,"request":"a"}',
    '{"version":1,"provider":"hermes","session":"s","kind":"waiting","tick":1,"epoch":2,"request":"a"}',
    '{"version":1,"provider":"hermes","session":"s","kind":"active","tick":2,"epoch":1,"request":"a"}',
    '{"version":1,"provider":"opencode","session":"s","kind":"active","tick":2,"epoch":1}'
)) { Assert ($null -eq [AITaskMonitor.ExternalProviders.EventParser]::Parse($invalid)) 'Invalid metadata was accepted.' }

# Old or legacy gap frames must never invalidate an observer started after a barrier.
$gapGlobal = [AITaskMonitor.ExternalProviders.StateStore]::new()
$gapGlobal.RetainProviders(@('hermes'))
$oldGapEpoch = Clock
Start-Sleep -Milliseconds 1
$gapGlobal.RetainProviders(@())
$gapGlobal.RetainProviders(@('hermes'))
Start-Sleep -Milliseconds 1
$newGapEpoch = Clock
Assert ($gapGlobal.Apply((Event s started (Clock) $newGapEpoch '' current), $now)) 'New global observer did not start.'
Assert (-not $gapGlobal.Apply((Event s gap (Clock) $oldGapEpoch), $now)) 'Old global gap was accepted.'
Assert (-not $gapGlobal.Apply((Event s gap ((Clock) + 3000000000) $oldGapEpoch), $now)) 'Old future gap was accepted.'
$untaggedGap = [AITaskMonitor.ExternalProviders.EventParser]::Parse('{"version":1,"provider":"hermes","session":"s","kind":"gap"}')
Assert ($null -ne $untaggedGap) 'Untagged legacy gap should parse without triggering a channel gap.'
Assert (-not $gapGlobal.Apply($untaggedGap, $now)) 'Gap without an epoch was accepted.'
Assert ((Status $gapGlobal s $now) -eq 'active') 'Old or untagged gap invalidated the new observer.'

# Scope reconnect is separate from a provider reconnect; old unknown-scope gaps are stale too.
$gapScoped = [AITaskMonitor.ExternalProviders.StateStore]::new()
$gapScoped.RetainProviders(@('hermes'))
$gapScoped.RetainSessionScopes('hermes', @($scopeA, $scopeB))
Start-Sleep -Milliseconds 1
$preReconnectEpoch = Clock
Assert ($gapScoped.Apply((Event $sessionA started (Clock) $preReconnectEpoch '' old_a), $now)) 'Old scope observer did not start.'
Assert ($gapScoped.Apply((Event $sessionB started (Clock) $preReconnectEpoch '' old_b), $now)) 'Other scope observer did not start.'
$gapScoped.RetainSessionScopes('hermes', @($scopeB))
$gapScoped.RetainSessionScopes('hermes', @($scopeA, $scopeB))
Start-Sleep -Milliseconds 1
$postReconnectEpoch = Clock
Assert ($gapScoped.Apply((Event $sessionA started (Clock) $postReconnectEpoch '' new_a), $now)) 'New scope observer did not start.'
Assert (-not $gapScoped.Apply((Event ($scopeA + '_unknown') gap (Clock) $preReconnectEpoch), $now)) 'Old unknown-scope gap was accepted.'
Assert (-not $gapScoped.Apply((Event $sessionA gap ((Clock) + 3000000000) $preReconnectEpoch), $now)) 'Old future scope gap was accepted.'
Assert ((Status $gapScoped $sessionA $now) -eq 'active') 'Old scope gap invalidated the restarted observer.'
Assert ((Status $gapScoped $sessionB $now) -eq 'active') 'Old scope gap invalidated another profile.'
Assert ($gapScoped.Apply((Event ($scopeA + '_unknown') gap (Clock) $postReconnectEpoch), $now)) 'Current scope gap was rejected.'
Assert ((Status $gapScoped $sessionA $now) -eq 'unknown') 'Current gap did not invalidate its profile.'
Assert ((Status $gapScoped $sessionB $now) -eq 'active') 'Current gap invalidated a healthy profile.'
Assert (-not $gapScoped.Apply((Event $sessionA active (Clock) $postReconnectEpoch '' new_a), $now)) 'Observer revived its profile after a gap.'
Assert ($gapScoped.Apply((Event $sessionB active (Clock) $preReconnectEpoch '' old_b), $now)) 'Healthy profile stopped reporting after another profile gap.'
Start-Sleep -Milliseconds 1
$afterScopeGapEpoch = Clock
Assert ($gapScoped.Apply((Event $sessionA started (Clock) $afterScopeGapEpoch '' recovered), $now)) 'Restarted scope did not recover after a gap.'
Assert ((Status $gapScoped $sessionA $now) -eq 'active') 'Restarted scope stayed unknown.'
Write-Output 'Hermes ordering, approvals, observer generations, and reconnect checks passed.'
