function Get-ConfirmedDisconnectedDeepSeekScopes {
 param([hashtable]$Confirmed,[hashtable]$ProfileScopes,[hashtable]$UncertainProfileScopes)
 if(-not $Confirmed.ContainsKey('deepseek')){return @()}
 $active=@($ProfileScopes['deepseek'])+@($UncertainProfileScopes['deepseek'])
 return @($Confirmed['deepseek'] | Where-Object {$_ -cmatch '^[a-f0-9]{32}$' -and $active -cnotcontains $_})
}

function Read-ExternalProviderSnapshot {
 param(
  [Parameter(Mandatory=$true)]$Channel,
  [Parameter(Mandatory=$true)]$Store,
  [string[]]$AllowedProviders = @(),
  [string[]]$RetainedProviders = $null,
  [string[]]$UncertainProviders = @(),
  [hashtable]$ProfileScopes = @{},
  [hashtable]$UncertainProfileScopes = @{},
  [hashtable]$ConfirmedDisconnectedProfileScopes = @{},
  [ValidateSet('ru','en')][string]$Language = 'ru',
  [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
 )
 $allowed=@{}
 foreach($name in $AllowedProviders){if($name -in @('kimi','deepseek','hermes','opencode')){$allowed[$name]=$true}}
 $retained=if($null -eq $RetainedProviders){[string[]]@($allowed.Keys)}else{[string[]]@($RetainedProviders)}
 $Channel.SetAllowedProviders([string[]]@($allowed.Keys))
 $Store.RetainProviders($retained)
 foreach($provider in $UncertainProviders){if($retained -ccontains $provider){$Store.MarkProviderGap([string]$provider)}}
 $confirmed=@(Get-ConfirmedDisconnectedDeepSeekScopes $ConfirmedDisconnectedProfileScopes $ProfileScopes $UncertainProfileScopes)
 $Store.ConfirmDeepSeekDisconnectedScopes([string[]]$confirmed)
 if($Channel.IsStopped){$Store.MarkGap();throw 'External provider channel stopped.'}
 $scoped=@{}
 foreach($provider in $ProfileScopes.Keys){
  if(-not $allowed.ContainsKey([string]$provider)){continue}
  $valid=@($ProfileScopes[$provider] | Where-Object {$_ -cmatch '^[a-f0-9]{32}$'} | Select-Object -Unique)
  $uncertain=@($UncertainProfileScopes[$provider] | Where-Object {$_ -cmatch '^[a-f0-9]{32}$'} | Select-Object -Unique)
  $scoped[$provider]=$valid
  $Store.RetainSessionScopes([string]$provider,[string[]]@($valid+$uncertain))
  $Store.MarkSessionScopesGap([string]$provider,[string[]]$uncertain)
 }
 $batch=$Channel.Drain()
 if($Channel.IsStopped){$Store.MarkGap();throw 'External provider channel stopped.'}
 if($batch.Gap){$Store.MarkGap()}
 foreach($event in @($batch.Events)){
  if(-not $allowed.ContainsKey([string]$event.Provider)){continue}
  if($scoped.ContainsKey([string]$event.Provider)){
   $session=[string]$event.Session
   if($session -cnotmatch '^([a-f0-9]{32})_' -or $scoped[[string]$event.Provider] -cnotcontains $Matches[1]){continue}
  }
  $received=[DateTimeOffset]$event.ObservedAt
  if($received -eq [DateTimeOffset]::MinValue -or $received -gt $Now.AddMinutes(1)){$Store.MarkGap();continue}
  if($received -gt $Now){$received=$Now}
  [void]$Store.Apply($event,$received)
 }
 foreach($provider in $scoped.Keys){$Store.MarkSessionScopesGap([string]$provider,[string[]]@($UncertainProfileScopes[$provider]))}
 if($Channel.IsStopped){$Store.MarkGap();throw 'External provider channel stopped.'}
 return @(Convert-ExternalProviderStates -States @($Store.Snapshot($Now)) -Language $Language)
}

# The application starts a receiver only when a provider has actually been
# connected. The store outlives a stopped receiver while this monitor is open.
function New-ExternalProviderController {
 param([string]$PipeName = '')
 return [PSCustomObject]@{Channel=$null;Store=$null;PipeName=$PipeName;DegradedProviders=@{}}
}

function Stop-ExternalProviderController {
 param([Parameter(Mandatory=$true)]$Controller,[switch]$KnownIdle)
 if($null -ne $Controller.Channel){
  if(-not $KnownIdle -and $null -ne $Controller.Store){$Controller.Store.MarkGap()}
  try{$Controller.Channel.Dispose()}finally{$Controller.Channel=$null}
 }
 $Controller.DegradedProviders.Clear()
}

function Read-ManagedExternalProviderSnapshot {
 param(
  [Parameter(Mandatory=$true)]$Controller,
  [string[]]$AllowedProviders = @(),
  [string[]]$RetainedProviders = $null,
  [string[]]$UncertainProviders = @(),
  [hashtable]$ProfileScopes = @{},
  [hashtable]$UncertainProfileScopes = @{},
  [hashtable]$ConfirmedDisconnectedProfileScopes = @{},
  [ValidateSet('ru','en')][string]$Language = 'ru',
  [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
 )
 $allowed=@($AllowedProviders | Where-Object {$_ -in @('kimi','deepseek','hermes','opencode')} | Select-Object -Unique)
 if($null -eq $RetainedProviders){$RetainedProviders=[string[]]$allowed}
 if($allowed.Count -eq 0){
  if($null -ne $Controller.Store){$Controller.Store.RetainProviders([string[]]@())}
  Stop-ExternalProviderController $Controller -KnownIdle;return @()
 }
 if($null -eq $Controller.Channel){
  if(-not ('AITaskMonitor.ExternalProviders.EventChannel' -as [type])){
   Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
   $sources=@((Join-Path $PSScriptRoot 'ProviderEventState.cs'),(Join-Path $PSScriptRoot 'ProviderEventChannel.cs'))
   Add-Type -Path $sources -ReferencedAssemblies System.Web.Extensions -ErrorAction Stop
  }
  if($null -eq $Controller.Store){$Controller.Store=[AITaskMonitor.ExternalProviders.StateStore]::new()}
  try{$Controller.Channel=[AITaskMonitor.ExternalProviders.EventChannel]::new($Controller.PipeName)}
  catch{foreach($provider in $allowed){$Controller.Store.MarkProviderGap([string]$provider)};throw}
 }
 return @(Read-ExternalProviderSnapshot -Channel $Controller.Channel -Store $Controller.Store -AllowedProviders $allowed -RetainedProviders $RetainedProviders -UncertainProviders $UncertainProviders -ProfileScopes $ProfileScopes -UncertainProfileScopes $UncertainProfileScopes -ConfirmedDisconnectedProfileScopes $ConfirmedDisconnectedProfileScopes -Language $Language -Now $Now)
}

# Connection failures are isolated per provider; only a shared channel failure
# marks every currently connected external source as unavailable.
function Read-ExternalProviderGroupSnapshot {
 param(
  [Parameter(Mandatory=$true)]$Controller,
  [Parameter(Mandatory=$true)][hashtable]$Connections,
  [Parameter(Mandatory=$true)][hashtable]$Seen,
  [object[]]$PreviousTasks = @(),
  [hashtable]$ProfileScopes = @{},
  [hashtable]$UncertainProfileScopes = @{},
  [hashtable]$ConfirmedDisconnectedProfileScopes = @{},
  [ValidateSet('ru','en')][string]$Language = 'ru'
 )
 $names=[ordered]@{kimi='Kimi Code';deepseek='DeepSeek Harness';hermes='Hermes Agent';opencode='OpenCode'}
 $allowed=New-Object 'Collections.Generic.List[string]'
 $uncertain=New-Object 'Collections.Generic.List[string]'
 $unavailable=New-Object 'Collections.Generic.List[string]'
 $partialConnection=New-Object 'Collections.Generic.List[string]'
 $partialData=New-Object 'Collections.Generic.List[string]'
 $newGaps=New-Object 'Collections.Generic.List[string]'
 foreach($provider in @($Controller.DegradedProviders.Keys)){
  if(-not $Connections.ContainsKey($provider) -or $Connections[$provider] -ne 'connected-degraded'){[void]$Controller.DegradedProviders.Remove($provider)}
 }
 foreach($provider in $names.Keys){
  if(-not $Connections.ContainsKey($provider)){
   if($Seen.ContainsKey($provider)){$uncertain.Add($provider);$unavailable.Add($names[$provider])}
   continue
  }
  switch([string]$Connections[$provider]){
   'connected' {$Seen[$provider]=$true;$allowed.Add($provider)}
   'connected-degraded' {
    $Seen[$provider]=$true;$allowed.Add($provider);$unavailable.Add($names[$provider])
    $partialConnection.Add($names[$provider])
    if(-not $ProfileScopes.ContainsKey($provider) -and -not $Controller.DegradedProviders.ContainsKey($provider)){$newGaps.Add($provider);$Controller.DegradedProviders[$provider]=$true}
   }
   'partial' {$uncertain.Add($provider);$unavailable.Add($names[$provider])}
   'error' {if($Seen.ContainsKey($provider)){$uncertain.Add($provider);$unavailable.Add($names[$provider])}}
   'disconnected' {[void]$Seen.Remove($provider)}
   default {throw 'Invalid external provider connection state.'}
  }
 }
 $confirmed=@(Get-ConfirmedDisconnectedDeepSeekScopes $ConfirmedDisconnectedProfileScopes $ProfileScopes $UncertainProfileScopes)
 $eligiblePrevious=@($PreviousTasks | Where-Object {
  $id=[string]$_.Id
  -not ($_.Provider -ceq 'deepseek' -and $id -cmatch '^deepseek:([a-f0-9]{32})_' -and $confirmed -ccontains $Matches[1])
 })
 $retained=@(Unconfirmed-ExternalTasks @($eligiblePrevious|Where-Object {$_.Provider -in $uncertain}))
 $keep=[string[]]@($allowed.ToArray()+$uncertain.ToArray() | Select-Object -Unique)
 if($allowed.Count -eq 0){
  if($null -ne $Controller.Store){
   $Controller.Store.RetainProviders($keep)
   foreach($provider in $uncertain){$Controller.Store.MarkProviderGap([string]$provider)}
   $Controller.Store.ConfirmDeepSeekDisconnectedScopes([string[]]$confirmed)
   $stored=@(Convert-ExternalProviderStates -States @($Controller.Store.Snapshot([DateTimeOffset]::UtcNow)) -Language $Language)
   $merged=[ordered]@{}
   foreach($task in @($retained+@($stored | Where-Object {$_.Provider -in $uncertain}))){if($task -and $task.Id){$merged[[string]$task.Id]=$task}}
   $retained=@($merged.Values)
  }
  Stop-ExternalProviderController $Controller -KnownIdle
  return [PSCustomObject]@{Tasks=$retained;Unavailable=$unavailable.ToArray();PartialConnection=@();PartialData=@()}
 }
 try{
  $current=@(Read-ManagedExternalProviderSnapshot -Controller $Controller -AllowedProviders $allowed.ToArray() -RetainedProviders $keep -UncertainProviders ([string[]]@($uncertain.ToArray()+$newGaps.ToArray())) -ProfileScopes $ProfileScopes -UncertainProfileScopes $UncertainProfileScopes -ConfirmedDisconnectedProfileScopes $ConfirmedDisconnectedProfileScopes -Language $Language)
  if($null -ne $Controller.Store){
   foreach($provider in @($Controller.Store.CapacityLimitedProviders)+@($Controller.Store.LossAffectedProviders)){
    if($keep -ccontains [string]$provider -and $names.Contains([string]$provider)){
     $name=[string]$names[$provider]
     if(-not $unavailable.Contains($name)){$unavailable.Add($name)}
     if($allowed.Contains([string]$provider) -and -not $partialData.Contains($name)){$partialData.Add($name)}
    }
   }
  }
  $merged=[ordered]@{}
  foreach($task in @($retained+$current)){if($task -and $task.Id){$merged[[string]$task.Id]=$task}}
  return [PSCustomObject]@{Tasks=@($merged.Values);Unavailable=$unavailable.ToArray();PartialConnection=$partialConnection.ToArray();PartialData=$partialData.ToArray()}
 }catch{
  foreach($provider in $allowed){$uncertain.Add($provider);if(-not $unavailable.Contains($names[$provider])){$unavailable.Add($names[$provider])}}
  $retained=@(Unconfirmed-ExternalTasks @($eligiblePrevious|Where-Object {$_.Provider -in $uncertain}))
  Stop-ExternalProviderController $Controller
  return [PSCustomObject]@{Tasks=$retained;Unavailable=$unavailable.ToArray();PartialConnection=@();PartialData=@()}
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
