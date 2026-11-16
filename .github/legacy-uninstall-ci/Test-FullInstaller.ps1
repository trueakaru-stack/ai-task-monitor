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
function Get-NativeWindowSummary([int]$processId){
    $windows=[Collections.Generic.List[string]]::new()
    $callback=[FallbackTestNative+EnumWindowsCallback]{
        param([IntPtr]$handle,[IntPtr]$parameter)
        $owner=[uint32]0
        [void][FallbackTestNative]::GetWindowThreadProcessId($handle,[ref]$owner)
        if($owner -eq $processId){
            $title=[Text.StringBuilder]::new(512);$className=[Text.StringBuilder]::new(256)
            [void][FallbackTestNative]::GetWindowText($handle,$title,$title.Capacity)
            [void][FallbackTestNative]::GetClassName($handle,$className,$className.Capacity)
            $windows.Add($className.ToString()+':'+$title.ToString()+':visible='+[FallbackTestNative]::IsWindowVisible($handle))
        }
        return $true
    }
    [void][FallbackTestNative]::EnumWindows($callback,[IntPtr]::Zero)
    return ($windows -join ' | ')
}
function Find-Window([Diagnostics.Process]$process,[int]$seconds){
    $idCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
    $nameCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'AI task monitor')
    $condition=[Windows.Automation.AndCondition]::new($idCondition,$nameCondition)
    $clock=[Diagnostics.Stopwatch]::StartNew();$firstNative=-1L;$lastNative=-1000L
    while($clock.Elapsed.TotalSeconds -lt $seconds){
        if($process.HasExited){throw 'The synthetic process exited before its window appeared.'}
        if($clock.ElapsedMilliseconds-$lastNative -ge 1000){
            $lastNative=$clock.ElapsedMilliseconds
            $native=Get-NativeWindowSummary $process.Id
            if($firstNative -lt 0 -and $null -ne $native -and $native.Contains('AI task monitor:visible=True')){$firstNative=$clock.ElapsedMilliseconds}
        }
        $found=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,$condition)
        if($null -ne $found -and $found.Current.Name -ceq 'AI task monitor' -and [FallbackTestNative]::IsWindowVisible([IntPtr]$found.Current.NativeWindowHandle)){
            Write-Host ('Synthetic window timing: UIA='+$clock.ElapsedMilliseconds+'ms; first sampled Win32='+$firstNative+'ms.')
            return $found
        }
        Start-Sleep -Milliseconds 100
    }
    $process.Refresh()
    $idCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
    $otherWindows=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$idCondition)
    $details=@(foreach($item in $otherWindows){$item.Current.ClassName+':'+$item.Current.Name})
    $children=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId = '+$process.Id) -Property Name|ForEach-Object {$_.Name})
    $postDeadline=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,$condition)
    Write-Warning ('Window diagnostic: elapsed='+$clock.ElapsedMilliseconds+'ms; first sampled Win32='+$firstNative+'ms; post-deadline UIA='+($null -ne $postDeadline)+'; alive='+(-not $process.HasExited)+'; UIA windows='+($details -join ' | ')+'; native windows='+(Get-NativeWindowSummary $process.Id)+'; child process names='+($children -join ','))
    throw 'The synthetic process window was not found in time.'
}
function Find-DialogText([Diagnostics.Process]$process,[string[]]$needles,[int]$seconds){
    $id=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
    $title=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'AI task monitor')
    $condition=[Windows.Automation.AndCondition]::new($id,$title)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt $seconds){
        if($process.HasExited){throw 'The synthetic removal process exited before its dialog.'}
        $window=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,$condition)
        if($null -ne $window){
            foreach($name in @(Get-Names $window)){foreach($needle in $needles){if($name.Contains($needle)){return $window}}}
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'The synthetic removal dialog was not found in time.'
}
function Get-Names($window){
    $children=$window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    return @(foreach($item in $children){$item.Current.Name})
}
function Invoke-DialogButton($window,[Diagnostics.Process]$process,[string[]]$names){
    $all=$window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    $buttons=@($all|Where-Object {$_.Current.Name -cin $names -and $_.Current.ClassName -ceq 'Button'})
    Check ($buttons.Count -eq 1) 'The synthetic setup dialog has no unique expected button.'
    $handle=[IntPtr]$buttons[0].Current.NativeWindowHandle;$owner=[uint32]0
    [void][FallbackTestNative]::GetWindowThreadProcessId($handle,[ref]$owner)
    Check ($handle -ne [IntPtr]::Zero -and $owner -eq $process.Id) 'The synthetic setup control belongs to another process.'
    Check ([FallbackTestNative]::PostMessage($handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)) 'Cannot activate the synthetic setup control.'
}
function Dismiss-Dialog($window,[Diagnostics.Process]$process){Invoke-DialogButton $window $process @('OK')}

function Save-DialogScreenshot($window,[Diagnostics.Process]$process,[string]$name){
    try{
        if($name -cnotmatch '^[a-z0-9-]+$'){throw 'Invalid screenshot name.'}
        $handle=[IntPtr]$window.Current.NativeWindowHandle;$owner=[uint32]0
        [void][FallbackTestNative]::GetWindowThreadProcessId($handle,[ref]$owner)
        if($handle -eq [IntPtr]::Zero -or $owner -ne $process.Id){throw 'The dialog belongs to another process.'}
        $rect=[FallbackTestNative+WindowRect]::new()
        if(-not [FallbackTestNative]::GetWindowRect($handle,[ref]$rect)){throw 'Cannot read dialog bounds.'}
        $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
        if($width -lt 50 -or $height -lt 50 -or $width -gt 4096 -or $height -gt 4096){throw 'Invalid dialog bounds.'}
        if($env:GITHUB_SHA -cnotmatch '^[a-f0-9]{40}$'){throw 'The source revision is unavailable.'}
        $temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
        $screenshots=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-dialogs-'+$env:GITHUB_SHA)))
        if(-not [string]::Equals([IO.Directory]::GetParent($screenshots).FullName,$temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe screenshot directory.'}
        if([IO.Directory]::Exists($screenshots)){
            if(([IO.File]::GetAttributes($screenshots) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'The screenshot directory is redirected.'}
        }else{[void][IO.Directory]::CreateDirectory($screenshots)}
        $bitmap=[Drawing.Bitmap]::new($width,$height)
        try{
            $graphics=[Drawing.Graphics]::FromImage($bitmap)
            try{
                $dc=$graphics.GetHdc()
                try{$printed=[FallbackTestNative]::PrintWindow($handle,$dc,2)}finally{$graphics.ReleaseHdc($dc)}
            }finally{$graphics.Dispose()}
            if(-not $printed){throw 'The dialog could not be rendered.'}
            $colors=[Collections.Generic.HashSet[int]]::new()
            $stepX=[Math]::Max(1,[int]($width/32));$stepY=[Math]::Max(1,[int]($height/32))
            for($y=0;$y -lt $height;$y+=$stepY){for($x=0;$x -lt $width;$x+=$stepX){[void]$colors.Add($bitmap.GetPixel($x,$y).ToArgb())}}
            if($colors.Count -lt 3){throw 'The dialog capture is blank.'}
            $path=Join-Path $screenshots ($name+'.png')
            $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
            Write-Output ('Saved synthetic dialog screenshot '+$name+'.png ('+$width+'x'+$height+').')
        }finally{$bitmap.Dispose()}
    }catch{Write-Warning ('Synthetic dialog screenshot unavailable: '+$name)}
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
# Compare hidden and normal startup in the same disposable profile.
# Neither control opens agent or user data.
$controlCode='Add-Type -AssemblyName PresentationFramework; $window=New-Object Windows.Window; $window.Title="AI task monitor"; [void]$window.ShowDialog()'
$controlResults=@{}
foreach($mode in @('hidden','normal')){
    $control=New-IsolatedStart $SystemPowerShell $values
    if($mode -eq 'hidden'){$control.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden}
    foreach($arg in @('-NoProfile','-ExecutionPolicy','Bypass')){[void]$control.ArgumentList.Add($arg)}
    if($mode -eq 'hidden'){foreach($arg in @('-WindowStyle','Hidden')){[void]$control.ArgumentList.Add($arg)}}
    foreach($arg in @('-Sta','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($controlCode)))){[void]$control.ArgumentList.Add($arg)}
    $controlProcess=[Diagnostics.Process]::Start($control)
    try{
        $controlVisible=$false
        try{$controlWindow=Find-Window $controlProcess 20;$controlVisible=$null -ne $controlWindow}catch{}
        $controlResults[$mode]=$controlVisible
        Write-Output ('Synthetic WPF positive control '+$mode+': UIA window found='+$controlVisible+'; native windows='+(Get-NativeWindowSummary $controlProcess.Id))
    }finally{
        if(-not $controlProcess.HasExited){$controlProcess.Kill();[void]$controlProcess.WaitForExit(10000)}
        $controlProcess.Dispose()
    }
}
Check ([bool]$controlResults['normal']) 'The disposable runner WPF positive control did not show a window.'

# Exercise the error after the real Claude setup changes fixture settings.
# Hold only the synthetic launcher so its subsequent start fails safely.
$claudeDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void]$claudeDirectories.Add([IO.Path]::GetFullPath((Join-Path $knownProfile '.claude')))
[void]$claudeDirectories.Add([IO.Path]::GetFullPath((Join-Path $profile '.claude')))
foreach($dir in $claudeDirectories){
    Check (-not [IO.Directory]::Exists($dir) -and -not [IO.File]::Exists($dir)) 'A synthetic Claude directory already exists.'
    $parent=[IO.Directory]::GetParent($dir).FullName
    Check ((Within $parent $runnerProfile) -or (Within $parent $FixtureRoot)) 'A synthetic Claude directory escaped the disposable profile.'
    for($p=[IO.DirectoryInfo]::new($parent);$null -ne $p;$p=$p.Parent){
        Check ($p.Exists -and (($p.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'A synthetic Claude path is redirected.'
    }
    [void][IO.Directory]::CreateDirectory($dir)
}
$fakeSettings=Join-Path $profile '.claude\settings.json'
[IO.File]::WriteAllText($fakeSettings,'{"user":"preserved"}')
$partialValues=@{}
foreach($key in $values.Keys){$partialValues[$key]=$values[$key]}
# This process-local test PATH does not contain the PowerShell directory.
$partialValues.PATH=(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot
$fixtureLauncher=Join-Path $install 'AI task monitor.exe'
$launcherLock=$null
$partialSetup=$null
try{
    $start=New-IsolatedStart $Installer $partialValues
    $partialSetup=[Diagnostics.Process]::Start($start)
    $prompt=Find-Window $partialSetup 30
    Save-DialogScreenshot $prompt $partialSetup 'claude-confirmation-en'
    $promptNames=Get-Names $prompt
    Check (@($promptNames|Where-Object {$_.Contains('Connect Claude Code?') -and $_.Contains('2.1.101')}).Count -gt 0) 'The English synthetic Claude connection prompt was not shown.'
    Invoke-DialogButton $prompt $partialSetup @('Yes','Да')
    $lockClock=[Diagnostics.Stopwatch]::StartNew()
    while($null -eq $launcherLock -and $lockClock.Elapsed.TotalSeconds -lt 30 -and -not $partialSetup.HasExited){
        if([IO.File]::Exists($fixtureLauncher)){
            try{$launcherLock=[IO.File]::Open($fixtureLauncher,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}catch [IO.IOException]{}
        }
        if($null -eq $launcherLock){Start-Sleep -Milliseconds 20}
    }
    Check ($null -ne $launcherLock) 'The synthetic launcher could not be held before the real Claude setup finished.'
    $clock=[Diagnostics.Stopwatch]::StartNew();$failure=$null;$systemClaudeSetupObserved=$false
    $idCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$partialSetup.Id)
    $nameCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'AI task monitor')
    $condition=[Windows.Automation.AndCondition]::new($idCondition,$nameCondition)
    while($null -eq $failure -and $clock.Elapsed.TotalSeconds -lt 60){
        $children=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId = '+$partialSetup.Id) -Property ExecutablePath,CommandLine)
        foreach($child in $children){
            if($child.CommandLine -and $child.CommandLine.Contains('Configure-ClaudeIntegration.ps1') -and
                [string]::Equals([string]$child.ExecutablePath,$SystemPowerShell,[StringComparison]::OrdinalIgnoreCase)){$systemClaudeSetupObserved=$true}
        }
        if($partialSetup.HasExited){throw 'The synthetic partial setup exited without its warning.'}
        $window=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,$condition)
        if($null -ne $window){
            $names=Get-Names $window
            if(@($names|Where-Object {$_.Contains('Настройки подключения Claude Code могли измениться.') -or $_.Contains('Claude Code connection settings may have changed.')}).Count -gt 0){$failure=$window;break}
        }
        Start-Sleep -Milliseconds 100
    }
    Check ($null -ne $failure) 'The synthetic partial setup did not warn about Claude settings.'
    Save-DialogScreenshot $failure $partialSetup 'partial-install-warning-en'
    Check $systemClaudeSetupObserved 'The Claude configuration process was not observed at the system PowerShell path.'
    $configured=[IO.File]::ReadAllText($fakeSettings)|ConvertFrom-Json
    $expectedHookPath=Join-Path $install 'ClaudeTaskHook.ps1'
    $expectedScript="& '"+$expectedHookPath.Replace("'","''")+"'"
    $expectedEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($expectedScript))
    $expectedCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$expectedEncoded
    if(-not ($configured.user -ceq 'preserved' -and
        [string]$configured.hooks.UserPromptSubmit[0].hooks[0].command -ceq $expectedCommand)){
        Write-Warning ('Synthetic installer error dialog: '+((Get-Names $failure) -join ' | '))
        $debug=New-IsolatedStart $SystemPowerShell $partialValues
        foreach($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $install 'Configure-ClaudeIntegration.ps1'),'-Mode','Install')){[void]$debug.ArgumentList.Add($arg)}
        $debug.RedirectStandardOutput=$true;$debug.RedirectStandardError=$true
        $debugProcess=[Diagnostics.Process]::Start($debug)
        try{
            $debugOut=$debugProcess.StandardOutput.ReadToEndAsync();$debugErr=$debugProcess.StandardError.ReadToEndAsync()
            if($debugProcess.WaitForExit(30000)){Write-Warning ('Synthetic configuration diagnosis: exit='+$debugProcess.ExitCode+'; stdout='+$debugOut.Result+'; stderr='+$debugErr.Result)}
            else{$debugProcess.Kill();[void]$debugProcess.WaitForExit(10000);Write-Warning 'Synthetic configuration diagnosis timed out.'}
        }finally{$debugProcess.Dispose()}
        throw 'The real Claude setup did not safely write the expected existing hook to fixture settings.'
    }
    $failureNames=Get-Names $failure
    Check (@($failureNames|Where-Object {$_.Contains($install)}).Count -gt 0) 'The partial-install warning omitted the actual installation path.'
    Dismiss-Dialog $failure $partialSetup
    Check ($partialSetup.WaitForExit(10000) -and $partialSetup.ExitCode -eq 1) 'The synthetic partial setup did not fail as expected.'
}finally{
    if($null -ne $launcherLock){$launcherLock.Dispose()}
    if($null -ne $partialSetup){if(-not $partialSetup.HasExited){$partialSetup.Kill();[void]$partialSetup.WaitForExit(10000)};$partialSetup.Dispose()}
}
$backup=[IO.Path]::GetFullPath($install+'.synthetic-partial')
Check ([string]::Equals([IO.Directory]::GetParent($install).FullName,$knownLocal,[StringComparison]::OrdinalIgnoreCase) -and
    [string]::Equals([IO.Directory]::GetParent($backup).FullName,$knownLocal,[StringComparison]::OrdinalIgnoreCase) -and
    [IO.Directory]::Exists($install) -and -not [IO.Directory]::Exists($backup) -and -not [IO.File]::Exists($backup)) 'The synthetic partial-install backup path is unsafe.'
[IO.Directory]::Move($install,$backup)
foreach($dir in $claudeDirectories){
    $saved=[IO.Path]::GetFullPath($dir+'.synthetic-backup')
    Check ([string]::Equals([IO.Directory]::GetParent($saved).FullName,[IO.Directory]::GetParent($dir).FullName,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Directory]::Exists($dir) -and -not [IO.Directory]::Exists($saved) -and -not [IO.File]::Exists($saved) -and
        (([IO.File]::GetAttributes($dir) -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'The synthetic Claude backup path is unsafe.'
    [IO.Directory]::Move($dir,$saved)
}
if([IO.File]::Exists($shortcut)){
    $savedShortcut=[IO.Path]::GetFullPath($shortcut+'.synthetic-backup')
    Check ([string]::Equals([IO.Directory]::GetParent($savedShortcut).FullName,$knownPrograms,[StringComparison]::OrdinalIgnoreCase) -and -not [IO.File]::Exists($savedShortcut)) 'The synthetic shortcut backup path is unsafe.'
    [IO.File]::Move($shortcut,$savedShortcut)
}
Check ((Get-FileHash -LiteralPath $oldShortcut -Algorithm SHA256).Hash -ceq $oldShortcutHash -and
    [IO.File]::ReadAllText($oldSentinel) -ceq 'synthetic user data') 'Synthetic partial setup changed pre-existing data.'
Write-Output 'Real system PowerShell configured only fixture Claude settings with PATH lacking PowerShell; a locked fixture launcher produced the expected partial-install warning.'

$setup=$null;$monitor=$null
try{
    $start=New-IsolatedStart $Installer $values
    $setup=[Diagnostics.Process]::Start($start)
    $setupTime=$setup.StartTime.ToUniversalTime()
    $dialog=Find-Window $setup 30
    Write-Output 'Synthetic setup dialog found.'
    Save-DialogScreenshot $dialog $setup 'installation-success-en'
    $names=Get-Names $dialog
    Check (@($names|Where-Object {$_.Contains('AI task monitor is installed.') -and $_.Contains('AI task monitor (new)')}).Count -gt 0) 'The installer did not report a completed installation with the alternative shortcut in English.'
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
    try{
        $startupClock=[Diagnostics.Stopwatch]::StartNew()
        $monitorWindow=Find-Window $monitor 90
        if($startupClock.Elapsed.TotalSeconds -gt 40){Write-Warning ('Visible monitor startup took '+[Math]::Round($startupClock.Elapsed.TotalSeconds,1)+' seconds after setup completed.')}
    }catch{
        $strictFailure=$_
        if(-not $monitor.HasExited){$monitor.Kill();[void]$monitor.WaitForExit(10000)}
        $monitor.Dispose();$monitor=$null
        # Diagnostic only: repeat the installed launcher's exact PowerShell
        # arguments with output redirected, in the same synthetic environment.
        $direct=New-IsolatedStart $SystemPowerShell $values
        $direct.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
        $direct.RedirectStandardOutput=$true;$direct.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-Sta','-File',$appScript)){[void]$direct.ArgumentList.Add($arg)}
        $probeMonitor=[Diagnostics.Process]::Start($direct)
        try{
            $probeOut=$probeMonitor.StandardOutput.ReadToEndAsync();$probeErr=$probeMonitor.StandardError.ReadToEndAsync()
            $probeWindowFound=$false
            try{$probeWindow=Find-Window $probeMonitor 30;$probeWindowFound=$null -ne $probeWindow}catch{}
            $finished=$probeMonitor.HasExited
            if(-not $finished){$probeMonitor.Kill();[void]$probeMonitor.WaitForExit(10000)}
            $observedOut=if($probeOut.IsCompleted){$probeOut.Result}else{'<stream still open>'}
            $observedErr=if($probeErr.IsCompleted){$probeErr.Result}else{'<stream still open>'}
            Write-Warning ('Direct installed-script diagnostic: UIA window found='+$probeWindowFound+'; exited='+$finished+'; stdout='+$observedOut+'; stderr='+$observedErr)
        }finally{$probeMonitor.Dispose()}
        # Insert checkpoints only into a synthetic copy in the fixture. The
        # installed resource itself remains unchanged.
        $checkpoint=Join-Path $FixtureRoot 'startup-checkpoints.txt'
        $instrumented=Join-Path $install 'synthetic-startup-diagnostic.ps1'
        $sourceText=[IO.File]::ReadAllText($appScript,[Text.Encoding]::UTF8).Replace([string][char]13+[char]10,[string][char]10)
        $lineFeed=[string][char]10;$literal=$checkpoint.Replace("'","''")
        $markers=[ordered]@{
            'before-wpf'='Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing'
            'after-wpf'='$codexHome = if ($env:CODEX_HOME)'
            'before-diagnostics'='foreach($module in @("DiagnosticPolicy.ps1","DiagnosticStore.ps1","LoopDetection.ps1","DiagnosticCollector.ps1","DiagnosticRuntime.ps1"))'
            'before-claude-reader'='try { . (Join-Path $PSScriptRoot "ClaudeReaderCore.ps1") }'
            'after-claude-reader'='$script:claudeRetentionAvailable=$false'
            'before-update-transport'='$script:releaseUpdatesAvailable=$false'
            'before-provider-init'='$script:externalProviderController=$null'
            'before-codex-cloud'='$script:codexCloudModulesAvailable=$false'
            'after-codex-cloud'='$script:currentVersion='
            'before-window-load'='$reader = New-Object System.Xml.XmlNodeReader $xaml'
            'after-window-load'='$iconPath = Join-Path $PSScriptRoot "assets\app-icon.ico"'
            'before-theme'='$initialTheme=if($ThemeOverride)'
            'before-diagnostic-runtime'='if($script:diagnosticModulesAvailable -and (($PreviewActiveTasks -lt 0 -and -not $SnapshotFile) -or $DiagnosticDirectory))'
            'before-language'='$initialLanguage=if($LanguageOverride)'
            'before-activity'='Refresh-ActivityMotion'+$lineFeed+'Update-View'
            'before-show-dialog'='$window.ShowDialog()|Out-Null'
        }
        foreach($entry in $markers.GetEnumerator()){
            $token=[string]$entry.Value
            $at=$sourceText.IndexOf($token,[StringComparison]::Ordinal)
            Check ($at -ge 0 -and $sourceText.LastIndexOf($token,[StringComparison]::Ordinal) -eq $at) ('A diagnostic checkpoint is absent or ambiguous: '+$entry.Key)
            $logStatement="[IO.File]::AppendAllText('"+$literal+"','"+[string]$entry.Key+"' + [Environment]::NewLine); "+$lineFeed
            $sourceText=$sourceText.Insert($at,$logStatement)
        }
        [IO.File]::WriteAllText($instrumented,$sourceText,[Text.UTF8Encoding]::new($true))
        $instrumentedStart=New-IsolatedStart $SystemPowerShell $values
        $instrumentedStart.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
        foreach($arg in @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-Sta','-File',$instrumented)){[void]$instrumentedStart.ArgumentList.Add($arg)}
        $instrumentedProcess=[Diagnostics.Process]::Start($instrumentedStart)
        try{
            $deadline=[Diagnostics.Stopwatch]::StartNew()
            while(-not $instrumentedProcess.HasExited -and $deadline.Elapsed.TotalSeconds -lt 25){
                if([IO.File]::Exists($checkpoint) -and [IO.File]::ReadAllText($checkpoint).Contains('before-show-dialog')){break}
                Start-Sleep -Milliseconds 200
            }
            $reached=[IO.File]::Exists($checkpoint) -and [IO.File]::ReadAllText($checkpoint).Contains('before-show-dialog')
            $instrumentedVisible=$false
            if($reached -and -not $instrumentedProcess.HasExited){
                try{$instrumentedWindow=Find-Window $instrumentedProcess 15;$instrumentedVisible=$null -ne $instrumentedWindow}catch{}
            }
            $nativeSummary=if(-not $instrumentedProcess.HasExited){Get-NativeWindowSummary $instrumentedProcess.Id}else{'process exited'}
            if(-not $instrumentedProcess.HasExited){$instrumentedProcess.Kill();[void]$instrumentedProcess.WaitForExit(10000)}
            $observed=if([IO.File]::Exists($checkpoint)){[IO.File]::ReadAllLines($checkpoint) -join ', '}else{'none'}
            Write-Warning ('Synthetic instrumented startup checkpoints: '+$observed+'; UIA window found='+$instrumentedVisible+'; native windows='+$nativeSummary)
        }finally{$instrumentedProcess.Dispose()}
        throw $strictFailure
    }
    Write-Output 'Synthetic monitor window found.'
    Check ($monitorWindow.Current.Name -ceq 'AI task monitor') 'The synthetic monitor window did not open.'
    $monitor.Kill();Check ($monitor.WaitForExit(10000)) 'The synthetic monitor did not exit.'
    $monitor.Dispose();$monitor=$null
    Check ([IO.File]::ReadAllText($oldSentinel) -ceq 'synthetic user data') 'The synthetic existing data was changed.'
    $foreign=Join-Path $install 'foreign.txt';[IO.File]::WriteAllText($foreign,'synthetic unrelated file')
    $launcherHash=(Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
    $shortcutHash=(Get-FileHash -LiteralPath $shortcut -Algorithm SHA256).Hash
    $appPreferences=Join-Path $oldData 'settings.json'
    foreach($case in @(
        @{Language='ru'; Needle='Папка установки уже существует.'; Screenshot='existing-installation-warning-ru'},
        @{Language='en'; Needle='The installation folder already exists.'; Screenshot='existing-installation-warning-en'}
    )){
        $preferences='{"language":"'+$case.Language+'","fixture":"preserved"}'
        [IO.File]::WriteAllText($appPreferences,$preferences,[Text.UTF8Encoding]::new($false))
        $start=New-IsolatedStart $Installer $values
        $setup=[Diagnostics.Process]::Start($start)
        $dialog=Find-Window $setup 30
        Save-DialogScreenshot $dialog $setup $case.Screenshot
        $names=Get-Names $dialog
        Check (@($names|Where-Object {$_.Contains($case.Needle)}).Count -gt 0) 'The repeated installer did not use the selected language for its warning.'
        Dismiss-Dialog $dialog $setup
        Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 1) 'The repeated synthetic installation did not stop.'
        Check ([IO.File]::ReadAllText($foreign) -ceq 'synthetic unrelated file' -and
            (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash -ceq $launcherHash -and
            (Get-FileHash -LiteralPath $shortcut -Algorithm SHA256).Hash -ceq $shortcutHash -and (Get-FileHash -LiteralPath $oldShortcut -Algorithm SHA256).Hash -ceq $oldShortcutHash -and
            [IO.File]::ReadAllText($oldSentinel) -ceq 'synthetic user data' -and [IO.File]::ReadAllText($appPreferences) -ceq $preferences) 'The repeated synthetic installation changed existing files or data.'
        $setup.Dispose();$setup=$null
    }
    Write-Output 'Full compiled setup: isolated known folders, clean install, shortcut and WPF window verified. Repeated setup refused the existing folder in both selected languages and preserved unrelated data, settings and shortcuts.'
    $modified=Join-Path $install 'DiagnosticStore.ps1'
    [IO.File]::WriteAllText($modified,'synthetic user modification')
    $removalScript=Join-Path $install 'Uninstall-CodexProgress.ps1'
    $appPreferences=Join-Path $oldData 'settings.json'
    $ruPreferences='{"language":"ru","fixture":"preserved"}'
    [IO.File]::WriteAllText($appPreferences,$ruPreferences,[Text.UTF8Encoding]::new($false))
    $removal=New-IsolatedStart $SystemPowerShell $values
    $literalRemoval=$removalScript.Replace("'","''")
    $ruCommand="[Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('en-US'); & '$literalRemoval'; exit `$LASTEXITCODE"
    foreach($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Sta','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ruCommand)))){[void]$removal.ArgumentList.Add($arg)}
    $setup=[Diagnostics.Process]::Start($removal)
    $ruQuestion=Find-DialogText $setup @('Отключить Claude Code и удалить') 30
    Save-DialogScreenshot $ruQuestion $setup 'removal-confirmation-ru'
    Invoke-DialogButton $ruQuestion $setup @('No','Нет')
    Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 0) 'Refusing synthetic removal did not exit cleanly.'
    Check ([IO.File]::Exists($launcher) -and [IO.File]::Exists($appScript) -and [IO.File]::ReadAllText($foreign) -ceq 'synthetic unrelated file' -and [IO.File]::ReadAllText($appPreferences) -ceq $ruPreferences) 'Refusing removal changed synthetic files or language preferences.'
    $setup.Dispose();$setup=$null
    $enPreferences='{"language":"en","fixture":"preserved"}'
    [IO.File]::WriteAllText($appPreferences,$enPreferences,[Text.UTF8Encoding]::new($false))
    $removal=New-IsolatedStart $SystemPowerShell $values
    $enCommand="[Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('ru-RU'); & '$literalRemoval'; exit `$LASTEXITCODE"
    foreach($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Sta','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($enCommand)))){[void]$removal.ArgumentList.Add($arg)}

    $setup=[Diagnostics.Process]::Start($removal)
    $question=Find-DialogText $setup @('Disconnect Claude Code and remove') 30
    Save-DialogScreenshot $question $setup 'removal-confirmation-en'
    Invoke-DialogButton $question $setup @('No','Нет')
    Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 0 -and [IO.File]::Exists($launcher)) 'Refusing English removal changed the synthetic installation.'
    $setup.Dispose();$setup=$null

    # Execute the installed CMD itself with no PowerShell directory on its
    # child PATH. Observe the actual system PowerShell and its own dialog.
    $cmdValues=@{}
    foreach($key in $values.Keys){$cmdValues[$key]=$values[$key]}
    $cmdValues.PATH=$tmp
    $commandPath=Join-Path $install 'Uninstall-CodexProgress.cmd'
    $cmdPath=Join-Path $env:SystemRoot 'System32\cmd.exe'
    $cmdStart=New-IsolatedStart $cmdPath $cmdValues
    $cmdStart.Arguments='/d /s /c ""'+$commandPath+'""'
    $cmdStart.RedirectStandardOutput=$true;$cmdStart.RedirectStandardError=$true
    $setup=[Diagnostics.Process]::Start($cmdStart)
    $cmdOut=$setup.StandardOutput.ReadToEndAsync();$cmdErr=$setup.StandardError.ReadToEndAsync()
    $childClock=[Diagnostics.Stopwatch]::StartNew();$removalChild=$null
    while($null -eq $removalChild -and $childClock.Elapsed.TotalSeconds -lt 30){
        if($setup.HasExited){throw 'The installed removal CMD exited before starting PowerShell.'}
        $children=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId = '+$setup.Id) -Property ProcessId,ExecutablePath,CommandLine)
        foreach($child in $children){
            if($child.CommandLine -and $child.CommandLine.Contains('Uninstall-CodexProgress.ps1') -and
                [string]::Equals([string]$child.ExecutablePath,$SystemPowerShell,[StringComparison]::OrdinalIgnoreCase)){
                $removalChild=[Diagnostics.Process]::GetProcessById([int]$child.ProcessId)
                $removalHandle=$removalChild.SafeHandle
                Check ($null -ne $removalHandle -and -not $removalHandle.IsInvalid -and -not $removalHandle.IsClosed) 'The synthetic removal process handle could not be held.'
                break
            }
        }
        if($null -eq $removalChild){Start-Sleep -Milliseconds 100}
    }
    Check ($null -ne $removalChild) 'The installed removal CMD did not start system PowerShell without PATH.'
    try{
        $question=Find-DialogText $removalChild @('Disconnect Claude Code and remove') 30
        Invoke-DialogButton $question $removalChild @('Yes','Да')
        $result=Find-DialogText $removalChild @('Claude Code disconnection was checked.') 40
        Save-DialogScreenshot $result $removalChild 'removal-result-en'
        Write-Output ('Synthetic removal result: '+((Get-Names $result) -join ' | '))
        Dismiss-Dialog $result $removalChild
        $removalExited=$removalChild.WaitForExit(10000)
        $removalExit=if($removalExited){[string]$removalChild.ExitCode}else{'still running'}
        $setup.Refresh()
        $observedCmdOut=if($cmdOut.IsCompleted){$cmdOut.Result}else{'pending'}
        $observedCmdErr=if($cmdErr.IsCompleted){$cmdErr.Result}else{'pending'}
        Write-Output ('Synthetic removal exit diagnostic: powershell='+$removalExit+'; cmd exited='+$setup.HasExited+'; launcher exists='+[IO.File]::Exists($launcher)+'; app script exists='+[IO.File]::Exists($appScript)+'; stdout='+$observedCmdOut+'; stderr='+$observedCmdErr)
        Check ($removalExited -and $removalChild.ExitCode -eq 0) 'The installed uninstaller did not complete its verified removal.'
    }finally{
        if(-not $removalChild.HasExited){$removalChild.Kill();[void]$removalChild.WaitForExit(10000)}
        $removalChild.Dispose()
    }
    Check ($setup.WaitForExit(10000) -and $setup.ExitCode -eq 0) 'The installed removal CMD did not exit successfully.'
    Write-Output 'Installed removal CMD started system PowerShell with no PowerShell on PATH and completed verified removal.'
    Check (-not [IO.File]::Exists($launcher) -and -not [IO.File]::Exists($appScript) -and
        [IO.File]::ReadAllText($modified) -ceq 'synthetic user modification' -and
        [IO.File]::ReadAllText($foreign) -ceq 'synthetic unrelated file' -and
        [IO.File]::ReadAllText($oldSentinel) -ceq 'synthetic user data' -and
        [IO.File]::ReadAllText($appPreferences) -ceq $enPreferences -and
        (Get-FileHash -LiteralPath $shortcut -Algorithm SHA256).Hash -ceq $shortcutHash -and
        (Get-FileHash -LiteralPath $oldShortcut -Algorithm SHA256).Hash -ceq $oldShortcutHash -and
        [IO.File]::Exists((Join-Path $install 'integrations\provider-events.mjs')) -and
        [IO.File]::Exists($removalScript)) 'The installed uninstaller did not preserve the expected synthetic files.'
    Write-Output 'Installed generated uninstaller removed unchanged application files; modified, unrelated, provider, data and shortcut fixtures were preserved.'
}finally{
    if($null -ne $monitor){if(-not $monitor.HasExited){$monitor.Kill();[void]$monitor.WaitForExit(10000)};$monitor.Dispose()}
    if($null -ne $setup){if(-not $setup.HasExited){$setup.Kill();[void]$setup.WaitForExit(10000)};$setup.Dispose()}
}
