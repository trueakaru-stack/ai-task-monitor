$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:RUNNER_OS -cne 'Windows' -or $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0'){
 throw 'A disposable hosted Windows runner with the PATH opt-out is required.'
}
function Check([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Read-PathState([string]$scope){
 $key=if($scope -eq 'User'){[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$false)}
      else{[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$false)}
 try{return [pscustomobject]@{Value=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);Kind=[string]$key.GetValueKind('Path')}}
 finally{$key.Dispose()}
}
$beforeUser=Read-PathState 'User'
$beforeMachine=Read-PathState 'Machine'
$beforeProcess=[Environment]::GetEnvironmentVariable('Path','Process')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root=Join-Path $env:RUNNER_TEMP ('aitm-display-'+[guid]::NewGuid().ToString('N'))
try{
 $null=[IO.Directory]::CreateDirectory($root)
 foreach($name in @('profile','appdata','localappdata','temp','nuget','dotnet','fixtures')){
  $null=[IO.Directory]::CreateDirectory((Join-Path $root $name))
 }
 python -B (Join-Path $repository 'windows/tests/Test-DotnetPathSafety.py')
 if($LASTEXITCODE -ne 0){throw 'The exact revision PATH guard failed.'}
 $command=Get-Command dotnet.exe -CommandType Application | Select-Object -First 1
 Check ($null -ne $command) 'A hosted .NET SDK is unavailable.'
 $dotnet=$command.Source
 $sdk=Split-Path -Parent $dotnet
 $config=Join-Path $root 'NuGet.Config'
 [IO.File]::WriteAllText($config,'<configuration><packageSources><clear /></packageSources></configuration>',[Text.UTF8Encoding]::new($false))
 $artifacts=Join-Path $root 'artifacts'
 function Invoke-Isolated([string[]]$arguments){
  $info=[Diagnostics.ProcessStartInfo]::new()
  $info.FileName=$dotnet;$info.WorkingDirectory=$repository;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.Environment.Clear()
  $values=@{
   SystemRoot=$env:SystemRoot;windir=$env:SystemRoot
   PATH=($sdk+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
   DOTNET_ROOT=$sdk;DOTNET_MULTILEVEL_LOOKUP='0';DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
   DOTNET_CLI_HOME=(Join-Path $root 'dotnet');DOTNET_CLI_TELEMETRY_OPTOUT='1'
   DOTNET_GENERATE_ASPNET_CERTIFICATE='0';DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'
   DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER='1'
   NUGET_PACKAGES=(Join-Path $root 'nuget');USERPROFILE=(Join-Path $root 'profile')
   APPDATA=(Join-Path $root 'appdata');LOCALAPPDATA=(Join-Path $root 'localappdata')
   TEMP=(Join-Path $root 'temp');TMP=(Join-Path $root 'temp')
   CI=$env:CI;GITHUB_ACTIONS=$env:GITHUB_ACTIONS;RUNNER_ENVIRONMENT=$env:RUNNER_ENVIRONMENT
   RUNNER_OS=$env:RUNNER_OS;RUNNER_TEMP=$env:RUNNER_TEMP
  }
  foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')){
   $value=[Environment]::GetEnvironmentVariable($name)
   if(-not [string]::IsNullOrEmpty($value)){$values[$name]=$value}
  }
  foreach($key in $values.Keys){$info.Environment[$key]=[string]$values[$key]}
  foreach($argument in $arguments){$null=$info.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($info)
  try{
   $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
   if(-not $process.WaitForExit(180000)){$process.Kill($true);throw 'A hosted test timed out.'}
   if($process.ExitCode -ne 0){throw ('The hosted test failed: '+$stdout.Result+$stderr.Result)}
   Write-Output $stdout.Result.TrimEnd()
  }finally{$process.Dispose()}
 }
 $project=Join-Path $repository 'windows/native/Prototype/Tests/DisplayPreferences/DisplayPreferences.Tests.csproj'
 Invoke-Isolated @('build',$project,'-c','Release','--configfile',$config,'--artifacts-path',$artifacts,'-p:NuGetAudit=false','--nologo')
 $assembly=Join-Path $artifacts 'bin/DisplayPreferences.Tests/release/AITaskMonitor.DisplayPreferences.Tests.dll'
 Check ([IO.File]::Exists($assembly)) 'The preferences test assembly is missing.'
 Invoke-Isolated @($assembly,(Join-Path $root 'fixtures'))
 $prototype=Join-Path $repository 'windows/native/Prototype/Prototype.csproj'
 Invoke-Isolated @('build',$prototype,'-c','Release','--configfile',$config,'--artifacts-path',$artifacts,'-p:NuGetAudit=false','--nologo')
 $hostProject=Join-Path $repository 'windows/native/Tests/DisplayHost/DisplayHost.Tests.csproj'
 Invoke-Isolated @('build',$hostProject,'-c','Release','--configfile',$config,'--artifacts-path',$artifacts,'-p:NuGetAudit=false','--nologo')
 $hostAssembly=Join-Path $artifacts 'bin/DisplayHost.Tests/release/AITaskMonitor.Prototype.Tests.dll'
 Check ([IO.File]::Exists($hostAssembly)) 'The display-host test assembly is missing.'
 Invoke-Isolated @($hostAssembly,$root)
 Check (@(Get-ChildItem -LiteralPath $root -Filter 'settings-*.png' -File).Count -eq 4) 'The four synthetic frames are missing.'
 $viewProject=Join-Path $repository 'windows/native/Prototype/Tests/Prototype.Tests.csproj'
 Invoke-Isolated @('build',$viewProject,'-c','Release','--configfile',$config,'--artifacts-path',$artifacts,'-p:NuGetAudit=false','--nologo')
 $viewAssembly=Join-Path $artifacts 'bin/Prototype.Tests/release/AITaskMonitor.Prototype.Tests.dll'
 Check ([IO.File]::Exists($viewAssembly)) 'The existing WPF test assembly is missing.'
 Invoke-Isolated @($viewAssembly)
}finally{
 foreach($scope in @('User','Machine')){
  $before=if($scope -eq 'User'){$beforeUser}else{$beforeMachine}
  $after=Read-PathState $scope
  if($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind){throw "$scope PATH changed during the hosted test."}
 }
 if([Environment]::GetEnvironmentVariable('Path','Process') -cne $beforeProcess){throw 'Process PATH changed during the hosted test.'}
}
