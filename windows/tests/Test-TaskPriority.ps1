$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application source could not be parsed.' }
$definitions = foreach ($name in @('Prop', 'Prioritize-Tasks')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $function) { throw "Missing function: $name" }
    $function.Extent.Text
}
$checks = @'
$script:taskPriority = @{}
$script:taskPriorityCounter = 0
$base = [DateTime]::UtcNow
$script:monitorStartedUtc = $base
$unconfirmedLabel = -join @(1057,1090,1072,1090,1091,1089,32,1085,1077,32,1087,1086,1076,1090,1074,1077,1088,1078,1076,1105,1085 | ForEach-Object { [char]$_ })
function Task([string]$id, [bool]$active, [string]$key, [int]$seconds) {
    [PSCustomObject]@{ Id=$id; Active=$active; Status=$(if ($active) { 'active' } else { $unconfirmedLabel }); StartKey=$key; Started=$base.AddSeconds($seconds); Updated=$base.AddSeconds($seconds) }
}
function Require($condition, [string]$message) { if (-not $condition) { throw $message } }

$old = Task 'old' $true 'turn-1' 1
$unknown = Task 'unknown' $false 'turn-x' -2
$result = Prioritize-Tasks @($unknown, $old) @() ''
Require ($result.SelectedId -eq 'old' -and $result.Tasks[0].Id -eq 'old') 'An active task did not take precedence over an unconfirmed task'

$new = Task 'new' $true 'turn-2' 3
$result = Prioritize-Tasks @($old, $unknown, $new) @($old, $unknown) 'old'
Require ($result.SelectedId -eq 'new' -and $result.Tasks[0].Id -eq 'new') 'A new active task was not selected and placed first'

$updatedOld = Task 'old' $true 'turn-1' 9
$result = Prioritize-Tasks @($updatedOld, $unknown, $new) @($old, $unknown, $new) 'old'
Require ($result.SelectedId -eq 'old' -and $result.Tasks[0].Id -eq 'new') 'A normal update changed manual selection or start ordering'

$resumed = Task 'old' $true 'turn-3' 10
$result = Prioritize-Tasks @($resumed, $unknown, $new) @($updatedOld, $unknown, $new) 'new'
Require ($result.SelectedId -eq 'old' -and $result.Tasks[0].Id -eq 'old') 'A new turn on an already active task was not selected'

$unknownRecovered = Task 'unknown' $true 'turn-x' 11
$result = Prioritize-Tasks @($resumed, $unknownRecovered, $new) @($resumed, $unknown, $new) 'old'
Require ($result.SelectedId -eq 'old') 'Recovery of the same unconfirmed turn stole selection'

$legacyWaiting = Task 'legacy' $false '' 12
$legacyActive = Task 'legacy' $true '' 13
$result = Prioritize-Tasks @($resumed, $new, $legacyActive) @($resumed, $new, $legacyWaiting) 'old'
Require ($result.SelectedId -eq 'legacy' -and $result.Tasks[0].Id -eq 'legacy') 'An observed activation without a turn key was not selected'

$legacyWithTurn = Task 'legacy' $true 'new-turn' 14
$result = Prioritize-Tasks @($resumed, $new, $legacyWithTurn) @($resumed, $new, $legacyActive) 'old'
Require ($result.SelectedId -eq 'legacy') 'A new identified turn after an unidentified turn was not selected'

$other1 = Task 'other-1' $true 'one' 14
$other2 = Task 'other-2' $true 'two' 15
$latest = Task 'latest' $true 'three' 16
$result = Prioritize-Tasks @($resumed, $new, $legacyActive, $other1, $other2, $latest) @($resumed, $new, $legacyActive) 'old'
Require ($result.SelectedId -eq 'latest' -and $result.Tasks[0].Id -eq 'latest') 'The latest new task was not first when more than three tasks were present'

$early = Task 'early' $true 'early-turn' 20
$early.Updated = $base.AddSeconds(99)
$later = Task 'later' $true 'later-turn' 21
$result = Prioritize-Tasks @($early, $later) @() ''
Require ($result.SelectedId -eq 'later' -and $result.Tasks[0].Id -eq 'later') 'Recent activity incorrectly outranked a more recent start'

$recentUnknown = Task 'recent-unknown' $false 'turn-new' 22
$result = Prioritize-Tasks @($early, $later, $recentUnknown) @($early, $later) 'later'
Require ($result.SelectedId -eq 'recent-unknown' -and $result.Tasks[0].Id -eq 'recent-unknown' -and -not $result.Tasks[0].Active) 'A newly started unconfirmed task was not selected honestly'
$result = Prioritize-Tasks @($early, $later, $recentUnknown) @($early, $later, $recentUnknown) 'early'
Require ($result.SelectedId -eq 'early') 'A repeated unconfirmed update stole manual selection'
$resumedUnknown = Task 'recent-unknown' $false 'turn-next' 23
$result = Prioritize-Tasks @($early, $later, $resumedUnknown) @($early, $later, $recentUnknown) 'early'
Require ($result.SelectedId -eq 'recent-unknown' -and $result.Tasks[0].Id -eq 'recent-unknown') 'A newly resumed unconfirmed task was not selected'
Write-Output 'Task priority: new tasks, resumed turns, manual selection and source recovery verified.'
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))
