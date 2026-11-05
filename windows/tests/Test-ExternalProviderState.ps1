$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path (Join-Path $PSScriptRoot '../app/integrations/ProviderEventState.cs') -ReferencedAssemblies System.Web.Extensions

function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Parse([string]$json) { return [AITaskMonitor.ExternalProviders.EventParser]::Parse($json) }
function Apply($store, [string]$json, $time) {
    $event = Parse $json
    Assert ($null -ne $event) "Expected a valid event: $json"
    Assert ($store.Apply($event, $time)) 'Expected the state update to succeed.'
}

$now = [DateTimeOffset]::Parse('2026-11-04T10:00:00Z')
$store = [AITaskMonitor.ExternalProviders.StateStore]::new()
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"started","turn":"1"}' $now
Apply $store '{"version":1,"provider":"opencode","session":"shared","kind":"active"}' $now
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"plan","steps":[{"title":"One","status":"done"},{"title":"Two","status":"active"}]}' $now
$tasks = @($store.Snapshot($now))
Assert ($tasks.Count -eq 2) 'Different providers must not collide when they reuse a session ID.'
$deep = @($tasks | Where-Object Provider -eq 'deepseek')[0]
Assert ($deep.Status -eq 'active' -and $deep.PlanConfirmed -and $deep.Steps.Count -eq 2) 'Expected an active, confirmed plan.'
Assert ($deep.Steps[0].status -eq 'done' -and $deep.Steps[1].status -eq 'active') 'Incorrect step state.'
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"tool_started","call":"call_1","action":"command"}' $now
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"tool_started","call":"call_2","action":"edit"}' $now
Assert ((@($store.Snapshot($now) | Where-Object Provider -eq 'deepseek')[0]).Activity -eq 'edit') 'The latest running action was not selected.'
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"tool_finished","call":"call_2"}' $now
Assert ((@($store.Snapshot($now) | Where-Object Provider -eq 'deepseek')[0]).Activity -eq 'command') 'Completing a concurrent action lost the remaining action.'
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"tool_finished","call":"call_1"}' $now
Assert (-not (@($store.Snapshot($now) | Where-Object Provider -eq 'deepseek')[0]).Activity) 'Completed actions must not remain current.'

Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"waiting"}' $now.AddSeconds(1)
Assert ((@($store.Snapshot($now.AddSeconds(1)) | Where-Object Provider -eq 'deepseek')[0]).Status -eq 'waiting') 'Approval must be shown as waiting.'
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"unknown"}' $now.AddSeconds(2)
Assert ((@($store.Snapshot($now.AddSeconds(2)) | Where-Object Provider -eq 'deepseek')[0]).Status -eq 'unknown') 'Resolution must not claim active work.'
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"completed"}' $now.AddSeconds(3)
Assert (@($store.Snapshot($now.AddSeconds(3))).Count -eq 1) 'Finished tasks must not remain in the active list.'
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"started","turn":"2"}' $now.AddSeconds(4)
$resumed = @($store.Snapshot($now.AddSeconds(4)) | Where-Object Provider -eq 'deepseek')[0]
Assert (-not $resumed.PlanConfirmed -and $resumed.Steps.Count -eq 2) 'A previous turn plan must be retained as unconfirmed.'
Assert ($resumed.StartKey -ne $deep.StartKey) 'A resumed turn must get a new focus key.'
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"plan","steps":[]}' $now.AddSeconds(5)
Assert ((@($store.Snapshot($now.AddSeconds(5)) | Where-Object Provider -eq 'deepseek')[0]).Steps.Count -eq 0) 'An empty published plan must clear the old plan.'
Apply $store '{"version":1,"provider":"deepseek","session":"shared","kind":"plan","steps":[{"title":"One","status":"done"}]}' $now.AddSeconds(5)

Apply $store '{"version":1,"provider":"opencode","session":"shared","kind":"gap"}' $now.AddSeconds(5)
Assert ((@($store.Snapshot($now.AddSeconds(5)) | Where-Object Provider -eq 'opencode')[0]).Status -eq 'unknown') 'A source gap must invalidate that source.'
Assert ((@($store.Snapshot($now.AddSeconds(5)) | Where-Object Provider -eq 'deepseek')[0]).Status -eq 'active') 'A source gap must not invalidate another provider.'
Assert ((@($store.Snapshot($now.AddSeconds(5)) | Where-Object Provider -eq 'deepseek')[0]).PlanConfirmed) 'A source gap must not invalidate another provider plan.'
$store.MarkGap()
Assert (@($store.Snapshot($now.AddSeconds(5)) | Where-Object Status -ne 'unknown').Count -eq 0) 'An unscoped channel gap must invalidate all active claims.'
Assert (-not (@($store.Snapshot($now.AddSeconds(5)) | Where-Object Provider -eq 'deepseek')[0]).PlanConfirmed) 'A transport gap must invalidate old plan confirmation.'
$freq = [System.Diagnostics.Stopwatch]::Frequency
$ticks = [System.Diagnostics.Stopwatch]::GetTimestamp()
$epoch = [long]([math]::Floor($ticks / $freq) * 1000000000 + (($ticks % $freq) * (1000000000.0 / $freq)))
Start-Sleep -Milliseconds 2
$ticks = [System.Diagnostics.Stopwatch]::GetTimestamp()
$first = [long]([math]::Floor($ticks / $freq) * 1000000000 + (($ticks % $freq) * (1000000000.0 / $freq)))
Apply $store ('{"version":1,"provider":"hermes","session":"session_1","kind":"started","turn":"turn_1","tick":' + $first + ',"epoch":' + $epoch + '}') $now
Assert ((@($store.Snapshot($now.AddMinutes(30)) | Where-Object Provider -eq 'hermes')[0]).Status -eq 'unknown') 'Stale activity must become unconfirmed.'
$ticks = [System.Diagnostics.Stopwatch]::GetTimestamp()
$second = [long]([math]::Floor($ticks / $freq) * 1000000000 + (($ticks % $freq) * (1000000000.0 / $freq)))
Apply $store ('{"version":1,"provider":"hermes","session":"session_1","kind":"plan","steps":[],"tick":' + $second + ',"epoch":' + $epoch + '}') $now.AddHours(3)
Assert ((@($store.Snapshot($now.AddHours(3)) | Where-Object Provider -eq 'hermes')[0]).Status -eq 'unknown') 'A plan update alone cannot revive stale activity.'

$kimi=[AITaskMonitor.ExternalProviders.StateStore]::new()
foreach($kind in @('started','waiting','interrupted','active','completed')){
    Apply $kimi ('{"version":1,"provider":"kimi","session":"one","kind":"'+$kind+'"}') $now
    $task=@($kimi.Snapshot($now))[0]
    Assert ($task.Status -eq 'unknown' -and -not $task.PlanConfirmed -and $task.Steps.Count -eq 0) 'Kimi events must never assert work, waiting or completion.'
}

$heartbeat = [AITaskMonitor.ExternalProviders.StateStore]::new()
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"heartbeat"}' $now
Assert (@($heartbeat.Snapshot($now)).Count -eq 0) 'Heartbeat must not create a task after monitor startup.'
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"tool_started","call":"cmd","action":"command"}' $now
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"plan","steps":[{"title":"One","status":"active"}]}' $now
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"heartbeat"}' $now.AddMinutes(29)
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"heartbeat"}' $now.AddMinutes(30)
$long = @($heartbeat.Snapshot($now.AddMinutes(30)))[0]
Assert ($long.Status -eq 'active' -and $long.LongRunning -and $long.Activity -eq 'command') 'A fresh heartbeat must identify a long-running reachable agent.'
Assert ($long.Updated -eq $now -and $long.PlanConfirmed) 'Heartbeats must not change event time, ordering or plan.'
$lost = @($heartbeat.Snapshot($now.AddMinutes(33).AddSeconds(1)))[0]
Assert ($lost.Status -eq 'unknown' -and -not $lost.LongRunning -and -not $lost.PlanConfirmed) 'A lost heartbeat must remove activity and plan confidence.'
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"heartbeat"}' $now.AddMinutes(34)
Assert ((@($heartbeat.Snapshot($now.AddMinutes(34)))[0]).Status -eq 'unknown') 'A late heartbeat must not revive an unconfirmed task.'
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"active"}' $now.AddMinutes(35)
Assert (-not (@($heartbeat.Snapshot($now.AddMinutes(35)))[0]).PlanConfirmed) 'New activity alone must not reconfirm an old plan.'
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"gap"}' $now.AddMinutes(35)
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"heartbeat"}' $now.AddMinutes(35)
Assert ((@($heartbeat.Snapshot($now.AddMinutes(35)))[0]).Status -eq 'unknown') 'Heartbeat must not revive a task after a transport gap.'
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"completed"}' $now.AddMinutes(36)
Apply $heartbeat '{"version":1,"provider":"opencode","session":"long","kind":"heartbeat"}' $now.AddMinutes(36)
Assert (@($heartbeat.Snapshot($now.AddMinutes(36))).Count -eq 0) 'Heartbeat must not revive completed tasks.'

$waitingStore = [AITaskMonitor.ExternalProviders.StateStore]::new()
Apply $waitingStore '{"version":1,"provider":"deepseek","session":"wait","kind":"waiting"}' $now
Apply $waitingStore '{"version":1,"provider":"deepseek","session":"wait","kind":"heartbeat"}' $now.AddMinutes(29)
$waiting = @($waitingStore.Snapshot($now.AddMinutes(30)))[0]
Assert ($waiting.Status -eq 'waiting' -and -not $waiting.LongRunning) 'A reachable approval request must remain waiting, never long-running work.'
Assert ($waiting.StartKey -and $waiting.Started -eq $now) 'A newly observed approval request must retain a focus key.'

foreach ($invalid in @(
    '{"version":1,"provider":"opencode","session":"../../bad","kind":"active"}',
    '{"version":1,"provider":"opencode","session":"one","kind":"active","prompt":"secret"}',
    '{"version":1,"provider":"opencode","session":"one","kind":"plan","steps":[{"title":"One","status":"cancelled"}]}',
    '{"version":1,"provider":"opencode","session":"one","kind":"active","steps":[]}',
    '{"version":1,"provider":"opencode","session":"one","kind":"tool_started","call":"c","action":"secret"}',
    '{"version":1,"provider":"opencode","session":"one","kind":"heartbeat","turn":"1"}',
    '{"version":2,"provider":"opencode","session":"one","kind":"active"}'
)) { Assert ($null -eq (Parse $invalid)) 'Invalid or private event was accepted.' }
Assert ($null -eq (Parse ('x' * 65537))) 'Oversized input was accepted.'

$filled = [AITaskMonitor.ExternalProviders.StateStore]::new()
for ($i = 0; $i -lt 256; $i++) {
    $entry = Parse ('{"version":1,"provider":"deepseek","session":"s' + $i + '","kind":"active"}')
    Assert ($filled.Apply($entry, $now)) 'Could not populate bounded fixture.'
}
$overflow = Parse '{"version":1,"provider":"deepseek","session":"overflow","kind":"active"}'
Assert (-not $filled.Apply($overflow, $now)) 'An all-active store must fail closed on overflow.'
Assert (@($filled.Snapshot($now) | Where-Object Status -ne 'unknown').Count -eq 0) 'Overflow must invalidate activity claims.'
Write-Output 'External provider state fixtures passed.'
