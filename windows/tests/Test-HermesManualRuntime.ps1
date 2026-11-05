param(
 [Parameter(Mandatory=$true)][string]$FixturePython,
 [Parameter(Mandatory=$true)][string]$FixtureHermesSource
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '../app/integrations/HermesRuntime.ps1')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-hermes-manual-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($root)
try{
 $fixtureHome=Join-Path $root 'home';$project=Join-Path $root 'project';$assets=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app/integrations'))
 foreach($folder in @($fixtureHome,$project,(Join-Path $fixtureHome 'profiles\work'))){[void][IO.Directory]::CreateDirectory($folder)}
 $config="plugins:`n  enabled: [foreign]`nprivate: PRIVATE_FIXTURE`n"
 [IO.File]::WriteAllText((Join-Path $fixtureHome 'config.yaml'),$config)
 [IO.File]::WriteAllText((Join-Path $fixtureHome 'profiles\work\config.yaml'),$config)
 foreach($name in @('hermes_cli\middleware.py','hermes_cli\plugins.py','hermes_cli\plugins_dispatch.py','hermes_cli\lifecycle.py','agent\turn_api_request.py','agent\turn_finalizer.py','tools\human_input_hooks.py','agent\conversation_loop.py','model_tools.py','hermes_cli\cli_shutdown.py','hermes_cli\cli_session_mixin.py','hermes_cli\plugins_discovery.py','hermes_cli\config.py','hermes_cli\config_backend.py','hermes_cli\managed_scope.py','hermes_yaml.py','hermes_cli\env_loader.py','hermes_cli\config_defaults.py','hermes_cli\profiles.py','hermes_constants.py','agent\tool_executor.py')){
  $target=Join-Path $project $name;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));Copy-Item -LiteralPath (Join-Path $FixtureHermesSource $name) -Destination $target
 }
 $context=[PSCustomObject]@{Home=$fixtureHome;Project=$project;Assets=$assets;Python=$FixturePython;Bridge=(Join-Path $assets 'hermes-setup.py')}
 $controller=New-HermesMonitorController -AppRoot (Split-Path -Parent $assets) -FixtureContext $context
 function Wait-HermesScan {
  param($controller)
  $deadline=[DateTimeOffset]::UtcNow.AddSeconds(20)
  do{
   Update-HermesMonitorController $controller
   if($controller.LastError){throw ('Hermes fixture failed: '+$controller.LastError)}
   if($controller.Scanned -and $null -eq $controller.Request -and $controller.NextScan -gt [DateTimeOffset]::UtcNow){return}
   Start-Sleep -Milliseconds 40
  }while([DateTimeOffset]::UtcNow -lt $deadline)
  throw 'Hermes fixture timed out.'
 }
 Wait-HermesScan $controller
 if(@($controller.Profiles).Count -ne 2 -or @($controller.Profiles | Where-Object {$_.State -ne 'absent'}).Count -ne 0){throw 'Unexpected initial profiles.'}
 if(@(Get-HermesAllowedScopes $controller).Count -ne 0){throw 'An unstaged profile was allowed.'}
 foreach($profile in @('root','profile:work')){
  Request-HermesProfilePrepare $controller $profile
  Wait-HermesScan $controller
  if($controller.ActionError){throw 'Manual preparation failed.'}
 }
 if(@(Get-HermesAllowedScopes $controller).Count -ne 0){throw 'Preparation alone must not claim that Hermes enabled the plugin.'}
 if([IO.File]::ReadAllText((Join-Path $fixtureHome 'config.yaml')) -cne $config -or [IO.File]::ReadAllText((Join-Path $fixtureHome 'profiles\work\config.yaml')) -cne $config){throw 'Hermes settings changed.'}
 # Simulate the user's subsequent manager action in these throwaway profiles.
 $enabledConfig=$config.Replace('[foreign]','[foreign, ai-task-monitor]')
 [IO.File]::WriteAllText((Join-Path $fixtureHome 'config.yaml'),$enabledConfig)
 [IO.File]::WriteAllText((Join-Path $fixtureHome 'profiles\work\config.yaml'),$enabledConfig)
 $controller.NextScan=[DateTimeOffset]::MinValue
 Wait-HermesScan $controller
 $scopes=@(Get-HermesAllowedScopes $controller)
 if($scopes.Count -ne 2 -or $scopes[0] -ceq $scopes[1]){throw 'Prepared profiles did not receive distinct scopes.'}
 $disabledConfig=$enabledConfig.Replace('  enabled:',"  disabled: [ai-task-monitor]`n  enabled:")
 [IO.File]::WriteAllText((Join-Path $fixtureHome 'config.yaml'),$disabledConfig)
 $controller.NextScan=[DateTimeOffset]::MinValue
 Wait-HermesScan $controller
 if(@(Get-HermesAllowedScopes $controller).Count -ne 1 -or @(Get-HermesUncertainScopes $controller).Count -ne 0){throw 'A manually disabled profile remained allowed.'}
 [IO.File]::WriteAllText((Join-Path $fixtureHome 'config.yaml'),$enabledConfig)
 $controller.NextScan=[DateTimeOffset]::MinValue
 Wait-HermesScan $controller
 $tampered=Join-Path $fixtureHome 'plugins\ai-task-monitor\hermes_observer.py'
 [IO.File]::WriteAllText($tampered,'foreign edit')
 $controller.NextScan=[DateTimeOffset]::MinValue
 Wait-HermesScan $controller
 if(@(Get-HermesAllowedScopes $controller).Count -ne 1 -or @(Get-HermesUncertainScopes $controller).Count -ne 1 -or (Get-HermesMonitorConnectionState $controller) -cne 'connected-degraded'){throw 'Tampered profile did not become uncertain.'}
 if([IO.File]::ReadAllText($tampered) -cne 'foreign edit'){throw 'A modified plugin was overwritten.'}
 $oversize=Join-Path $root 'oversize.py';[IO.File]::WriteAllText($oversize,'import sys; sys.stdin.read(); print("x" * 200000)')
 $large=[AITaskMonitor.Hermes.Command]::new($FixturePython,$oversize,$root,'{}',5000)
 try{
  $deadline=[DateTimeOffset]::UtcNow.AddSeconds(8)
  while(-not $large.Completed -and [DateTimeOffset]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 30}
  if(-not $large.Completed -or $large.GetResult().Ok){throw 'Oversized bridge output was accepted.'}
 }finally{$large.Dispose()}
 $slow=Join-Path $root 'slow.py';[IO.File]::WriteAllText($slow,'import time; time.sleep(20)')
 $blocked=[AITaskMonitor.Hermes.Command]::new($FixturePython,$slow,$root,'{}',300)
 try{
  $deadline=[DateTimeOffset]::UtcNow.AddSeconds(5)
  while(-not $blocked.Completed -and [DateTimeOffset]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 30}
  if(-not $blocked.Completed -or $blocked.GetResult().Ok){throw 'A stuck bridge did not time out.'}
 }finally{$blocked.Dispose()}
 $envProbe=Join-Path $root 'environment.py'
 [IO.File]::WriteAllText($envProbe,'import os,sys; sys.stdin.read(); print("safe" if "AITM_FIXTURE_SECRET" not in os.environ else "unsafe")')
 $previousFixtureSecret=[Environment]::GetEnvironmentVariable('AITM_FIXTURE_SECRET','Process')
 try{
  [Environment]::SetEnvironmentVariable('AITM_FIXTURE_SECRET','synthetic-only','Process')
  $probe=[AITaskMonitor.Hermes.Command]::new($FixturePython,$envProbe,$root,'{}',5000)
  try{
   $deadline=[DateTimeOffset]::UtcNow.AddSeconds(7)
   while(-not $probe.Completed -and [DateTimeOffset]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 30}
   if(-not $probe.Completed -or -not $probe.GetResult().Ok -or $probe.GetResult().Json.Trim() -cne 'safe'){throw 'The bridge inherited an unrelated environment value.'}
  }finally{$probe.Dispose()}
 }finally{[Environment]::SetEnvironmentVariable('AITM_FIXTURE_SECRET',$previousFixtureSecret,'Process')}
 'Hermes manual runtime: isolated profiles, preparation, scope isolation, tampering, bounded output and timeout passed.'
}finally{
 if($null -ne (Get-Variable -Name controller -ErrorAction SilentlyContinue)){Stop-HermesMonitorController $controller}
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
