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
$stages = -join ([char[]]@(0x044D,0x0442,0x0430,0x043F,0x043E,0x0432))
$planned = [PSCustomObject]@{Progress=50;ProgressKind='exact';ProgressBasis='steps';Steps=@(1,2)}
$manual = [PSCustomObject]@{Progress=42;ProgressKind='exact';ProgressBasis='task';Steps=@(1,2)}
$estimate = [PSCustomObject]@{Progress=30;ProgressKind='approximate';ProgressBasis='task';Steps=@()}
$none = [PSCustomObject]@{Progress=$null;ProgressKind='none';Steps=@()}
if ((Progress-Label $planned) -cne ('50% '+$stages)) { throw 'A plan fraction must be labelled as stages.' }
$script:resolvedLanguage = 'en'
if ((Progress-Label $planned) -cne '50% of steps') { throw 'An English plan fraction must identify the steps.' }
$script:resolvedLanguage = 'ru'
if ((Progress-Label $manual) -cne '42%') { throw 'An exact overall value must not be labelled as a plan fraction.' }
if ((Progress-Label $estimate) -cne ([char]0x2248+' 30%')) { throw 'An approximate value must preserve the approximation mark.' }
if ((Progress-Label $none) -cne '') { throw 'An unknown value must remain hidden.' }
Write-Output 'Progress labels: plan fraction, exact, approximate and unknown values verified.'
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))
