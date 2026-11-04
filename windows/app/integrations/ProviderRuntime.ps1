function Read-ExternalProviderSnapshot {
 param(
  [Parameter(Mandatory=$true)]$Channel,
  [Parameter(Mandatory=$true)]$Store,
  [string[]]$AllowedProviders = @(),
  [ValidateSet('ru','en')][string]$Language = 'ru',
  [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
 )
 $allowed=@{}
 foreach($name in $AllowedProviders){if($name -in @('kimi','deepseek','hermes','opencode')){$allowed[$name]=$true}}
 $Channel.SetAllowedProviders([string[]]@($allowed.Keys))
 $Store.RetainProviders([string[]]@($allowed.Keys))
 $batch=$Channel.Drain()
 if($batch.Gap){$Store.MarkGap()}
 foreach($event in @($batch.Events)){
  if(-not $allowed.ContainsKey([string]$event.Provider)){continue}
  $received=[DateTimeOffset]$event.ObservedAt
  if($received -eq [DateTimeOffset]::MinValue -or $received -gt $Now.AddMinutes(1)){$Store.MarkGap();continue}
  if($received -gt $Now){$received=$Now}
  [void]$Store.Apply($event,$received)
 }
 return @(Convert-ExternalProviderStates -States @($Store.Snapshot($Now)) -Language $Language)
}

# The application starts a receiver only when a provider has actually been
# connected. An empty allowlist stops it and clears all in-memory task state.
function New-ExternalProviderController {
 param([string]$PipeName = '')
 return [PSCustomObject]@{Channel=$null;Store=$null;PipeName=$PipeName}
}

function Stop-ExternalProviderController {
 param([Parameter(Mandatory=$true)]$Controller)
 if($null -ne $Controller.Channel){$Controller.Channel.Dispose()}
 $Controller.Channel=$null
 $Controller.Store=$null
}

function Read-ManagedExternalProviderSnapshot {
 param(
  [Parameter(Mandatory=$true)]$Controller,
  [string[]]$AllowedProviders = @(),
  [ValidateSet('ru','en')][string]$Language = 'ru',
  [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
 )
 $allowed=@($AllowedProviders | Where-Object {$_ -in @('kimi','deepseek','hermes','opencode')} | Select-Object -Unique)
 if($allowed.Count -eq 0){Stop-ExternalProviderController $Controller;return @()}
 if($null -eq $Controller.Channel){
  if(-not ('AITaskMonitor.ExternalProviders.EventChannel' -as [type])){
   Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
   $sources=@((Join-Path $PSScriptRoot 'ProviderEventState.cs'),(Join-Path $PSScriptRoot 'ProviderEventChannel.cs'))
   Add-Type -Path $sources -ReferencedAssemblies System.Web.Extensions -ErrorAction Stop
  }
  $Controller.Store=[AITaskMonitor.ExternalProviders.StateStore]::new()
  try{$Controller.Channel=[AITaskMonitor.ExternalProviders.EventChannel]::new($Controller.PipeName)}
  catch{$Controller.Store=$null;throw}
 }
 return @(Read-ExternalProviderSnapshot -Channel $Controller.Channel -Store $Controller.Store -AllowedProviders $allowed -Language $Language -Now $Now)
}

# Connection failures are isolated per provider; only a shared channel failure
# marks every currently connected external source as unavailable.
function Read-ExternalProviderGroupSnapshot {
 param(
  [Parameter(Mandatory=$true)]$Controller,
  [Parameter(Mandatory=$true)][hashtable]$Connections,
  [Parameter(Mandatory=$true)][hashtable]$Seen,
  [object[]]$PreviousTasks = @(),
  [ValidateSet('ru','en')][string]$Language = 'ru'
 )
 $names=[ordered]@{kimi='Kimi Code';deepseek='DeepSeek Harness';hermes='Hermes Agent';opencode='OpenCode'}
 $allowed=New-Object 'Collections.Generic.List[string]'
 $uncertain=New-Object 'Collections.Generic.List[string]'
 $unavailable=New-Object 'Collections.Generic.List[string]'
 foreach($provider in $names.Keys){
  if(-not $Connections.ContainsKey($provider)){continue}
  switch([string]$Connections[$provider]){
   'connected' {$Seen[$provider]=$true;$allowed.Add($provider)}
   'partial' {$uncertain.Add($provider);$unavailable.Add($names[$provider])}
   'error' {if($Seen.ContainsKey($provider)){$uncertain.Add($provider);$unavailable.Add($names[$provider])}}
   'disconnected' {[void]$Seen.Remove($provider)}
   default {throw 'Invalid external provider connection state.'}
  }
 }
 $retained=@(Unconfirmed-ExternalTasks @($PreviousTasks|Where-Object {$_.Provider -in $uncertain}))
 if($allowed.Count -eq 0){
  Stop-ExternalProviderController $Controller
  return [PSCustomObject]@{Tasks=$retained;Unavailable=$unavailable.ToArray()}
 }
 try{
  $current=@(Read-ManagedExternalProviderSnapshot -Controller $Controller -AllowedProviders $allowed.ToArray() -Language $Language)
  return [PSCustomObject]@{Tasks=@($current+$retained);Unavailable=$unavailable.ToArray()}
 }catch{
  foreach($provider in $allowed){$uncertain.Add($provider);$unavailable.Add($names[$provider])}
  $retained=@(Unconfirmed-ExternalTasks @($PreviousTasks|Where-Object {$_.Provider -in $uncertain}))
  Stop-ExternalProviderController $Controller
  return [PSCustomObject]@{Tasks=$retained;Unavailable=$unavailable.ToArray()}
 }
}

function Get-OpenCodeConnectionState {
 param([Parameter(Mandatory=$true)][string]$AppRoot)
 $setup=Join-Path $AppRoot 'Configure-OpenCodeIntegration.ps1'
 if(-not (Test-Path -LiteralPath $setup -PathType Leaf)){return 'disconnected'}
 return (& {param($path) . $path -Mode State -ReturnStateToCaller} $setup)
}

function Test-OpenCodePotentialInstallation {
 if(@(Get-Command -Name 'opencode.exe' -CommandType Application -All -ErrorAction SilentlyContinue).Count -gt 0){return $true}
 if(-not $env:USERPROFILE){return $false}
 return [IO.File]::Exists((Join-Path $env:USERPROFILE '.opencode\bin\opencode.exe'))
}
