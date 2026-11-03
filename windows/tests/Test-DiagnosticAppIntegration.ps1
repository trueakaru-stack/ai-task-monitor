$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
. (Join-Path $appRoot "DiagnosticPolicy.ps1")
. (Join-Path $appRoot "DiagnosticStore.ps1")

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-app-test-" + [Guid]::NewGuid().ToString("N"))
$expectedRoot = [IO.Path]::GetFullPath($testRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $expectedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($expectedRoot)
try {
    $data = Join-Path $expectedRoot "data"
    $snapshot = Join-Path $expectedRoot "preview.png"
    $settingsSnapshot = Join-Path $expectedRoot "settings.png"
    $journalSnapshot = Join-Path $expectedRoot "journal.png"
    $dropdownSnapshot = Join-Path $expectedRoot "dropdown.png"
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $appRoot "CodexProgress.ps1") -PreviewActiveTasks 1 -DiagnosticDirectory $data -ThemeOverride dark -SnapshotFile $snapshot -SettingsSnapshotFile $settingsSnapshot -PreviewJournalSettings -JournalSnapshotFile $journalSnapshot -JournalDropdownSnapshotFile $dropdownSnapshot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot) -or -not (Test-Path -LiteralPath $settingsSnapshot) -or -not (Test-Path -LiteralPath $journalSnapshot) -or -not (Test-Path -LiteralPath $dropdownSnapshot)) { throw "The WPF preview failed." }
    $events = @(Read-DiagnosticEvents -Directory $data -Now ([DateTimeOffset]::UtcNow) -RetentionDays 7 -MaximumBytes 10000000)
    if (@($events|Where-Object type -eq "task_observed").Count -ne 1) { throw "The application did not record the synthetic task observation." }
    $raw = [IO.File]::ReadAllText((Join-Path $data "diagnostic-events-v1.jsonl"))
    if ($raw -match 'preview-0|title|activity|prompt|command|output') { throw "The diagnostic log contains a raw task ID or text field." }
    Write-Output "Diagnostic app integration: WPF preview writes only pseudonymous metadata."
} finally {
    if (Test-Path -LiteralPath $expectedRoot) {
        $resolved = (Resolve-Path -LiteralPath $expectedRoot).Path
        if ($resolved -ne $expectedRoot -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
