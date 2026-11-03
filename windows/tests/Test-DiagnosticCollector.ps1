$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
. (Join-Path $appRoot "DiagnosticPolicy.ps1")
. (Join-Path $appRoot "DiagnosticCollector.ps1")

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-collector-" + [Guid]::NewGuid().ToString("N"))
$expectedRoot = [IO.Path]::GetFullPath($testRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $expectedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($expectedRoot)
try {
    $now = [DateTimeOffset]::Parse("2026-11-02T12:00:00Z")
    $key = [byte[]](0..31)
    $task = Get-DiagnosticTaskKey -Provider "codex" -TaskId "synthetic-task" -Key $key
    $secret = "SYNTHETIC_CONTENT_NOT_FOR_JOURNAL"
    $start = @{timestamp=$now.ToString("o");type="response_item";payload=@{type="custom_tool_call";name="exec";call_id="call-1";input=$secret}} | ConvertTo-Json -Compress -Depth 4
    $end = @{timestamp=$now.ToString("o");type="response_item";payload=@{type="custom_tool_call_output";call_id="call-1";output=$secret}} | ConvertTo-Json -Compress -Depth 4
    $path = Join-Path $expectedRoot "session.jsonl"
    [IO.File]::WriteAllText($path, ($start + "`n" + $end), [Text.UTF8Encoding]::new($false))
    $events = @(Read-CodexToolEvents -Path $path -TaskKey $task -Key $key -Since $now.AddSeconds(-1))
    if ($events.Count -ne 1 -or $events[0].type -ne "tool_started") { throw "An incomplete final line must be ignored." }
    [IO.File]::AppendAllText($path, "`n", [Text.UTF8Encoding]::new($false))
    $events = @(Read-CodexToolEvents -Path $path -TaskKey $task -Key $key -Since $now.AddSeconds(-1))
    if ($events.Count -ne 2 -or $events[1].type -ne "tool_finished") { throw "The completed line must be read on the next poll." }
    $result = $events | ConvertTo-Json -Compress -Depth 4
    if ($result.Contains($secret)) { throw "Session content leaked into diagnostic events." }
    $prefix = "x" * 2097200
    [IO.File]::WriteAllText($path, ($prefix + "`n" + $start + "`n" + $end + "`n"), [Text.UTF8Encoding]::new($false))
    $events = @(Read-CodexToolEvents -Path $path -TaskKey $task -Key $key -Since $now.AddSeconds(-1))
    if ($events.Count -ne 2) { throw "A bounded tail must skip its first partial line." }

    $incremental = Join-Path $expectedRoot "incremental.jsonl"
    [IO.File]::WriteAllText($incremental, ($start + "`n" + $end.Substring(0,20)), [Text.UTF8Encoding]::new($false))
    $cursor = New-CodexDiagnosticCursor -Path $incremental -MaximumBytes 1024
    $events = @(Read-CodexToolEventsIncremental -Path $incremental -Cursor $cursor -TaskKey $task -Key $key -Since $now.AddSeconds(-1) -MaximumBytes 1024)
    if ($events.Count -ne 1 -or $events[0].type -ne "tool_started") { throw "Incremental reading must preserve an incomplete output." }
    [IO.File]::AppendAllText($incremental, ($end.Substring(20) + "`n"), [Text.UTF8Encoding]::new($false))
    $events = @(Read-CodexToolEventsIncremental -Path $incremental -Cursor $cursor -TaskKey $task -Key $key -Since $now.AddSeconds(-1) -MaximumBytes 1024)
    if ($events.Count -ne 1 -or $events[0].type -ne "tool_finished") { throw "A call must be paired across incremental reads." }
    if (@(Read-CodexToolEventsIncremental -Path $incremental -Cursor $cursor -TaskKey $task -Key $key -Since $now.AddSeconds(-1) -MaximumBytes 1024).Count -ne 0) { throw "Unchanged data must not produce repeated events." }
    $newStart = $start.Replace("call-1","call-2")
    $newEnd = $end.Replace("call-1","call-2")
    [IO.File]::WriteAllText($incremental, ($newStart + "`n" + $newEnd + "`n"), [Text.UTF8Encoding]::new($false))
    $events = @(Read-CodexToolEventsIncremental -Path $incremental -Cursor $cursor -TaskKey $task -Key $key -Since $now.AddSeconds(-1) -MaximumBytes 1024)
    if ($events.Count -ne 2) { throw "A same-size rewrite must reset the cursor using its anchor." }

    $large = Join-Path $expectedRoot "large-line.jsonl"
    [IO.File]::WriteAllText($large, "", [Text.UTF8Encoding]::new($false))
    $cursor = New-CodexDiagnosticCursor -Path $large -MaximumBytes 256
    [IO.File]::AppendAllText($large, ("x"*300), [Text.UTF8Encoding]::new($false))
    if (@(Read-CodexToolEventsIncremental -Path $large -Cursor $cursor -TaskKey $task -Key $key -Since $now.AddSeconds(-1) -MaximumBytes 256).Count -ne 0) { throw "An oversized partial line must be skipped." }
    [IO.File]::AppendAllText($large, ("x"*100 + "`n" + $start + "`n" + $end + "`n"), [Text.UTF8Encoding]::new($false))
    $events = @(1..5 | ForEach-Object { Read-CodexToolEventsIncremental -Path $large -Cursor $cursor -TaskKey $task -Key $key -Since $now.AddSeconds(-1) -MaximumBytes 256 })
    if (@($events|Where-Object type -eq "tool_started").Count -ne 1 -or @($events|Where-Object type -eq "tool_finished").Count -ne 1) { throw "Reading must resume after an oversized line." }
    Write-Output "Diagnostic collector: bounded reads, partial records and metadata-only output verified."
} finally {
    if (Test-Path -LiteralPath $expectedRoot) {
        $resolved = (Resolve-Path -LiteralPath $expectedRoot).Path
        if ($resolved -ne $expectedRoot -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
