$ErrorActionPreference = 'Stop'
$app = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
$installer = [IO.File]::ReadAllText((Join-Path $app 'Build-Installer-v2.ps1'))
$extractor = [IO.File]::ReadAllText((Join-Path $app 'CodexProgressInstaller.cs'))
$store = [IO.File]::ReadAllText([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../msix/Build-StorePackage.ps1')))
$files = @('ProviderEventView.ps1','ProviderRuntime.ps1','ProviderEventState.cs','ProviderEventChannel.cs','provider-events.mjs','provider-observers.mjs','provider-transport.mjs','opencode-entry.js')
foreach ($name in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $app 'integrations') $name) -PathType Leaf)) { throw "Missing integration source: $name" }
    if (-not $installer.Contains("integrations.$name") -or -not $extractor.Contains('"' + $name + '"') -or -not $store.Contains("'$name'")) {
        throw "An integration file is missing from a packaging path: $name"
    }
}
if (-not $installer.Contains('Configure-OpenCodeIntegration.ps1') -or -not $extractor.Contains('Configure-OpenCodeIntegration.ps1') -or -not $store.Contains('Configure-OpenCodeIntegration.ps1')) {
    throw 'The OpenCode configuration helper is missing from a packaging path.'
}
Write-Output 'OpenCode packaging: installer and Store layouts include the runtime and observer files.'
