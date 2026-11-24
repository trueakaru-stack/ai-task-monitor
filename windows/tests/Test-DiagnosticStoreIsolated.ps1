param([ValidateSet('store','worker','queue','restart','clear','timer')][string]$Target='store')
$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-store-profile-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic profile.'}
[void][IO.Directory]::CreateDirectory($root);$child=$null
try{
 $profile=Join-Path $root 'profile';$roaming=Join-Path $root 'roaming';$local=Join-Path $root 'local';$scratch=Join-Path $root 'temp'
 foreach($path in @($profile,$roaming,$local,$scratch)){[void][IO.Directory]::CreateDirectory($path)}
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $test=Join-Path $PSScriptRoot $(switch($Target){'worker'{'Test-DiagnosticWorker.ps1'}'queue'{'Test-DiagnosticClientQueue.ps1'}'restart'{'Test-DiagnosticClientRestart.ps1'}'clear'{'Test-DiagnosticClearBoundary.ps1'}'timer'{'Test-DiagnosticTimer.ps1'}default{'Test-DiagnosticStore.ps1'}})
 $start.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$test+'"'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.EnvironmentVariables.Clear()
 foreach($name in @('SystemRoot','windir','ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')){
  $value=[Environment]::GetEnvironmentVariable($name,'Process');if($value){$start.EnvironmentVariables[$name]=$value}
 }
 $start.EnvironmentVariables['PATH']=(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot
 $start.EnvironmentVariables['DOTNET_ADD_GLOBAL_TOOLS_TO_PATH']='0'
 $start.EnvironmentVariables['DOTNET_GENERATE_ASPNET_CERTIFICATE']='false'
 $start.EnvironmentVariables['DOTNET_CLI_TELEMETRY_OPTOUT']='1'
 $start.EnvironmentVariables['USERPROFILE']=$profile;$start.EnvironmentVariables['APPDATA']=$roaming;$start.EnvironmentVariables['LOCALAPPDATA']=$local
 $start.EnvironmentVariables['TEMP']=$scratch;$start.EnvironmentVariables['TMP']=$scratch;$start.EnvironmentVariables['RUNNER_TEMP']=$scratch
 $child=[Diagnostics.Process]::Start($start)
 $output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
 if(-not $child.WaitForExit(45000)){throw 'The isolated synthetic diagnostic store test timed out.'}
 if($child.ExitCode -ne 0){throw ('The isolated synthetic diagnostic store test failed: '+$errors.GetAwaiter().GetResult())}
 Write-Output ($output.GetAwaiter().GetResult().Trim())
 Write-Output ('The diagnostic '+$Target+' test passed with a synthetic profile and a restricted process environment.')
}finally{
 if($null -ne $child){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)};$child.Dispose()}
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic profile cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
