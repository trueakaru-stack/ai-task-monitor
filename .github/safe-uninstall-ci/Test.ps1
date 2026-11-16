$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Check([bool]$value,[string]$message){if(-not $value){throw $message}}
Check ($env:CI -ceq 'true' -and $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -ceq '0') 'A disposable hosted Windows runner is required.'
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$fixture=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-safe-uninstall-'+[Guid]::NewGuid().ToString('N'))))
Check ($fixture.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase) -and -not [IO.Directory]::Exists($fixture)) 'Unsafe fixture root.'
for($item=[IO.DirectoryInfo]::new($temp);$null -ne $item;$item=$item.Parent){Check ($item.Exists -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Redirected runner temporary directory.'}
[void][IO.Directory]::CreateDirectory($fixture)
$profile=Join-Path $fixture 'profile';$local=Join-Path $profile 'AppData\Local';$roaming=Join-Path $profile 'AppData\Roaming';$tmp=Join-Path $fixture 'temp'
foreach($dir in @($profile,$local,$roaming,$tmp,(Join-Path $roaming 'Microsoft\Windows\Start Menu\Programs'))){[void][IO.Directory]::CreateDirectory($dir)}
$powershell=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
$values=@{SystemRoot=$env:SystemRoot;windir=$env:SystemRoot;PATH=((Split-Path -Parent $powershell)+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot);USERPROFILE=$profile;LOCALAPPDATA=$local;APPDATA=$roaming;TEMP=$tmp;TMP=$tmp;DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0';PSModulePath=((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))}
foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')){
 $value=[Environment]::GetEnvironmentVariable($name);if($value){$values[$name]=$value}
}
function New-Start([string]$file){
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$file;$start.WorkingDirectory=$fixture;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.Environment.Clear();foreach($key in $values.Keys){$start.Environment[$key]=[string]$values[$key]}
 return $start
}
$probe=New-Start $powershell;$probe.RedirectStandardOutput=$true;$probe.RedirectStandardError=$true
$probeCode='[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)'
foreach($arg in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCode)))){[void]$probe.ArgumentList.Add($arg)}
$p=[Diagnostics.Process]::Start($probe)
try{
 $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
 Check ($p.WaitForExit(15000) -and $p.ExitCode -eq 0) 'Known-folder probe failed.'
 Check ([string]::Equals([IO.Path]::GetFullPath($out.Result.Trim()),[IO.Path]::GetFullPath($local),[StringComparison]::OrdinalIgnoreCase)) 'Known-folder probe escaped the synthetic profile.'
}finally{$p.Dispose()}
$install=Join-Path $local 'AITaskMonitor'
Check (-not [IO.Directory]::Exists($install) -and -not [IO.File]::Exists($install)) 'Synthetic installation already exists.'
[void][IO.Directory]::CreateDirectory($install)
$payload=Join-Path $fixture 'payload';[void][IO.Directory]::CreateDirectory($payload)
$inventory=@(Get-Content -LiteralPath (Join-Path $source 'windows/app/Uninstall-Inventory.json') -Raw -Encoding UTF8|ConvertFrom-Json)
$map=@{}
foreach($name in $inventory){
 $name=[string]$name
 $synthetic=Join-Path $payload ($name.Replace('/','\'))
 $parent=Split-Path -Parent $synthetic
 [void][IO.Directory]::CreateDirectory($parent)
 if($name -in @('SafeUninstall.cs','Configure-ClaudeIntegration.ps1')){
  [IO.File]::Copy((Join-Path $source ('windows/app/'+$name)),$synthetic,$false)
 }else{[IO.File]::WriteAllText($synthetic,'synthetic-payload:'+$name)}
 $map[$name]=$synthetic
 if($name -ne 'assets/app-icon.ico'){
  $target=Join-Path $install ($name.Replace('/','\'))
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
  [IO.File]::Copy($synthetic,$target,$false)
 }
}
$outside=Join-Path $fixture 'outside';[void][IO.Directory]::CreateDirectory($outside)
[IO.File]::Copy($map['assets/app-icon.ico'],(Join-Path $outside 'app-icon.ico'),$false)
$link=Join-Path $install 'assets'
$null=New-Item -ItemType Junction -Path $link -Target $outside
Check (((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'The synthetic junction was not created.'
$generated=Join-Path $install 'Uninstall-CodexProgress.ps1'
& (Join-Path $source 'windows/app/Build-UninstallManifest.ps1') -Files $map -TemplatePath (Join-Path $source 'windows/app/Uninstall-CodexProgress.ps1') -OutputPath $generated
$changed=Join-Path $install 'DiagnosticStore.ps1';[IO.File]::WriteAllText($changed,'synthetic-user-change')
$foreign=Join-Path $install 'unrelated.txt';[IO.File]::WriteAllText($foreign,'synthetic-foreign-data')
$claude=Join-Path $profile '.claude';[void][IO.Directory]::CreateDirectory($claude)
$hookPath=Join-Path $install 'ClaudeTaskHook.ps1'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& '"+$hookPath.Replace("'","''")+"'"))
$command='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
$settings=[ordered]@{model='synthetic-preserved';hooks=[ordered]@{Stop=@([ordered]@{hooks=@([ordered]@{type='command';command=$command;timeout=10},[ordered]@{type='command';command='echo synthetic-other'})})}}|ConvertTo-Json -Depth 8 -Compress
$settingsPath=Join-Path $claude 'settings.json'
[void][IO.Directory]::CreateDirectory($settingsPath)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RemovalTestNative {
 [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessage(IntPtr window,uint message,IntPtr wparam,IntPtr lparam);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
}
'@
function Find-Dialog([Diagnostics.Process]$process,[string]$needle){
 $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.Elapsed.TotalSeconds -lt 60){
  if($process.HasExited){throw 'The synthetic uninstaller exited before its dialog.'}
  $windows=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition)
  foreach($window in $windows){
   if($window.Current.Name -cne 'AI task monitor'){continue}
   $items=$window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
   foreach($item in $items){if($item.Current.Name.Contains($needle)){return $window}}
  }
  Start-Sleep -Milliseconds 100
 }
 throw 'The synthetic removal dialog was not found.'
}
function Press-Button($window,[Diagnostics.Process]$process,[string]$name){
 $items=$window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
 $buttons=@($items|Where-Object {$_.Current.Name -ceq $name -and $_.Current.ClassName -ceq 'Button'})
 Check ($buttons.Count -eq 1) 'The synthetic dialog control is not unique.'
 $handle=[IntPtr]$buttons[0].Current.NativeWindowHandle;$owner=[uint32]0
 [void][RemovalTestNative]::GetWindowThreadProcessId($handle,[ref]$owner)
 Check ($handle -ne [IntPtr]::Zero -and $owner -eq $process.Id) 'The synthetic dialog control belongs to another process.'
 Check ([RemovalTestNative]::PostMessage($handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)) 'The synthetic dialog could not be operated.'
}
$start=New-Start $powershell;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($arg in @('-NoProfile','-STA','-NonInteractive','-ExecutionPolicy','Bypass','-File',$generated)){[void]$start.ArgumentList.Add($arg)}
$process=[Diagnostics.Process]::Start($start)
try{
 $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
 $question=Find-Dialog $process 'Disconnect Claude Code'
 Press-Button $question $process 'Yes'
 $blocked=Find-Dialog $process 'Automatic removal stopped.'
 Press-Button $blocked $process 'OK'
 Check ($process.WaitForExit(15000) -and $process.ExitCode -eq 1) 'Ambiguous Claude settings did not stop removal.'
}finally{if(-not $process.HasExited){$process.Kill($true);[void]$process.WaitForExit(5000)};$process.Dispose()}
Check ([IO.File]::Exists((Join-Path $install 'CodexProgress.ps1')) -and [IO.Directory]::Exists($settingsPath)) 'Ambiguous Claude settings changed a synthetic file.'
$resolvedSettings=[IO.Path]::GetFullPath($settingsPath)
Check ([string]::Equals([IO.Directory]::GetParent($resolvedSettings).FullName,[IO.Path]::GetFullPath($claude),[StringComparison]::OrdinalIgnoreCase) -and
      (([IO.File]::GetAttributes($resolvedSettings) -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Unsafe synthetic settings directory.'
[IO.Directory]::Delete($resolvedSettings,$false)
[IO.File]::WriteAllText($settingsPath,$settings,[Text.UTF8Encoding]::new($false))
$start=New-Start $powershell;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($arg in @('-NoProfile','-STA','-NonInteractive','-ExecutionPolicy','Bypass','-File',$generated)){[void]$start.ArgumentList.Add($arg)}
$process=[Diagnostics.Process]::Start($start)
try{
 $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
 $question=Find-Dialog $process 'Disconnect Claude Code'
 Press-Button $question $process 'Yes'
 $result=Find-Dialog $process 'Claude Code disconnection was checked.'
 Press-Button $result $process 'OK'
 Check ($process.WaitForExit(15000) -and $process.ExitCode -eq 0) 'The synthetic uninstaller did not complete.'
}finally{if(-not $process.HasExited){$process.Kill($true);[void]$process.WaitForExit(5000)};$process.Dispose()}
Check (-not [IO.File]::Exists((Join-Path $install 'CodexProgress.ps1'))) 'An unchanged owned file was not removed.'
Check ([IO.File]::ReadAllText($changed) -ceq 'synthetic-user-change') 'A modified file was changed.'
Check ([IO.File]::ReadAllText($foreign) -ceq 'synthetic-foreign-data') 'An unrelated file was changed.'
Check ([IO.File]::Exists((Join-Path $outside 'app-icon.ico'))) 'A file beyond a junction was touched.'
Check ([IO.File]::Exists((Join-Path $install 'integrations/provider-events.mjs'))) 'Unconfirmed provider files were removed.'
Check ([IO.File]::Exists($generated) -and [IO.File]::Exists((Join-Path $install 'Uninstall-CodexProgress.cmd'))) 'The partial-removal tools were not preserved.'
$remaining=[IO.File]::ReadAllText((Join-Path $claude 'settings.json'))|ConvertFrom-Json
Check ($remaining.model -ceq 'synthetic-preserved') 'Unrelated Claude settings were changed.'
$commands=@($remaining.hooks.Stop|ForEach-Object {$_.hooks}|ForEach-Object {$_.command})
Check ($commands -ccontains 'echo synthetic-other' -and $commands -cnotcontains $command) 'Claude hook removal changed another hook or retained its own.'
Write-Output 'Synthetic uninstall: ambiguous Claude settings refused; owned file removed; modified and foreign files, junction target and unconfirmed providers preserved; Claude own hook removed and other hook retained.'
