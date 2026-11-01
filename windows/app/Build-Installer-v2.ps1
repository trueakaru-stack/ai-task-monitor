$ErrorActionPreference = "Stop"
$source = $PSScriptRoot
$outputDirectory = Join-Path $source "dist"
$output = Join-Path $outputDirectory "AITaskMonitorSetup.exe"
$compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path -LiteralPath $compiler)) { throw "C# compiler was not found" }

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$buildTemp = Join-Path $source "build-temp"
New-Item -ItemType Directory -Path $buildTemp -Force | Out-Null
$env:TEMP = $buildTemp
$env:TMP = $buildTemp

$arguments = @(
    "/nologo",
    "/target:winexe",
    "/optimize+",
    "/out:$output",
    "/reference:System.Windows.Forms.dll",
    "/resource:$(Join-Path $source 'CodexProgress.ps1'),CodexProgress.ps1",
    "/resource:$(Join-Path $source 'Uninstall-CodexProgress.ps1'),Uninstall-CodexProgress.ps1",
    "/resource:$(Join-Path $source 'Uninstall-CodexProgress.cmd'),Uninstall-CodexProgress.cmd",
    "/resource:$(Join-Path $source 'ClaudeTaskHook.ps1'),ClaudeTaskHook.ps1",
    "/resource:$(Join-Path $source 'Configure-ClaudeIntegration.ps1'),Configure-ClaudeIntegration.ps1",
    (Join-Path $source "CodexProgressInstaller.cs")
)

& $compiler $arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw "Installer compilation failed" }
Get-Item -LiteralPath $output
