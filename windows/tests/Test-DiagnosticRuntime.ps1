$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
foreach ($name in @("DiagnosticPolicy.ps1","DiagnosticStore.ps1","LoopDetection.ps1","DiagnosticCollector.ps1","DiagnosticRuntime.ps1")) {
    $path = Join-Path $appRoot $name
    if (-not (Test-Path -LiteralPath $path)) { throw "Diagnostic runtime dependency is missing: $name" }
    . $path
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-runtime-" + [Guid]::NewGuid().ToString("N"))
$expectedRoot = [IO.Path]::GetFullPath($testRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $expectedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($expectedRoot)

try {
    $now = [DateTimeOffset]::Parse("2026-11-02T12:00:00Z")
    $secret = "SYNTHETIC_PRIVATE_REQUEST_AND_OUTPUT"
    $script:fixturePath = Join-Path $expectedRoot "session.jsonl"
    $start = @{timestamp=$now.ToString("o");type="response_item";payload=@{type="custom_tool_call";name="exec";call_id="call-1";input=$secret}} | ConvertTo-Json -Compress -Depth 4
    $end = @{timestamp=$now.ToString("o");type="response_item";payload=@{type="custom_tool_call_output";call_id="call-1";output=$secret}} | ConvertTo-Json -Compress -Depth 4
    [IO.File]::WriteAllText($script:fixturePath, ($start+"`n"+$end.Substring(0,20)), [Text.UTF8Encoding]::new($false))
    $directory = Join-Path $expectedRoot "data"
    $runtime = New-DiagnosticRuntime -Directory $directory -Since $now.AddSeconds(-1) -Now $now
    $task = [PSCustomObject]@{Id="synthetic-task";Provider="codex";State="active"}
    $resolver = {param($id) return $script:fixturePath}
    $script:fakeState = "unknown"
    $stateResolver = {param($id) return [PSCustomObject]@{State=$script:fakeState}}
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @($task) -Unavailable @() -Now $now -SessionResolver $resolver -StateResolver $stateResolver
    $events = @(Read-DiagnosticEvents -Directory $directory -Now $now -RetentionDays 7 -MaximumBytes 10000000)
    if ($events.Count -ne 2 -or @($events|Where-Object type -eq "task_observed").Count -ne 1 -or @($events|Where-Object type -eq "tool_started").Count -ne 1) {
        throw "Expected a task observation and action start."
    }
    [IO.File]::AppendAllText($script:fixturePath, ($end.Substring(20)+"`n"), [Text.UTF8Encoding]::new($false))
    $journalPath = Join-Path $directory "diagnostic-events-v1.jsonl"
    $savedJournal = [IO.File]::ReadAllBytes($journalPath)
    [IO.File]::WriteAllText($journalPath, "synthetic corruption")
    $threw = $false
    try { Update-DiagnosticRuntime -Runtime $runtime -Tasks @($task) -Unavailable @() -Now $now.AddSeconds(1) -SessionResolver $resolver -StateResolver $stateResolver } catch { $threw = $true }
    if (-not $threw) { throw "A corrupt journal must be reported without advancing the source cursor." }
    [IO.File]::WriteAllBytes($journalPath, $savedJournal)
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @($task) -Unavailable @() -Now $now.AddSeconds(1) -SessionResolver $resolver -StateResolver $stateResolver
    if (@(Read-DiagnosticEvents -Directory $directory -Now $now.AddSeconds(1) -RetentionDays 7 -MaximumBytes 10000000).Count -ne 3) { throw "Repeated refresh must not duplicate events." }
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @($task) -Unavailable @() -Now $now.AddSeconds(1) -SessionResolver $resolver -StateResolver $stateResolver
    if (@(Read-DiagnosticEvents -Directory $directory -Now $now.AddSeconds(1) -RetentionDays 7 -MaximumBytes 10000000).Count -ne 3) { throw "Repeated refresh must not duplicate events." }
    $task.State = "unknown"
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @($task) -Unavailable @() -Now $now.AddSeconds(2) -SessionResolver $resolver -StateResolver $stateResolver
    $script:fakeState = "completed"
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @() -Unavailable @() -Now $now.AddSeconds(3) -SessionResolver $resolver -StateResolver $stateResolver
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @() -Unavailable @("Claude Code") -Now $now.AddSeconds(4) -SessionResolver $resolver -StateResolver $stateResolver
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @() -Unavailable @() -Now $now.AddSeconds(5) -SessionResolver $resolver -StateResolver $stateResolver
    $events = @(Read-DiagnosticEvents -Directory $directory -Now $now.AddSeconds(5) -RetentionDays 7 -MaximumBytes 10000000)
    foreach ($type in @("task_unconfirmed","task_completed","source_unavailable","source_recovered")) {
        if (@($events|Where-Object type -eq $type).Count -ne 1) { throw "Missing state transition: $type" }
    }
    $task.State="active"
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @($task) -Unavailable @() -Now $now.AddSeconds(6) -SessionResolver $resolver -StateResolver $stateResolver
    $script:fakeState="interrupted"
    Update-DiagnosticRuntime -Runtime $runtime -Tasks @() -Unavailable @() -Now $now.AddSeconds(7) -SessionResolver $resolver -StateResolver $stateResolver
    $events=@(Read-DiagnosticEvents -Directory $directory -Now $now.AddSeconds(7) -RetentionDays 7 -MaximumBytes 10000000)
    if (@($events|Where-Object type -eq "task_interrupted").Count -ne 1) { throw "A stopped turn must be recorded as interrupted, not completed." }
    $raw = [IO.File]::ReadAllText((Join-Path $directory "diagnostic-events-v1.jsonl"))
    if ($raw.Contains($secret) -or $raw.Contains("synthetic-task")) { throw "The runtime stored sensitive source content or a raw task ID." }
    Write-Output "Diagnostic runtime: task and source transitions, tool metadata and deduplication verified."
} finally {
    if (Test-Path -LiteralPath $expectedRoot) {
        $resolved = (Resolve-Path -LiteralPath $expectedRoot).Path
        if ($resolved -ne $expectedRoot -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
