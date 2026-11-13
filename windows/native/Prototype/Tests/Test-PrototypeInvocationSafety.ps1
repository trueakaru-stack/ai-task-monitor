$ErrorActionPreference = 'Stop'
$prototype = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Test-Prototype.ps1'))
$capture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Capture-PublishedCompact.ps1'))
. (Join-Path $PSScriptRoot '..\Assert-PrototypeIsolatedInvocation.ps1')

$syntheticRoot = Join-Path ([IO.Path]::GetPathRoot($prototype)) 'AI Task Monitor fixture\PowerShell'
$syntheticHost = Join-Path $syntheticRoot 'powershell.exe'
$syntheticScript = Join-Path ([IO.Path]::GetPathRoot($prototype)) 'AI Task Monitor fixture\project\Test-Prototype.ps1'
$otherScript = Join-Path ([IO.Path]::GetPathRoot($prototype)) 'AI Task Monitor fixture\other\Test-Prototype.ps1'
$count = 0
function Expect-Allowed([string[]]$arguments, [string]$executable = $syntheticHost) {
    $confirmation = @(Assert-PrototypeIsolatedInvocation -ProcessArguments $arguments -ScriptPath $syntheticScript `
        -ExecutablePath $executable -PowerShellRoot $syntheticRoot -Edition 'Desktop')
    if ($confirmation.Count -ne 1 -or $confirmation[0] -isnot [bool] -or -not $confirmation[0]) {
        throw 'A safe invocation did not receive exactly one positive confirmation.'
    }
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
foreach ($mode in @('call','dot-source')) {
    $message = ''
    try {
        if ($mode -eq 'call') { & $capture -PublishedSource $missing -OutputFile $missing -FixtureRoot $missing -Theme dark -Language ru -Scene gap }
        else { . $capture -PublishedSource $missing -OutputFile $missing -FixtureRoot $missing -Theme dark -Language ru -Scene gap }
    } catch { $message = $_.Exception.Message }
    if ($message -notmatch 'separate PowerShell process') { throw 'The reference capture did not reject the unsafe invocation.' }
    Assert-EnvironmentUnchanged
    $count++
}

# Exercise copies of the actual guards. Replace their remaining bodies with a
# harmless sentinel, so a regression cannot mutate the test environment or
# launch the SDK or the reference application.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aitm-prototype-guard-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
foreach ($target in @(
    @{ Name='prototype'; Path=$prototype; Marker='# Prototype test body starts below the invocation guard.'; Entry='Test-Prototype.ps1'; Arguments=@{ SdkRoot=$missing; WorkDirectory=$missing } },
    @{ Name='capture'; Path=$capture; Marker='# Reference capture body starts below the invocation guard.'; Entry='Tests/Capture-PublishedCompact.ps1'; Arguments=@{ PublishedSource=$missing; OutputFile=$missing; FixtureRoot=$missing; Theme='dark'; Language='ru'; Scene='gap' } }
)) {
    $entryText = [IO.File]::ReadAllText($target.Path)
    $markerIndex = $entryText.IndexOf($target.Marker, [StringComparison]::Ordinal)
    if ($markerIndex -lt 0 -or $entryText.IndexOf($target.Marker, $markerIndex + $target.Marker.Length, [StringComparison]::Ordinal) -ge 0) {
        throw 'The entry-guard test boundary is missing or ambiguous.'
    }
    $entryGuard = $entryText.Substring(0, $markerIndex) + "`r`nthrow 'RESET_REACHED'`r`n"
    foreach ($case in @('missing','empty','invalid','no-op','false','extra')) {
        $fixture = Join-Path (Join-Path $fixtureRoot $target.Name) $case
        $entry = Join-Path $fixture $target.Entry
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($entry)) | Out-Null
        $helper = Join-Path $fixture 'Assert-PrototypeIsolatedInvocation.ps1'
        [IO.File]::WriteAllText($entry, $entryGuard, [Text.UTF8Encoding]::new($false))
        if ($case -eq 'empty') { [IO.File]::WriteAllText($helper, '', [Text.UTF8Encoding]::new($false)) }
        if ($case -eq 'invalid') { [IO.File]::WriteAllText($helper, 'function {', [Text.UTF8Encoding]::new($false)) }
        if ($case -eq 'no-op') { [IO.File]::WriteAllText($helper, 'function Assert-PrototypeIsolatedInvocation {}', [Text.UTF8Encoding]::new($false)) }
        if ($case -eq 'false') { [IO.File]::WriteAllText($helper, 'function Assert-PrototypeIsolatedInvocation { $false }', [Text.UTF8Encoding]::new($false)) }
        if ($case -eq 'extra') { [IO.File]::WriteAllText($helper, 'function Assert-PrototypeIsolatedInvocation { $true; "unexpected" }', [Text.UTF8Encoding]::new($false)) }
        foreach ($mode in @('call','dot-source')) {
            $message = ''
            $priorPreference = $ErrorActionPreference
            $entryArguments = $target.Arguments
            try {
                # The caller may use PowerShell's default non-terminating behavior.
                $ErrorActionPreference = 'Continue'
                try {
                    if ($mode -eq 'call') { & $entry @entryArguments 2>$null }
                    else { . $entry @entryArguments 2>$null }
                } catch { $message = $_.Exception.Message }
            } finally { $ErrorActionPreference = $priorPreference }
            if ($message -notmatch 'Prototype safety guard failed' -or $message -match 'RESET_REACHED') {
                throw 'The entry guard did not fail closed when its safety helper was unavailable.'
            }
            Assert-EnvironmentUnchanged
            $count++
        }
    }
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

# A separate -File reference capture must pass its real guard. Run only a
# synthetic copy whose body is a sentinel; no reference application is opened.
$positiveRoot = Join-Path $fixtureRoot 'capture-positive'
$positiveEntry = Join-Path $positiveRoot 'Tests/Capture-PublishedCompact.ps1'
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($positiveEntry)) | Out-Null
$captureText = [IO.File]::ReadAllText($capture)
$captureMarker = '# Reference capture body starts below the invocation guard.'
$captureBoundary = $captureText.IndexOf($captureMarker, [StringComparison]::Ordinal)
if ($captureBoundary -lt 0) { throw 'The reference capture guard boundary is missing.' }
[IO.File]::WriteAllText($positiveEntry, $captureText.Substring(0, $captureBoundary) + "`r`nWrite-Output 'GUARD_PASSED'`r`n", [Text.UTF8Encoding]::new($false))
[IO.File]::Copy((Join-Path $PSScriptRoot '..\Assert-PrototypeIsolatedInvocation.ps1'), (Join-Path $positiveRoot 'Assert-PrototypeIsolatedInvocation.ps1'))
if ($positiveEntry.Contains('"')) { throw 'Synthetic paths contain an unsupported quote.' }
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $windowsPowerShell
$info.Arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + $positiveEntry + '" -PublishedSource "' + $missing + '" -OutputFile "' + $missing + '" -FixtureRoot "' + $missing + '" -Theme dark -Language ru -Scene gap'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($info)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'The reference guard process did not exit.' }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or $output -notmatch 'GUARD_PASSED') { throw 'The separate reference guard did not pass.' }
} finally { $process.Dispose() }
Assert-EnvironmentUnchanged
$count++
Write-Output ('Prototype invocation safety: ' + $count + ' checks passed without a build or GUI.')
