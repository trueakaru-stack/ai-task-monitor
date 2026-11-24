$ErrorActionPreference = 'Stop'
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
try {
    . (Join-Path $PSScriptRoot '..\app\CodexAgentRetention.ps1')
    function Require([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
    function Task([string]$Id, [string]$Identity, [bool]$Active = $true, [bool]$Paused = $false) {
        return [PSCustomObject]@{
            Id = $Id; Provider = 'codex'; Source = 'local'; ActivityIdentity = $Identity
            Title = 'Synthetic task'; AgentNickname = 'Synthetic agent'; StartKey = 'turn-1'
            Active = $Active; Paused = $Paused; Status = 'synthetic'; TerminalConfirmed = $false
        }
    }
    function Root([string]$Identity) { return [PSCustomObject]@{ IsRoot = $true; IdentityToken = $Identity } }
    function Edge([string]$Parent, [string]$Identity) {
        return [PSCustomObject]@{ IsRoot = $false; ParentThreadId = $Parent; IdentityToken = $Identity }
    }
    function Result($State, [object[]]$Tasks, $Links, [bool]$Partial = $false, [bool]$Unavailable = $false) {
        return Update-CodexAgentRetention -State $State -Tasks $Tasks -Links $Links -SourcePartial $Partial -SourceUnavailable $Unavailable
    }
    function OnlyGroup($Value) {
        Require (@($Value.Groups).Count -eq 1) 'Expected exactly one retained root.'
        return $Value.Groups[0]
    }
    function Member($Group, [string]$Id) {
        $matches = @($Group.Members | Where-Object { $_.Id -ceq $Id })
        Require ($matches.Count -eq 1) 'Expected exactly one retained agent identity.'
        return $matches[0]
    }

    $root = '10000000-0000-0000-0000-000000000001'
    $first = '10000000-0000-0000-0000-000000000002'
    $nested = '10000000-0000-0000-0000-000000000003'
    $other = '10000000-0000-0000-0000-000000000004'
    $rootTask = Task $root 'root-file'
    $firstTask = Task $first 'first-file'
    $nestedTask = Task $nested 'nested-file'
    $links = @{}
    $links[$root] = Root 'root-file'
    $links[$first] = Edge $root 'first-file'
    $links[$nested] = Edge $first 'nested-file'

    $state = New-CodexAgentRetention
    $empty = Result $state @() @{}
    Require (@($empty.Groups).Count -eq 0 -and $empty.CoverageUnconfirmed -and $empty.ClosureUnconfirmed) 'Empty observations were reported as exact coverage.'

    # A confirmed intermediate ancestor is still an observed helper when its
    # own turn is not visible; the complete chain is required before counting.
    $snapshot = Result $state @($rootTask, $nestedTask) $links
    $group = OnlyGroup $snapshot
    Require ($group.RootId -ceq $root -and $group.RootIdentity -ceq 'root-file' -and $group.KnownCount -eq 2) 'The verified nested chain was not retained.'
    Require ($group.CanAttach -and $group.CountUnconfirmed -and $group.CoverageUnconfirmed -and
        $group.ClosureUnconfirmed -and $group.ContinuityUnconfirmed) 'Unknown coverage, closure or continuity was presented as certain.'
    Require ((Member $group $nested).Current -and (Member $group $nested).Active) 'A currently verified observation was lost.'
    Require (-not (Member $group $first).Current -and (Member $group $first).StatusUnconfirmed) 'An intermediate without a current turn was confirmed.'
    $group.Members[0].Title = 'Output mutation'
    $unknownRootCard = $rootTask.PSObject.Copy(); $unknownRootCard.ActivityIdentity = ''
    $unknownRootGroup = OnlyGroup (Result $state @($unknownRootCard, $nestedTask) $links)
    Require ($unknownRootGroup.KnownCount -eq 2 -and -not $unknownRootGroup.CanAttach) 'A root card without file identity received a retained count.'
    $missingRootGroup = OnlyGroup (Result $state @($nestedTask) $links)
    Require ($missingRootGroup.KnownCount -eq 2 -and $missingRootGroup.CanAttach -and
        (Member $missingRootGroup $nested).Current) 'A current child and independently verified root could not retain their group.'

    # A normal new turn, missing record, source failure, and reappearance do
    # not amount to an explicit agent close or mutate retained identity.
    $nestedTask.StartKey = 'turn-2'
    $again = OnlyGroup (Result $state @($rootTask, $nestedTask) $links)
    Require ($again.KnownCount -eq 2 -and (Member $again $nested).Current) 'A new turn changed the retained agent count.'
    Require ((Member $again $first).Title -cne 'Output mutation' -and (Member $again $nested).Title -cne 'Output mutation') 'A returned value changed stored evidence.'
    $lost = OnlyGroup (Result $state @($rootTask) @{} $true)
    Require ($lost.KnownCount -eq 2 -and $lost.CanAttach -and
        -not (Member $lost $first).Current -and -not (Member $lost $nested).Current -and
        (Member $lost $nested).StatusUnconfirmed) 'A missing snapshot silently removed or confirmed an agent.'
    $failed = OnlyGroup (Result $state @($rootTask, $nestedTask) $links $true $true)
    Require ($failed.KnownCount -eq 2 -and -not (Member $failed $nested).Current -and
        (Member $failed $nested).StatusUnconfirmed) 'A source failure confirmed or removed an earlier agent.'
    $recovered = OnlyGroup (Result $state @($rootTask, $nestedTask) $links)
    Require ($recovered.KnownCount -eq 2 -and (Member $recovered $nested).Current) 'A verified reappearance was not recognized.'
    $terminal = $nestedTask.PSObject.Copy(); $terminal.TerminalConfirmed = $true
    $completed = OnlyGroup (Result $state @($rootTask, $terminal) $links)
    Require ($completed.KnownCount -eq 2 -and -not (Member $completed $nested).Current -and
        (Member $completed $nested).StatusUnconfirmed) 'A completed turn reduced or confirmed the agent count.'
    $rootGone = OnlyGroup (Result $state @() @{} $true)
    Require ($rootGone.KnownCount -eq 2 -and -not $rootGone.CanAttach) 'Retained agents created a new visible root without current evidence.'

    # A temporary unavailable link is not by itself proof of a conflicting
    # identity. It remains explicit for this snapshot and can later recover.
    $waitingLinks = $links.Clone(); $waitingLinks[$first] = [PSCustomObject]@{ Conflict = $true }
    $waiting = Result $state @($rootTask, $nestedTask) $waitingLinks $true
    $waitingGroup = OnlyGroup $waiting
    Require ($waitingGroup.KnownCount -eq 2 -and -not $waitingGroup.CanAttach -and
        $waiting.ConflictIds -ccontains $first) 'Unavailable chain evidence was silently hidden.'
    $afterWaiting = OnlyGroup (Result $state @($rootTask, $nestedTask) $links)
    Require ($afterWaiting.CanAttach -and $afterWaiting.KnownCount -eq 2) 'A temporary missing proof permanently blocked a matching chain.'

    # A true same-ID/different-file conflict preserves the old count and must
    # not attach it to a newly observed, incompatible identity.
    $differentLinks = $links.Clone(); $differentLinks[$nested] = Edge $first 'replacement-file'
    $replacement = Task $nested 'replacement-file'
    $conflict = Result $state @($rootTask, $replacement) $differentLinks
    $conflictGroup = OnlyGroup $conflict
    Require ($conflictGroup.KnownCount -eq 2 -and -not $conflictGroup.CanAttach -and
        $conflict.ConflictIds -ccontains $nested -and
        (Member $conflictGroup $nested).IdentityToken -ceq 'nested-file' -and
        -not (Member $conflictGroup $nested).Current) 'A conflicting file overwrote or hid the earlier identity.'

    $changedParent = New-CodexAgentRetention
    [void](Result $changedParent @($rootTask, $firstTask) $links)
    $movedLinks = $links.Clone(); $movedLinks[$first] = Edge $other 'first-file'
    $moved = Result $changedParent @($rootTask, $firstTask) $movedLinks
    $movedGroup = OnlyGroup $moved
    Require ($movedGroup.KnownCount -eq 1 -and -not $movedGroup.CanAttach -and
        $moved.ConflictIds -ccontains $first -and (Member $movedGroup $first).ParentId -ceq $root) 'A conflicting parent moved an earlier agent.'

    $changedRoot = New-CodexAgentRetention
    [void](Result $changedRoot @($rootTask, $firstTask) $links)
    $newRootLinks = $links.Clone(); $newRootLinks[$root] = Root 'new-root-file'
    $newRootTask = Task $root 'new-root-file'
    $rootConflict = Result $changedRoot @($newRootTask, $firstTask) $newRootLinks
    Require ((OnlyGroup $rootConflict).KnownCount -eq 1 -and -not (OnlyGroup $rootConflict).CanAttach -and
        $rootConflict.ConflictIds -ccontains $root) 'A different root identity received the previous count.'

    # An incomplete chain cannot establish a parent, but a later fully verified
    # chain can. Duplicates and reused file identities never become two agents.
    $fresh = New-CodexAgentRetention
    $pending = @{ $nested = [PSCustomObject]@{ Conflict = $true } }
    $pendingResult = Result $fresh @($nestedTask) $pending $true
    Require (@($pendingResult.Groups).Count -eq 0 -and $pendingResult.ConflictIds -ccontains $nested) 'An unresolved initial link was silently accepted.'
    $freshResult = Result $fresh @($rootTask, $nestedTask) $links
    Require ((OnlyGroup $freshResult).KnownCount -eq 2) 'A resolved initial link could not become verified.'
    $duplicates = New-CodexAgentRetention
    $duplicateResult = Result $duplicates @($rootTask, $firstTask, $firstTask) $links
    Require (@($duplicateResult.Groups).Count -eq 0 -and $duplicateResult.ConflictIds -ccontains $first) 'A duplicate ID was counted as a verified agent.'
    $sameFile = New-CodexAgentRetention
    $sameLinks = @{}; $sameLinks[$root] = Root 'same-file'; $sameLinks[$first] = Edge $root 'same-file'
    $sameResult = Result $sameFile @((Task $root 'same-file'), (Task $first 'same-file')) $sameLinks
    Require (@($sameResult.Groups).Count -eq 0 -and $sameResult.ConflictIds -ccontains $first) 'One file identity was used for multiple agents.'

    # Capacity exhaustion is explicit, never silently evicts a previously seen
    # unclosed agent, and does not partially admit an oversized new chain.
    $limited = New-CodexAgentRetention -MaximumAgents 1 -MaximumRoots 1
    $tooDeep = Result $limited @($rootTask, $nestedTask) $links
    Require (@($tooDeep.Groups).Count -eq 0 -and $tooDeep.CapacityExceeded) 'An oversized chain was partly admitted or the limit was hidden.'
    $single = New-CodexAgentRetention -MaximumAgents 1 -MaximumRoots 1
    [void](Result $single @($rootTask, $firstTask) $links)
    $full = Result $single @($rootTask, $firstTask, $nestedTask) $links
    Require ((OnlyGroup $full).KnownCount -eq 1 -and $full.CapacityExceeded) 'Capacity exhaustion discarded an already retained agent.'

    Write-Output 'Synthetic retention: verified ancestry, missing sources, turn completion, reappearance, identity conflicts and capacity verified.'
} finally {
    if (-not [string]::Equals($userPath, [Environment]::GetEnvironmentVariable('PATH', 'User'), [StringComparison]::Ordinal) -or
        -not [string]::Equals($machinePath, [Environment]::GetEnvironmentVariable('PATH', 'Machine'), [StringComparison]::Ordinal)) {
        throw 'Persistent PATH changed during the synthetic retention checks.'
    }
}
