param([string]$Installer,[string]$FixtureRoot,[hashtable]$ProcessValues,[string]$SystemPowerShell)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Check([bool]$value,[string]$message){if(-not $value){throw $message}}
function Within([string]$path,[string]$parent){
    $p=[IO.Path]::GetFullPath($path).TrimEnd('\')
    $base=[IO.Path]::GetFullPath($parent).TrimEnd('\')
    return [string]::Equals($p,$base,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)
}
function New-IsolatedStart([string]$file,[hashtable]$values){
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$file;$start.WorkingDirectory=$FixtureRoot;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.Environment.Clear()
    foreach($key in $values.Keys){$start.Environment[$key]=[string]$values[$key]}
    return $start
}
function Find-Window([Diagnostics.Process]$process,[int]$seconds){
    $idCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
    $nameCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'AI task monitor')
    $condition=[Windows.Automation.AndCondition]::new($idCondition,$nameCondition)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt $seconds){
        if($process.HasExited){throw 'The synthetic process exited before its window appeared.'}
        $found=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,$condition)
        if($null -ne $found -and $found.Current.Name -ceq 'AI task monitor'){return $found}
        Start-Sleep -Milliseconds 100
    }
    $process.Refresh()
    $idCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
    $otherWindows=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$idCondition)
    $details=@(foreach($item in $otherWindows){$item.Current.ClassName+':'+$item.Current.Name})
    $children=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId = '+$process.Id) -Property Name|ForEach-Object {$_.Name})
    Write-Output ('Window diagnostic: alive='+(-not $process.HasExited)+'; UIA windows='+($details -join ' | ')+'; child process names='+($children -join ','))
    throw 'The synthetic process window was not found in time.'
}
function Get-Names($window){
    $children=$window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    return @(foreach($item in $children){$item.Current.Name})
}
function Dismiss-Dialog($window,[Diagnostics.Process]$process){
    $all=$window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    $buttons=@($all|Where-Object {$_.Current.Name -ceq 'OK' -and $_.Current.ClassName -ceq 'Button'})
    Check ($buttons.Count -eq 1) 'The synthetic setup dialog has no unique OK control.'
    $handle=[IntPtr]$buttons[0].Current.NativeWindowHandle;$owner=[uint32]0
    [void][FallbackTestNative]::GetWindowThreadProcessId($handle,[ref]$owner)
    Check ($handle -ne [IntPtr]::Zero -and $owner -eq $process.Id) 'The synthetic setup control belongs to another process.'
    Check ([FallbackTestNative]::PostMessage($handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)) 'Cannot dismiss the synthetic setup dialog.'
}
Check ($env:CI -ceq 'true' -and $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -ceq '0') 'Requires disposable hosted Windows.'
$runnerProfile=[IO.Path]::GetFullPath($env:USERPROFILE)
Check ([string]::Equals($runnerProfile,[IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)),[StringComparison]::OrdinalIgnoreCase)) 'The disposable runner profile identity is inconsistent.'
$values=@{}
foreach($key in $ProcessValues.Keys){$values[$key]=$ProcessValues[$key]}
$profile=Join-Path $FixtureRoot 'full-profile';$local=Join-Path $profile 'AppData\Local';$roaming=Join-Path $profile 'AppData\Roaming';$tmp=Join-Path $FixtureRoot 'full-temp'
foreach($dir in @($profile,$local,$roaming,$tmp)){[void][IO.Directory]::CreateDirectory($dir)}
[void][IO.Directory]::CreateDirectory((Join-Path $roaming 'Microsoft\Windows\Start Menu\Programs'))
$values.USERPROFILE=$profile;$values.LOCALAPPDATA=$local;$values.APPDATA=$roaming;$values.TEMP=$tmp;$values.TMP=$tmp
$values.DOTNET_CLI_HOME=$tmp;$values.NUGET_PACKAGES=Join-Path $tmp 'nuget'
$probeCode='foreach($name in @("UserProfile","LocalApplicationData","Programs")){$item=[Enum]::Parse([Environment+SpecialFolder],$name);$path=[Environment]::GetFolderPath($item);if($path){$path}else{"<empty>"}}'
$probe=New-IsolatedStart $SystemPowerShell $values
$probe.RedirectStandardOutput=$true;$probe.RedirectStandardError=$true
foreach($arg in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCode)))){[void]$probe.ArgumentList.Add($arg)}
$process=[Diagnostics.Process]::Start($probe)
try{
    $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
    Check ($process.WaitForExit(15000) -and $process.ExitCode -eq 0) 'The known-folder probe failed.'
    $paths=@($out.Result -split "\r?\n"|Where-Object {$_})
}finally{$process.Dispose()}
if($paths.Count -ne 3 -or @($paths|Where-Object {$_ -ceq '<empty>'}).Count -gt 0){
    $empty=@()
    for($i=0;$i -lt $paths.Count;$i++){if($paths[$i] -ceq '<empty>'){$empty+=@('UserProfile','LocalApplicationData','Programs')[$i]}}
    Write-Output ('Known-folder probe returned '+$paths.Count+' entries; empty fields: '+($empty -join ','))
    throw 'The known-folder probe did not return three populated paths.'
}
$knownProfile=[IO.Path]::GetFullPath($paths[0]);$knownLocal=[IO.Path]::GetFullPath($paths[1]);$knownPrograms=[IO.Path]::GetFullPath($paths[2])
foreach($path in @($knownProfile,$knownLocal,$knownPrograms)){
    Check ((Within $path $runnerProfile) -or (Within $path $FixtureRoot)) 'A known folder escaped the disposable runner profile and synthetic fixture.'
}
Check ([IO.Directory]::Exists($knownLocal) -and [IO.Directory]::Exists($knownPrograms)) 'The disposable known folders are unavailable.'
Check (-not [IO.Directory]::Exists((Join-Path $knownProfile '.claude')) -and -not [IO.Directory]::Exists((Join-Path $knownProfile '.codex'))) 'The disposable runner profile unexpectedly contains real-looking agent sources.'
$install=[IO.Path]::GetFullPath((Join-Path $knownLocal 'AITaskMonitor'))
$oldShortcut=[IO.Path]::GetFullPath((Join-Path $knownPrograms 'AI task monitor.lnk'))
$shortcut=[IO.Path]::GetFullPath((Join-Path $knownPrograms 'AI task monitor (new).lnk'))
Check (-not [IO.Directory]::Exists($install) -and -not [IO.File]::Exists($install) -and
    -not [IO.File]::Exists($oldShortcut) -and -not [IO.Directory]::Exists($oldShortcut) -and
    -not [IO.File]::Exists($shortcut) -and -not [IO.Directory]::Exists($shortcut)) 'The synthetic setup target already exists.'
$seedShortcut=Join-Path $FixtureRoot 'install-engine\programs\AI task monitor.lnk'
Check ([IO.File]::Exists($seedShortcut)) 'The old CMD shortcut fixture is missing.'
[IO.File]::Copy($seedShortcut,$oldShortcut,$false)
$oldShortcutHash=(Get-FileHash -LiteralPath $oldShortcut -Algorithm SHA256).Hash
$oldData=Join-Path $local 'CodexTaskProgress'
[void][IO.Directory]::CreateDirectory($oldData)
$oldSentinel=Join-Path $oldData 'user-note.txt';[IO.File]::WriteAllText($oldSentinel,'synthetic user data')
$setup=$null;$monitor=$null
try{
    $start=New-IsolatedStart $Installer $values
    $setup=[Diagnostics.Process]::Start($start)
    $setupTime=$setup.StartTime.ToUniversalTime()
    $dialog=Find-Window $setup 30
    Write-Output 'Synthetic setup dialog found.'
    $names=Get-Names $dialog
    Check (@($names|Where-Object {$_.Contains('AI task monitor установлен.') -and $_.Contains('AI task monitor (new)')}).Count -gt 0) 'The installer did not report a completed installation with the alternative shortcut.'
    $launcher=Join-Path $install 'AI task monitor.exe';$appScript=Join-Path $install 'CodexProgress.ps1'
    Check ([IO.File]::Exists($launcher) -and [IO.File]::Exists($appScript) -and [IO.File]::Exists($shortcut) -and (Get-FileHash -LiteralPath $oldShortcut -Algorithm SHA256).Hash -ceq $oldShortcutHash) 'The full installer did not create the application and alternative shortcut while preserving the old one.'
    $clock=[Diagnostics.Stopwatch]::StartNew();$candidate=$null
    while($null -eq $candidate -and $clock.Elapsed.TotalSeconds -lt 30){
        $matches=@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -Property ProcessId,CreationDate,ExecutablePath,CommandLine |
            Where-Object {$_.CommandLine -and $_.CommandLine.Contains($appScript) -and ([DateTime]$_.CreationDate).ToUniversalTime() -ge $setupTime.AddSeconds(-1)})
        Check ($matches.Count -le 1) 'More than one synthetic monitor process matched.'
        if($matches.Count -eq 1){$candidate=$matches[0];break}
        Start-Sleep -Milliseconds 100
    }
    Check ($null -ne $candidate) 'The installer did not launch the synthetic monitor.'
    Write-Output 'Synthetic monitor process found.'
    $monitor=[Diagnostics.Process]::GetProcessById([int]$candidate.ProcessId)
    $observedTime=([DateTime]$candidate.CreationDate).ToUniversalTime()
    Check ((($monitor.StartTime.ToUniversalTime()-$observedTime).Duration().TotalSeconds -le 1) -and [string]::Equals($monitor.MainModule.FileName,$SystemPowerShell,[StringComparison]::OrdinalIgnoreCase)) 'The opened monitor process identity did not match.'
    Dismiss-Dialog $dialog $setup
    Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 0) 'The synthetic setup did not finish successfully.'
    $setup.Dispose();$setup=$null
    Write-Output 'Synthetic setup completed; waiting for monitor window.'
    $monitorWindow=Find-Window $monitor 40
    Write-Output 'Synthetic monitor window found.'
    Check ($monitorWindow.Current.Name -ceq 'AI task monitor') 'The synthetic monitor window did not open.'
    $monitor.Kill();Check ($monitor.WaitForExit(10000)) 'The synthetic monitor did not exit.'
    $monitor.Dispose();$monitor=$null
    Check ([IO.File]::ReadAllText($oldSentinel) -ceq 'synthetic user data') 'The synthetic existing data was changed.'
    $foreign=Join-Path $install 'foreign.txt';[IO.File]::WriteAllText($foreign,'synthetic unrelated file')
    $launcherHash=(Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
    $shortcutHash=(Get-FileHash -LiteralPath $shortcut -Algorithm SHA256).Hash
    $start=New-IsolatedStart $Installer $values
    $setup=[Diagnostics.Process]::Start($start)
    $dialog=Find-Window $setup 30
    $names=Get-Names $dialog
    Check (@($names|Where-Object {$_.Contains('Папка установки уже существует.') -or $_.Contains('The installation folder already exists.')}).Count -gt 0) 'The installer did not explain why the existing folder is preserved.'
    Dismiss-Dialog $dialog $setup
    Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 1) 'The repeated synthetic installation did not stop.'
    Check ([IO.File]::ReadAllText($foreign) -ceq 'synthetic unrelated file' -and
        (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash -ceq $launcherHash -and
        (Get-FileHash -LiteralPath $shortcut -Algorithm SHA256).Hash -ceq $shortcutHash -and (Get-FileHash -LiteralPath $oldShortcut -Algorithm SHA256).Hash -ceq $oldShortcutHash -and
        [IO.File]::ReadAllText($oldSentinel) -ceq 'synthetic user data') 'The repeated synthetic installation changed existing files or data.'
    Write-Output 'Full compiled setup: isolated known folders, clean install, shortcut and WPF window verified. A second setup refused the existing folder and preserved unrelated data and shortcut.'
}finally{
    if($null -ne $monitor){if(-not $monitor.HasExited){$monitor.Kill();[void]$monitor.WaitForExit(10000)};$monitor.Dispose()}
    if($null -ne $setup){if(-not $setup.HasExited){$setup.Kill();[void]$setup.WaitForExit(10000)};$setup.Dispose()}
}
