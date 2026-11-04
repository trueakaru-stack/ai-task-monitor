$ErrorActionPreference = "Stop"

$appRoot = Join-Path $PSScriptRoot "..\app"
$source = Join-Path $appRoot "CodexProgress.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Unable to parse the application." }
$definitions = foreach ($name in @("Prop", "Read-TailText", "Lock-State", "Thread-State", "Codex-Uncertain", "Plan-Progress", "Codex-IndexCandidates", "Codex-Tasks")) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $function) { throw "Missing lifecycle function: $name" }
    $function.Extent.Text
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-observation-" + [Guid]::NewGuid().ToString("N"))
$expectedRoot = [IO.Path]::GetFullPath($testRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $expectedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($expectedRoot)

$checks = @'
$codexHome = $args[0]
$sessionIndex = Join-Path $codexHome "session_index.jsonl"
$lockDirectory = Join-Path $codexHome "thread-writer-locks"
[void][IO.Directory]::CreateDirectory($lockDirectory)
$script:sessionDates = @{}
$script:observedCodex = @{}
$script:lifecycleState = @{}
$script:lastCodexTasks = @()
$script:monitorStartedUtc = [DateTime]::UtcNow
$script:sessionPaths = @{
    "active-id" = (Join-Path $codexHome "active.jsonl")
    "old-id" = (Join-Path $codexHome "old.jsonl")
}
function Session-File([string]$id) { return $script:sessionPaths[$id] }
function Manual-Tasks($sessions) { return @{} }
function Codex-Plan([string]$id) { return @() }
function Codex-Activity([string]$id) { return "Synthetic activity" }

$now = [DateTime]::UtcNow.ToString("o")
$records = @(
    (@{ id="active-id"; thread_name="Active synthetic task"; updated_at=$now } | ConvertTo-Json -Compress),
    (@{ id="old-id"; thread_name="Old synthetic task"; updated_at=$now } | ConvertTo-Json -Compress)
)
[IO.File]::WriteAllText($sessionIndex, (($records -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
$started = @{timestamp=$script:monitorStartedUtc.AddHours(-3).ToString("o");type="event_msg";payload=@{type="task_started"}}|ConvertTo-Json -Compress
foreach ($path in $script:sessionPaths.Values) {
    [IO.File]::WriteAllText($path, ($started + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($path, $script:monitorStartedUtc.AddHours(-3))
}
$lock = Join-Path $lockDirectory "active-id.lock"
$oldLock = Join-Path $lockDirectory "old-id.lock"
[void](New-Item -ItemType File -Path $lock)
[void](New-Item -ItemType File -Path $oldLock)
$newEvent=@{timestamp=$script:monitorStartedUtc.AddSeconds(1).ToString("o");type="event_msg";payload=@{type="agent_reasoning"}}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($script:sessionPaths["active-id"], ($newEvent + "`n"), [Text.UTF8Encoding]::new($false))
$owner = [IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$oldOwner = [IO.File]::Open($oldLock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    function Manual-Tasks($sessions) { return @{"old-id"=[PSCustomObject]@{title="Synthetic stale progress";status="В работе";steps=@()}} }
    $tasks = @(Codex-Tasks)
    if ($tasks.Count -ne 1 -or $tasks[0].Id -ne "active-id" -or -not $tasks[0].Active) {
        throw "The newly observed task must appear; the old silent task must stay hidden despite a held lock and manual status."
    }
    function Manual-Tasks($sessions) { return @{} }
    [IO.File]::AppendAllText($script:sessionPaths["old-id"], ($newEvent + "`n"), [Text.UTF8Encoding]::new($false))
    if (@(Codex-Tasks|Where-Object Active).Count -ne 2) { throw "A new event must reveal the formerly silent task." }
    $oldAborted='{"type":"event_msg","payload":{"type":"turn_aborted"}}'
    [IO.File]::AppendAllText($script:sessionPaths["old-id"], ($oldAborted + "`n"), [Text.UTF8Encoding]::new($false))
} finally { $owner.Dispose();$oldOwner.Dispose() }

$tasks = @(Codex-Tasks)
if ($tasks.Count -ne 1 -or $tasks[0].Id -ne "active-id" -or $tasks[0].Active -or $tasks[0].Activity -eq "Synthetic activity") {
    throw "The previously observed task must become unconfirmed after its lock is released."
}
$complete = '{"type":"event_msg","payload":{"type":"task_complete"}}'
[IO.File]::AppendAllText($script:sessionPaths["active-id"], ($complete + "`n"), [Text.UTF8Encoding]::new($false))
$tasks = @(Codex-Tasks)
if ($tasks.Count -ne 0) { throw "Completed and previously unseen old tasks must not be displayed." }
function Manual-Tasks($sessions) { return @{"active-id"=[PSCustomObject]@{title="Synthetic stale progress";status="В работе";steps=@()}} }
if (@(Codex-Tasks).Count -ne 0) { throw "A stale manual status must not make a completed task reappear as working." }
function Manual-Tasks($sessions) { return @{"active-id"=[PSCustomObject]@{title="Synthetic approval";status="Ожидает подтверждения";steps=@()}} }
$waiting=@(Codex-Tasks)
if ($waiting.Count -ne 1 -or $waiting[0].Active -or $waiting[0].Status -ne "Ожидает подтверждения") { throw "An explicit manual approval wait should remain visible without being active." }
function Manual-Tasks($sessions) { return @{} }
$startedAgain = @{timestamp=$script:monitorStartedUtc.AddSeconds(2).ToString("o");type="event_msg";payload=@{type="task_started";turn_id="turn-2"}}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($script:sessionPaths["active-id"], ($startedAgain + "`n"), [Text.UTF8Encoding]::new($false))
$owner = [IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    if (@(Codex-Tasks|Where-Object Active).Count -ne 1) { throw "The resumed task must be observed as active." }
    function Manual-Tasks($sessions) { return @{"active-id"=[PSCustomObject]@{title="Synthetic progress";status="В работе";steps=@()}} }
    $aborted = '{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2"}}'
    [IO.File]::AppendAllText($script:sessionPaths["active-id"], ($aborted + "`n"), [Text.UTF8Encoding]::new($false))
    if (@(Codex-Tasks).Count -ne 0) { throw "An interrupted task must remain hidden even if a writer lock and old manual progress still exist." }
} finally { $owner.Dispose() }
Write-Output "Codex observed tasks: old records hidden, live lock retained, uncertainty and completion verified."
'@

try {
    & ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks)) $expectedRoot
} finally {
    if (Test-Path -LiteralPath $expectedRoot) {
        $resolved = (Resolve-Path -LiteralPath $expectedRoot).Path
        if ($resolved -ne $expectedRoot -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
