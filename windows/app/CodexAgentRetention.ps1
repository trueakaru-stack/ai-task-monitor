# In-memory observations for the local Codex source owner. This module does not
# read files, start processes, close agents, or modify the supplied snapshots.
# A retained relationship proves only that it was observed before; neither a
# complete agent list nor a successful agent closure is available here.

function Get-CodexRetentionProperty($Value, [string]$Name, $Fallback = $null) {
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $Fallback
}

function Test-CodexRetentionId([string]$Value) {
    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Test-CodexRetentionIdentity([string]$Value) {
    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Length -le 256 -and $Value -notmatch '[\x00-\x1f\x7f]')
}

function New-CodexAgentRetention {
    param(
        [ValidateRange(1, 2048)][int]$MaximumAgents = 512,
        [ValidateRange(1, 256)][int]$MaximumRoots = 64
    )
    # The owner creates a new instance for each independently verified profile.
    # No records are expired by age, missing input, or a completed turn.
    return [PSCustomObject]@{
        Kind = 'CodexAgentRetention-v1'
        MaximumAgents = $MaximumAgents
        MaximumRoots = $MaximumRoots
        Nodes = @{}
        Identities = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        Agents = @{}
        Roots = @{}
        Conflicts = @{}
        CapacityExceeded = $false
    }
}

function Add-CodexRetentionConflict($State, [string]$Id) {
    if (-not (Test-CodexRetentionId $Id)) { return }
    $key = $Id.ToLowerInvariant()
    if ($State.Conflicts.ContainsKey($key)) { return }
    if ($State.Conflicts.Count -ge (4 * ($State.MaximumAgents + $State.MaximumRoots))) {
        $State.CapacityExceeded = $true
        return
    }
    $State.Conflicts[$key] = $true
}

function Get-CodexRetentionText($Value, [int]$MaximumLength) {
    $text = [string]$Value
    if ($text.Length -gt $MaximumLength -or $text -match '[\x00-\x1f\x7f]') { return '' }
    return $text
}

function Update-CodexAgentRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [AllowEmptyCollection()][object[]]$Tasks = @(),
        [AllowNull()][System.Collections.IDictionary]$Links = $null,
        [bool]$SourcePartial = $false,
        [bool]$SourceUnavailable = $false
    )
    if ($null -eq $State -or [string](Get-CodexRetentionProperty $State 'Kind' '') -cne 'CodexAgentRetention-v1') {
        throw 'A Codex agent retention state is required.'
    }

    # Only local Codex UUID tasks with a unique current file identity can add
    # observations. Retain duplicate IDs as conflicts; never select one by order.
    $taskById = @{}
    $duplicateIds = @{}
    $unavailableNodes = @{}
    foreach ($task in @($Tasks)) {
        $id = [string](Get-CodexRetentionProperty $task 'Id' '')
        if ([string](Get-CodexRetentionProperty $task 'Provider' '') -cne 'codex' -or
            [string](Get-CodexRetentionProperty $task 'Source' '') -ceq 'Codex Cloud' -or
            -not (Test-CodexRetentionId $id)) { continue }
        $id = $id.ToLowerInvariant()
        if ($taskById.ContainsKey($id)) {
            $duplicateIds[$id] = $true
            if ($SourceUnavailable) { $unavailableNodes[$id] = $true }
            else { Add-CodexRetentionConflict $State $id }
        }
        else { $taskById[$id] = $task }
    }

    # The caller supplies independently verified link records. Normalize them
    # into primitive values and preserve explicit contradictions as conflicts.
    $currentNodes = @{}
    if ($null -ne $Links -and $Links.Count -gt 2048) {
        $State.CapacityExceeded = $true
        $SourcePartial = $true
    } elseif ($null -ne $Links -and -not $SourceUnavailable) {
        foreach ($rawId in $Links.Keys) {
            $id = [string]$rawId
            if (-not (Test-CodexRetentionId $id)) { continue }
            $id = $id.ToLowerInvariant()
            $link = $Links[$rawId]
            if ([bool](Get-CodexRetentionProperty $link 'Conflict' $false)) {
                # The existing reader also uses Conflict when identity evidence
                # is not ready yet. It is a current uncertainty, not proof of
                # a permanent contradictory identity or parent.
                $unavailableNodes[$id] = $true
                continue
            }
            $identity = [string](Get-CodexRetentionProperty $link 'IdentityToken' '')
            $isRoot = [bool](Get-CodexRetentionProperty $link 'IsRoot' $false)
            $parent = [string](Get-CodexRetentionProperty $link 'ParentThreadId' '')
            if (-not (Test-CodexRetentionIdentity $identity) -or
                ($isRoot -and $parent) -or
                (-not $isRoot -and (-not (Test-CodexRetentionId $parent) -or $parent -ieq $id))) {
                $unavailableNodes[$id] = $true
                continue
            }
            if ($parent) { $parent = $parent.ToLowerInvariant() }
            $node = [PSCustomObject]@{ Id = $id; ParentId = $parent; IdentityToken = $identity; IsRoot = $isRoot }
            if ($currentNodes.ContainsKey($id)) { Add-CodexRetentionConflict $State $id; continue }
            $currentNodes[$id] = $node
            if ($State.Nodes.ContainsKey($id)) {
                $old = $State.Nodes[$id]
                if ($old.IdentityToken -cne $identity -or $old.ParentId -cne $parent -or $old.IsRoot -ne $isRoot) {
                    Add-CodexRetentionConflict $State $id
                }
            }
            if ($State.Identities.ContainsKey($identity) -and $State.Identities[$identity] -cne $id) {
                Add-CodexRetentionConflict $State $id
                Add-CodexRetentionConflict $State ([string]$State.Identities[$identity])
            }
        }
    }

    # A task with the same UUID but a different file identity must not replace
    # an earlier observation, even when the current parent link is unavailable.
    if (-not $SourceUnavailable) {
        foreach ($id in @($taskById.Keys)) {
            if (-not $State.Nodes.ContainsKey($id)) { continue }
            $identity = [string](Get-CodexRetentionProperty $taskById[$id] 'ActivityIdentity' '')
            if ($identity -and $identity -cne [string]$State.Nodes[$id].IdentityToken) {
                Add-CodexRetentionConflict $State $id
            }
        }
    }

    $current = @{}
    if (-not $SourceUnavailable) {
        foreach ($id in @($taskById.Keys | Sort-Object)) {
            if ($duplicateIds.ContainsKey($id) -or $State.Conflicts.ContainsKey($id) -or -not $currentNodes.ContainsKey($id)) { continue }
            $task = $taskById[$id]
            if ([bool](Get-CodexRetentionProperty $task 'TerminalConfirmed' $false)) { continue }
            $identity = [string](Get-CodexRetentionProperty $task 'ActivityIdentity' '')
            if (-not (Test-CodexRetentionIdentity $identity) -or $identity -cne [string]$currentNodes[$id].IdentityToken) {
                if ($State.Nodes.ContainsKey($id) -and $identity) { Add-CodexRetentionConflict $State $id }
                continue
            }
            if ($currentNodes[$id].IsRoot) { continue }

            # Every edge through the root must be present, identity-verified,
            # acyclic and consistent with any earlier observation.
            $chain = New-Object 'Collections.Generic.List[object]'
            $seen = @{}
            $seenIdentities = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $cursor = $id
            $valid = $false
            for ($depth = 0; $depth -lt 128; $depth++) {
                if ($seen.ContainsKey($cursor)) {
                    foreach ($visited in @($seen.Keys)) { Add-CodexRetentionConflict $State $visited }
                    break
                }
                if (-not $currentNodes.ContainsKey($cursor) -or $State.Conflicts.ContainsKey($cursor) -or $duplicateIds.ContainsKey($cursor)) { break }
                $seen[$cursor] = $true
                $node = $currentNodes[$cursor]
                if ($State.Identities.ContainsKey([string]$node.IdentityToken) -and
                    $State.Identities[[string]$node.IdentityToken] -cne $cursor) {
                    Add-CodexRetentionConflict $State $cursor
                    Add-CodexRetentionConflict $State $State.Identities[[string]$node.IdentityToken]
                    break
                }
                if ($seenIdentities.ContainsKey([string]$node.IdentityToken) -and
                    $seenIdentities[[string]$node.IdentityToken] -cne $cursor) {
                    Add-CodexRetentionConflict $State $cursor
                    Add-CodexRetentionConflict $State $seenIdentities[[string]$node.IdentityToken]
                    break
                }
                $seenIdentities[[string]$node.IdentityToken] = $cursor
                if ($taskById.ContainsKey($cursor)) {
                    $taskIdentity = [string](Get-CodexRetentionProperty $taskById[$cursor] 'ActivityIdentity' '')
                    if ($taskIdentity -and $taskIdentity -cne [string]$node.IdentityToken) {
                        Add-CodexRetentionConflict $State $cursor
                        break
                    }
                }
                $chain.Add($node)
                if ($node.IsRoot) { $valid = $true; break }
                $cursor = [string]$node.ParentId
            }
            if (-not $valid -or $chain.Count -lt 2) { continue }
            $root = $chain[$chain.Count - 1]
            $newAgents = 0
            foreach ($node in $chain) {
                if (-not $node.IsRoot -and -not $State.Agents.ContainsKey($node.Id)) { $newAgents++ }
            }
            if (($State.Agents.Count + $newAgents) -gt $State.MaximumAgents -or
                (-not $State.Roots.ContainsKey($root.Id) -and $State.Roots.Count -ge $State.MaximumRoots)) {
                $State.CapacityExceeded = $true
                continue
            }

            # Add the complete chain atomically after all checks and capacity
            # checks. An intermediate helper need not have a visible turn.
            $State.Roots[$root.Id] = [string]$root.IdentityToken
            for ($index = $chain.Count - 1; $index -ge 0; $index--) {
                $node = $chain[$index]
                if (-not $State.Nodes.ContainsKey($node.Id)) {
                    $State.Nodes[$node.Id] = $node
                    $State.Identities[$node.IdentityToken] = $node.Id
                }
                if ($node.IsRoot) { continue }
                if (-not $State.Agents.ContainsKey($node.Id)) {
                    $ancestry = @($chain[$index..($chain.Count - 1)] | ForEach-Object { [string]$_.Id })
                    $State.Agents[$node.Id] = [PSCustomObject]@{
                        Id = [string]$node.Id; ParentId = [string]$node.ParentId; IdentityToken = [string]$node.IdentityToken
                        RootId = [string]$root.Id; RootIdentity = [string]$root.IdentityToken
                        Ancestry = $ancestry; Title = ''; AgentNickname = ''
                    }
                }
            }
            $current[$id] = $true
            $stored = $State.Agents[$id]
            $title = Get-CodexRetentionText (Get-CodexRetentionProperty $task 'Title' '') 4096
            $nickname = Get-CodexRetentionText (Get-CodexRetentionProperty $task 'AgentNickname' '') 256
            if ($title) { $stored.Title = $title }
            if ($nickname) { $stored.AgentNickname = $nickname }
        }
    }

    $groups = New-Object 'Collections.Generic.List[object]'
    foreach ($rootId in @($State.Roots.Keys | Sort-Object)) {
        $members = New-Object 'Collections.Generic.List[object]'
        $groupConflicts = @{}
        foreach ($record in @($State.Agents.Values | Where-Object { $_.RootId -ceq $rootId } | Sort-Object Id)) {
            foreach ($ancestor in @($record.Ancestry)) {
                if ($State.Conflicts.ContainsKey([string]$ancestor)) { $groupConflicts[[string]$ancestor] = $true }
                if ($unavailableNodes.ContainsKey([string]$ancestor)) { $groupConflicts[[string]$ancestor] = $true }
            }
            $isCurrent = $current.ContainsKey($record.Id) -and -not $State.Conflicts.ContainsKey($record.Id)
            $task = if ($isCurrent) { $taskById[$record.Id] } else { $null }
            $active = $isCurrent -and [bool](Get-CodexRetentionProperty $task 'Active' $false)
            $paused = $isCurrent -and [bool](Get-CodexRetentionProperty $task 'Paused' $false)
            $members.Add([PSCustomObject]@{
                Id = $record.Id; ParentId = $record.ParentId; IdentityToken = $record.IdentityToken
                Title = $record.Title; AgentNickname = $record.AgentNickname
                Current = [bool]$isCurrent; Active = [bool]$active; Paused = [bool]$paused
                StatusUnconfirmed = [bool](-not $isCurrent -or (-not $active -and -not $paused))
                Conflict = [bool]$State.Conflicts.ContainsKey($record.Id)
            })
        }
        if ($State.Conflicts.ContainsKey($rootId)) { $groupConflicts[$rootId] = $true }
        $rootIdentity = [string]$State.Roots[$rootId]
        $rootMatches = $false
        if ($taskById.ContainsKey($rootId)) {
            # A matching link must not be attached to a visible card whose
            # own file identity is absent or different.
            $rootMatches = [string](Get-CodexRetentionProperty $taskById[$rootId] 'ActivityIdentity' '') -ceq $rootIdentity
            if ($rootMatches -and $currentNodes.ContainsKey($rootId)) {
                $rootMatches = $currentNodes[$rootId].IsRoot -and [string]$currentNodes[$rootId].IdentityToken -ceq $rootIdentity
            }
        } elseif ($currentNodes.ContainsKey($rootId)) {
            $rootMatches = $currentNodes[$rootId].IsRoot -and [string]$currentNodes[$rootId].IdentityToken -ceq $rootIdentity
        }
        $hasVisibleRoot = $taskById.ContainsKey($rootId)
        $hasCurrentMember = @($members | Where-Object Current).Count -gt 0
        $canAttach = $rootMatches -and $groupConflicts.Count -eq 0 -and ($hasVisibleRoot -or $hasCurrentMember)
        $groups.Add([PSCustomObject]@{
            RootId = $rootId; RootIdentity = $rootIdentity; KnownCount = $members.Count; Members = $members.ToArray()
            CountUnconfirmed = $true; CoverageUnconfirmed = $true; ClosureUnconfirmed = $true; ContinuityUnconfirmed = $true
            CanAttach = [bool]$canAttach; ConflictIds = [string[]]@($groupConflicts.Keys | Sort-Object)
        })
    }
    $allConflicts = @{}
    foreach ($id in @($State.Conflicts.Keys) + @($unavailableNodes.Keys)) { $allConflicts[[string]$id] = $true }
    return [PSCustomObject]@{
        Groups = $groups.ToArray(); ConflictIds = [string[]]@($allConflicts.Keys | Sort-Object)
        SourcePartial = [bool]$SourcePartial; SourceUnavailable = [bool]$SourceUnavailable
        CapacityExceeded = [bool]$State.CapacityExceeded
        CoverageUnconfirmed = $true; ClosureUnconfirmed = $true; ContinuityUnconfirmed = $true
    }
}
