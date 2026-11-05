$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The application source failed to parse.' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-SourceSettings' }, $true)
if ($null -eq $definition) { throw 'The source settings function is missing.' }

$checks = @'
function Tr([string]$value) { return $value }
function Update-CodexCloudSourceSettings {}
function Update-OpenCodeSourceSettings {}
function Update-DeepSeekSourceSettings {}
function Claude-InstallationState { return $script:installationFixture }
function Claude-ConnectionState {
    if ($script:connectionFixture -eq 'error') { throw 'Synthetic unreadable settings.' }
    return $script:connectionFixture
}
$codexSourceStatus = [Windows.Controls.TextBlock]::new()
$claudeSourceStatus = [Windows.Controls.TextBlock]::new()
$claudeSourceAction = [Windows.Controls.Button]::new()
$sessionIndex = Join-Path ([IO.Path]::GetTempPath()) ('aitm-no-index-' + [Guid]::NewGuid().ToString('N'))
$script:sourceErrors = @()

$script:installationFixture = 'unconfirmed'; $script:connectionFixture = 'disconnected'
Update-SourceSettings
if (-not $claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne 'Install' -or [string]::IsNullOrWhiteSpace($claudeSourceStatus.Text)) { throw 'An unconfirmed profile must allow connection and expose its uncertain status.' }
$script:installationFixture = 'not-found'; Update-SourceSettings
if ($claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne '') { throw 'A missing installation must not enable connection.' }
$script:connectionFixture = 'connected'; Update-SourceSettings
if (-not $claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne 'Remove') { throw 'An existing connection must remain removable.' }
$script:connectionFixture = 'partial'; Update-SourceSettings
if (-not $claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne 'Install') { throw 'A partial connection must remain repairable.' }
$script:connectionFixture = 'error'; Update-SourceSettings
if ($claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne '') { throw 'Unreadable settings must not enable connection.' }
Write-Output 'Claude source controls: unconfirmed, missing, connected, partial and unreadable states verified.'
'@
& ([scriptblock]::Create($definition.Extent.Text + "`n" + $checks))
