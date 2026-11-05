$ErrorActionPreference = "Stop"

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-privacy-" + [Guid]::NewGuid().ToString("N"))
$expectedRoot = [IO.Path]::GetFullPath($testRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $expectedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test directory is not inside the system temporary directory."
}
[void][IO.Directory]::CreateDirectory($expectedRoot)
$previousLocalAppData = $env:LOCALAPPDATA
$previousUserProfile = $env:USERPROFILE
$previousAudit = $env:AI_TASK_MONITOR_AUDIT
$testMutex = 'AITM.Test.' + [Guid]::NewGuid().ToString('N')
$testPipe = 'AITM.Test.' + [Guid]::NewGuid().ToString('N')

try {
    $env:LOCALAPPDATA = $expectedRoot
    $env:USERPROFILE = $expectedRoot
    $env:AI_TASK_MONITOR_AUDIT = "1"
    $appRoot = Join-Path $PSScriptRoot "..\app"
    . (Join-Path $appRoot "ClaudeReaderCore.ps1")
    $hookDirectory = Join-Path $expectedRoot "hook"
    [void][IO.Directory]::CreateDirectory($hookDirectory)
    foreach ($fileName in @("ClaudeTaskHook.ps1", "ClaudeLoopClient.ps1")) {
        Copy-Item -LiteralPath (Join-Path $appRoot $fileName) -Destination (Join-Path $hookDirectory $fileName)
    }
    $hook = Join-Path $hookDirectory "ClaudeTaskHook.ps1"
    $secret = "SYNTHETIC_ONLY_SECRET_9D42EBF6"
    $dataDirectory = Join-Path $expectedRoot "CodexTaskProgress"
    [void][IO.Directory]::CreateDirectory($dataDirectory)
    $preservedLegacy = Join-Path $dataDirectory "claude-events.jsonl"
    [IO.File]::WriteAllText($preservedLegacy, ("SYNTHETIC_LEGACY_" + ('x' * 8400000)))
    $legacyHash = (Get-FileHash -LiteralPath $preservedLegacy -Algorithm SHA256).Hash
    foreach ($eventName in @("UserPromptSubmit", "PreToolUse", "TaskCreated")) {
        $inputEvent = @{
            hook_event_name = $eventName
            session_id = "new-session"
            prompt = $secret
            cwd = "C:\synthetic-project"
            tool_name = "Read"
            tool_input = @{ taskId = "step-1"; subject = "Synthetic plan step"; status = "in_progress" }
        } | ConvertTo-Json -Compress -Depth 4
        $inputEvent | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook -LogTestMutex $testMutex -LoopTestPipe $testPipe
        if ($LASTEXITCODE -ne 0) { throw "The Claude hook failed for $eventName." }
    }

    $eventFile = Join-Path $dataDirectory "claude-events-v2.jsonl"
    if ((Get-FileHash -LiteralPath $preservedLegacy -Algorithm SHA256).Hash -ne $legacyHash) { throw "The legacy Claude event file was modified." }
    $stored = [IO.File]::ReadAllText($eventFile)
    if ($stored.Contains($secret)) { throw "Prompt text was stored in the hook event." }
    $records = @($stored -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($records.Count -ne 3) { throw "Expected three hook events." }
    foreach ($record in $records) {
        if ($null -ne $record.PSObject.Properties["prompt"]) { throw "The hook event contains a prompt field." }
        if ($null -ne $record.PSObject.Properties["cwd"]) { throw "The hook event contains a working-directory path." }
    }
    $oversized='{"hook_event_name":"UserPromptSubmit","prompt":"'+('x' * 1050000)+'"}'
    $oversized | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook -LogTestMutex $testMutex -LoopTestPipe $testPipe
    if ($LASTEXITCODE -ne 0) { throw "The hook did not reject oversized input safely." }
    if ([IO.File]::ReadAllText($eventFile) -ne $stored) { throw "Oversized hook input must not create an event." }

    $legacyFile = Join-Path $expectedRoot "legacy-events.jsonl"
    $legacy = @{
        timestamp = [DateTime]::UtcNow.ToString("o")
        session_id = "legacy-session"
        event = "UserPromptSubmit"
        active = $true
        prompt = $secret
        activity = $secret
        cwd = "C:\synthetic-project"
    } | ConvertTo-Json -Compress
    $step = @{
        timestamp = [DateTime]::UtcNow.ToString("o")
        session_id = "legacy-session"
        event = "TaskCreated"
        active = $true
        task_id = "step-1"
        task_subject = "Synthetic plan step"
        task_status = "in_progress"
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($legacyFile, ($legacy + "`n" + $step + "`n"), [Text.UTF8Encoding]::new($false))

    $tokens = $null
    $errors = $null
    $source = Join-Path $appRoot "CodexProgress.ps1"
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Unable to parse the task reader." }
    $definitions = foreach ($name in @("Prop", "Read-TailText", "Plan-Progress", "Claude-Tasks")) {
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if ($null -eq $function) { throw "Missing reader function: $name" }
        $function.Extent.Text
    }
    $check = @'
$script:monitorStartedUtc = [DateTime]::UtcNow.AddMinutes(-1)
$claudeEventPath = $args[0]
$claudeLegacyEventPath = ""
$tasks = @(Claude-Tasks)
if ($tasks.Count -ne 1) { throw "Expected one active task from the legacy event." }
if ($tasks[0].Title -notmatch "Claude Code" -or $tasks[0].Title -match "SYNTHETIC_ONLY_SECRET") { throw "Legacy prompt was used as the task title." }
if ($tasks[0].Activity -match "SYNTHETIC_ONLY_SECRET") { throw "Legacy prompt was used as activity." }
if ($tasks[0].Steps.Count -ne 1 -or $tasks[0].Steps[0].title -ne "Synthetic plan step" -or $tasks[0].Steps[0].status -ne "active") {
    throw "The existing plan step was not preserved."
}
'@
    & ([scriptblock]::Create(($definitions -join "`n") + "`n" + $check)) $legacyFile
    $migrationCheck = @'
$claudeEventPath = $args[0]
$claudeLegacyEventPath = $args[1]
$tasks = @(Claude-Tasks)
if (@($tasks | Where-Object Id -eq "claude:legacy-session").Count -ne 0) { throw "A legacy-only session must not reappear without a new event." }
$new = @{timestamp=[DateTime]::UtcNow.AddSeconds(1).ToString("o");session_id="legacy-session";event="PreToolUse";active=$true;tool_name="Read"} | ConvertTo-Json -Compress
[IO.File]::AppendAllText($claudeEventPath,($new+"`n"),[Text.UTF8Encoding]::new($false))
$tasks = @(Claude-Tasks)
$legacy = @($tasks | Where-Object Id -eq "claude:legacy-session")
if ($legacy.Count -ne 1 -or $legacy[0].Steps.Count -ne 1 -or $legacy[0].Steps[0].title -ne "Synthetic plan step") { throw "A newly observed session must retain its legacy plan steps." }
if ($legacy[0].Title -match "SYNTHETIC_ONLY_SECRET" -or $legacy[0].Activity -match "SYNTHETIC_ONLY_SECRET") { throw "Legacy prompt content leaked into the task view." }
'@
    & ([scriptblock]::Create(($definitions -join "`n") + "`n" + $migrationCheck)) $eventFile $legacyFile
    $quietFile = Join-Path $expectedRoot "quiet-events.jsonl"
    $quietEvent = @{timestamp=[DateTime]::UtcNow.AddHours(-3).ToString("o");session_id="quiet";event="PreToolUse";active=$true} | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($quietFile,($quietEvent+"`n"),[Text.UTF8Encoding]::new($false))
    $quietCheck = @'
$script:monitorStartedUtc = [DateTime]::UtcNow.AddHours(-4)
$claudeEventPath = $args[0]
$claudeLegacyEventPath = ""
$tasks = @(Claude-Tasks)
if ($tasks.Count -ne 1 -or $tasks[0].Active -or [string]::IsNullOrEmpty($tasks[0].Status) -or $tasks[0].Status -ne $tasks[0].Activity) { throw "An observed quiet session must remain visible as unconfirmed." }
$new = @{timestamp=[DateTime]::UtcNow.ToString("o");session_id="quiet";event="PostToolUse";active=$true} | ConvertTo-Json -Compress
[IO.File]::AppendAllText($claudeEventPath,($new+"`n"),[Text.UTF8Encoding]::new($false))
$tasks = @(Claude-Tasks)
if ($tasks.Count -ne 1 -or -not $tasks[0].Active) { throw "A new event must restore the active state." }
'@
    & ([scriptblock]::Create(($definitions -join "`n") + "`n" + $quietCheck)) $quietFile
    Write-Output "Claude privacy: prompt excluded, oversized input rejected, legacy title neutral, and plan step preserved."
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:USERPROFILE = $previousUserProfile
    $env:AI_TASK_MONITOR_AUDIT = $previousAudit
    if (Test-Path -LiteralPath $expectedRoot) {
        $resolved = (Resolve-Path -LiteralPath $expectedRoot).Path
        if ($resolved -ne $expectedRoot -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove an unexpected test directory."
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
