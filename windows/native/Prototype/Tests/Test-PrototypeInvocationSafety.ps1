$ErrorActionPreference = 'Stop'
$prototype = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Test-Prototype.ps1'))
. (Join-Path $PSScriptRoot '..\Assert-PrototypeIsolatedInvocation.ps1')

$syntheticRoot = Join-Path ([IO.Path]::GetPathRoot($prototype)) 'AI Task Monitor fixture\PowerShell'
$syntheticHost = Join-Path $syntheticRoot 'powershell.exe'
$syntheticScript = Join-Path ([IO.Path]::GetPathRoot($prototype)) 'AI Task Monitor fixture\project\Test-Prototype.ps1'
$otherScript = Join-Path ([IO.Path]::GetPathRoot($prototype)) 'AI Task Monitor fixture\other\Test-Prototype.ps1'
$count = 0
function Expect-Allowed([string[]]$arguments, [string]$executable = $syntheticHost) {
    Assert-PrototypeIsolatedInvocation -ProcessArguments $arguments -ScriptPath $syntheticScript `
        -ExecutablePath $executable -PowerShellRoot $syntheticRoot -Edition 'Desktop'
    $script:count++
}
function Expect-Rejected([string[]]$arguments, [string]$executable = $syntheticHost) {
    $rejected = $false
    try {
        Assert-PrototypeIsolatedInvocation -ProcessArguments $arguments -ScriptPath $syntheticScript `
            -ExecutablePath $executable -PowerShellRoot $syntheticRoot -Edition 'Desktop'
    } catch { $rejected = $_.Exception.Message -match 'separate PowerShell process' }
    if (-not $rejected) { throw 'An unsafe invocation was accepted or produced an unrelated error.' }
    $script:count++
}

Expect-Allowed @($syntheticHost, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $syntheticScript, '-SdkRoot', 'fixture')
Expect-Allowed @($syntheticHost, '-noprofile', '-noninteractive', '-file', $syntheticScript.ToUpperInvariant())
Expect-Allowed @($syntheticHost, '-WindowStyle', 'Hidden', '-NoLogo', '-File', $syntheticScript)
Expect-Allowed @($syntheticHost, '-File', (Join-Path (Split-Path $syntheticScript -Parent) '..\project\Test-Prototype.ps1'))
Expect-Rejected @($syntheticHost, '-Command', '& Test-Prototype.ps1')
Expect-Rejected @($syntheticHost, '-Command', '. Test-Prototype.ps1')
Expect-Rejected @($syntheticHost, '-NoExit', '-File', $syntheticScript)
Expect-Rejected @($syntheticHost, '-noe', '-File', $syntheticScript)
Expect-Rejected @($syntheticHost, '-EncodedCommand', 'fixture', '-File', $syntheticScript)
Expect-Rejected @($syntheticHost, '-File', $otherScript, $syntheticScript)
Expect-Rejected @($syntheticHost, '-File', $syntheticScript) (Join-Path ([IO.Path]::GetPathRoot($prototype)) 'other\powershell.exe')
Expect-Rejected @($syntheticHost, '-ExecutionPolicy', '-NoExit', '-File', $syntheticScript)
Expect-Rejected @($syntheticHost, '-File')

# Calling the real entry point inside this process must fail before changing its
# process environment. The deliberately missing SDK prevents a build even if
# the guard regresses; no application window or SDK process is started.
$before = [Environment]::GetEnvironmentVariables('Process')
function Assert-EnvironmentUnchanged {
    $after = [Environment]::GetEnvironmentVariables('Process')
    if ($after.Count -ne $before.Count) { throw 'The caller process environment changed.' }
    foreach ($key in $before.Keys) {
        if (-not $after.Contains($key) -or [string]$after[$key] -cne [string]$before[$key]) { throw 'The caller process environment changed.' }
    }
}
$missing = Join-Path ([IO.Path]::GetPathRoot($prototype)) ('aitm-missing-' + [Guid]::NewGuid().ToString('N'))
if ([IO.Directory]::Exists($missing)) { throw 'The synthetic missing directory unexpectedly exists.' }
foreach ($mode in @('call','dot-source')) {
    $message = ''
    try {
        if ($mode -eq 'call') { & $prototype -SdkRoot $missing -WorkDirectory $missing }
        else { . $prototype -SdkRoot $missing -WorkDirectory $missing }
    } catch { $message = $_.Exception.Message }
    if ($message -notmatch 'separate PowerShell process') { throw 'The real entry point did not reject the unsafe invocation.' }
    Assert-EnvironmentUnchanged
    $count++
}

# A dedicated Windows PowerShell -File invocation must pass the guard and stop
# at the missing SDK. It cannot reach the build or launch a window.
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not [IO.File]::Exists($windowsPowerShell)) { throw 'Windows PowerShell is unavailable.' }
foreach ($value in @($prototype, $missing)) { if ($value.Contains('"')) { throw 'Synthetic paths contain an unsupported quote.' } }
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $windowsPowerShell
$info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $prototype + '" -SdkRoot "' + $missing + '" -WorkDirectory "' + $missing + '"'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($info)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'The separate process did not exit.' }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -eq 0 -or $output -notmatch 'The isolated \.NET SDK is missing') { throw 'The documented separate process did not reach the expected SDK check.' }
} finally { $process.Dispose() }
Assert-EnvironmentUnchanged
$count++
Write-Output ('Prototype invocation safety: ' + $count + ' checks passed without a build or GUI.')
