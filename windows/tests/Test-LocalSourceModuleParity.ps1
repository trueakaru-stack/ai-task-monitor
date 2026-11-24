$ErrorActionPreference='Stop'
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
$original=Join-Path $app 'CodexProgress.ps1';$shared=Join-Path $app 'LocalSourceCore.ps1'
$tokens=$null;$errors=$null
$appAst=[Management.Automation.Language.Parser]::ParseFile($original,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The application source did not parse.'}
$tokens=$null;$errors=$null
$sharedAst=[Management.Automation.Language.Parser]::ParseFile($shared,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The local source module did not parse.'}
$names=@('Prop','Lock-State','Find-PriorLifecycle','Thread-State','Codex-Uncertain','Update-CodexRolloutPaths','Confirm-CodexTerminal',
 'Session-File','Session-Workspace','Progress-Files','Manual-Tasks','Read-TailText','Codex-Plan','Codex-TurnStartIndex',
 'Codex-ContainsIdentifier','Codex-CurrentToolActivity','Codex-FigmaCompleted','Codex-FirstFigmaCompletion','Codex-Activity',
 'Read-ObservedCodexTail','Codex-ObservedActivity','Plan-Progress','Codex-IndexCandidates','Codex-SubagentMetadata',
 'Codex-ReadSubagentMetadata','Codex-UnindexedCandidates','Group-CodexTasks','Codex-Tasks','Claude-Tasks','Unconfirmed-Tasks')
foreach($name in $names){
 $fromApp=@($appAst.FindAll({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name},$true))
 $fromShared=@($sharedAst.FindAll({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq $name},$true))
 if($fromApp.Count -ne 1 -or $fromShared.Count -ne 1){throw ('A source function is missing or ambiguous: '+$name)}
 $first=$fromApp[0].Extent.Text.Replace("`r`n","`n").Trim()
 $second=$fromShared[0].Extent.Text.Replace("`r`n","`n").Trim()
 if($first -cne $second){throw ('A source function diverged from the shared module: '+$name)}
}
$embedded=@($appAst.FindAll({param($item)$item -is [Management.Automation.Language.StringConstantExpressionAst] -and $item.Value -like '*namespace AITaskMonitor.CodexTitles*'},$true))
if($embedded.Count -ne 1){throw 'The original Codex reader was missing or ambiguous.'}
$first=$embedded[0].Value.Replace("`r`n","`n").Trim()
$second=[IO.File]::ReadAllText((Join-Path $app 'CodexTitlesCore.cs')).Replace("`r`n","`n").Trim()
if($first -cne $second){throw 'The shared Codex reader diverged from the application reader.'}
Write-Output 'The staged local-source functions and Codex reader match their current production definitions; connection-state overrides are tested separately.'
