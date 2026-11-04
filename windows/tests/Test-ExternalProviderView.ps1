$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path (Join-Path $PSScriptRoot '../app/integrations/ProviderEventState.cs') -ReferencedAssemblies System.Web.Extensions
. (Join-Path $PSScriptRoot '../app/integrations/ProviderEventView.ps1')
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
function Add($store,[string]$json,$now){$event=[AITaskMonitor.ExternalProviders.EventParser]::Parse($json);Assert ($null -ne $event) 'Invalid fixture.';Assert ($store.Apply($event,$now)) 'Could not apply fixture.'}
$now=[DateTimeOffset]::UtcNow
$store=[AITaskMonitor.ExternalProviders.StateStore]::new()
Add $store '{"version":1,"provider":"opencode","session":"one","kind":"tool_started","call":"c1","action":"command"}' $now
Add $store '{"version":1,"provider":"opencode","session":"one","kind":"plan","steps":[{"title":"One","status":"done"},{"title":"Two","status":"active"}]}' $now
Add $store '{"version":1,"provider":"kimi","session":"two","kind":"waiting"}' $now
$tasks=@(Convert-ExternalProviderStates -States @($store.Snapshot($now)))
Assert ($tasks.Count -eq 2) 'Expected two separate provider tasks.'
$one=@($tasks|Where-Object Provider -eq 'opencode')[0]
$two=@($tasks|Where-Object Provider -eq 'kimi')[0]
Assert ($one.Id -eq 'opencode:one' -and $one.Active -and $one.Activity -eq 'Выполняет команду') 'Incorrect current action.'
Assert ($one.Progress -eq 50 -and $one.ProgressKind -eq 'exact' -and $one.ProgressBasis -eq 'steps') 'Incorrect plan-based progress.'
Assert (-not $two.Active -and $two.Paused -and $null -eq $two.Progress -and $two.Steps.Count -eq 0) 'Waiting task must not invent progress.'
$english=@(Convert-ExternalProviderStates -States @($store.Snapshot($now)) -Language 'en')
Assert ((@($english|Where-Object Provider -eq 'opencode')[0]).Title -eq 'OpenCode task') 'The generated title must follow the selected language.'
Add $store '{"version":1,"provider":"opencode","session":"one","kind":"heartbeat"}' $now.AddMinutes(29)
$longRu=@(Convert-ExternalProviderStates -States @($store.Snapshot($now.AddMinutes(30))))
$longEn=@(Convert-ExternalProviderStates -States @($store.Snapshot($now.AddMinutes(30))) -Language 'en')
Assert ((@($longRu|Where-Object Provider -eq 'opencode')[0]).Activity -eq 'Долго выполняется · связь с агентом есть') 'Incorrect Russian long-running label.'
Assert ((@($longEn|Where-Object Provider -eq 'opencode')[0]).Activity -eq 'Running for a long time · agent reachable') 'Incorrect English long-running label.'
Write-Output 'External provider view fixtures passed.'
