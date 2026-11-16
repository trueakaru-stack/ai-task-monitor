$ErrorActionPreference = "Stop"

$source = Join-Path (Join-Path $PSScriptRoot "..\app") "CodexProgress.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Unable to parse the application." }
$definitions = foreach ($name in @("Thread-State", "Codex-Uncertain")) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $function) { throw "Missing lifecycle function: $name" }
    $function.Extent.Text
}

$checks = @'
$script:lifecycleState = @{}
$script:monitorStartedUtc = [DateTime]::UtcNow
$script:observedCodex = @{}
$start = @{timestamp=$script:monitorStartedUtc.AddHours(-3).ToString("o");type="event_msg";payload=@{type="task_started";turn_id="turn-a"}}|ConvertTo-Json -Compress
$script:fakeTail = $start
$script:fakeLength = $script:fakeTail.Length
$script:fakeModified = [DateTime]::UtcNow.AddHours(-3)
$script:fakeLock = "present"
$script:fileExists = $true
$script:reads = 0
$script:sessionCalls = 0
$lockDirectory = "synthetic-lock-directory"
function Session-File([string]$id) { $script:sessionCalls++; return "synthetic-session" }
function Test-Path([string]$LiteralPath) { return $script:fileExists }
function Get-Item([string]$LiteralPath) { return [PSCustomObject]@{ Length=$script:fakeLength; LastWriteTimeUtc=$script:fakeModified } }
function Read-TailText([string]$path,[long]$maxBytes) { $script:reads++; return $script:fakeTail }
function Lock-State([string]$path) { return $script:fakeLock }

$state = Thread-State "synthetic-id"
if ($state.State -ne "unknown" -or -not $state.HasStartMarker -or -not (Codex-Uncertain "synthetic-id" $state)) { throw "An old start and a present lock must remain unconfirmed." }
$newEvent=@{timestamp=$script:monitorStartedUtc.AddSeconds(1).ToString("o");type="event_msg";payload=@{type="agent_reasoning"}}|ConvertTo-Json -Compress
$script:fakeTail += "`n"+$newEvent
$script:fakeLength = $script:fakeTail.Length
$script:fakeModified = [DateTime]::UtcNow
$state = Thread-State "synthetic-id"
if ($state.State -ne "unknown" -or -not (Codex-Uncertain "synthetic-id" $state)) { throw "A new event must not confirm activity from lock presence." }
[void](Codex-Uncertain "synthetic-id" $state)
$readCount=$script:reads
$script:fakeLock = "missing"
$state = Thread-State "synthetic-id"
if ($state.State -ne "unknown" -or -not $state.HasStartMarker) { throw "A lost lock must not leave a cached task active." }
if ($script:reads -ne $readCount) { throw "Lifecycle contents should remain cached while lock state is rechecked." }
$script:fakeLock = "present"
if ((Thread-State "synthetic-id").State -ne "unknown") { throw "A present lock must not restore confirmed activity." }
$script:fakeLock = "unavailable"
$threw = $false
try { [void](Thread-State "synthetic-id") } catch { $threw = $true }
if (-not $threw) { throw "An unreadable lock should be reported as a source error." }
$script:fakeLock = "present"

$script:fakeTail += "`n"+'{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}'
$script:fakeLength = $script:fakeTail.Length
$script:fakeModified = [DateTime]::UtcNow
if ((Thread-State "synthetic-id").State -ne "completed") { throw "A completed event must override a held lock." }
$script:fakeTail = '{"type":"event_msg","payload":{"type":"turn_started","turn_id":"turn-b"}}'+"`n"+'{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a"}}'
$script:fakeLength = $script:fakeTail.Length
$script:fakeModified = $script:fakeModified.AddTicks(1)
$turnB = Thread-State "synthetic-id"
if ($turnB.State -ne "unknown" -or -not $turnB.HasStartMarker -or $turnB.StartKey -ne "turn:turn-b") { throw "An old turn interruption must not stop a newer unconfirmed turn or change its identity." }
if ((Thread-State "synthetic-id").StartKey -ne "turn:turn-b") { throw "Cached turn identity was lost." }
$script:fakeTail += "`n"+'{ "payload": { "turn_id": "turn-b", "type": "turn_aborted" }, "type": "event_msg" }'
$script:fakeLength = $script:fakeTail.Length
$script:fakeModified = $script:fakeModified.AddTicks(1)
if ((Thread-State "synthetic-id").State -ne "interrupted") { throw "An interrupted turn must not remain active even if its writer lock is held." }
$script:fakeTail += "`n"+'{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-c"}}'
$newTurnEvent=@{timestamp=$script:monitorStartedUtc.AddSeconds(2).ToString("o");type="event_msg";payload=@{type="agent_reasoning";turn_id="turn-c"}}|ConvertTo-Json -Compress
$script:fakeTail += "`n"+$newTurnEvent
$script:fakeLength = $script:fakeTail.Length
$script:fakeModified = $script:fakeModified.AddTicks(1)
$turnC = Thread-State "synthetic-id"
if ($turnC.State -ne "unknown" -or -not $turnC.HasStartMarker -or $turnC.StartKey -ne "turn:turn-c") { throw "A new turn after interruption should be unconfirmed and identifiable." }
$script:fakeTail = '{"type":"event_msg","payload":{"type":"unrecognized"}}'
$script:fakeLength = $script:fakeTail.Length
$script:fakeModified = $script:fakeModified.AddTicks(1)
if ((Thread-State "synthetic-id").State -ne "unknown") { throw "Missing lifecycle evidence must be unknown." }
$script:fileExists = $false
if ((Thread-State "synthetic-id").State -ne "unknown") { throw "A missing session file must not be called active or completed." }
$beforeUnsafe = $script:sessionCalls
if ((Thread-State "../outside").State -ne "unknown" -or $script:sessionCalls -ne $beforeUnsafe) { throw "Unsafe session identifiers must not be resolved." }
$script:observedCodex = @{}
$script:monitorStartedUtc = [DateTime]::UtcNow
$oldUnknown = [PSCustomObject]@{ State="unknown"; HasStartMarker=$true; UpdatedUtc=$script:monitorStartedUtc.AddHours(-3) }
if (Codex-Uncertain "old" $oldUnknown) { throw "An old unseen record should remain hidden." }
$active = [PSCustomObject]@{ State="active"; HasStartMarker=$true; UpdatedUtc=$script:monitorStartedUtc.AddHours(-3) }
if (Codex-Uncertain "observed" $active) { throw "An active record should not be uncertain." }
if (-not (Codex-Uncertain "observed" $oldUnknown)) { throw "A previously observed task should become uncertain." }
$freshUnknown = [PSCustomObject]@{ State="unknown"; HasStartMarker=$true; UpdatedUtc=$script:monitorStartedUtc.AddSeconds(1) }
if (-not (Codex-Uncertain "new" $freshUnknown)) { throw "A new unconfirmed start should be visible as uncertain." }
$completed = [PSCustomObject]@{ State="completed"; HasStartMarker=$false; UpdatedUtc=$script:monitorStartedUtc.AddSeconds(2) }
[void](Codex-Uncertain "observed" $completed)
if (Codex-Uncertain "observed" $oldUnknown) { throw "A completed task should no longer be tracked as uncertain." }
if (Codex-Uncertain "observed" $active) { throw "An active record should not be uncertain." }
$interrupted = [PSCustomObject]@{ State="interrupted"; HasStartMarker=$false; UpdatedUtc=$script:monitorStartedUtc.AddSeconds(3) }
[void](Codex-Uncertain "observed" $interrupted)
if (Codex-Uncertain "observed" $oldUnknown) { throw "An interrupted task should no longer be tracked as uncertain." }
Write-Output "Codex lifecycle: passive lock metadata, cache invalidation, matched completion and uncertainty verified."
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))

$lockFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Lock-State" }, $true)
if ($null -eq $lockFunction) { throw "Lock-State is missing." }
$lockPath = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-lock-" + [Guid]::NewGuid().ToString("N") + ".tmp")
$lockChecks = @'
$path = $args[0]
if ((Lock-State $path) -ne "missing") { throw "A missing lock should remain unknown." }
[void](New-Item -ItemType File -Path $path -ErrorAction Stop)
if ((Lock-State $path) -ne "present") { throw "An existing file must only be reported as present." }
$owner = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
try {
    if ((Lock-State $path) -ne "present") { throw "A writer's file must only be reported as present." }
} finally { $owner.Dispose() }
if ((Lock-State $path) -ne "present") { throw "A released file still exists and cannot prove writer state." }
'@
try {
    & ([scriptblock]::Create($lockFunction.Extent.Text + "`n" + $lockChecks)) $lockPath
    Write-Output "Codex lifecycle: synthetic writer file remains present before and after release."
} finally {
    if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }
}
