Set-StrictMode -Version 2.0

# Discover only npm installations with an identifiable executable and manifest.
function Get-KimiRuntimeContext {
 param([Parameter(Mandatory=$true)][string]$AppRoot)
 $node=@(Get-Command -Name 'node.exe' -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique) | Select-Object -First 1
 $commands=@(Get-Command -Name 'kimi.cmd' -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
 $roots=New-Object 'Collections.Generic.List[string]'
 foreach($command in $commands){$roots.Add((Split-Path -Parent $command))}
 if($env:APPDATA){$roots.Add((Join-Path $env:APPDATA 'npm'))}
 $anchor=''
 foreach($root in $roots){
  $candidate=Join-Path $root 'node_modules\@moonshot-ai\kimi-code\package.json'
  if([IO.File]::Exists((Join-Path $root 'kimi.cmd')) -and [IO.File]::Exists($candidate)){$anchor=$candidate;break}
 }
 $kimiHome=if($env:KIMI_CODE_HOME -and $env:KIMI_CODE_HOME.Trim()){
  $configured=$env:KIMI_CODE_HOME.Trim()
  if($configured -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/.?][^\\/]*[\\/][^\\/]+(?:[\\/]|$))'){return $null}
  try{[IO.Path]::GetFullPath($configured)}catch{return $null}
 }elseif($env:USERPROFILE){Join-Path $env:USERPROFILE '.kimi-code'}else{''}
 $integrations=Join-Path $AppRoot 'integrations'
 $assets=Join-Path $integrations 'kimi-plugin'
 $bridge=Join-Path $integrations 'kimi-setup.mjs'
 if(-not $node -or -not $anchor -or -not $kimiHome -or -not [IO.File]::Exists($bridge) -or -not [IO.Directory]::Exists($assets)){return $null}
 return [PSCustomObject]@{Node=[IO.Path]::GetFullPath($node);Home=[IO.Path]::GetFullPath($kimiHome);Assets=[IO.Path]::GetFullPath($assets);Anchor=[IO.Path]::GetFullPath($anchor);Bridge=[IO.Path]::GetFullPath($bridge)}
}

function Start-KimiRuntimeRequest {
 param([Parameter(Mandatory=$true)]$Context)
 $body=@{home=[string]$Context.Home;assets=[string]$Context.Assets;installAnchor=[string]$Context.Anchor} | ConvertTo-Json -Compress
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=[string]$Context.Node;$start.Arguments='"'+[string]$Context.Bridge+'"'
 $start.WorkingDirectory=[string]$Context.Assets
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
 $process=[Diagnostics.Process]::Start($start)
 try{
  $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
  $bytes=[Text.Encoding]::UTF8.GetBytes($body)
  $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$process.StandardInput.Close()
  return [PSCustomObject]@{Process=$process;Output=$output;Errors=$errors;Started=[DateTimeOffset]::UtcNow}
 }catch{$process.Dispose();throw}
}

function Receive-KimiRuntimeRequest {
 param([Parameter(Mandatory=$true)]$Request)
 if(-not $Request.Process.HasExited){
  if(([DateTimeOffset]::UtcNow-$Request.Started).TotalSeconds -lt 30){return $null}
  try{$Request.Process.Kill()}catch{};$Request.Process.Dispose();throw 'Kimi source check timed out.'
 }
 try{
  $output=$Request.Output.GetAwaiter().GetResult();$errors=$Request.Errors.GetAwaiter().GetResult()
  if($output.Length -gt 131072 -or $errors.Length -gt 0){throw 'Kimi source check returned invalid output.'}
  $response=$output | ConvertFrom-Json
  if($null -eq $response -or $response.ok -isnot [bool]){throw 'Kimi source check returned invalid output.'}
  if(-not $response.ok){return [PSCustomObject]@{Ok=$false;Error=[string]$response.error;Result=$null}}
  if($Request.Process.ExitCode -ne 0){throw 'Kimi source check failed.'}
  return [PSCustomObject]@{Ok=$true;Error='';Result=$response.result}
 }finally{$Request.Process.Dispose()}
}

function New-KimiMonitorController {
 param([Parameter(Mandatory=$true)][string]$AppRoot,$FixtureContext=$null)
 return [PSCustomObject]@{AppRoot=$AppRoot;FixtureContext=$FixtureContext;Context=$null;Request=$null;State='disconnected';Scope='';SeenScope='';Scanned=$false;LastError='';NextScan=[DateTimeOffset]::MinValue}
}

function Update-KimiMonitorController {
 param([Parameter(Mandatory=$true)]$Controller,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if($null -ne $Controller.Request){
  try{$reply=Receive-KimiRuntimeRequest $Controller.Request}
  catch{$reply=[PSCustomObject]@{Ok=$false;Error='operation-failed';Result=$null}}
  if($null -ne $reply){
   $Controller.Request=$null
   if($reply.Ok -and $null -ne $reply.Result -and $null -ne $reply.Result.PSObject.Properties['state']){
    $state=[string]$reply.Result.state
    $scope=if($null -ne $reply.Result.PSObject.Properties['scope']){[string]$reply.Result.scope}else{''}
    if($state -notin @('connected','disconnected','disabled') -or ($state -eq 'connected' -and $scope -cnotmatch '^[a-f0-9]{32}$') -or ($state -ne 'connected' -and $scope)){$Controller.LastError='invalid-response'}
    else{
     $Controller.State=$state;$Controller.Scope=$scope;$Controller.Scanned=$true;$Controller.LastError=''
     if($state -eq 'connected'){$Controller.SeenScope=$scope}else{$Controller.SeenScope=''}
    }
   }elseif($reply.Ok){$Controller.LastError='invalid-response'}else{$Controller.LastError=[string]$reply.Error}
   $Controller.NextScan=$Now.AddSeconds(15)
  }
 }
 if($null -eq $Controller.Request -and $Now -ge $Controller.NextScan){
  try{
   $Controller.Context=if($null -ne $Controller.FixtureContext){$Controller.FixtureContext}else{Get-KimiRuntimeContext -AppRoot $Controller.AppRoot}
   if($null -eq $Controller.Context){$Controller.LastError='installation-unconfirmed';$Controller.NextScan=$Now.AddSeconds(15);return}
   $Controller.Request=Start-KimiRuntimeRequest $Controller.Context
  }catch{$Controller.LastError='operation-failed';$Controller.NextScan=$Now.AddSeconds(15)}
 }
}

function Get-KimiMonitorConnectionState {
 param([Parameter(Mandatory=$true)]$Controller)
 if($Controller.LastError){return $(if($Controller.SeenScope){'error'}else{'disconnected'})}
 return $(if($Controller.Scanned -and $Controller.State -eq 'connected'){'connected'}else{'disconnected'})
}

function Get-KimiAllowedScopes {
 param([Parameter(Mandatory=$true)]$Controller)
 if(-not $Controller.LastError -and $Controller.State -eq 'connected' -and $Controller.Scope -cmatch '^[a-f0-9]{32}$'){return @($Controller.Scope)}
 return @()
}

function Get-KimiUncertainScopes {
 param([Parameter(Mandatory=$true)]$Controller)
 if($Controller.LastError -and $Controller.SeenScope -cmatch '^[a-f0-9]{32}$'){return @($Controller.SeenScope)}
 return @()
}
