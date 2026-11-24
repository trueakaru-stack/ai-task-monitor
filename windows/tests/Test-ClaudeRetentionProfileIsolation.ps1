$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-retention-parent-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic parent directory.'
if([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)){throw 'The synthetic parent directory already exists.'}
[void][IO.Directory]::CreateDirectory($root);$child=$null
try{
 $profile=Join-Path $root 'profile';$backup=Join-Path $profile '.claude';$scratch=Join-Path $root 'temp'
 foreach($path in @($backup,$scratch)){[void][IO.Directory]::CreateDirectory($path)}
 $old=Join-Path $backup 'settings.json.codex-tasks-backup-20260901-100000-0000001'
 $new=Join-Path $backup 'settings.json.codex-tasks-backup-20260902-100000-0000002'
 [IO.File]::WriteAllText($old,'synthetic old backup');[IO.File]::WriteAllText($new,'synthetic new backup')
 [IO.File]::SetLastWriteTimeUtc($old,[DateTime]::UtcNow.AddDays(-40));[IO.File]::SetLastWriteTimeUtc($new,[DateTime]::UtcNow.AddDays(-39))
 $beforeOld=(Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash;$beforeNew=(Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $test=Join-Path $PSScriptRoot 'Test-ClaudeRetentionGate.ps1'
 $start.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$test+'"'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.EnvironmentVariables.Clear()
 foreach($name in @('SystemRoot','windir','ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')){
  $value=[Environment]::GetEnvironmentVariable($name,'Process');if($value){$start.EnvironmentVariables[$name]=$value}
 }
 $start.EnvironmentVariables['PATH']=(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot
 $start.EnvironmentVariables['DOTNET_ADD_GLOBAL_TOOLS_TO_PATH']='0'
 $start.EnvironmentVariables['DOTNET_GENERATE_ASPNET_CERTIFICATE']='false';$start.EnvironmentVariables['DOTNET_CLI_TELEMETRY_OPTOUT']='1'
 $start.EnvironmentVariables['USERPROFILE']=$profile;$start.EnvironmentVariables['APPDATA']=$scratch;$start.EnvironmentVariables['LOCALAPPDATA']=$scratch
 $start.EnvironmentVariables['TEMP']=$scratch;$start.EnvironmentVariables['TMP']=$scratch
 $child=[Diagnostics.Process]::Start($start);$output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
 Require ($child.WaitForExit(45000)) 'The directly invoked retention gate test did not finish.'
 if($child.ExitCode -ne 0){throw ('The directly invoked retention gate test failed: '+$errors.GetAwaiter().GetResult())}
 Require ([IO.File]::Exists($old) -and [IO.File]::Exists($new) -and
  (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -ceq $beforeOld -and
  (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash -ceq $beforeNew) 'The directly invoked test touched the inherited synthetic profile.'
 $child.Dispose();$child=$null
 $preloaded=Join-Path $root 'preloaded.ps1'
 $fixture='$ErrorActionPreference=''Stop'''+[Environment]::NewLine+
  'Add-Type -TypeDefinition ''namespace AITaskMonitor.Claude { public static class Retention {} }'''+[Environment]::NewLine+
  '& '''+$test.Replace("'","''")+''''
 [IO.File]::WriteAllText($preloaded,$fixture,[Text.UTF8Encoding]::new($false))
 $start.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+$preloaded+'"'
 $child=[Diagnostics.Process]::Start($start);$output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
 Require ($child.WaitForExit(45000) -and $child.ExitCode -ne 0 -and $errors.GetAwaiter().GetResult().Contains('requires a fresh process')) 'The test accepted a pre-existing retention implementation.'
 Require ([IO.File]::Exists($old) -and [IO.File]::Exists($new) -and
  (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -ceq $beforeOld -and
  (Get-FileHash -LiteralPath $new -Algorithm SHA256).Hash -ceq $beforeNew) 'The rejected preloaded process touched the inherited synthetic profile.'
 Write-Output 'Direct retention gate test: inherited synthetic Claude backups were preserved.'
}finally{
 if($null -ne $child){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)};$child.Dispose()}
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic parent cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
