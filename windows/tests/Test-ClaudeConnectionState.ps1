$ErrorActionPreference = 'Stop'

$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
$source = Join-Path $appRoot 'CodexProgress.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The application source failed to parse.' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Claude-ConnectionState' }, $true)
if ($null -eq $definition) { throw 'The source connection function is missing.' }
$appLiteral = "'" + $appRoot.Replace("'", "''") + "'"
$code = $definition.Extent.Text.Replace('$PSScriptRoot', $appLiteral)

$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-connection-state-' + [Guid]::NewGuid().ToString('N'))))
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $root.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory((Join-Path $root '.claude'))
$originalProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $root
    $checks = @'
$settingsPath = Join-Path (Join-Path $env:USERPROFILE '.claude') 'settings.json'
$events = @('UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'TaskCreated', 'TaskCompleted', 'SubagentStart', 'SubagentStop', 'Stop', 'SessionEnd')
$hook = Join-Path $args[0] 'ClaudeTaskHook.ps1'
$legacy = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $hook + '"'
function Write-Hooks($hooks) {
    $value = @{ hooks = $hooks } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($settingsPath, $value, [Text.UTF8Encoding]::new($false))
}
Write-Hooks @{}
if ((Claude-ConnectionState) -ne 'disconnected') { throw 'No owned hooks must be disconnected.' }
$partial = @{ PreToolUse = @(@{ hooks = @(@{ type='command'; command=$legacy }) }) }
Write-Hooks $partial
if ((Claude-ConnectionState) -ne 'partial') { throw 'A single owned hook must be reported as partial.' }
$complete = @{}
foreach ($event in $events) { $complete[$event] = @(@{ hooks = @(@{ type='command'; command=$legacy }) }) }
Write-Hooks $complete
if ((Claude-ConnectionState) -ne 'connected') { throw 'All owned hooks must be reported as connected.' }
$complete.Remove('Stop')
Write-Hooks $complete
if ((Claude-ConnectionState) -ne 'partial') { throw 'A missing Stop hook must be reported as partial.' }
Write-Output 'Claude connection states: disconnected, partial and complete verified.'
'@
    & ([scriptblock]::Create($code + "`n" + $checks)) $appRoot
} finally {
    $env:USERPROFILE = $originalProfile
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
