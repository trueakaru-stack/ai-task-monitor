param([string]$OutputDirectory="",[string]$BuildTempDirectory="")

$ErrorActionPreference = "Stop"
$source = $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $source "dist" }
$outputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$output = Join-Path $outputDirectory "AITaskMonitorSetup.exe"
$compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path -LiteralPath $compiler)) { throw "C# compiler was not found" }

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$buildTemp = if ($BuildTempDirectory) { [IO.Path]::GetFullPath($BuildTempDirectory) } else { Join-Path $source "build-temp" }
New-Item -ItemType Directory -Path $buildTemp -Force | Out-Null
$env:TEMP = $buildTemp
$env:TMP = $buildTemp

$launcher = Join-Path $buildTemp "AI task monitor.exe"
$launcherArguments = @(
    "/nologo",
    "/target:winexe",
    "/optimize+",
    "/out:$launcher",
    "/win32icon:$(Join-Path $source 'assets\app-icon.ico')",
    (Join-Path $source "CodexTasksLauncher.cs")
)
& $compiler $launcherArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcher)) { throw "Launcher compilation failed" }

$arguments = @(
    "/nologo",
    "/target:winexe",
    "/optimize+",
    "/out:$output",
    "/win32icon:$(Join-Path $source 'assets\app-icon.ico')",
    "/reference:System.Windows.Forms.dll",
    "/resource:$(Join-Path $source 'CodexProgress.ps1'),CodexProgress.ps1",
    "/resource:$(Join-Path $source 'Uninstall-CodexProgress.ps1'),Uninstall-CodexProgress.ps1",
    "/resource:$(Join-Path $source 'Uninstall-CodexProgress.cmd'),Uninstall-CodexProgress.cmd",
    "/resource:$(Join-Path $source 'ClaudeTaskHook.ps1'),ClaudeTaskHook.ps1",
    "/resource:$(Join-Path $source 'ClaudeLoopClient.ps1'),ClaudeLoopClient.ps1",
    "/resource:$(Join-Path $source 'ClaudeLoopDetection.ps1'),ClaudeLoopDetection.ps1",
    "/resource:$(Join-Path $source 'ClaudeLoopChannel.cs'),ClaudeLoopChannel.cs",
    "/resource:$(Join-Path $source 'ClaudeReaderCore.ps1'),ClaudeReaderCore.ps1",
    "/resource:$(Join-Path $source 'ClaudeRetention.cs'),ClaudeRetention.cs",
    "/resource:$(Join-Path $source 'AppShellIdentity.cs'),AppShellIdentity.cs",
    "/resource:$(Join-Path $source 'Configure-ClaudeIntegration.ps1'),Configure-ClaudeIntegration.ps1",
    "/resource:$(Join-Path $source 'Configure-OpenCodeIntegration.ps1'),Configure-OpenCodeIntegration.ps1",
    "/resource:$(Join-Path $source 'integrations\ProviderEventView.ps1'),integrations.ProviderEventView.ps1",
    "/resource:$(Join-Path $source 'integrations\ProviderRuntime.ps1'),integrations.ProviderRuntime.ps1",
    "/resource:$(Join-Path $source 'integrations\ProviderEventState.cs'),integrations.ProviderEventState.cs",
    "/resource:$(Join-Path $source 'integrations\ProviderEventChannel.cs'),integrations.ProviderEventChannel.cs",
    "/resource:$(Join-Path $source 'integrations\provider-events.mjs'),integrations.provider-events.mjs",
    "/resource:$(Join-Path $source 'integrations\provider-observers.mjs'),integrations.provider-observers.mjs",
    "/resource:$(Join-Path $source 'integrations\provider-transport.mjs'),integrations.provider-transport.mjs",
    "/resource:$(Join-Path $source 'integrations\opencode-entry.js'),integrations.opencode-entry.js",
    "/resource:$(Join-Path $source 'integrations\DeepSeekRuntime.ps1'),integrations.DeepSeekRuntime.ps1",
    "/resource:$(Join-Path $source 'integrations\CodexCloudRuntime.ps1'),integrations.CodexCloudRuntime.ps1",
    "/resource:$(Join-Path $source 'integrations\CodexCloudProcess.cs'),integrations.CodexCloudProcess.cs",
    "/resource:$(Join-Path $source 'integrations\deepseek-integration.mjs'),integrations.deepseek-integration.mjs",
    "/resource:$(Join-Path $source 'integrations\deepseek-setup.mjs'),integrations.deepseek-setup.mjs",
    "/resource:$(Join-Path $source 'integrations\deepseek-plugin.js'),integrations.deepseek-plugin.js",
    "/resource:$(Join-Path $source 'integrations\package.json'),integrations.package.json",
    "/resource:$(Join-Path $source 'integrations\cordis.patch.yml'),integrations.cordis.patch.yml",
    "/resource:$(Join-Path $source 'DiagnosticPolicy.ps1'),DiagnosticPolicy.ps1",
    "/resource:$(Join-Path $source 'DiagnosticStore.ps1'),DiagnosticStore.ps1",
    "/resource:$(Join-Path $source 'LoopDetection.ps1'),LoopDetection.ps1",
    "/resource:$(Join-Path $source 'DiagnosticCollector.ps1'),DiagnosticCollector.ps1",
    "/resource:$(Join-Path $source 'DiagnosticRuntime.ps1'),DiagnosticRuntime.ps1",
    "/resource:$(Join-Path $source 'ReleaseUpdates.ps1'),ReleaseUpdates.ps1",
    "/resource:$launcher,AI task monitor.exe",
    "/resource:$(Join-Path $source 'assets\app-icon.ico'),app-icon.ico",
    (Join-Path $source "CodexProgressInstaller.cs")
)

& $compiler $arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw "Installer compilation failed" }
Get-Item -LiteralPath $output
