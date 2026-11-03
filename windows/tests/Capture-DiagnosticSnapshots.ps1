param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
. (Join-Path $appRoot "DiagnosticPolicy.ps1")
. (Join-Path $appRoot "DiagnosticStore.ps1")

$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Snapshot destination already exists." }
[void][IO.Directory]::CreateDirectory($output)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-capture-" + [Guid]::NewGuid().ToString("N"))
$expectedRoot = [IO.Path]::GetFullPath($testRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $expectedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($expectedRoot)

try {
    $now = [DateTimeOffset]::UtcNow
    foreach ($theme in @("dark","light")) {
        $data = Join-Path $expectedRoot ("data-"+$theme)
        $key = Get-DiagnosticInstallationKey -Directory $data
        $task = Get-DiagnosticTaskKey -Provider "codex" -TaskId "preview-0" -Key $key
        $events = @(
            [PSCustomObject]@{version=1;time=$now.AddMinutes(-4).ToString("o");source="codex";task=$task;type="task_observed";id=(Get-DiagnosticEventKey -TaskKey $task -Type "task_observed" -Reference "capture-1" -Time $now.AddMinutes(-4) -Key $key)},
            [PSCustomObject]@{version=1;time=$now.AddMinutes(-3).ToString("o");source="codex";task=$task;type="tool_started";id=(Get-DiagnosticEventKey -TaskKey $task -Type "tool_started" -Reference "capture-2" -Time $now.AddMinutes(-3) -Key $key)},
            [PSCustomObject]@{version=1;time=$now.AddMinutes(-2).ToString("o");source="codex";task=$task;type="tool_finished";id=(Get-DiagnosticEventKey -TaskKey $task -Type "tool_finished" -Reference "capture-2" -Time $now.AddMinutes(-2) -Key $key)}
        )
        Write-DiagnosticEvents -Directory $data -Events $events -Now $now -RetentionDays 7 -MaximumBytes 10000000
        $preview = Join-Path $expectedRoot ("preview-"+$theme+".png")
        $settings = Join-Path $output ("settings-"+$theme+".png")
        $journal = Join-Path $output ("journal-"+$theme+".png")
        $dropdown = Join-Path $output ("dropdown-"+$theme+".png")
        $taskDropdown = Join-Path $output ("task-dropdown-"+$theme+".png")
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $appRoot "CodexProgress.ps1") -PreviewActiveTasks 2 -DiagnosticDirectory $data -ThemeOverride $theme -SnapshotFile $preview -SettingsSnapshotFile $settings -PreviewJournalSettings -JournalSnapshotFile $journal -JournalDropdownSnapshotFile $dropdown -JournalFilterDropdownSnapshotFile $taskDropdown
        if ($LASTEXITCODE -ne 0) { throw "Journal preview failed: $theme" }
        $filtered = Join-Path $output ("journal-filtered-"+$theme+".png")
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $appRoot "CodexProgress.ps1") -PreviewActiveTasks 2 -DiagnosticDirectory $data -ThemeOverride $theme -SnapshotFile $preview -JournalSnapshotFile $filtered -PreviewJournalFilterTask
        if ($LASTEXITCODE -ne 0) { throw "Filtered journal preview failed: $theme" }
        $confirmation = Join-Path $output ("confirmation-"+$theme+".png")
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $appRoot "CodexProgress.ps1") -PreviewActiveTasks 2 -DiagnosticDirectory $data -ThemeOverride $theme -SnapshotFile $preview -SettingsSnapshotFile $confirmation -PreviewJournalClearConfirmation
        if ($LASTEXITCODE -ne 0) { throw "Confirmation preview failed: $theme" }
    }
    Get-ChildItem -LiteralPath $output | Select-Object Name,Length
} finally {
    if (Test-Path -LiteralPath $expectedRoot) {
        $resolved = (Resolve-Path -LiteralPath $expectedRoot).Path
        if ($resolved -ne $expectedRoot -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
