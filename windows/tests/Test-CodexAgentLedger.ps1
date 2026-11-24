$ErrorActionPreference = 'Stop'
$initialUserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$initialMachinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')

try {
 Add-Type -Path (Join-Path $PSScriptRoot '..\app\CodexAgentLedger.cs')
 function Require([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
 function Evidence($ledger, [guid]$root, [string]$run, [guid]$parent, [guid]$child,
                   [string]$childRun, [long]$generation, [string]$kind,
                   [bool]$identity = $true, [bool]$chain = $true, [bool]$verified = $true) {
  $eventKind = [Enum]::Parse([AITaskMonitor.CodexAgentLedger.EvidenceKind], $kind)
  $item = [AITaskMonitor.CodexAgentLedger.Evidence]::new($root, $run, $parent, $child, $childRun,
      $generation, $eventKind, $identity, $chain, $verified)
  return $ledger.Apply($item).ToString()
 }
 function CheckCount($ledger, [guid]$root, [string]$run, [int]$expected, [bool]$complete, [string]$message) {
  $snapshot = $ledger.Snapshot($root, $run)
  Require ($snapshot.IsTracked -and $snapshot.KnownUnclosedCount -eq $expected -and $snapshot.IsComplete -eq $complete) $message
 }

 $root = [guid]'10000000-0000-0000-0000-000000000001'
 $otherRoot = [guid]'10000000-0000-0000-0000-000000000002'
 $childA = [guid]'20000000-0000-0000-0000-000000000001'
 $childB = [guid]'20000000-0000-0000-0000-000000000002'
 $childC = [guid]'20000000-0000-0000-0000-000000000003'

 # Unknown and partial sources cannot establish an exact empty list.
 $ledger = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require (-not $ledger.TrackTask($root, 'task-lifetime-1', $false, $true)) 'An unverified task identity was accepted.'
 $unknown = $ledger.Snapshot($root, 'task-lifetime-1')
 Require (-not $unknown.IsTracked -and -not $unknown.IsComplete) 'An untracked task was reported complete.'
 Require ($ledger.TrackTask($root, 'task-lifetime-1', $true, $false)) 'A verified task was rejected.'
 CheckCount $ledger $root 'task-lifetime-1' 0 $false 'Unverified coverage was presented as an exact zero.'
 Require ($ledger.TrackTask($root, 'task-lifetime-1', $true, $true)) 'An existing task was rejected.'
 CheckCount $ledger $root 'task-lifetime-1' 0 $false 'A repeated registration silently repaired missing coverage.'
 Require ((Evidence $ledger $root 'task-lifetime-1' $root $childA 'agent-a-1' 1 'Observed') -eq 'Accepted') 'A verified child was not recorded.'
 Require ((Evidence $ledger $root 'task-lifetime-1' $root $childA 'agent-a-1' 1 'Observed') -eq 'NoChange') 'A duplicate child was counted twice.'
 Require ((Evidence $ledger $root 'task-lifetime-1' $childA $childB 'agent-b-1' 1 'Observed') -eq 'Accepted') 'A verified nested child was not recorded.'
 CheckCount $ledger $root 'task-lifetime-1' 2 $false 'Verified child count is incorrect.'
 Require ((Evidence $ledger $root 'task-lifetime-1' $root $childA 'agent-a-1' 1 'TurnCompleted') -eq 'NoChange') 'A completed turn changed the ledger.'
 CheckCount $ledger $root 'task-lifetime-1' 2 $false 'A completed turn reduced the count.'
 Require ($ledger.MarkSourceUnavailable($root, 'task-lifetime-1')) 'A source interruption was not recorded.'
 CheckCount $ledger $root 'task-lifetime-1' 2 $false 'A source interruption removed observed children.'
 Require ((Evidence $ledger $root 'task-lifetime-1' $root $childA 'agent-a-1' 1 'ExplicitClose') -eq 'Accepted') 'A verified ancestor closure was ignored.'
 CheckCount $ledger $root 'task-lifetime-1' 1 $false 'Closing one agent also removed a descendant without explicit closure.'

 # Unverified relationships and closures never change the count.
 $checks = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($checks.TrackTask($root, 'proofs', $true, $true)) 'The synthetic task was not tracked.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'Observed') -eq 'Accepted') 'The synthetic child was not added.'
 Require ((Evidence $checks $root 'proofs' $root $childB 'b-1' 1 'Observed' $true $false $true) -eq 'Unverified') 'An unverified parent chain was accepted.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'ExplicitClose' $true $true $false) -eq 'Unverified') 'An unverified closure was accepted.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'ExplicitClose' $false $true $true) -eq 'Unverified') 'An unverified child identity was accepted.'
 CheckCount $checks $root 'proofs' 1 $false 'Unverified evidence changed the count or hid uncertainty.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'ExplicitClose') -eq 'Accepted') 'A verified matching closure was ignored.'
 CheckCount $checks $root 'proofs' 0 $false 'A verified closure did not remove its child.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'ExplicitClose') -eq 'NoChange') 'A duplicate closure changed the count.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'Observed') -eq 'Unverified') 'An observation after closure was treated as certain.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'Restarted') -eq 'Unverified') 'A same-generation restart was treated as new.'
 CheckCount $checks $root 'proofs' 0 $false 'An ambiguous restart reopened a closed child.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-2' 2 'Restarted') -eq 'Accepted') 'A verified new incarnation was not restored.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'ExplicitClose') -eq 'IgnoredStale') 'An old closure was applied to a newer incarnation.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-1' 1 'Restarted') -eq 'IgnoredStale') 'An older restart replaced a newer incarnation.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-3' 3 'Observed') -eq 'Unverified') 'A changed incarnation was accepted without a verified restart.'
 CheckCount $checks $root 'proofs' 1 $false 'A delayed closure removed the restarted child.'
 Require ((Evidence $checks $root 'proofs' $root $childA 'a-2' 2 'ExplicitClose') -eq 'Accepted') 'The new incarnation did not close.'
 CheckCount $checks $root 'proofs' 0 $false 'The confirmed new closure was ignored.'

 # An explicit close arriving first creates a tombstone for delayed observations.
 $outOfOrder = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($outOfOrder.TrackTask($root, 'out-of-order', $true, $true)) 'The task was not tracked.'
 Require ((Evidence $outOfOrder $root 'out-of-order' $root $childA 'a-1' 1 'ExplicitClose') -eq 'Accepted') 'A verified early closure was not retained.'
 Require ((Evidence $outOfOrder $root 'out-of-order' $root $childA 'a-1' 1 'Observed') -eq 'Unverified') 'An observation after closure was treated as certain.'
 CheckCount $outOfOrder $root 'out-of-order' 0 $false 'A late observation resurrected a closed child or hid uncertainty.'

 # The same child in another task incarnation must not affect the original.
 $epochs = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($epochs.TrackTask($root, 'task-1', $true, $true)) 'The first incarnation was not tracked.'
 Require ($epochs.TrackTask($root, 'task-2', $true, $true)) 'The second incarnation was not tracked.'
 [void](Evidence $epochs $root 'task-1' $root $childA 'a-1' 1 'Observed')
 [void](Evidence $epochs $root 'task-2' $root $childA 'a-2' 2 'Observed')
 [void](Evidence $epochs $root 'task-1' $root $childA 'a-1' 1 'ExplicitClose')
 CheckCount $epochs $root 'task-1' 0 $true 'The first task closure was ignored.'
 CheckCount $epochs $root 'task-2' 1 $true 'A closure from another task incarnation removed a child.'
 Require ((Evidence $epochs $root 'task-3' $root $childA 'a-2' 2 'ExplicitClose') -eq 'NotTracked') 'An unknown task incarnation affected the ledger.'
 CheckCount $epochs $root 'task-2' 1 $true 'An unknown task incarnation changed the current count.'

 # A normal new chat turn is not a new task incarnation. An available child
 # remains counted across repeated turns and closes once for that task lifetime.
 $turns = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($turns.TrackTask($root, 'same-task-lifetime', $true, $true)) 'The multi-turn task was not tracked.'
 [void](Evidence $turns $root 'same-task-lifetime' $root $childA 'a-1' 1 'Observed')
 [void](Evidence $turns $root 'same-task-lifetime' $root $childA 'a-1' 1 'TurnCompleted')
 Require ($turns.TrackTask($root, 'same-task-lifetime', $true, $true)) 'The same task could not continue on a new turn.'
 [void](Evidence $turns $root 'same-task-lifetime' $root $childA 'a-1' 1 'Observed')
 [void](Evidence $turns $root 'same-task-lifetime' $root $childA 'a-1' 1 'TurnCompleted')
 CheckCount $turns $root 'same-task-lifetime' 1 $true 'An available agent was lost or double-counted across turns.'
 Require ((Evidence $turns $root 'same-task-lifetime' $root $childA 'a-1' 1 'ExplicitClose') -eq 'Accepted') 'The multi-turn agent did not close.'
 CheckCount $turns $root 'same-task-lifetime' 0 $true 'Closing a multi-turn agent left another copy counted.'

 # A conflicting parent must not move the child or permit a disputed close.
 $conflicts = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($conflicts.TrackTask($root, 'conflict', $true, $true)) 'The conflict test task was not tracked.'
 [void](Evidence $conflicts $root 'conflict' $root $childA 'a-1' 1 'Observed')
 Require ((Evidence $conflicts $root 'conflict' $childB $childA 'a-1' 1 'Observed') -eq 'Conflict') 'Conflicting parent claims were accepted.'
 Require ((Evidence $conflicts $root 'conflict' $root $childA 'a-1' 1 'ExplicitClose') -eq 'Conflict') 'A disputed child was removed by one conflicting claim.'
 CheckCount $conflicts $root 'conflict' 1 $false 'A conflict changed the count or remained unreported.'
 Require ((Evidence $conflicts $root 'conflict' $root $childA 'a-2' 2 'Restarted') -eq 'Accepted') 'A verified fresh incarnation did not supersede the conflict.'
 Require ((Evidence $conflicts $root 'conflict' $root $childA 'a-2' 2 'ExplicitClose') -eq 'Accepted') 'A fresh verified incarnation could not be closed.'
 CheckCount $conflicts $root 'conflict' 0 $false 'A fresh closure was ignored or old uncertainty was erased.'

 # A conflicted ancestor makes every claimed chain through it unverified.
 $ancestry = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($ancestry.TrackTask($root, 'ancestry', $true, $true)) 'The ancestry test task was not tracked.'
 [void](Evidence $ancestry $root 'ancestry' $root $childA 'a-1' 1 'Observed')
 [void](Evidence $ancestry $root 'ancestry' $childA $childB 'b-1' 1 'Observed')
 Require ((Evidence $ancestry $root 'ancestry' $childC $childA 'a-1' 1 'Observed') -eq 'Conflict') 'An ancestor conflict was not retained.'
 Require ((Evidence $ancestry $root 'ancestry' $childA $childB 'b-1' 1 'ExplicitClose') -eq 'Conflict') 'A child was removed through a disputed ancestor.'
 Require ((Evidence $ancestry $root 'ancestry' $childA $childC 'c-1' 1 'Observed') -eq 'Conflict') 'A new child was accepted through a disputed ancestor.'
 CheckCount $ancestry $root 'ancestry' 2 $false 'An ancestor conflict changed a known count or remained exact.'
 $disputed = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($disputed.TrackTask($root, 'disputed-chain', $true, $true)) 'The disputed-chain task was not tracked.'
 [void](Evidence $disputed $root 'disputed-chain' $root $childA 'a-1' 1 'Observed')
 [void](Evidence $disputed $root 'disputed-chain' $root $childC 'c-1' 1 'Observed')
 [void](Evidence $disputed $root 'disputed-chain' $childB $childC 'c-1' 1 'Observed')
 Require ((Evidence $disputed $root 'disputed-chain' $childC $childA 'a-1' 1 'Observed') -eq 'Conflict') 'A claim through a disputed ancestor was accepted.'
 Require ((Evidence $disputed $root 'disputed-chain' $root $childA 'a-1' 1 'ExplicitClose') -eq 'Conflict') 'A child with a disputed parent was silently removed.'
 CheckCount $disputed $root 'disputed-chain' 2 $false 'A disputed chain caused an unconfirmed decrement.'

 # Conflicting roots cannot both count one child as an exact verified agent.
 $roots = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($roots.TrackTask($root, 'roots', $true, $true)) 'First root not tracked.'
 Require ($roots.TrackTask($otherRoot, 'roots', $true, $true)) 'Second root not tracked.'
 [void](Evidence $roots $root 'roots' $root $childA 'a-1' 1 'Observed')
 Require ((Evidence $roots $otherRoot 'roots' $otherRoot $childA 'a-1' 1 'Observed') -eq 'Conflict') 'Two roots accepted the same child.'
 CheckCount $roots $root 'roots' 1 $false 'The original root lost its child or conflict warning.'
 CheckCount $roots $otherRoot 'roots' 0 $false 'A conflicting second root counted the child as exact.'
 Require ((Evidence $roots $root 'roots' $root $childA 'a-1' 1 'ExplicitClose') -eq 'Conflict') 'Conflicting root evidence removed a child.'

 # Reuse under a different root requires closing the old identity first and a
 # verified later restart; a delayed old closure cannot touch the new task.
 $transfer = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($transfer.TrackTask($root, 'transfer', $true, $true)) 'The old transfer root was not tracked.'
 Require ($transfer.TrackTask($otherRoot, 'transfer', $true, $true)) 'The new transfer root was not tracked.'
 [void](Evidence $transfer $root 'transfer' $root $childA 'a-1' 1 'Observed')
 [void](Evidence $transfer $root 'transfer' $root $childA 'a-1' 1 'ExplicitClose')
 Require ((Evidence $transfer $otherRoot 'transfer' $otherRoot $childA 'a-2' 2 'Restarted') -eq 'Accepted') 'A verified transfer after closure was rejected.'
 [void](Evidence $transfer $root 'transfer' $root $childA 'a-1' 1 'ExplicitClose')
 CheckCount $transfer $otherRoot 'transfer' 1 $true 'A delayed old-root closure affected the restarted child.'

 # A newly discovered cycle invalidates closure of its previously known path.
 $cycle = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($cycle.TrackTask($root, 'cycle', $true, $true)) 'The cycle test task was not tracked.'
 [void](Evidence $cycle $root 'cycle' $childB $childA 'a-1' 1 'Observed')
 Require ((Evidence $cycle $root 'cycle' $childA $childB 'b-1' 1 'Observed') -eq 'Conflict') 'A parent cycle was accepted.'
 Require ((Evidence $cycle $root 'cycle' $childB $childA 'a-1' 1 'ExplicitClose') -eq 'Conflict') 'A cycle participant was removed despite conflicting identity.'
 CheckCount $cycle $root 'cycle' 1 $false 'A cycle silently discarded a previously counted child.'

 # Bounded memory preserves accepted agents and makes overflow visible.
 $limited = [AITaskMonitor.CodexAgentLedger.Ledger]::new(2, 2)
 Require ($limited.TrackTask($root, 'limit', $true, $true)) 'The capacity test task was not tracked.'
 [void](Evidence $limited $root 'limit' $root $childA 'a-1' 1 'Observed')
 [void](Evidence $limited $root 'limit' $root $childB 'b-1' 1 'Observed')
 Require ((Evidence $limited $root 'limit' $root $childC 'c-1' 1 'Observed') -eq 'Capacity') 'An over-capacity child was accepted.'
 CheckCount $limited $root 'limit' 2 $false 'Overflow silently evicted known agents or remained exact.'
 Require ($limited.TrackTask($otherRoot, 'limit', $true, $true)) 'The second task was not tracked.'
 $thirdRoot = [guid]'10000000-0000-0000-0000-000000000003'
 Require (-not $limited.TrackTask($thirdRoot, 'limit', $true, $true)) 'Task capacity was exceeded.'
 $notTracked = $limited.Snapshot($thirdRoot, 'limit')
 Require (-not $notTracked.IsTracked -and -not $notTracked.IsComplete -and
          ($notTracked.Reasons -band [AITaskMonitor.CodexAgentLedger.Incompleteness]::CapacityExceeded)) 'Task overflow was not exposed.'
 CheckCount $limited $root 'limit' 2 $false 'Task overflow changed an existing count.'

 # Retirement cannot discard an agent or incomplete evidence. A confirmed,
 # quiescent task with only confirmed closures can free its working capacity.
 $retirement = [AITaskMonitor.CodexAgentLedger.Ledger]::new(1, 2)
 Require ($retirement.TrackTask($root, 'persistent-task', $true, $true)) 'The retirement task was not tracked.'
 Require (-not $retirement.TrackTask($otherRoot, 'waiting-task', $true, $true)) 'A full ledger accepted another task.'
 [void](Evidence $retirement $root 'persistent-task' $root $childA 'a-1' 1 'Observed')
 Require (-not $retirement.TryRetireTask($root, 'persistent-task', $true, $true, $true)) 'An unclosed agent was discarded.'
 CheckCount $retirement $root 'persistent-task' 1 $true 'Failed retirement removed an agent.'
 [void](Evidence $retirement $root 'persistent-task' $root $childA 'a-1' 1 'ExplicitClose')
 Require (-not $retirement.TryRetireTask($root, 'persistent-task', $true, $false, $true)) 'A normal turn completion retired the task.'
 Require (-not $retirement.TryRetireTask($root, 'persistent-task', $true, $true, $false)) 'A non-quiescent task was retired.'
 Require ($retirement.TryRetireTask($root, 'persistent-task', $true, $true, $true)) 'A safely ended task could not be retired.'
 $waiting = $retirement.Snapshot($otherRoot, 'waiting-task')
 Require (-not ($waiting.Reasons -band [AITaskMonitor.CodexAgentLedger.Incompleteness]::CapacityExceeded)) 'Freed capacity remained incorrectly reported as full.'
 $retired = $retirement.Snapshot($root, 'persistent-task')
 Require (-not $retired.IsTracked -and -not $retired.IsComplete -and
          ($retired.Reasons -band [AITaskMonitor.CodexAgentLedger.Incompleteness]::TaskRetired)) 'A retired task was reported as an exact empty task.'
 Require (-not $retirement.TrackTask($root, 'persistent-task', $true, $true)) 'A delayed observation resurrected a retired task incarnation.'
 Require ((Evidence $retirement $root 'persistent-task' $root $childA 'a-1' 1 'Observed') -eq 'NotTracked') 'A delayed event mutated a retired task.'
 Require ($retirement.TrackTask($root, 'new-task-lifetime', $true, $true)) 'Retirement did not release task capacity.'
 [void](Evidence $retirement $root 'new-task-lifetime' $root $childA 'a-2' 2 'Observed')
 [void](Evidence $retirement $root 'persistent-task' $root $childA 'a-1' 1 'ExplicitClose')
 CheckCount $retirement $root 'new-task-lifetime' 1 $true 'A late old-task closure removed an agent in the new lifetime.'

 $unresolved = [AITaskMonitor.CodexAgentLedger.Ledger]::new(1, 2)
 Require ($unresolved.TrackTask($root, 'unknown-coverage', $true, $false)) 'The incomplete task was not tracked.'
 [void](Evidence $unresolved $root 'unknown-coverage' $root $childA 'a-1' 1 'Observed')
 [void](Evidence $unresolved $root 'unknown-coverage' $root $childA 'a-1' 1 'ExplicitClose')
 Require (-not $unresolved.TryRetireTask($root, 'unknown-coverage', $true, $true, $true)) 'An incomplete task was discarded.'
 CheckCount $unresolved $root 'unknown-coverage' 0 $false 'Failed retirement discarded incomplete state.'

 # Tombstones are bounded and never silently removed to make room. Without a
 # verified replay horizon, exhaustion is a visible capacity limitation.
 $tombstones = [AITaskMonitor.CodexAgentLedger.Ledger]::new(1, 1)
 foreach ($index in 1..4) {
  $lifetime = 'retired-' + $index
  Require ($tombstones.TrackTask($root, $lifetime, $true, $true)) 'A bounded retirement fixture was not tracked.'
  Require ($tombstones.TryRetireTask($root, $lifetime, $true, $true, $true)) 'A bounded retirement fixture was not retired.'
 }
 Require ($tombstones.TrackTask($root, 'retired-5', $true, $true)) 'The fifth retirement fixture was not tracked.'
 Require (-not $tombstones.TryRetireTask($root, 'retired-5', $true, $true, $true)) 'A tombstone was silently evicted.'
 Require ($tombstones.RetirementCapacityExceeded) 'Retirement capacity exhaustion was not exposed.'
 CheckCount $tombstones $root 'retired-5' 0 $true 'Tombstone exhaustion discarded the task.'
 Require (-not $tombstones.TrackTask($root, 'retired-1', $true, $true)) 'An older retired task was resurrected after exhaustion.'

 # Invalid identifiers or missing generation cannot become trusted records.
 $invalid = [AITaskMonitor.CodexAgentLedger.Ledger]::new()
 Require ($invalid.TrackTask($root, 'valid', $true, $true)) 'The invalid-evidence task was not tracked.'
 Require ((Evidence $invalid $root 'valid' $root $root 'a-1' 1 'Observed') -eq 'Invalid') 'A task counted itself as an agent.'
 Require ((Evidence $invalid $root 'valid' $root $childA 'a-1' 0 'Observed') -eq 'Invalid') 'A missing child generation was accepted.'
 Require ((Evidence $invalid $root 'valid' $root $childA 'path with spaces' 1 'Observed') -eq 'Invalid') 'An invalid identity token was accepted.'
 CheckCount $invalid $root 'valid' 0 $false 'Invalid evidence produced a count or left it exact.'

 Write-Output 'Synthetic agent ledger checks passed: evidence, stale events, task incarnations, conflicts, cycles, capacity and incomplete sources.'
} finally {
 $sameUserPath = [string]::Equals($initialUserPath, [Environment]::GetEnvironmentVariable('PATH', 'User'), [StringComparison]::Ordinal)
 $sameMachinePath = [string]::Equals($initialMachinePath, [Environment]::GetEnvironmentVariable('PATH', 'Machine'), [StringComparison]::Ordinal)
 if (-not $sameUserPath -or -not $sameMachinePath) { throw 'Persistent PATH changed during the synthetic checks.' }
}
