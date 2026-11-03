$ErrorActionPreference = "Stop"

$source = Join-Path (Join-Path $PSScriptRoot "..\app") "CodexProgress.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Unable to parse the application." }
$definitions = foreach ($name in @("Prop", "Source-Snapshot", "Unconfirmed-Tasks")) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $function) { throw "Missing source function: $name" }
    $function.Extent.Text
}

$checks = @'
$script:codexFails = $false
$script:claudeFails = $false
$script:claudeConnection = "connected"
$ClaudeEventFile = ""
$script:lastCodexTasks = @()
$script:lastClaudeTasks = @()
function Codex-Tasks {
    if ($script:codexFails) { throw "synthetic Codex read error" }
    return [PSCustomObject]@{ Provider="codex"; Active=$true; Status="working"; Activity="working" }
}
function Claude-Tasks {
    if ($script:claudeFails) { throw "synthetic Claude read error" }
    return [PSCustomObject]@{ Provider="claude"; Active=$true; Status="working"; Activity="working" }
}
function Claude-ConnectionState {
    if ($script:claudeConnection -eq "unknown") { throw "synthetic settings read error" }
    return $script:claudeConnection
}

$snapshot = Source-Snapshot
if (@($snapshot.Tasks).Count -ne 2 -or @($snapshot.Unavailable).Count -ne 0) { throw "Both sources should remain available." }
$script:codexFails = $true
$snapshot = Source-Snapshot
if (@($snapshot.Tasks).Count -ne 2 -or @($snapshot.Tasks | Where-Object { $_.Provider -eq "claude" -and $_.Active }).Count -ne 1 -or @($snapshot.Tasks | Where-Object { $_.Provider -eq "codex" -and -not $_.Active -and $_.Status -ne "working" }).Count -ne 1 -or (@($snapshot.Unavailable) -join ",") -ne "Codex") {
    throw "A Codex error should retain the observed task as uncertain without hiding Claude."
}
$script:codexFails = $false
$script:claudeFails = $true
$snapshot = Source-Snapshot
if (@($snapshot.Tasks).Count -ne 2 -or @($snapshot.Tasks | Where-Object { $_.Provider -eq "codex" -and $_.Active }).Count -ne 1 -or @($snapshot.Tasks | Where-Object { $_.Provider -eq "claude" -and -not $_.Active -and $_.Status -ne "working" }).Count -ne 1 -or (@($snapshot.Unavailable) -join ",") -ne "Claude Code") {
    throw "A Claude error should retain the observed task as uncertain without hiding Codex."
}
$script:codexFails = $true
$snapshot = Source-Snapshot
if (@($snapshot.Tasks).Count -ne 2 -or @($snapshot.Tasks | Where-Object Active).Count -ne 0 -or @($snapshot.Unavailable).Count -ne 2) { throw "Both unavailable sources and their uncertain tasks must be reported." }
$script:codexFails = $false
$script:claudeFails = $false
$snapshot = Source-Snapshot
if (@($snapshot.Tasks | Where-Object Active).Count -ne 2 -or @($snapshot.Unavailable).Count -ne 0) { throw "Both tasks should recover when sources recover." }
$script:claudeConnection = "disconnected"
$snapshot = Source-Snapshot
if (@($snapshot.Tasks).Count -ne 1 -or @($snapshot.Tasks | Where-Object { $_.Provider -eq "claude" }).Count -ne 0 -or @($snapshot.Unavailable).Count -ne 0) { throw "A disconnected provider must not keep old tasks visible or report an error." }
$script:claudeConnection = "connected"
[void](Source-Snapshot)
$script:claudeConnection = "unknown"
$snapshot = Source-Snapshot
if (@($snapshot.Tasks | Where-Object { $_.Provider -eq "claude" -and -not $_.Active }).Count -ne 1 -or (@($snapshot.Unavailable) -join ",") -ne "Claude Code") { throw "Unreadable provider settings must retain an observed task as unconfirmed." }
Write-Output "Source availability: independent errors and surviving tasks verified."
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))

$claudeDefinition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Claude-Tasks" }, $true)
$missingPath = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-missing-" + [Guid]::NewGuid().ToString("N") + ".jsonl")
$claudeChecks = @'
$claudeEventPath = $args[0]
$claudeLegacyEventPath = ""
$script:lastClaudeTasks = @()
if (@(Claude-Tasks).Count -ne 0) { throw "A missing event log before any task is not a source error." }
$script:lastClaudeTasks = @([PSCustomObject]@{ Active=$true })
$threw = $false
try { [void](Claude-Tasks) } catch { $threw = $true }
if (-not $threw) { throw "A disappeared event log after an observed task must be reported." }
$claudeEventPath = [IO.Path]::GetTempPath()
$threw = $false
try { [void](Claude-Tasks) } catch { $threw = $true }
if (-not $threw) { throw "A directory must not be treated as a readable event log." }
Write-Output "Source availability: first-run absence and later disappearance distinguished."
'@
& ([scriptblock]::Create($claudeDefinition.Extent.Text + "`n" + $claudeChecks)) $missingPath
