$ErrorActionPreference='Stop'
$prototype=Join-Path $PSScriptRoot 'Prototype'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path (Join-Path $prototype 'ProviderEventState.cs') -ReferencedAssemblies System.Web.Extensions
$needed=@(
 @{Path=(Join-Path $prototype 'ProviderRuntime.ps1');Names=@('New-ExternalProviderController','Stop-ExternalProviderController','Read-ManagedExternalProviderSnapshot')},
 @{Path=(Join-Path $prototype 'DeepSeekRuntime.ps1');Names=@('Get-DeepSeekUncertainScopes')}
)
foreach($source in $needed){
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($source.Path,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The synthetic runtime source could not be parsed.'}
 foreach($wantedName in $source.Names){
  $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wantedName},$true)
  if($null -eq $definition){throw 'A synthetic runtime function is missing.'}
  . ([scriptblock]::Create($definition.Extent.Text))
 }
}
function Assert($condition,[string]$message){if(-not $condition){throw $message}}

# No pipe, real agent, or profile is opened by this fixture.
$controller=New-ExternalProviderController -PipeName 'AITaskMonitor.Test.Synthetic'
$store=[AITaskMonitor.ExternalProviders.StateStore]::new()
$controller.Store=$store
$store.RetainProviders([string[]]@('opencode'))
$channel=[PSCustomObject]@{Disposed=$false}
$channel | Add-Member -MemberType ScriptMethod -Name Dispose -Value {$this.Disposed=$true}
$controller.Channel=$channel
Assert (@(Read-ManagedExternalProviderSnapshot -Controller $controller -AllowedProviders @()).Count -eq 0) 'Disconnect returned tasks.'
Assert ($channel.Disposed -and $null -eq $controller.Channel -and [object]::ReferenceEquals($controller.Store,$store)) 'Stopping the channel lost its source history.'
$store.RetainProviders([string[]]@('opencode'))
$frame=[AITaskMonitor.ExternalProviders.EventParser]::Parse('{"version":1,"provider":"opencode","session":"delayed","kind":"active"}')
Assert ($store.Apply($frame,[DateTimeOffset]::UtcNow)) 'The synthetic event was not applied.'
Assert ((@($store.Snapshot([DateTimeOffset]::UtcNow))[0]).Status -eq 'unknown') 'Reconnect restored an unproven source.'

$scopeA='a'*32;$scopeB='b'*32
$profiles=@(
 [PSCustomObject]@{Name='one';State='connected';Scope=$scopeA},
 [PSCustomObject]@{Name='two';State='connected';Scope=$scopeA},
 [PSCustomObject]@{Name='independent';State='connected';Scope=$scopeB}
)
$deep=[PSCustomObject]@{Profiles=$profiles;Seen=@{};LastError=''}
$uncertain=@(Get-DeepSeekUncertainScopes $deep)
Assert ($uncertain -ccontains $scopeA) 'Duplicate profile ownership was accepted.'
Assert ($uncertain -cnotcontains $scopeB) 'A unique neighboring profile was marked ambiguous.'
Stop-ExternalProviderController $controller
Assert ($null -eq $controller.Store) 'Full controller shutdown retained its state.'

# Known counterexample: the production group path has not adopted this
# prototype. Import only its two functions and give them a fake channel.
$production=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../app/integrations/ProviderRuntime.ps1'))
$tokens=$null;$errors=$null
$productionAst=[Management.Automation.Language.Parser]::ParseFile($production,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The production runtime source could not be parsed.'}
foreach($wantedName in @('Stop-ExternalProviderController','Read-ExternalProviderGroupSnapshot')){
 $definition=$productionAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wantedName},$true)
 if($null -eq $definition){throw 'A production runtime function is missing.'}
 . ([scriptblock]::Create($definition.Extent.Text))
}
function Unconfirmed-ExternalTasks {param([object[]]$tasks) return @($tasks)}
$realChannel=[PSCustomObject]@{Disposed=$false}
$realChannel | Add-Member -MemberType ScriptMethod -Name Dispose -Value {$this.Disposed=$true}
$realController=[PSCustomObject]@{Channel=$realChannel;Store=[AITaskMonitor.ExternalProviders.StateStore]::new();PipeName='synthetic';DegradedProviders=@{}}
$realController.Store.RetainProviders([string[]]@('opencode'))
$result=Read-ExternalProviderGroupSnapshot -Controller $realController -Connections @{} -Seen @{}
Assert ($realChannel.Disposed -and $null -eq $realController.Store) 'The documented production group-stop counterexample changed.'
Write-Output 'Provider confidence runtime: synthetic scope checks passed; production group-stop still discards history.'
