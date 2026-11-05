$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$source=Join-Path $PSScriptRoot '../app/CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Application source could not be parsed.'}
$names=@('Prop','Unconfirmed-Tasks','Unconfirmed-ExternalTasks','Source-Snapshot')
$definitions=foreach($name in $names){
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if($null -eq $function){throw ('Missing function: '+$name)}
 $function.Extent.Text
}
$runtime=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../app/integrations/ProviderRuntime.ps1') -Raw
$checks=@'
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Codex-Tasks { return @() }
function Claude-ConnectionState { return 'disconnected' }
function Get-OpenCodeConnectionState { return 'disconnected' }
function Update-HermesMonitorController { if($script:fixtureScanFailure){throw 'Synthetic scan failure.'} }
function Get-HermesAllowedScopes { return @($script:fixtureAllowed) }
function Get-HermesUncertainScopes { return @($script:fixtureUncertain) }
function Get-HermesMonitorConnectionState { return $script:fixtureState }
function Read-ManagedExternalProviderSnapshot {
 param($Controller,$AllowedProviders,$ProfileScopes,$UncertainProfileScopes,$Language)
 Assert ($AllowedProviders -ccontains 'hermes') 'The Hermes receiver was not enabled.'
 $script:receivedAllowed=@($ProfileScopes.hermes)
 $script:receivedUncertain=@($UncertainProfileScopes.hermes)
 return [PSCustomObject]@{Id='hermes:one';Provider='hermes';Active=$true;Paused=$false;Status='active';Activity='active';PlanConfirmed=$true}
}
$ClaudeEventFile='';$SnapshotFile='';$PreviewActiveTasks=-1
$script:lastCodexTasks=@();$script:lastClaudeTasks=@();$script:lastExternalTasks=@()
$script:codexCloudModulesAvailable=$false;$script:externalProviderModulesAvailable=$true
$script:externalProviderController=New-ExternalProviderController;$script:seenExternalConnections=@{}
$script:hermesModulesAvailable=$true;$script:hermesController=[PSCustomObject]@{}
$script:showingSettings=$false;$script:resolvedLanguage='ru'
$script:fixtureAllowed='a'*32;$script:fixtureUncertain='b'*32
$script:fixtureState='connected-degraded';$script:fixtureScanFailure=$false
$degraded=Source-Snapshot
Assert ($script:receivedAllowed.Count -eq 1 -and $script:receivedAllowed[0] -ceq $script:fixtureAllowed) 'A prepared scope did not reach the receiver.'
Assert ($script:receivedUncertain.Count -eq 1 -and $script:receivedUncertain[0] -ceq $script:fixtureUncertain) 'An uncertain scope did not reach the receiver.'
Assert (@($degraded.Tasks | Where-Object Provider -eq 'hermes').Count -eq 1) 'The Hermes task did not reach the monitor.'
$script:fixtureScanFailure=$true
$failed=Source-Snapshot
$task=@($failed.Tasks | Where-Object Provider -eq 'hermes')
Assert ($task.Count -eq 1 -and -not $task[0].Active -and -not $task[0].Paused -and -not $task[0].PlanConfirmed -and $task[0].Status -cne 'active') 'A failed scan did not retain an unconfirmed task.'
Assert ($failed.Unavailable -contains 'Hermes Agent') 'A failed Hermes scan was not reported.'
$script:fixtureScanFailure=$false;$script:fixtureState='disconnected'
$removed=Source-Snapshot
Assert (@($removed.Tasks | Where-Object Provider -eq 'hermes').Count -eq 0) 'Disconnect did not clear the Hermes task.'
Write-Output 'Hermes source snapshot: prepared scopes, uncertain scopes, scan failure and disconnect verified.'
'@
& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$runtime+"`n"+$checks))

# Verify scope pruning through the real channel/store when another Hermes
# profile remains enabled. No real profile, session, or shared pipe is used.
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path @((Join-Path $PSScriptRoot '../app/integrations/ProviderEventState.cs'),(Join-Path $PSScriptRoot '../app/integrations/ProviderEventChannel.cs')) -ReferencedAssemblies System.Web.Extensions
. (Join-Path $PSScriptRoot '../app/integrations/ProviderEventView.ps1')
. (Join-Path $PSScriptRoot '../app/integrations/ProviderRuntime.ps1')
$pipe='AITaskMonitor.Test.'+[Guid]::NewGuid().ToString('N')
$channel=[AITaskMonitor.ExternalProviders.EventChannel]::new($pipe)
$store=[AITaskMonitor.ExternalProviders.StateStore]::new()
$scopeA='a'*32;$scopeB='b'*32
try{
 [void]@(Read-ExternalProviderSnapshot -Channel $channel -Store $store -AllowedProviders @('hermes') -ProfileScopes @{hermes=@($scopeA,$scopeB)})
 Start-Sleep -Milliseconds 2
 foreach($scope in @($scopeA,$scopeB)){
  $frequency=[Diagnostics.Stopwatch]::Frequency;$ticks=[Diagnostics.Stopwatch]::GetTimestamp()
  $timestamp=[long]([math]::Floor($ticks/$frequency)*1000000000+(($ticks%$frequency)*(1000000000.0/$frequency)))
  $event=[AITaskMonitor.ExternalProviders.EventParser]::Parse('{"version":1,"provider":"hermes","session":"'+$scope+'_fixture","kind":"started","tick":'+$timestamp+',"epoch":'+$timestamp+'}')
  if($null -eq $event -or -not $store.Apply($event,[DateTimeOffset]::UtcNow)){throw 'Could not create the isolated Hermes task.'}
 }
 $both=@(Read-ExternalProviderSnapshot -Channel $channel -Store $store -AllowedProviders @('hermes') -ProfileScopes @{hermes=@($scopeA,$scopeB)})
 if($both.Count -ne 2){throw 'Both enabled synthetic profiles must be visible.'}
 $one=@(Read-ExternalProviderSnapshot -Channel $channel -Store $store -AllowedProviders @('hermes') -ProfileScopes @{hermes=@($scopeA)})
 if($one.Count -ne 1 -or $one[0].Id -notlike ('hermes:'+$scopeA+'_*')){throw 'Disabling one profile must remove only its task.'}
 $reenabled=@(Read-ExternalProviderSnapshot -Channel $channel -Store $store -AllowedProviders @('hermes') -ProfileScopes @{hermes=@($scopeA,$scopeB)})
 if($reenabled.Count -ne 1){throw 'A disabled task must not return without a new event.'}
}finally{$channel.Dispose()}
if(-not $channel.IsStopped){throw 'The isolated provider channel did not stop.'}
'Hermes source scopes: disabling one of two profiles removes only its task.'
