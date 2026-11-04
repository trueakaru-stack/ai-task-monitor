$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The application source failed to parse.' }
$definitions = foreach ($name in @('Prop', 'Lock-State', 'Codex-Uncertain', 'Plan-Progress', 'Codex-IndexCandidates', 'Codex-Tasks')) {
    $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true)
    if ($null -eq $node) {
        if ($name -eq 'Codex-IndexCandidates') { continue }
        throw "Missing function: $name"
    }
    $node.Extent.Text
}
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-index-history-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory($root)
$checks = @'
$codexHome = $args[0]
$sessionIndex = Join-Path $codexHome 'session_index.jsonl'
$sessionsDirectory = Join-Path $codexHome 'sessions'
$lockDirectory = Join-Path $codexHome 'thread-writer-locks'
[void][IO.Directory]::CreateDirectory($lockDirectory)
$script:sessionDates = @{}
$script:sessionIndexLookup = @{}
$script:observedCodex = @{}
$script:lastCodexTasks = @()
$script:monitorStartedUtc = [DateTime]::UtcNow.AddSeconds(-5)
function Manual-Tasks($sessions) { return @{} }
function Codex-Plan([string]$id) { return @() }
function Codex-Activity([string]$id) { return 'Synthetic action' }
function Thread-State([string]$id) {
    $active = (Lock-State (Join-Path $lockDirectory ($id + '.lock'))) -eq 'held'
    return [PSCustomObject]@{ State=$(if ($active) { 'active' } else { 'unknown' }); HasStartMarker=$true; UpdatedUtc=[DateTime]::UtcNow; StartKey='turn:test'; StartedUtc=[DateTime]::UtcNow }
}
$now = [DateTime]::UtcNow.ToString('o')
$records = New-Object 'Collections.Generic.List[string]'
$records.Add((@{id='older-active';thread_name='Synthetic older';updated_at=$now}|ConvertTo-Json -Compress))
for ($i=0; $i -lt 60; $i++) { $records.Add((@{id=('quiet-'+$i);thread_name='Synthetic quiet';updated_at=$now}|ConvertTo-Json -Compress)) }
[IO.File]::WriteAllLines($sessionIndex, $records, [Text.UTF8Encoding]::new($false))
$lock = [IO.File]::Open((Join-Path $lockDirectory 'older-active.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $active = @(Codex-Tasks | Where-Object { $_.Id -eq 'older-active' -and $_.Active })
    if ($active.Count -ne 1) { throw 'An observed, locked session outside the last 50 index rows must remain visible.' }
    $again = @(Codex-Tasks | Where-Object { $_.Id -eq 'older-active' -and $_.Active })
    if ($again.Count -ne 1) { throw 'A cached older active session must remain visible on the next refresh.' }
    $records[0] = (@{id='older-active';thread_name='Synthetic renamed older task';updated_at=$now}|ConvertTo-Json -Compress)
    [IO.File]::WriteAllLines($sessionIndex, $records, [Text.UTF8Encoding]::new($false))
    $renamed = @(Codex-Tasks | Where-Object { $_.Id -eq 'older-active' -and $_.Title -eq 'Synthetic renamed older task' })
    if ($renamed.Count -ne 1) { throw 'A rewritten index must invalidate the older-session cache.' }
} finally { $lock.Dispose() }
$uncertain = @(Codex-Tasks | Where-Object { $_.Id -eq 'older-active' -and -not $_.Active })
if ($uncertain.Count -ne 1) { throw 'A formerly observed task must remain visible as unconfirmed after its lock is released.' }
Write-Output 'Codex index: older active and previously observed sessions remain visible.'
'@
try { & ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks)) $root }
finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
