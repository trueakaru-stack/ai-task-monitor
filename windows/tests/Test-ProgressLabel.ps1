$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'The application source failed to parse.' }
$definitions = foreach ($name in @('Prop', 'Progress-Label')) {
    $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true)
    if ($null -eq $node) { throw "Missing function: $name" }
    $node.Extent.Text
}
$checks = @'
function Tr([string]$text) { return $text }
$script:resolvedLanguage = 'ru'
$stepWord = -join ([char[]]@(0x042D,0x0442,0x0430,0x043F))
$doneWord = -join ([char[]]@(0x0413,0x043E,0x0442,0x043E,0x0432,0x043E))
$ofWord = -join ([char[]]@(0x0438,0x0437))
$steps = @([PSCustomObject]@{status='done'},[PSCustomObject]@{status='active'},[PSCustomObject]@{status='pending'})
$planned = [PSCustomObject]@{Progress=33;ProgressKind='exact';ProgressBasis='steps';Steps=$steps;PlanConfirmed=$true}
$manual = [PSCustomObject]@{Progress=42;ProgressKind='exact';ProgressBasis='task';Steps=$steps}
$estimate = [PSCustomObject]@{Progress=30;ProgressKind='approximate';ProgressBasis='task';Steps=@()}
$none = [PSCustomObject]@{Progress=$null;ProgressKind='none';Steps=@()}
if ((Progress-Label $planned) -cne ("$stepWord 2 $ofWord 3")) { throw 'The current step must be shown without a percentage.' }
$script:resolvedLanguage = 'en'
if ((Progress-Label $planned) -cne 'Step 2 of 3') { throw 'The current step must be localized.' }
$noActive = [PSCustomObject]@{Progress=33;ProgressKind='exact';ProgressBasis='steps';Steps=@([PSCustomObject]@{status='done'},[PSCustomObject]@{status='pending'},[PSCustomObject]@{status='pending'})}
if ((Progress-Label $noActive) -cne 'Done 1 of 3') { throw 'An unspecified current step must not be invented.' }
$multiple = [PSCustomObject]@{Progress=33;ProgressKind='exact';ProgressBasis='steps';Steps=@([PSCustomObject]@{status='done'},[PSCustomObject]@{status='active'},[PSCustomObject]@{status='active'})}
if ((Progress-Label $multiple) -cne 'Done 1 of 3') { throw 'Multiple active steps must not be reduced to one.' }
$allDone = [PSCustomObject]@{Progress=100;ProgressKind='exact';ProgressBasis='steps';Steps=@([PSCustomObject]@{status='done'},[PSCustomObject]@{status='done'})}
if ((Progress-Label $allDone) -cne 'Done 2 of 2') { throw 'A complete plan must report completed steps only.' }
$unknown = [PSCustomObject]@{Progress=0;ProgressKind='exact';ProgressBasis='steps';Steps=@([PSCustomObject]@{status='unknown'})}
if ((Progress-Label $unknown) -cne '') { throw 'An invalid step status must not be interpreted.' }
$planned.PlanConfirmed=$false
if ((Progress-Label $planned) -cne '') { throw 'An unconfirmed plan must not claim a current step.' }
$planned.PlanConfirmed=$true
$script:resolvedLanguage = 'ru'
if ((Progress-Label $noActive) -cne ("$doneWord 1 $ofWord 3")) { throw 'Completed-step text must be localized.' }
if ((Progress-Label $manual) -cne '42%') { throw 'An exact overall value must not be labelled as a plan fraction.' }
if ((Progress-Label $estimate) -cne ([char]0x2248+' 30%')) { throw 'An approximate value must preserve the approximation mark.' }
if ((Progress-Label $none) -cne '') { throw 'An unknown value must remain hidden.' }
Write-Output 'Progress labels: current step, ambiguous and unconfirmed plans, overall percentages and unknown values verified.'
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))
