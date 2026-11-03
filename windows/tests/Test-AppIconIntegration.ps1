$ErrorActionPreference = "Stop"
$app = Join-Path $PSScriptRoot "..\app\CodexProgress.ps1"
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-icon-ui-" + [Guid]::NewGuid().ToString("N"))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture path." }
[void][IO.Directory]::CreateDirectory($root)
try {
    foreach ($mode in @("full", "compact")) {
        $parameters = @("-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", $app, "-PreviewActiveTasks", "1", "-PreviewIconUiTest", "-SnapshotFile", (Join-Path $root ($mode + ".png")))
        if ($mode -eq "compact") { $parameters += "-CompactMode" }
        & powershell.exe @parameters
        if ($LASTEXITCODE -ne 0) { throw "Icon UI test failed: $mode." }
    }
} finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
