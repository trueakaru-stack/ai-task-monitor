param([string]$NodeExe = '')
$ErrorActionPreference = 'Stop'
if (-not $NodeExe) { $NodeExe = (Get-Command node.exe -ErrorAction Stop).Source }
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path @((Join-Path $PSScriptRoot '../app/integrations/ProviderEventState.cs'), (Join-Path $PSScriptRoot '../app/integrations/ProviderEventChannel.cs')) -ReferencedAssemblies System.Web.Extensions
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app/integrations'))
$fixture = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-dsh-profiles-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $fixture.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
[void][IO.Directory]::CreateDirectory($fixture)
$channel = $null
$process = $null
try {
    $profiles = @()
    foreach ($namespace in @(('a' * 32), ('b' * 32))) {
        $directory = Join-Path $fixture $namespace.Substring(0, 1)
        [void][IO.Directory]::CreateDirectory($directory)
        foreach ($name in @('package.json', 'deepseek-plugin.js', 'provider-events.mjs', 'provider-observers.mjs', 'provider-transport.mjs')) {
            [IO.File]::Copy((Join-Path $source $name), (Join-Path $directory $name))
        }
        [IO.File]::WriteAllText((Join-Path $directory 'monitor-profile.json'), ('{"namespace":"' + $namespace + '"}'), [Text.UTF8Encoding]::new($false))
        $profiles += $directory
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $profileHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fixture)), 0, 12).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $channel = [AITaskMonitor.ExternalProviders.EventChannel]::new('AITaskMonitor.ProviderEvents.' + $profileHash)
    $channel.SetAllowedProviders(@('deepseek'))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $NodeExe
    $start.Arguments = '"' + (Join-Path $PSScriptRoot 'Invoke-DeepSeekProfilesFixture.mjs') + '" "' + $profiles[0] + '" "' + $profiles[1] + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['USERPROFILE'] = $fixture
    $process = [Diagnostics.Process]::Start($start)
    if (-not $process.WaitForExit(10000)) { throw 'The synthetic DeepSeek observers did not exit.' }
    if ($process.ExitCode -ne 0) { throw ('Synthetic DeepSeek observer failed: ' + $process.StandardError.ReadToEnd()) }
    $batch = $channel.Drain()
    if ($batch.Gap -or $batch.Events.Count -ne 6) { throw ('Expected six ordered events without a transport gap: ' + $channel.DiagnosticCounts) }
    if (@($batch.Events | Where-Object { $_.Provider -cne 'deepseek' }).Count) { throw 'Unexpected provider.' }
    $sessions = @($batch.Events | Select-Object -ExpandProperty Session -Unique)
    if ($sessions.Count -ne 2 -or $sessions[0] -eq $sessions[1]) { throw 'Equal IDs from different profiles were mixed.' }
    if (@($batch.Events | Where-Object { $_.Session -match 'same|SECRET' -or $_.Call -match 'tool:call' }).Count) { throw 'A raw session, tool ID or private payload was forwarded.' }
    $toolEvents = @($batch.Events | Where-Object { $_.Kind -in @('tool_started', 'tool_finished') })
    if ($toolEvents.Count -ne 2 -or $toolEvents[0].Call -cne $toolEvents[1].Call -or $toolEvents[0].Action -cne 'command') { throw 'Opaque tool IDs were not correctly paired.' }
    $store = [AITaskMonitor.ExternalProviders.StateStore]::new()
    foreach ($event in $batch.Events) { [void]$store.Apply($event, $event.ObservedAt) }
    $states = @($store.Snapshot([DateTimeOffset]::UtcNow))
    if ($states.Count -ne 2) { throw 'The runtime did not preserve two separate tasks.' }
    if (@($states | Where-Object { $_.Status -eq 'waiting' }).Count -ne 1) { throw 'The second profile did not remain waiting.' }
    $planned = @($states | Where-Object { $_.Steps.Count -eq 1 })
    if ($planned.Count -ne 1 -or $planned[0].Steps[0].title -cne 'Profile one step') { throw 'The plan crossed profile boundaries or was lost.' }
    Write-Output 'DeepSeek: two profiles with the same session ID stayed independent through the local channel and state store.'
} finally {
    if ($null -ne $process) { $process.Dispose() }
    if ($null -ne $channel) { $channel.Dispose() }
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).Path
        if ($resolved -ne $fixture -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
