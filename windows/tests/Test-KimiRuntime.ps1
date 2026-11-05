$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '../app/integrations/KimiRuntime.ps1')
. (Join-Path $PSScriptRoot '../app/integrations/ProviderEventView.ps1')
. (Join-Path $PSScriptRoot '../app/integrations/ProviderRuntime.ps1')
function Unconfirmed-ExternalTasks($tasks){
 foreach($task in $tasks){$copy=$task.PSObject.Copy();$copy.Active=$false;$copy.Paused=$false;$copy.Status='Статус не подтверждён';$copy.Activity='Статус не подтверждён';$copy.PlanConfirmed=$false;$copy}
}
$node=(Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-kimi-runtime-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($root)
$old=@{}
foreach($name in @('PATH','USERPROFILE','APPDATA','KIMI_CODE_HOME')){$old[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
function Wait-Kimi($controller,[scriptblock]$condition){
 $limit=[DateTimeOffset]::UtcNow.AddSeconds(15)
 while([DateTimeOffset]::UtcNow -lt $limit){
  Update-KimiMonitorController $controller
  if(& $condition){return}
  Start-Sleep -Milliseconds 50
 }
 throw 'The Kimi fixture did not reach the expected state.'
}
try{
 $bin=Join-Path $root 'bin';$package=Join-Path $bin 'node_modules\@moonshot-ai\kimi-code'
 $testHome=Join-Path $root 'kimi-home';$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
 $assets=Join-Path $app 'integrations\kimi-plugin';$bridge=Join-Path $app 'integrations\kimi-setup.mjs'
 foreach($directory in @($bin,$package,$testHome)){[void][IO.Directory]::CreateDirectory($directory)}
 foreach($name in @('node.exe','kimi.cmd')){[IO.File]::WriteAllText((Join-Path $bin $name),'fixture')}
 $anchor=Join-Path $package 'package.json'
 [IO.File]::WriteAllText($anchor,'{"name":"@moonshot-ai/kimi-code","version":"2.5.0"}')
 $env:PATH=$bin;$env:USERPROFILE=$root;$env:APPDATA=$root;$env:KIMI_CODE_HOME=$testHome
 $found=Get-KimiRuntimeContext -AppRoot $app
 if($null -eq $found -or $found.Home -cne $testHome -or $found.Anchor -cne $anchor){throw 'The isolated Kimi installation was not discovered.'}
 foreach($invalid in @('relative','C:relative','\relative','\\server','\\?\C:\device')){
  $env:KIMI_CODE_HOME=$invalid
  if($null -ne (Get-KimiRuntimeContext -AppRoot $app)){throw 'A non-absolute Kimi home must not be guessed.'}
 }
 $env:KIMI_CODE_HOME=$testHome
 $context=[PSCustomObject]@{Node=$node;Home=$testHome;Assets=$assets;Anchor=$anchor;Bridge=$bridge}
 $controller=New-KimiMonitorController -AppRoot $app -FixtureContext $context
 Wait-Kimi $controller {$controller.Scanned -and $null -eq $controller.Request}
 if($controller.State -ne 'disconnected'){throw 'An absent plugin must be disconnected.'}
 $plugins=Join-Path $testHome 'plugins';$managed=Join-Path $plugins 'managed\ai-task-monitor'
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $managed))
 Copy-Item -LiteralPath $assets -Destination $managed -Recurse
 $registry=Join-Path $plugins 'installed.json'
 $record=@{version=1;plugins=@(@{id='other';root='PRIVATE';enabled=$true},@{id='ai-task-monitor';root=$managed;enabled=$true})} | ConvertTo-Json -Depth 5 -Compress
 [IO.File]::WriteAllText($registry,$record,[Text.UTF8Encoding]::new($false))
 $controller.NextScan=[DateTimeOffset]::MinValue
 Wait-Kimi $controller {$controller.State -eq 'connected' -and $null -eq $controller.Request}
 if($controller.Scope -cnotmatch '^[a-f0-9]{32}$' -or $controller.SeenScope -cne $controller.Scope){throw 'The connected Kimi scope is invalid.'}
 if([IO.File]::ReadAllText($registry) -cne $record){throw 'A read-only Kimi check changed its registry.'}
 # Deliver real plugin callbacks through the actual receiver using only this
 # disposable USERPROFILE and its corresponding unique named pipe.
 $receiver=New-ExternalProviderController
 $seen=@{};$previous=@();$connections=@{kimi='connected';opencode='connected'}
 $scopes=@{kimi=@($controller.Scope)}
 try {
  $group=Read-ExternalProviderGroupSnapshot -Controller $receiver -Connections $connections -Seen $seen -ProfileScopes $scopes
  if($null -eq $receiver.Channel){throw 'The connected Kimi receiver did not start.'}
  foreach($kind in @('TurnStarted','PermissionRequest','PermissionResult','Interrupt')){
   $start=[Diagnostics.ProcessStartInfo]::new()
   $start.FileName=$node;$start.Arguments='"'+(Join-Path $assets 'kimi-hook.mjs')+'"';$start.WorkingDirectory=$assets
   $start.UseShellExecute=$false;$start.CreateNoWindow=$true
   $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
   $process=[Diagnostics.Process]::Start($start)
   try{
    $payload=@{hook_event_name=$kind;session_id='synthetic-session';turn_id=1;prompt='PRIVATE_PROMPT'} | ConvertTo-Json -Compress
    $process.StandardInput.Write($payload);$process.StandardInput.Close()
    $out=$process.StandardOutput.ReadToEnd();$err=$process.StandardError.ReadToEnd()
    if(-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0 -or $out -or $err){throw 'A synthetic Kimi hook was not silent.'}
   }finally{if(-not $process.HasExited){$process.Kill()};$process.Dispose()}
   $group=Read-ExternalProviderGroupSnapshot -Controller $receiver -Connections $connections -Seen $seen -PreviousTasks $previous -ProfileScopes $scopes
   $previous=@($group.Tasks)
   $task=@($previous | Where-Object {$_.Provider -eq 'kimi'})
   if($task.Count -ne 1 -or $task[0].Active -or $task[0].Paused -or $task[0].Status -ne 'Статус не подтверждён' -or $null -ne $task[0].Progress){throw 'A Kimi callback was not shown as unconfirmed.'}
  }
  if(($previous | ConvertTo-Json -Depth 8 -Compress) -match 'PRIVATE_PROMPT|synthetic-session'){throw 'A Kimi task exposed private input.'}
 [IO.File]::WriteAllText((Join-Path $managed 'foreign.txt'),'KEEP')
 $controller.NextScan=[DateTimeOffset]::MinValue
 Wait-Kimi $controller {$controller.LastError -eq 'modified-bundle' -and $null -eq $controller.Request}
 if((Get-KimiMonitorConnectionState $controller) -ne 'error' -or @(Get-KimiAllowedScopes $controller).Count -ne 0 -or @(Get-KimiUncertainScopes $controller).Count -ne 1){throw 'A modified Kimi bundle must become unconfirmed.'}
 $connections.kimi=Get-KimiMonitorConnectionState $controller
 $group=Read-ExternalProviderGroupSnapshot -Controller $receiver -Connections $connections -Seen $seen -PreviousTasks $previous -ProfileScopes $scopes
 if(@($group.Tasks|Where-Object {$_.Provider -eq 'kimi' -and -not $_.Active -and -not $_.Paused}).Count -ne 1 -or 'Kimi Code' -notin $group.Unavailable){throw 'A Kimi read failure lost or confirmed the existing task.'}
 $previous=@($group.Tasks)
 if([IO.File]::ReadAllText((Join-Path $managed 'foreign.txt')) -ne 'KEEP'){throw 'A foreign Kimi file was changed.'}
 [IO.File]::Delete((Join-Path $managed 'foreign.txt'))
 $controller.NextScan=[DateTimeOffset]::MinValue
 Wait-Kimi $controller {$controller.LastError -eq '' -and $controller.State -eq 'connected' -and $null -eq $controller.Request}
 $connections.kimi=Get-KimiMonitorConnectionState $controller
 $group=Read-ExternalProviderGroupSnapshot -Controller $receiver -Connections $connections -Seen $seen -PreviousTasks $previous -ProfileScopes $scopes
 $previous=@($group.Tasks)
 $disabled=@{version=1;plugins=@(@{id='other';root='PRIVATE';enabled=$true},@{id='ai-task-monitor';root=$managed;enabled=$false})} | ConvertTo-Json -Depth 5 -Compress
 [IO.File]::WriteAllText($registry,$disabled,[Text.UTF8Encoding]::new($false))
 $controller.NextScan=[DateTimeOffset]::MinValue
 Wait-Kimi $controller {$controller.State -eq 'disabled' -and $null -eq $controller.Request}
 if((Get-KimiMonitorConnectionState $controller) -ne 'disconnected' -or $controller.SeenScope){throw 'A disabled Kimi plugin must be disconnected.'}
 $connections.kimi=Get-KimiMonitorConnectionState $controller
 $group=Read-ExternalProviderGroupSnapshot -Controller $receiver -Connections $connections -Seen $seen -PreviousTasks $previous -ProfileScopes $scopes
 if(@($group.Tasks|Where-Object Provider -eq 'kimi').Count -ne 0 -or $null -eq $receiver.Channel){throw 'Disabling Kimi must remove its tasks while leaving other sources available.'}
 }finally{Stop-ExternalProviderController $receiver}
 'Kimi Windows bridge: isolated discovery, registry, scope and conflict checks passed.'
}finally{
 foreach($name in $old.Keys){[Environment]::SetEnvironmentVariable($name,$old[$name],'Process')}
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
