$ErrorActionPreference = 'Stop'
if ($env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:GITHUB_ACTIONS -cne 'true' -or -not $env:RUNNER_TEMP) {
    throw 'The rendered compact-switch check requires a disposable GitHub-hosted Windows runner.'
}

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
if (-not [IO.Directory]::Exists($runnerTemp)) { throw 'The hosted-runner temporary directory is unavailable.' }
$root = [IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-compact-switch-' + [Guid]::NewGuid().ToString('N'))))
if (-not $root.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($root)) {
    throw 'The synthetic compact-switch directory is unsafe.'
}
foreach ($name in @('profile', 'appdata', 'localappdata', 'temp')) {
    [void][IO.Directory]::CreateDirectory((Join-Path $root $name))
}

$app = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'))
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$snapshot = Join-Path $root 'temp\compact-switch.png'
$preferences = Join-Path $root 'temp\preferences.json'
$diagnostics = Join-Path $root 'temp\diagnostics'
$appArguments = @(
    '-NoProfile', '-STA', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $app,
    '-PreviewActiveTasks', '2', '-PreviewOffscreen', '-PreviewCompactSwitchUiTest', '-CompactMode',
    '-ThemeOverride', 'dark', '-LanguageOverride', 'ru', '-SnapshotFile', $snapshot,
    '-PreferencesFile', $preferences, '-DiagnosticDirectory', $diagnostics
)
foreach ($argument in $appArguments) {
    if ($argument.Contains('"') -or $argument.EndsWith('\')) { throw 'Unsupported synthetic argument.' }
}

$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $powerShell
$info.Arguments = ($appArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
$info.WorkingDirectory = $root
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables.Clear()
$childEnvironment = @{
    SystemRoot = $env:SystemRoot
    windir = $env:SystemRoot
    PATH = ((Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
    USERPROFILE = (Join-Path $root 'profile')
    APPDATA = (Join-Path $root 'appdata')
    LOCALAPPDATA = (Join-Path $root 'localappdata')
    TEMP = (Join-Path $root 'temp')
    TMP = (Join-Path $root 'temp')
    CODEX_HOME = (Join-Path $root 'profile\.codex')
    RUNNER_TEMP = $env:RUNNER_TEMP
    RUNNER_ENVIRONMENT = $env:RUNNER_ENVIRONMENT
    RUNNER_OS = $env:RUNNER_OS
    GITHUB_ACTIONS = $env:GITHUB_ACTIONS
    CI = $env:CI
    DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
    DOTNET_GENERATE_ASPNET_CERTIFICATE = '0'
    DOTNET_CLI_TELEMETRY_OPTOUT = '1'
}
foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'SystemDrive', 'ComSpec', 'PATHEXT')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if (-not [string]::IsNullOrEmpty($value)) { $childEnvironment[$name] = $value }
}
foreach ($name in $childEnvironment.Keys) { $info.EnvironmentVariables[$name] = [string]$childEnvironment[$name] }

$process = [Diagnostics.Process]::Start($info)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(45000)) {
        $process.Kill()
        [void]$process.WaitForExit(5000)
        throw 'The rendered compact-switch check timed out.'
    }
    if ($process.ExitCode -ne 0) { throw ('The rendered compact-switch check failed: ' + $stderr.Result) }
    $lines = @($stdout.Result -split "`r?`n" | Where-Object { $_.StartsWith('CompactSwitchUi: ', [StringComparison]::Ordinal) })
    if ($lines.Count -ne 1) { throw 'The rendered compact-switch measurement is missing or duplicated.' }
    $measurement = $lines[0].Substring('CompactSwitchUi: '.Length) | ConvertFrom-Json -ErrorAction Stop
    if ($measurement.scriptedClicks -ne 2 -or -not $measurement.buttonsPreserved -or -not $measurement.renderingChanged -or
        $measurement.firstHandlerMs -lt 0 -or $measurement.secondHandlerMs -lt 0) {
        throw 'The rendered compact-switch measurement is incomplete.'
    }
    if (-not [IO.File]::Exists($snapshot) -or (Get-Item -LiteralPath $snapshot).Length -eq 0) {
        throw 'The compact-switch snapshot is missing.'
    }
    Write-Output ('Rendered compact switch: scripted Button.Click, not physical mouse; handler_ms={0},{1}' -f $measurement.firstHandlerMs, $measurement.secondHandlerMs)
} finally {
    $process.Dispose()
}
