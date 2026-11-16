$ErrorActionPreference = "SilentlyContinue"
$installDirectory = $PSScriptRoot
$expectedInstallDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "AITaskMonitor")).TrimEnd('\')
$actualInstallDirectory = [IO.Path]::GetFullPath($installDirectory).TrimEnd('\')
if (-not [string]::Equals($actualInstallDirectory, $expectedInstallDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Uninstaller can run only from the AI task monitor installation directory."
}
$integration = Join-Path $installDirectory "Configure-ClaudeIntegration.ps1"
if (Test-Path -LiteralPath $integration) { & $integration -Mode Remove }
$openCodeIntegration = Join-Path $installDirectory "Configure-OpenCodeIntegration.ps1"
if (Test-Path -LiteralPath $openCodeIntegration) {
    try { & $openCodeIntegration -Mode Remove } catch { }
}
$shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\AI task monitor.lnk"
Remove-Item -LiteralPath $shortcutPath -Force
$literalTarget = $installDirectory.Replace("'", "''")
$cleanupCommand = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$literalTarget' -Recurse -Force"
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupCommand))
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @("-NoProfile", "-EncodedCommand", $encodedCommand)
