$ErrorActionPreference = 'Stop'
$app = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\ClaudeTaskHook.ps1'))
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-hook-lock-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory($root)
$name = 'AITM.Test.Log.' + [Guid]::NewGuid().ToString('N')
$mutex = [Threading.Mutex]::new($true, 'Local\' + $name)
$oldData = $env:LOCALAPPDATA; $oldAudit = $env:AI_TASK_MONITOR_AUDIT
try {
    $env:LOCALAPPDATA = $root
    $env:AI_TASK_MONITOR_AUDIT = '1'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'powershell.exe'
    $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $app + '" -LogTestMutex "' + $name + '"'
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardError = $true
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.StandardInput.Write('{"hook_event_name":"UserPromptSubmit","session_id":"synthetic"}')
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(6000)) { throw 'The hook exceeded its bounded log-lock wait.' }
        $watch.Stop()
        if ($process.ExitCode -ne 0) { throw ('The hook did not fail open: ' + $process.StandardError.ReadToEnd()) }
        if ($watch.ElapsedMilliseconds -lt 1600 -or $watch.ElapsedMilliseconds -gt 4500) { throw ("Unexpected hook lock wait: $($watch.ElapsedMilliseconds) ms") }
        if (Test-Path -LiteralPath (Join-Path $root 'CodexTaskProgress\claude-events-v2.jsonl')) { throw 'The blocked fixture unexpectedly wrote an event.' }
    } finally { $process.Dispose() }
    Write-Output 'Claude event log: a busy lock is bounded to two seconds and the hook fails open.'
} finally {
    $mutex.ReleaseMutex(); $mutex.Dispose()
    $env:LOCALAPPDATA = $oldData; $env:AI_TASK_MONITOR_AUDIT = $oldAudit
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
