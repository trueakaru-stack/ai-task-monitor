param([ValidateRange(1,40000)][int]$Count=5000,[switch]$IncludeView,[ValidateSet("dark","light")][string]$Theme="dark",[string]$EvidenceFile="")
$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
. (Join-Path $appRoot "DiagnosticPolicy.ps1")
. (Join-Path $appRoot "DiagnosticStore.ps1")

$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-measure-"+[Guid]::NewGuid().ToString("N"))))
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $root.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe benchmark directory." }
[void][IO.Directory]::CreateDirectory($root)
try {
    if ($IncludeView) { [void](Get-DiagnosticInstallationKey -Directory $root) }
    $now = [DateTimeOffset]::UtcNow
    $time = $now.ToString("o")
    $task = "a"*64
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append($script:DiagnosticHeader).Append("`n")
    for ($index=0; $index -lt $Count; $index++) {
        $id = $index.ToString("x64")
        [void]$builder.Append('{"version":1,"time":"').Append($time).Append('","source":"codex","task":"').Append($task).Append('","type":"tool_started","id":"').Append($id).Append('"}').Append("`n")
    }
    [IO.File]::WriteAllText((Join-Path $root "diagnostic-events-v1.jsonl"), $builder.ToString(), [Text.UTF8Encoding]::new($false))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $events = @(Read-DiagnosticEvents -Directory $root -Now $now -RetentionDays 7 -MaximumBytes 10000000)
    $watch.Stop()
    $readMilliseconds = $watch.ElapsedMilliseconds
    $event = [PSCustomObject]@{version=1;time=$now.AddSeconds(1).ToString("o");source="codex";task=$task;type="tool_finished";id=("f"*64)}
    $watch.Restart()
    Write-DiagnosticEvent -Directory $root -Event $event -Now $now.AddSeconds(1) -RetentionDays 7 -MaximumBytes 10000000
    $watch.Stop()
    $writeMilliseconds = $watch.ElapsedMilliseconds
    $viewMilliseconds = $null
    if ($IncludeView) {
        $watch.Restart()
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $appRoot "CodexProgress.ps1") -PreviewActiveTasks 0 -DiagnosticDirectory $root -ThemeOverride $Theme -SnapshotFile (Join-Path $root "preview.png") -JournalSnapshotFile (Join-Path $root "journal.png")
        $watch.Stop()
        if ($LASTEXITCODE -ne 0) { throw "The journal preview failed." }
        if ($EvidenceFile) {
            if (Test-Path -LiteralPath $EvidenceFile) { throw "The requested evidence file already exists." }
            Copy-Item -LiteralPath (Join-Path $root "journal.png") -Destination $EvidenceFile
        }
        $viewMilliseconds = $watch.ElapsedMilliseconds
    }
    [PSCustomObject]@{Events=$events.Count;ReadMilliseconds=$readMilliseconds;WriteMilliseconds=$writeMilliseconds;PreviewMilliseconds=$viewMilliseconds}
} finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe benchmark cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
