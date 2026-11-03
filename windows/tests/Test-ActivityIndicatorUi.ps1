$ErrorActionPreference = 'Stop'
$app = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'))
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-activity-indicator-ui-' + [guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory($root)
$oldLocal = $env:LOCALAPPDATA; $oldProfile = $env:USERPROFILE; $oldCodex = $env:CODEX_HOME
try {
    $env:LOCALAPPDATA = $root; $env:USERPROFILE = $root; $env:CODEX_HOME = Join-Path $root 'codex'
    foreach ($theme in @('dark', 'light')) {
        foreach ($mode in @('expanded', 'compact')) {
            foreach ($state in @('active-default', 'active-motion', 'active-preview-static', 'unconfirmed')) {
                $snapshot = Join-Path $root ($theme + '-' + $mode + '-' + $state + '.png')
                $parameters = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $app,
                    '-PreviewActiveTasks', '1', '-PreviewMotionUiTest', '-PreviewOffscreen', '-ThemeOverride', $theme, '-SnapshotFile', $snapshot)
                if ($mode -eq 'compact') { $parameters += '-CompactMode' }
                if ($state -eq 'unconfirmed') { $parameters += @('-PreviewMotion', 'on', '-PreviewUnconfirmed') }
                elseif ($state -eq 'active-preview-static') { $parameters += @('-PreviewMotion', 'off', '-PreviewScenario', 'unplanned', '-PreviewActivityUiTest') }
                elseif ($state -eq 'active-default') { $parameters += @('-PreviewMotion', 'default', '-PreviewScenario', 'unplanned', '-PreviewActivityUiTest') }
                else { $parameters += @('-PreviewMotion', 'on', '-PreviewScenario', 'planned', '-PreviewActivityUiTest') }
                & powershell.exe @parameters
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot -PathType Leaf)) { throw "Activity indicator UI failed: $theme $mode $state." }
            }
        }
    }
    Write-Output 'Activity indicator UI: 16 by 4 px optical alignment, both themes and window modes, planned and unplanned tasks, active and unconfirmed states verified.'
} finally {
    $env:LOCALAPPDATA = $oldLocal; $env:USERPROFILE = $oldProfile; $env:CODEX_HOME = $oldCodex
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
