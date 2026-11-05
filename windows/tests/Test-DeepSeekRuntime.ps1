param(
 [Parameter(Mandatory=$true)][string]$DshAnchor,
 [Parameter(Mandatory=$true)][string]$PnpmScript
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\app\integrations\DeepSeekRuntime.ps1')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-runtime-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($root)
$old=@{}
foreach($name in @('USERPROFILE','APPDATA','LOCALAPPDATA','DSH_HOME','HOME','XDG_CONFIG_HOME','XDG_CACHE_HOME','PNPM_CONFIG_STORE_DIR','PNPM_CONFIG_IGNORE_SCRIPTS','PNPM_CONFIG_IGNORE_PNPMFILE','PNPM_CONFIG_OFFLINE','NPM_CONFIG_USERCONFIG')){
 $old[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}
function Await-FixtureRequest($request){
 $deadline=[DateTimeOffset]::UtcNow.AddSeconds(50)
 while([DateTimeOffset]::UtcNow -lt $deadline){
  $result=Receive-DeepSeekRuntimeRequest $request
  if($null -ne $result){return $result}
  Start-Sleep -Milliseconds 100
 }
 throw 'The isolated DeepSeek setup did not finish.'
}
function Await-FixtureController($controller,[scriptblock]$condition){
 $deadline=[DateTimeOffset]::UtcNow.AddSeconds(50)
 while([DateTimeOffset]::UtcNow -lt $deadline){
  Update-DeepSeekMonitorController $controller
  if(& $condition){return}
  Start-Sleep -Milliseconds 100
 }
 throw 'The isolated DeepSeek controller did not reach the expected state.'
}
try{
 foreach($name in @('USERPROFILE','APPDATA','LOCALAPPDATA','HOME')){[Environment]::SetEnvironmentVariable($name,$root,'Process')}
 $dshHome=Join-Path $root 'dsh-home'
 [Environment]::SetEnvironmentVariable('DSH_HOME',$dshHome,'Process')
 [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME',(Join-Path $root 'config'),'Process')
 [Environment]::SetEnvironmentVariable('XDG_CACHE_HOME',(Join-Path $root 'cache'),'Process')
 [Environment]::SetEnvironmentVariable('PNPM_CONFIG_STORE_DIR',(Join-Path $root 'store'),'Process')
 [Environment]::SetEnvironmentVariable('PNPM_CONFIG_IGNORE_SCRIPTS','true','Process')
 [Environment]::SetEnvironmentVariable('PNPM_CONFIG_IGNORE_PNPMFILE','true','Process')
 [Environment]::SetEnvironmentVariable('PNPM_CONFIG_OFFLINE','true','Process')
 [Environment]::SetEnvironmentVariable('NPM_CONFIG_USERCONFIG',(Join-Path $root 'empty-npmrc'),'Process')
 [IO.File]::WriteAllText($env:NPM_CONFIG_USERCONFIG,'')
 $foreign=Join-Path $root 'foreign';[void][IO.Directory]::CreateDirectory($foreign)
 [IO.File]::WriteAllText((Join-Path $foreign 'package.json'),'{"name":"aitm-foreign-fixture","version":"1.0.0","type":"module","main":"index.js","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}',[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $foreign 'index.js'),'export function apply() {}',[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $foreign 'cordis.patch.yml'),"- insert:`n    - id: foreign-fixture`n      name: aitm-foreign-fixture`n",[Text.UTF8Encoding]::new($false))
 $profile='тестовый-профиль'
 $node=(Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
 $bin=Join-Path (Split-Path -Parent $DshAnchor) 'lib\bin.js'
 & $node $bin plugin --profile $profile add --offline --ignore-scripts $foreign | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Could not initialize the isolated profile.'}
 $assets=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\integrations'))
 $context=[PSCustomObject]@{Node=$node;Home=$dshHome;Assets=$assets;Anchor=[IO.Path]::GetFullPath($DshAnchor);Pnpm=[IO.Path]::GetFullPath($PnpmScript);Bridge=(Join-Path $assets 'deepseek-setup.mjs')}
 $list=Await-FixtureRequest (Start-DeepSeekRuntimeRequest $context 'list')
 if(-not $list.Ok -or @($list.Result).Count -ne 1 -or $list.Result[0].name -cne $profile -or $list.Result[0].state -cne 'disconnected'){throw 'Profile list did not round-trip Unicode correctly.'}
 $connected=Await-FixtureRequest (Start-DeepSeekRuntimeRequest $context 'connect' $profile)
 if(-not $connected.Ok -or $connected.Result -cne 'connected'){throw 'The isolated connection failed.'}
 $disconnected=Await-FixtureRequest (Start-DeepSeekRuntimeRequest $context 'disconnect' $profile)
 if(-not $disconnected.Ok -or $disconnected.Result -cne 'disconnected'){throw 'The isolated disconnection failed.'}
 $manifest=Get-Content -LiteralPath (Join-Path $dshHome ("profiles\$profile\package.json")) -Raw | ConvertFrom-Json
 if($null -eq $manifest.dependencies.'aitm-foreign-fixture'){throw 'An unrelated plugin was changed.'}
 $profileTwo='second-profile'
 & $node $bin plugin --profile $profileTwo add --offline --ignore-scripts $foreign | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Could not initialize the second isolated profile.'}
 $controller=New-DeepSeekMonitorController -AppRoot (Split-Path -Parent $assets) -FixtureContext $context
 Await-FixtureController $controller { $controller.Scanned -and $null -eq $controller.Request }
 Request-DeepSeekProfileConnection $controller $profile $true
 Await-FixtureController $controller { $controller.Scanned -and $null -eq $controller.Request -and (Get-DeepSeekMonitorConnectionState $controller) -eq 'connected' }
 Request-DeepSeekProfileConnection $controller $profileTwo $true
 Await-FixtureController $controller { $null -eq $controller.Request -and @($controller.Profiles|Where-Object {$_.State -eq 'connected'}).Count -eq 2 }
 $controller.Seen['unavailable-profile']=$true
 if((Get-DeepSeekMonitorConnectionState $controller) -ne 'connected-degraded'){throw 'A failed profile hid a connected profile.'}
 [void]$controller.Seen.Remove('unavailable-profile')

 # Exercise the app's real source snapshot, channel and state store using the
 # two monitor bundles just installed in the isolated profile directories.
 . (Join-Path $assets 'ProviderEventView.ps1')
 . (Join-Path $assets 'ProviderRuntime.ps1')
 $tokens=$null;$parseErrors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $assets) 'CodexProgress.ps1'),[ref]$tokens,[ref]$parseErrors)
 if($parseErrors.Count){throw 'Application source could not be parsed.'}
 foreach($functionName in @('Prop','Unconfirmed-Tasks','Unconfirmed-ExternalTasks','Source-Snapshot')){
  $definition=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $functionName},$true)
  . ([scriptblock]::Create($definition.Extent.Text))
 }
 function Codex-Tasks {return [PSCustomObject]@{Id='codex:one';Provider='codex';Active=$true;Status='working'}}
 function Claude-ConnectionState {return 'connected'}
 function Claude-Tasks {return [PSCustomObject]@{Id='claude:one';Provider='claude';Active=$true;Status='working'}}
 function Get-OpenCodeConnectionState {return 'disconnected'}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root)),0,12).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 $pipe='AITaskMonitor.ProviderEvents.'+$hash
 $ClaudeEventFile='';$script:lastCodexTasks=@();$script:lastClaudeTasks=@();$script:lastExternalTasks=@()
 $script:externalProviderModulesAvailable=$true;$script:externalProviderController=New-ExternalProviderController -PipeName $pipe
 $script:seenExternalConnections=@{};$script:resolvedLanguage='en';$script:showingSettings=$false
 $script:deepSeekModulesAvailable=$true;$script:deepSeekController=$controller
 try{
  $initial=Source-Snapshot
  if(@($initial.Tasks).Count -ne 2 -or $null -eq $script:externalProviderController.Channel){throw 'The connected profiles did not start the app channel.'}
  $first=Join-Path $dshHome ("profiles\$profile\ai-task-monitor-observer")
  $second=Join-Path $dshHome ("profiles\$profileTwo\ai-task-monitor-observer")
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$node
  $start.Arguments='"'+(Join-Path $PSScriptRoot 'Invoke-DeepSeekProfilesFixture.mjs')+'" "'+$first+'" "'+$second+'"'
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $observer=[Diagnostics.Process]::Start($start)
  try{if(-not $observer.WaitForExit(10000) -or $observer.ExitCode -ne 0){throw 'The synthetic profile events failed.'}}finally{$observer.Dispose()}
  $snapshot=Source-Snapshot
  $external=@($snapshot.Tasks|Where-Object {$_.Provider -eq 'deepseek'})
  if($external.Count -ne 2 -or @($external|Where-Object {$_.Paused}).Count -ne 1 -or @($external|Where-Object {$_.Steps.Count -eq 1}).Count -ne 1){throw 'The app mixed or lost DeepSeek profile events.'}
  $firstScope=[string](@($controller.Profiles|Where-Object {$_.Name -ceq $profile})[0].Scope)
  Request-DeepSeekProfileConnection $controller $profile $false
  Await-FixtureController $controller { $null -eq $controller.Request -and @($controller.Profiles|Where-Object {$_.Name -ceq $profile -and $_.State -eq 'disconnected'}).Count -eq 1 }
  $after=Source-Snapshot
  $remaining=@($after.Tasks|Where-Object {$_.Provider -eq 'deepseek'})
  if($remaining.Count -ne 1 -or $remaining[0].Id.StartsWith('deepseek:'+$firstScope+'_')){throw 'Disconnect did not remove only the selected profile task.'}
  if(@($after.Tasks|Where-Object {$_.Provider -eq 'codex' -or $_.Provider -eq 'claude'}).Count -ne 2){throw 'The other sources changed unexpectedly.'}
 }finally{Stop-ExternalProviderController $script:externalProviderController}
 Request-DeepSeekProfileConnection $controller $profileTwo $false
 Await-FixtureController $controller { $null -eq $controller.Request -and (Get-DeepSeekMonitorConnectionState $controller) -eq 'disconnected' }
 'DeepSeek Windows bridge: hidden process, Unicode profile and isolated add/remove passed.'
}finally{
 foreach($name in $old.Keys){[Environment]::SetEnvironmentVariable($name,$old[$name],'Process')}
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
