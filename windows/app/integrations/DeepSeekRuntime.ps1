Set-StrictMode -Version 2.0

# Resolve only installation paths. Profile contents are read by the bridge after
# a user opens settings or the monitor checks an already connected source.
function Get-DeepSeekRuntimeContext {
 param([Parameter(Mandatory=$true)][string]$AppRoot)
 $node = @(Get-Command -Name 'node.exe' -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique) | Select-Object -First 1
 $dshCommands = @(Get-Command -Name 'dsh.cmd' -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
 $pnpmCommands = @(Get-Command -Name 'pnpm.cmd' -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
 $dshCandidates = New-Object 'Collections.Generic.List[string]'
 $pnpmCandidates = New-Object 'Collections.Generic.List[string]'
 foreach($command in $dshCommands){
  $directory = Split-Path -Parent $command
  $dshCandidates.Add((Join-Path $directory 'node_modules\@deepseek-ai\dsh\package.json'))
  $dshCandidates.Add((Join-Path $directory '..\@deepseek-ai\dsh\package.json'))
 }
 foreach($command in $pnpmCommands){
  $directory = Split-Path -Parent $command
  foreach($file in @('pnpm.mjs','pnpm.cjs')){
   $pnpmCandidates.Add((Join-Path $directory ('node_modules\pnpm\bin\'+$file)))
   $pnpmCandidates.Add((Join-Path $directory ('..\pnpm\bin\'+$file)))
  }
 }
 if($env:APPDATA){
  $dshCandidates.Add((Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\package.json'))
  foreach($file in @('pnpm.mjs','pnpm.cjs')){$pnpmCandidates.Add((Join-Path $env:APPDATA ('npm\node_modules\pnpm\bin\'+$file)))}
 }
 $anchor = @($dshCandidates | Where-Object {[IO.File]::Exists($_)} | Select-Object -First 1)
 $pnpm = @($pnpmCandidates | Where-Object {[IO.File]::Exists($_)} | Select-Object -First 1)
 $dshHome = if($env:DSH_HOME -and $env:DSH_HOME.Trim()){
  $configuredHome = $env:DSH_HOME.Trim()
  # IsPathRooted also accepts paths relative to the current drive or directory.
  # Only accept a drive-qualified or complete UNC path, never a device path.
  if($configuredHome -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/.?][^\\/]*[\\/][^\\/]+(?:[\\/]|$))'){return $null}
  try{[IO.Path]::GetFullPath($configuredHome)}catch{return $null}
 }elseif($env:USERPROFILE){Join-Path $env:USERPROFILE '.dsh'}else{''}
 $assets = Join-Path $AppRoot 'integrations'
 $bridge = Join-Path $assets 'deepseek-setup.mjs'
 if(-not $node -or -not $anchor.Count -or -not $pnpm.Count -or -not $dshHome -or -not [IO.File]::Exists($bridge)){return $null}
 return [PSCustomObject]@{Node=[IO.Path]::GetFullPath($node);Home=[IO.Path]::GetFullPath($dshHome);Assets=[IO.Path]::GetFullPath($assets);Anchor=[IO.Path]::GetFullPath($anchor[0]);Pnpm=[IO.Path]::GetFullPath($pnpm[0]);Bridge=[IO.Path]::GetFullPath($bridge)}
}

function Start-DeepSeekRuntimeRequest {
 param([Parameter(Mandatory=$true)]$Context,[ValidateSet('list','connect','disconnect')][string]$Action,[string]$Profile='')
 if($Action -ne 'list' -and -not $Profile){throw 'A DeepSeek profile is required.'}
 $request = @{action=$Action;home=[string]$Context.Home}
 $request.installAnchor=[string]$Context.Anchor;$request.pnpmScript=[string]$Context.Pnpm
 if($Action -ne 'list'){
  $request.profile=$Profile;$request.assets=[string]$Context.Assets
 }
 $body = $request | ConvertTo-Json -Compress
 $start = [Diagnostics.ProcessStartInfo]::new()
 $start.FileName=[string]$Context.Node
 $start.Arguments='"'+[string]$Context.Bridge+'"'
 $start.WorkingDirectory=[string]$Context.Assets
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
 $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
 $process=[Diagnostics.Process]::Start($start)
 try{
  $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
  $bytes=[Text.Encoding]::UTF8.GetBytes($body)
  $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
  $process.StandardInput.Close()
  return [PSCustomObject]@{Process=$process;Output=$output;Errors=$errors;Action=$Action;Profile=$Profile;Started=[DateTimeOffset]::UtcNow}
 }catch{
  $process.Dispose()
  throw
 }
}

function Receive-DeepSeekRuntimeRequest {
 param([Parameter(Mandatory=$true)]$Request)
 if(-not $Request.Process.HasExited){return $null}
 try{
  $output=$Request.Output.GetAwaiter().GetResult()
  $errorText=$Request.Errors.GetAwaiter().GetResult()
  if($output.Length -gt 131072 -or $errorText.Length -gt 0){throw 'DeepSeek setup returned invalid output.'}
  $response=$output | ConvertFrom-Json
  if($null -eq $response -or $response.ok -isnot [bool]){throw 'DeepSeek setup returned invalid output.'}
  if(-not $response.ok){return [PSCustomObject]@{Ok=$false;Error=[string]$response.error;Action=$Request.Action;Profile=$Request.Profile;Result=$null}}
  if($Request.Process.ExitCode -ne 0){throw 'DeepSeek setup failed.'}
  return [PSCustomObject]@{Ok=$true;Error='';Action=$Request.Action;Profile=$Request.Profile;Result=$response.result}
 }finally{$Request.Process.Dispose()}
}

function New-DeepSeekMonitorController {
 param([Parameter(Mandatory=$true)][string]$AppRoot,$FixtureContext=$null)
 return [PSCustomObject]@{AppRoot=$AppRoot;FixtureContext=$FixtureContext;Context=$null;Request=$null;Profiles=@();Seen=[Collections.Hashtable]::new([StringComparer]::Ordinal);Scanned=$false;LastError='';ActionError='';NextScan=[DateTimeOffset]::MinValue}
}

function Update-DeepSeekMonitorController {
 param([Parameter(Mandatory=$true)]$Controller,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if($null -ne $Controller.Request){
  try{$reply=Receive-DeepSeekRuntimeRequest $Controller.Request}
  catch{$reply=[PSCustomObject]@{Ok=$false;Error='operation-failed';Action=$Controller.Request.Action;Profile=$Controller.Request.Profile;Result=$null}}
  if($null -ne $reply){
   $Controller.Request=$null
   if($reply.Action -eq 'list'){
    if($reply.Ok){
     $valid=$true;$profiles=New-Object 'Collections.Generic.List[object]'
     foreach($item in @($reply.Result)){
      if($null -eq $item -or [string]$item.name -eq '' -or [string]$item.state -notin @('connected','disconnected','partial','error')){$valid=$false;break}
      $scope=if($null -ne $item.PSObject.Properties['scope']){[string]$item.scope}else{''}
      $profileError=if($null -ne $item.PSObject.Properties['error']){[string]$item.error}else{''}
      if($item.state -eq 'connected' -and $scope -cnotmatch '^[a-f0-9]{32}$'){$valid=$false;break}
      $profiles.Add([PSCustomObject]@{Name=[string]$item.name;State=[string]$item.state;Scope=$scope;Error=$profileError})
     }
     if($valid){
      $Controller.Profiles=$profiles.ToArray();$Controller.Scanned=$true;$Controller.LastError=''
      foreach($item in $Controller.Profiles){
       if($item.State -eq 'connected'){$Controller.Seen[$item.Name]=$item.Scope}
       elseif($item.State -eq 'disconnected'){[void]$Controller.Seen.Remove($item.Name)}
      }
     }else{$Controller.LastError='invalid-response'}
    }else{$Controller.LastError=[string]$reply.Error}
    $Controller.NextScan=$Now.AddSeconds(15)
   }else{
    if($reply.Ok){
     $Controller.ActionError=''
     if($reply.Action -eq 'disconnect'){[void]$Controller.Seen.Remove([string]$reply.Profile)}
    }else{$Controller.ActionError=[string]$reply.Error}
    $Controller.NextScan=[DateTimeOffset]::MinValue
   }
  }
 }
 if($null -eq $Controller.Request -and $Now -ge $Controller.NextScan){
  try{
   $Controller.Context=if($null -ne $Controller.FixtureContext){$Controller.FixtureContext}else{Get-DeepSeekRuntimeContext -AppRoot $Controller.AppRoot}
   if($null -eq $Controller.Context){$Controller.LastError='installation-unconfirmed';$Controller.NextScan=$Now.AddSeconds(15);return}
   $Controller.Request=Start-DeepSeekRuntimeRequest -Context $Controller.Context -Action 'list'
  }catch{$Controller.LastError='operation-failed';$Controller.NextScan=$Now.AddSeconds(15)}
 }
}

function Request-DeepSeekProfileConnection {
 param([Parameter(Mandatory=$true)]$Controller,[Parameter(Mandatory=$true)][string]$Profile,[bool]$Connect)
 if($null -ne $Controller.Request -or $null -eq $Controller.Context){throw 'DeepSeek setup is busy or unavailable.'}
 $matches=@($Controller.Profiles | Where-Object {$_.Name -ceq $Profile})
 if($matches.Count -ne 1){throw 'Select an existing DeepSeek profile.'}
 $Controller.ActionError=''
 $action=if($Connect){'connect'}else{'disconnect'}
 $Controller.Request=Start-DeepSeekRuntimeRequest -Context $Controller.Context -Action $action -Profile $Profile
}

function Get-DeepSeekMonitorConnectionState {
 param([Parameter(Mandatory=$true)]$Controller)
 if($Controller.LastError){return $(if($Controller.Seen.Count -gt 0){'error'}else{'disconnected'})}
 $connected=@($Controller.Profiles | Where-Object {$_.State -eq 'connected'})
 $uncertain=$false
 foreach($name in @($Controller.Seen.Keys)){
  $match=@($Controller.Profiles | Where-Object {$_.Name -ceq $name})
  if($match.Count -ne 1 -or $match[0].State -in @('partial','error')){$uncertain=$true}
 }
 if($connected.Count -gt 0){return $(if($uncertain){'connected-degraded'}else{'connected'})}
 if($uncertain){return 'partial'}
 return 'disconnected'
}

function Get-DeepSeekAllowedScopes {
 param([Parameter(Mandatory=$true)]$Controller)
 if($Controller.LastError){return @()}
 return @($Controller.Profiles | Where-Object {$_.State -eq 'connected' -and $_.Scope -cmatch '^[a-f0-9]{32}$'} | ForEach-Object {$_.Scope} | Select-Object -Unique)
}

function Get-DeepSeekUncertainScopes {
 param([Parameter(Mandatory=$true)]$Controller)
 $result=New-Object 'Collections.Generic.List[string]'
 foreach($name in @($Controller.Seen.Keys)){
  $scope=[string]$Controller.Seen[$name]
  if($scope -cnotmatch '^[a-f0-9]{32}$'){continue}
  $match=@($Controller.Profiles | Where-Object {$_.Name -ceq $name})
  if($Controller.LastError -or $match.Count -ne 1 -or $match[0].State -in @('partial','error')){$result.Add($scope)}
 }
 return $result.ToArray()
}
