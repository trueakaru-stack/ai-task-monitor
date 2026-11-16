$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path (Join-Path $PSScriptRoot '../app/integrations/ProviderEventState.cs') -ReferencedAssemblies System.Web.Extensions
. (Join-Path $PSScriptRoot '../app/integrations/ProviderRuntime.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Read-ManagedExternalProviderSnapshot {
    param($Controller, $AllowedProviders, $ProfileScopes, $UncertainProfileScopes, $Language)
    return @()
}
function Unconfirmed-ExternalTasks { param([object[]]$tasks) return @($tasks) }
$bounded = [AITaskMonitor.ExternalProviders.StateStore]::new()
$bounded.RetainProviders([string[]]@('deepseek','opencode','kimi'))
$now = [DateTimeOffset]::Parse('2026-11-04T10:00:00Z')
for ($i = 0; $i -lt 256; $i++) {
    $input = [AITaskMonitor.ExternalProviders.EventParser]::Parse(('{"version":1,"provider":"deepseek","session":"s' + $i + '","kind":"active"}'))
    Assert ($bounded.Apply($input, $now)) 'Could not fill the synthetic store.'
}
$overflow = [AITaskMonitor.ExternalProviders.EventParser]::Parse('{"version":1,"provider":"deepseek","session":"overflow","kind":"active"}')
Assert (-not $bounded.Apply($overflow, $now)) 'The synthetic store accepted an overflow.'
$controller = [PSCustomObject]@{Store=$bounded; Channel=$null; DegradedProviders=@{}}
$group = Read-ExternalProviderGroupSnapshot -Controller $controller -Connections @{deepseek='connected';opencode='connected';kimi='connected'} -Seen @{}
Assert (@($group.Unavailable) -ccontains 'DeepSeek Harness') 'The group hid a capacity-limited source.'
Assert (@($group.Unavailable).Count -eq 1) 'An unrelated source was marked unavailable at capacity.'
Write-Output 'External provider capacity warning: synthetic group policy passed.'
