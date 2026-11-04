$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../app/CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Application source could not be parsed.'}
$names=@('Prop','Unconfirmed-Tasks','Unconfirmed-ExternalTasks','Source-Snapshot')
$definitions=foreach($name in $names){
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if($null -eq $function){throw "Missing function: $name"}
 $function.Extent.Text
}
$checks=@'
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Codex-Tasks { return [PSCustomObject]@{Id='codex:one';Active=$true;Status='working'} }
function Claude-ConnectionState { return 'connected' }
function Claude-Tasks { return [PSCustomObject]@{Id='claude:one';Active=$true;Status='working'} }
function Get-OpenCodeConnectionState { return $script:fixtureConnection }
function Read-ManagedExternalProviderSnapshot {
 if($script:fixtureChannelFailure){throw 'Synthetic channel failure.'}
 return [PSCustomObject]@{Id='opencode:one';Provider='opencode';Active=$false;Paused=$true;Status='waiting';Activity='waiting';PlanConfirmed=$true;Steps=@([PSCustomObject]@{title='Step';status='active'})}
}
function Stop-ExternalProviderController { $script:stops++ }
$ClaudeEventFile='';$script:lastCodexTasks=@();$script:lastClaudeTasks=@();$script:lastExternalTasks=@()
$script:externalProviderModulesAvailable=$true;$script:externalProviderController=[PSCustomObject]@{}
$script:lastOpenCodeConnected=$false;$script:resolvedLanguage='ru';$script:fixtureChannelFailure=$false;$script:stops=0
$script:fixtureConnection='connected'
$combined=Source-Snapshot
Assert (@($combined.Tasks).Count -eq 3 -and @($combined.Tasks|Where-Object Id -eq 'opencode:one').Count -eq 1) 'Connected source did not join existing tasks.'
$script:fixtureConnection='partial'
$partial=Source-Snapshot
$task=@($partial.Tasks|Where-Object Id -eq 'opencode:one')[0]
Assert ($partial.Unavailable -contains 'OpenCode' -and -not $task.Active -and -not $task.Paused -and -not $task.PlanConfirmed -and $task.Status -ne 'waiting') 'A broken connection must retain only an unconfirmed task and plan.'
$script:fixtureConnection='disconnected'
$disconnected=Source-Snapshot
Assert (@($disconnected.Tasks).Count -eq 2 -and $disconnected.Unavailable.Count -eq 0 -and $script:stops -ge 2) 'Disconnect must clear external tasks without affecting other sources.'
$script:fixtureConnection='connected'
[void](Source-Snapshot)
$script:fixtureChannelFailure=$true
$failed=Source-Snapshot
$task=@($failed.Tasks|Where-Object Id -eq 'opencode:one')[0]
Assert ($failed.Unavailable -contains 'OpenCode' -and -not $task.Active -and -not $task.Paused) 'A channel failure must not claim ongoing work.'
Write-Output 'External source snapshot: connected, partial, disconnected and channel failure states verified.'
'@
& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks))
