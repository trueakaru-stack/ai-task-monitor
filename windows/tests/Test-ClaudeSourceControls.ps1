$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The application source failed to parse.' }
$definitions = foreach($name in @('Update-ClaudeSourceStatus','Update-SourceSettings')) {
 $node = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
 if ($null -eq $node) { throw 'A source settings function is missing.' };$node.Extent.Text
}

$checks = @'
function Tr([string]$value) { return $value }
function Update-CodexCloudSourceSettings {}
function Update-OpenCodeSourceSettings {}
function Update-KimiSourceSettings {}
function Update-DeepSeekSourceSettings {}
function Update-HermesSourceSettings {}
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
$script:sourcePartialData = @();$script:sourceCodexIncomplete = $false

$script:installationFixture = 'unconfirmed'; $script:connectionFixture = 'disconnected'
Update-SourceSettings
if (-not $claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne 'Install' -or [string]::IsNullOrWhiteSpace($claudeSourceStatus.Text)) { throw 'An unconfirmed profile must allow connection and expose its uncertain status.' }
$script:installationFixture = 'not-found'; Update-SourceSettings
if ($claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne '') { throw 'A missing installation must not enable connection.' }
$script:connectionFixture = 'connected'; Update-SourceSettings
if (-not $claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne 'Remove') { throw 'An existing connection must remain removable.' }
$script:sourceErrors = @('Claude Code');$script:sourcePartialData = @('Claude Code');Update-SourceSettings
$partialText=-join @([int[]]@(1063,1072,1089,1090,1100,32,1076,1072,1085,1085,1099,1093,32,1085,1077,1076,1086,1089,1090,1091,1087,1085,1072)|ForEach-Object {[char]$_})
if ($claudeSourceStatus.Text -cne $partialText) { throw 'Partial Claude history was presented as a complete lack of data in settings.' }
$script:sourcePartialData = @();Update-SourceSettings
$missingText=-join @([int[]]@(1053,1077,1090,32,1076,1072,1085,1085,1099,1093)|ForEach-Object {[char]$_})
if ($claudeSourceStatus.Text -cne $missingText) { throw 'A fully unavailable Claude source was not reported in settings.' }
$script:sourceErrors = @()
$script:connectionFixture = 'partial'; Update-SourceSettings
if (-not $claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne 'Install') { throw 'A partial connection must remain repairable.' }
$script:connectionFixture = 'error'; Update-SourceSettings
if ($claudeSourceAction.IsEnabled -or $claudeSourceAction.Tag -ne '') { throw 'Unreadable settings must not enable connection.' }
$errorStatus=$claudeSourceStatus.Text;Update-ClaudeSourceStatus
if ($claudeSourceStatus.Text -cne $errorStatus -or $null -ne $script:claudeSourceStatusContext) { throw 'A later snapshot restored a stale status after a settings error.' }
$script:installationFixture = 'available';$script:connectionFixture = 'connected';Update-SourceSettings
$script:installationFixture = 'not-found';$script:connectionFixture = 'disconnected';Update-SourceSettings
$missingStatus=$claudeSourceStatus.Text;Update-ClaudeSourceStatus
if ($claudeSourceStatus.Text -cne $missingStatus -or $null -ne $script:claudeSourceStatusContext) { throw 'A later snapshot restored a stale status after the installation disappeared.' }
Write-Output 'Claude source controls: unconfirmed, missing, connected, partial and unreadable states verified.'
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))
