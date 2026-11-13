function New-ExternalProviderController {
 param([string]$PipeName = '')
 return [PSCustomObject]@{Channel=$null;Store=$null;PipeName=$PipeName;DegradedProviders=@{}}
}

function Stop-ExternalProviderController {
 param([Parameter(Mandatory=$true)]$Controller,[switch]$PreserveStore)
 if($null -ne $Controller.Channel){$Controller.Channel.Dispose()}
 $Controller.Channel=$null
 if(-not $PreserveStore){$Controller.Store=$null}
 $Controller.DegradedProviders.Clear()
}

function Read-ManagedExternalProviderSnapshot {
 param(
  [Parameter(Mandatory=$true)]$Controller,
  [string[]]$AllowedProviders = @(),
  [hashtable]$ProfileScopes = @{},
  [hashtable]$UncertainProfileScopes = @{},
  [ValidateSet('ru','en')][string]$Language = 'ru',
  [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
 )
 $allowed=@($AllowedProviders | Where-Object {$_ -in @('kimi','deepseek','hermes','opencode')} | Select-Object -Unique)
 if($allowed.Count -eq 0){
  if($null -ne $Controller.Store){$Controller.Store.RetainProviders([string[]]@())}
  Stop-ExternalProviderController $Controller -PreserveStore
  return @()
 }
 if($null -eq $Controller.Channel){
  if(-not ('AITaskMonitor.ExternalProviders.EventChannel' -as [type])){
   Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
   $sources=@((Join-Path $PSScriptRoot 'ProviderEventState.cs'),(Join-Path $PSScriptRoot 'ProviderEventChannel.cs'))
   Add-Type -Path $sources -ReferencedAssemblies System.Web.Extensions -ErrorAction Stop
  }
  if($null -eq $Controller.Store){$Controller.Store=[AITaskMonitor.ExternalProviders.StateStore]::new()}
  try{$Controller.Channel=[AITaskMonitor.ExternalProviders.EventChannel]::new($Controller.PipeName)}
  catch{$Controller.Store.MarkGap();throw}
 }
 return @(Read-ExternalProviderSnapshot -Channel $Controller.Channel -Store $Controller.Store -AllowedProviders $allowed -ProfileScopes $ProfileScopes -UncertainProfileScopes $UncertainProfileScopes -Language $Language -Now $Now)
}
