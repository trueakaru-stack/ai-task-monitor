Set-StrictMode -Version 2.0

function Test-HermesRuntimePlainPath {
 param([Parameter(Mandatory=$true)][string]$Path)
 try{
  $current=[IO.Path]::GetFullPath($Path)
  while($current){
   if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $false}
   $next=[IO.Path]::GetDirectoryName($current.TrimEnd('\'))
   if(-not $next -or $next -eq $current){break}
   $current=$next
  }
  return $true
 }catch{return $false}
}

# Resolve only a source installation whose committed Python environment is
# explicitly recorded by Hermes, or its legacy in-tree virtual environment.
# Discovery does not launch Hermes or read profile contents.
function Get-HermesRuntimeContext {
 param([Parameter(Mandatory=$true)][string]$AppRoot)
 try {
  if(-not $env:LOCALAPPDATA -or -not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)){return $null}
  $native=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'hermes'))
  $requested=if($env:HERMES_HOME -and $env:HERMES_HOME.Trim()){$env:HERMES_HOME.Trim()}else{$native}
  if($requested -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/.?][^\\/]*[\\/][^\\/]+(?:[\\/]|$))'){return $null}
  $requested=[IO.Path]::GetFullPath($requested)
  if($requested.Equals($native,[StringComparison]::OrdinalIgnoreCase)){$hermesRoot=$native}
  elseif((Split-Path -Leaf (Split-Path -Parent $requested)) -ceq 'profiles'){$hermesRoot=Split-Path -Parent (Split-Path -Parent $requested)}
  else{$hermesRoot=$requested}
  $project=Join-Path $hermesRoot 'hermes-agent'
  if(-not [IO.File]::Exists((Join-Path $hermesRoot 'config.yaml')) -or -not [IO.Directory]::Exists($project) -or
     -not (Test-HermesRuntimePlainPath $hermesRoot) -or -not (Test-HermesRuntimePlainPath $project) -or
     -not (Test-HermesRuntimePlainPath (Join-Path $hermesRoot 'config.yaml'))){return $null}
  $project=(Resolve-Path -LiteralPath $project -ErrorAction Stop).Path
  if(-not [IO.File]::Exists((Join-Path $project 'hermes_cli\active_sessions.py')) -or
     -not [IO.File]::Exists((Join-Path $project 'pm\publication.py')) -or
     -not (Test-HermesRuntimePlainPath (Join-Path $project 'hermes_cli\active_sessions.py')) -or
     -not (Test-HermesRuntimePlainPath (Join-Path $project 'pm\publication.py'))){return $null}
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$bytes=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($project))}finally{$sha.Dispose()}
  $key=(-join ($bytes | ForEach-Object {$_.ToString('x2')})).Substring(0,16)
  $install=Join-Path (Join-Path $hermesRoot 'installs') $key
  $facts=Join-Path $install 'facts.json'
  $environment=''
  $info=try{Get-Item -LiteralPath $facts -Force -ErrorAction Stop}catch [System.Management.Automation.ItemNotFoundException]{$null}catch{return $null}
  if($null -ne $info){
   if($info.PSIsContainer -or $info.Length -gt 1048576 -or -not (Test-HermesRuntimePlainPath $facts)){return $null}
   $document=[IO.File]::ReadAllText($facts,[Text.Encoding]::UTF8) | ConvertFrom-Json
   if($null -eq $document -or $null -eq $document.PSObject.Properties['packages'] -or
      $null -eq $document.packages -or $null -eq $document.packages.PSObject.Properties['venv'] -or
      $null -eq $document.packages.venv -or $null -eq $document.packages.venv.PSObject.Properties['environment']){return $null}
   $value=$document.packages.venv.environment
   if($value -isnot [string] -or $value -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/.?][^\\/]*[\\/][^\\/]+(?:[\\/]|$))'){return $null}
   $generationRoot=Join-Path $install 'environments'
   if(-not [IO.Directory]::Exists($generationRoot) -or -not [IO.Directory]::Exists($value) -or
      -not (Test-HermesRuntimePlainPath $generationRoot) -or -not (Test-HermesRuntimePlainPath $value)){return $null}
   $generationRoot=(Resolve-Path -LiteralPath $generationRoot -ErrorAction Stop).Path.TrimEnd('\')+'\'
   $environment=(Resolve-Path -LiteralPath $value -ErrorAction Stop).Path
   if(-not $environment.StartsWith($generationRoot,[StringComparison]::OrdinalIgnoreCase)){return $null}
  }else{
   foreach($name in @('venv','.venv')){
    $candidate=Join-Path $project $name
    if([IO.Directory]::Exists($candidate)){$environment=$candidate;break}
   }
  }
  if(-not $environment -or -not [IO.File]::Exists((Join-Path $environment 'pyvenv.cfg')) -or
     -not (Test-HermesRuntimePlainPath $environment) -or -not (Test-HermesRuntimePlainPath (Join-Path $environment 'pyvenv.cfg'))){return $null}
  $python=Join-Path $environment 'Scripts\python.exe'
  if(-not [IO.File]::Exists($python) -or -not (Test-HermesRuntimePlainPath $python)){return $null}
  $assets=Join-Path $AppRoot 'integrations'
  if(-not [IO.File]::Exists((Join-Path $assets 'hermes-setup.py')) -or
     -not [IO.File]::Exists((Join-Path $assets 'hermes-manager.py')) -or
     -not [IO.File]::Exists((Join-Path $assets 'HermesBridgeProcess.cs')) -or
     -not [IO.File]::Exists((Join-Path $assets 'provider_bundle.py'))){return $null}
  $backend=[Environment]::GetEnvironmentVariable('HERMES_CONFIG_BACKEND','Process')
  $managed=(-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('HERMES_MANAGED_DIR','Process'))) -or
   (-not [string]::IsNullOrWhiteSpace($backend) -and $backend.Trim().ToLowerInvariant() -cne 'file')
  return [PSCustomObject]@{Home=$hermesRoot;Project=$project;Python=$python;Assets=[IO.Path]::GetFullPath($assets);Bridge=(Join-Path $assets 'hermes-setup.py');Managed=$managed}
 }catch{return $null}
}

function Start-HermesRuntimeRequest {
 param([Parameter(Mandatory=$true)]$Context,[ValidateSet('list','prepare')][string]$Action,[string]$Profile='')
 if($Action -eq 'prepare' -and -not $Profile){throw 'A Hermes profile is required.'}
 $request=@{action=$Action;home=[string]$Context.Home;project=[string]$Context.Project;assets=[string]$Context.Assets}
 $request.managed=if($null -ne $Context.PSObject.Properties['Managed']){[bool]$Context.Managed}else{$false}
 if($Action -eq 'prepare'){$request.profile=$Profile}
 $body=$request | ConvertTo-Json -Compress
 if(-not ('AITaskMonitor.Hermes.Command' -as [type])){Add-Type -Path (Join-Path $Context.Assets 'HermesBridgeProcess.cs') -ErrorAction Stop}
 $command=[AITaskMonitor.Hermes.Command]::new([string]$Context.Python,[string]$Context.Bridge,[string]$Context.Assets,[string]$body,30000)
 return [PSCustomObject]@{Command=$command;Action=$Action;Profile=$Profile}
}

function Receive-HermesRuntimeRequest {
 param([Parameter(Mandatory=$true)]$Request)
 if(-not $Request.Command.Completed){return $null}
 try{
  $result=$Request.Command.GetResult()
  if($null -eq $result -or -not $result.Ok){throw 'Hermes preparation failed.'}
  $response=$result.Json | ConvertFrom-Json -ErrorAction Stop
  if($null -eq $response -or $null -eq $response.PSObject.Properties['ok'] -or $response.ok -isnot [bool]){throw 'Invalid Hermes response.'}
  if(-not $response.ok){
   $code=if($null -ne $response.PSObject.Properties['error']){[string]$response.error}else{'operation-failed'}
   return [PSCustomObject]@{Ok=$false;Error=$code;Action=$Request.Action;Profile=$Request.Profile;Result=$null}
  }
  if($null -eq $response.PSObject.Properties['result']){throw 'Invalid Hermes response.'}
  return [PSCustomObject]@{Ok=$true;Error='';Action=$Request.Action;Profile=$Request.Profile;Result=$response.result}
 }finally{$Request.Command.Dispose()}
}

function New-HermesMonitorController {
 param([Parameter(Mandatory=$true)][string]$AppRoot,$FixtureContext=$null)
 return [PSCustomObject]@{AppRoot=$AppRoot;FixtureContext=$FixtureContext;Context=$null;Request=$null;Profiles=@();Seen=[Collections.Hashtable]::new([StringComparer]::Ordinal);Scanned=$false;LastError='';ActionError='';NextScan=[DateTimeOffset]::MinValue}
}

function Update-HermesMonitorController {
 param([Parameter(Mandatory=$true)]$Controller,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if($null -ne $Controller.Request){
  try{$reply=Receive-HermesRuntimeRequest $Controller.Request}
  catch{$reply=[PSCustomObject]@{Ok=$false;Error='operation-failed';Action=$Controller.Request.Action;Profile=$Controller.Request.Profile;Result=$null}}
  if($null -ne $reply){
   $Controller.Request=$null
   if($reply.Action -eq 'list'){
    if($reply.Ok -and $reply.Result -is [array] -and $reply.Result.Count -le 256){
     $valid=$true;$profiles=New-Object 'Collections.Generic.List[object]';$ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$scopes=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
     foreach($item in $reply.Result){
      if($null -eq $item -or $null -eq $item.PSObject.Properties['id'] -or $null -eq $item.PSObject.Properties['name'] -or $null -eq $item.PSObject.Properties['state']){$valid=$false;break}
      $id=[string]$item.id;$name=[string]$item.name;$state=[string]$item.state
      $scope=if($null -ne $item.PSObject.Properties['scope']){[string]$item.scope}else{''}
      $hasEnabled=$null -ne $item.PSObject.Properties['enabled']
      $enabled=if($hasEnabled -and $item.enabled -is [bool]){[bool]$item.enabled}else{$null}
      $errorCode=if($null -ne $item.PSObject.Properties['error']){[string]$item.error}else{''}
      if(($id -ceq 'root' -and $name -cne 'default') -or ($id -cne 'root' -and ($name -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$' -or $name -cin @('hermes','default','test','tmp','root','sudo') -or $id -cne ('profile:'+$name))) -or
         -not $ids.Add($id) -or $state -notin @('absent','prepared','error') -or
         ($state -eq 'prepared' -and ($enabled -isnot [bool] -or $scope -cnotmatch '^[a-f0-9]{32}$' -or -not $scopes.Add($scope))) -or
         ($state -ne 'prepared' -and ($scope -or $hasEnabled))){$valid=$false;break}
      $profiles.Add([PSCustomObject]@{Id=$id;Name=$name;State=$state;Scope=$scope;Enabled=$enabled;Error=$errorCode})
     }
     if($valid -and $ids.Contains('root')){
      $Controller.Profiles=$profiles.ToArray();$Controller.Scanned=$true;$Controller.LastError=''
      foreach($item in $Controller.Profiles){
       if($item.State -eq 'prepared' -and $item.Enabled){$Controller.Seen[$item.Id]=$item.Scope}
       elseif($item.State -eq 'absent' -or ($item.State -eq 'prepared' -and -not $item.Enabled)){[void]$Controller.Seen.Remove($item.Id)}
      }
     }else{$Controller.LastError='invalid-response'}
    }elseif($reply.Ok){$Controller.LastError='invalid-response'}else{$Controller.LastError=[string]$reply.Error}
    $Controller.NextScan=$Now.AddSeconds(15)
   }else{
    if($reply.Ok -and [string]$reply.Result -ceq 'prepared'){$Controller.ActionError=''}
    else{$Controller.ActionError=if($reply.Ok){'invalid-response'}else{[string]$reply.Error}}
    $Controller.NextScan=[DateTimeOffset]::MinValue
   }
  }
 }
 if($null -eq $Controller.Request -and $Now -ge $Controller.NextScan){
  try{
   $Controller.Context=if($null -ne $Controller.FixtureContext){$Controller.FixtureContext}else{Get-HermesRuntimeContext -AppRoot $Controller.AppRoot}
   if($null -eq $Controller.Context){$Controller.LastError='installation-unconfirmed';$Controller.NextScan=$Now.AddSeconds(15);return}
   $Controller.Request=Start-HermesRuntimeRequest -Context $Controller.Context -Action 'list'
  }catch{$Controller.LastError='operation-failed';$Controller.NextScan=$Now.AddSeconds(15)}
 }
}

function Request-HermesProfilePrepare {
 param([Parameter(Mandatory=$true)]$Controller,[Parameter(Mandatory=$true)][string]$Profile)
 if($null -ne $Controller.Request -or $null -eq $Controller.Context -or $Controller.LastError){throw 'Hermes preparation is busy or unavailable.'}
 $matches=@($Controller.Profiles | Where-Object {$_.Id -ceq $Profile -and $_.State -ceq 'absent'})
 if($matches.Count -ne 1){throw 'Select an available Hermes profile.'}
 $Controller.ActionError=''
 $Controller.Request=Start-HermesRuntimeRequest -Context $Controller.Context -Action 'prepare' -Profile $Profile
}

function Get-HermesMonitorConnectionState {
 param([Parameter(Mandatory=$true)]$Controller)
 if($Controller.LastError){return $(if($Controller.Seen.Count -gt 0){'error'}else{'disconnected'})}
 $prepared=@($Controller.Profiles | Where-Object {$_.State -eq 'prepared' -and $_.Enabled})
 $uncertain=@(Get-HermesUncertainScopes $Controller)
 if($prepared.Count -gt 0){return $(if($uncertain.Count -gt 0){'connected-degraded'}else{'connected'})}
 return $(if($uncertain.Count -gt 0){'partial'}else{'disconnected'})
}

function Get-HermesAllowedScopes {
 param([Parameter(Mandatory=$true)]$Controller)
 if($Controller.LastError){return @()}
 return @($Controller.Profiles | Where-Object {$_.State -eq 'prepared' -and $_.Enabled -and $_.Scope -cmatch '^[a-f0-9]{32}$'} | ForEach-Object {$_.Scope} | Select-Object -Unique)
}

function Get-HermesUncertainScopes {
 param([Parameter(Mandatory=$true)]$Controller)
 $result=New-Object 'Collections.Generic.List[string]'
 foreach($id in @($Controller.Seen.Keys)){
  $scope=[string]$Controller.Seen[$id]
  if($scope -cnotmatch '^[a-f0-9]{32}$'){continue}
  $match=@($Controller.Profiles | Where-Object {$_.Id -ceq $id})
  if($Controller.LastError -or $match.Count -ne 1 -or $match[0].State -eq 'error'){$result.Add($scope)}
 }
 return $result.ToArray()
}

function Stop-HermesMonitorController {
 param([Parameter(Mandatory=$true)]$Controller)
 if($null -eq $Controller.Request){return}
 try{$Controller.Request.Command.Cancel();$Controller.Request.Command.Dispose()}catch{}
 $Controller.Request=$null
}
