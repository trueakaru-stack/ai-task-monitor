$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-opencode-uninstall-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
$oldLocal = $env:LOCALAPPDATA; $oldRoaming = $env:APPDATA; $oldProfile = $env:USERPROFILE
try {
    $env:LOCALAPPDATA = Join-Path $root 'local'
    $env:APPDATA = Join-Path $root 'roaming'
    $env:USERPROFILE = Join-Path $root 'profile'
    $install = Join-Path $env:LOCALAPPDATA 'AITaskMonitor'
    $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
    foreach ($path in @($install, $env:APPDATA, $env:USERPROFILE)) { [void][IO.Directory]::CreateDirectory($path) }
    foreach ($name in @('Uninstall-CodexProgress.ps1', 'Configure-OpenCodeIntegration.ps1')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $install $name)
    }
    $integrationAssets = Join-Path $install 'integrations'
    [void][IO.Directory]::CreateDirectory($integrationAssets)
    foreach ($name in @('opencode-entry.js', 'provider-events.mjs', 'provider-observers.mjs', 'provider-transport.mjs')) {
        Copy-Item -LiteralPath (Join-Path (Join-Path $source 'integrations') $name) -Destination (Join-Path $integrationAssets $name)
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'Configure-OpenCodeIntegration.ps1') -Mode Install -FixtureHome $env:USERPROFILE
    if ($LASTEXITCODE -ne 0) { throw 'Fixture connection failed.' }
    $plugins = Join-Path $env:USERPROFILE '.config\opencode\plugins'
    $unrelated = Join-Path $plugins 'unrelated.js'
    [IO.File]::WriteAllText($unrelated, 'KEEP')
    $settings = Join-Path $env:LOCALAPPDATA 'CodexTaskProgress\settings.json'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($settings))
    [IO.File]::WriteAllText($settings, 'KEEP')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'Uninstall-CodexProgress.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Fixture uninstaller failed.' }
    if (Test-Path -LiteralPath (Join-Path $plugins 'ai-task-monitor.js')) { throw 'Owned OpenCode plugin remained after uninstall.' }
    if ([IO.File]::ReadAllText($unrelated) -cne 'KEEP' -or [IO.File]::ReadAllText($settings) -cne 'KEEP') { throw 'Uninstall changed unrelated files or settings.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ((Test-Path -LiteralPath $install) -and $watch.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 100 }
    if (Test-Path -LiteralPath $install) { throw 'Fixture installation directory remained.' }
    Write-Output 'Uninstall: only the owned OpenCode plugin was removed; unrelated files and settings were preserved.'
} finally {
    $env:LOCALAPPDATA = $oldLocal; $env:APPDATA = $oldRoaming; $env:USERPROFILE = $oldProfile
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
