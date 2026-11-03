$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
$build = [IO.File]::ReadAllText((Join-Path $appRoot "Build-Installer-v2.ps1"))
$installer = [IO.File]::ReadAllText((Join-Path $appRoot "CodexProgressInstaller.cs"))
foreach ($name in @("ClaudeReaderCore.ps1","ClaudeLoopClient.ps1","ClaudeLoopDetection.ps1","ClaudeLoopChannel.cs","AppShellIdentity.cs","DiagnosticPolicy.ps1","DiagnosticStore.ps1","LoopDetection.ps1","DiagnosticCollector.ps1","DiagnosticRuntime.ps1","ReleaseUpdates.ps1")) {
    if (-not (Test-Path -LiteralPath (Join-Path $appRoot $name) -PathType Leaf)) { throw "Missing diagnostic module: $name" }
    if (-not $build.Contains("'),$name")) { throw "Build source does not embed $name." }
    if (-not $installer.Contains(('Extract("{0}",' -f $name))) { throw "Installer source does not extract $name." }
}
Write-Output "Diagnostic packaging: all source resources are declared and extracted; no installer was built."
