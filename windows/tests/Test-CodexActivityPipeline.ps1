$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application source could not be parsed.' }
$names = @('Prop', 'Read-TailText', 'Lock-State', 'Thread-State', 'Codex-Uncertain', 'Codex-Plan', 'Codex-Activity', 'Plan-Progress', 'Codex-Tasks', 'Prioritize-Tasks')
$definitions = foreach ($name in $names) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $function) { throw "Missing function: $name" }
    $function.Extent.Text
}
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-activity-pipeline-' + [guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture directory.' }
[void][IO.Directory]::CreateDirectory($root)
$checks = @'
$codexHome = $args[0]
$sessionIndex = Join-Path $codexHome 'session_index.jsonl'
$sessionsDirectory = Join-Path $codexHome 'sessions'
$lockDirectory = Join-Path $codexHome 'thread-writer-locks'
[void][IO.Directory]::CreateDirectory($sessionsDirectory)
[void][IO.Directory]::CreateDirectory($lockDirectory)
$script:monitorStartedUtc = [DateTime]::UtcNow.AddSeconds(-10)
$script:sessionPaths = @{}
$script:sessionDates = @{}
$script:observedCodex = @{}
$script:lifecycleState = @{}
$script:planCache = @{}
$script:lastCodexTasks = @()
$script:taskPriority = @{}
$script:taskPriorityCounter = 0
function Session-File([string]$id) { return $script:sessionPaths[$id] }
function Manual-Tasks($sessions) { return @{} }
function Require($condition, [string]$message) { if (-not $condition) { throw $message } }
function Write-Record([string]$path, $record) {
    $json = $record | ConvertTo-Json -Compress -Depth 12
    [IO.File]::AppendAllText($path, ($json + "`n"), [Text.UTF8Encoding]::new($false))
}
function New-Fixture([string]$id, [string]$key, [int]$seconds, [string]$summary) {
    $when = $script:monitorStartedUtc.AddSeconds($seconds).ToString('o')
    $path = Join-Path $sessionsDirectory ($id + '.jsonl')
    $script:sessionPaths[$id] = $path
    Write-Record $sessionIndex @{id=$id;thread_name=('Synthetic '+$id);updated_at=$when}
    Write-Record $path @{timestamp=$when;type='event_msg';payload=@{type='task_started';turn_id=$key}}
    Write-Record $path @{timestamp=$when;type='response_item';payload=@{type='reasoning';summary=@(@{type='summary_text';text=('**'+$summary+'**')});content=@(@{text='PRIVATE_REASONING'})}}
    $lockPath = Join-Path $lockDirectory ($id + '.lock')
    return [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}
$owners = New-Object Collections.Generic.List[IO.FileStream]
try {
    $owners.Add((New-Fixture 'old-id' 'old-turn' 2 'Preparing plan'))
    $plan = @{plan=@(@{step='First';status='completed'},@{step='Second';status='in_progress'})} | ConvertTo-Json -Compress -Depth 8
    Write-Record $script:sessionPaths['old-id'] @{type='response_item';payload=@{type='function_call';name='update_plan';arguments=$plan}}
    $old = @(Codex-Tasks)
    Require ($old.Count -eq 1 -and $old[0].Activity -eq 'Preparing plan' -and @($old[0].Steps).Count -eq 2 -and $old[0].Progress -eq 50) 'The planned task did not connect its live activity and real plan'
    $first = Prioritize-Tasks $old @() ''
    Require ($first.SelectedId -eq 'old-id') 'The initial task was not selected'

    $owners.Add((New-Fixture 'new-id' 'new-turn' 4 'Checking screenshot stability'))
    $current = @(Codex-Tasks)
    $new = @($current | Where-Object Id -eq 'new-id')
    Require ($new.Count -eq 1 -and $new[0].Activity -eq 'Checking screenshot stability' -and @($new[0].Steps).Count -eq 0 -and $null -eq $new[0].Progress) 'The unplanned task lost activity or gained fabricated progress'
    $second = Prioritize-Tasks $current $old 'old-id'
    Require ($second.SelectedId -eq 'new-id' -and $second.Tasks[0].Id -eq 'new-id') 'The new live task was not selected and first'

    $when = $script:monitorStartedUtc.AddSeconds(6).ToString('o')
    Write-Record $script:sessionPaths['old-id'] @{timestamp=$when;type='event_msg';payload=@{type='task_started';turn_id='resumed-turn'}}
    Write-Record $script:sessionPaths['old-id'] @{timestamp=$when;type='event_msg';payload=@{type='item_completed';turn_id='resumed-turn';item=@{type='Reasoning';summary_text=@('**Resume work**')}}}
    $resumed = @(Codex-Tasks)
    $third = Prioritize-Tasks $resumed $current 'new-id'
    Require ($third.SelectedId -eq 'old-id' -and $third.Tasks[0].Id -eq 'old-id' -and $third.Tasks[0].Activity -eq 'Resume work') 'The continued task did not take focus with its current action'
    Require (-not (($resumed | ConvertTo-Json -Compress -Depth 8) -match 'PRIVATE_REASONING')) 'Raw reasoning leaked into task display data'
    Write-Output 'Codex activity pipeline: live sessions, plans, no-plan activity, new and resumed selection, and privacy verified.'
} finally { foreach ($owner in $owners) { $owner.Dispose() } }
'@
try { & ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks)) $root }
finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
