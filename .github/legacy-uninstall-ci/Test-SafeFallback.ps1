$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Check([bool]$value,[string]$message){if(-not $value){throw $message}}
function PathState([string]$scope){
    $key=if($scope -eq 'User'){[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$false)}
        else{[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$false)}
    try{return [pscustomobject]@{Value=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);Kind=[string]$key.GetValueKind('Path')}}
    finally{$key.Dispose()}
}
Check ($env:CI -ceq 'true' -and $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -ceq '0') 'Requires a disposable hosted Windows runner.'
$beforeUser=PathState 'User';$beforeMachine=PathState 'Machine';$beforeProcess=[Environment]::GetEnvironmentVariable('Path','Process')
try{
    $temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
    for($p=[IO.DirectoryInfo]::new($temp);$null -ne $p;$p=$p.Parent){Check ($p.Exists -and (($p.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Runner temp has a redirected ancestor.'}
    $root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-safe-uninstall-'+[guid]::NewGuid().ToString('N'))))
    Check ([string]::Equals([IO.Directory]::GetParent($root).FullName,$temp,[StringComparison]::OrdinalIgnoreCase) -and -not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'Unsafe fixture root.'
    $profile=Join-Path $root 'profile';$local=Join-Path $root 'local';$roaming=Join-Path $root 'roaming';$tmp=Join-Path $root 'temp';$external=Join-Path $root 'external'
    foreach($dir in @($profile,$local,$roaming,$tmp,$external)){[void][IO.Directory]::CreateDirectory($dir)}
    $install=[IO.Path]::GetFullPath((Join-Path $local 'AITaskMonitor'))
    Check ([string]::Equals([IO.Directory]::GetParent($install).FullName,$local,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture installation.'
    [void][IO.Directory]::CreateDirectory($install)
    $source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\windows\app\Uninstall-CodexProgress.ps1'))
    $uninstaller=Join-Path $install 'Uninstall-CodexProgress.ps1'
    [IO.File]::Copy($source,$uninstaller,$false)
    Check ((Get-FileHash -LiteralPath $uninstaller -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash) 'Copied candidate differs from source.'
    $folder=Join-Path $install 'user-folder';[void][IO.Directory]::CreateDirectory($folder)
    $junction=Join-Path $install 'linked'
    $null=New-Item -ItemType Junction -Path $junction -Target $external
    $link=Get-Item -LiteralPath $junction -Force
    Check (($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and [string]::Equals([IO.Path]::GetFullPath([string]$link.Target),$external,[StringComparison]::OrdinalIgnoreCase)) 'Invalid synthetic junction.'
    $programs=Join-Path $roaming 'Microsoft\Windows\Start Menu\Programs';$claude=Join-Path $profile '.claude'
    foreach($dir in @($programs,$claude)){[void][IO.Directory]::CreateDirectory($dir)}
    $items=[ordered]@{}
    $items[(Join-Path $install 'unrelated.txt')]='synthetic unrelated content'
    $items[(Join-Path $folder 'nested.txt')]='synthetic nested content'
    $items[(Join-Path $install 'CodexProgress.ps1')]='synthetic modified program file'
    $items[(Join-Path $external 'linked.txt')]='synthetic linked content'
    $items[(Join-Path $programs 'AI task monitor.lnk')]='synthetic modified shortcut'
    $items[(Join-Path $claude 'settings.json')]='{"synthetic":"unaltered"}'
    $items[(Join-Path $install 'Configure-ClaudeIntegration.ps1')]='throw "Unexpected integration invocation"'
    $items[(Join-Path $install 'Configure-OpenCodeIntegration.ps1')]='throw "Unexpected integration invocation"'
    foreach($entry in $items.GetEnumerator()){[IO.File]::WriteAllText([string]$entry.Key,[string]$entry.Value,[Text.UTF8Encoding]::new($false))}
    $ps=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $values=@{
        CI=$env:CI;GITHUB_ACTIONS=$env:GITHUB_ACTIONS;RUNNER_ENVIRONMENT=$env:RUNNER_ENVIRONMENT;RUNNER_OS=$env:RUNNER_OS;RUNNER_TEMP=$env:RUNNER_TEMP
        SystemRoot=$env:SystemRoot;windir=$env:SystemRoot
        PATH=((Split-Path -Parent $ps)+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
        USERPROFILE=$profile;LOCALAPPDATA=$local;APPDATA=$roaming;TEMP=$tmp;TMP=$tmp
        PSModulePath=((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))
        DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0';DOTNET_GENERATE_ASPNET_CERTIFICATE='0'
        DOTNET_CLI_HOME=$tmp;NUGET_PACKAGES=(Join-Path $tmp 'nuget')
    }
    foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')){
        $v=[Environment]::GetEnvironmentVariable($name);if(-not [string]::IsNullOrEmpty($v)){$values[$name]=$v}
    }
    function New-IsolatedPS {
        $s=[Diagnostics.ProcessStartInfo]::new();$s.FileName=$ps;$s.WorkingDirectory=$root
        $s.UseShellExecute=$false;$s.CreateNoWindow=$true;$s.Environment.Clear()
        foreach($key in $values.Keys){$s.Environment[$key]=[string]$values[$key]}
        foreach($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass')){[void]$s.ArgumentList.Add($arg)}
        return $s
    }
    # Compile the real installer from the candidate source; never execute the EXE.
    $output=Join-Path $root 'out';$build=Join-Path $root 'build'
    $builder=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\windows\app\Build-Installer-v2.ps1'))
    $start=New-IsolatedPS
    foreach($arg in @('-File',$builder,'-OutputDirectory',$output,'-BuildTempDirectory',$build)){[void]$start.ArgumentList.Add($arg)}
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $compiler=[Diagnostics.Process]::Start($start)
    try{
        $compilerOut=$compiler.StandardOutput.ReadToEndAsync();$compilerErr=$compiler.StandardError.ReadToEndAsync()
        if(-not $compiler.WaitForExit(90000)){throw 'Candidate installer compilation timed out.'}
        if($compiler.ExitCode -ne 0){Write-Output $compilerOut.Result;Write-Output $compilerErr.Result;throw 'Candidate installer did not compile.'}
    }finally{$compiler.Dispose()}
    $exe=Join-Path $output 'AITaskMonitorSetup.exe'
    Check ([IO.File]::Exists($exe)) 'Compiled installer is missing.'
    $extractor=Join-Path $root 'extract.ps1'
    [IO.File]::WriteAllText($extractor,@'
param([string]$InputExe,[string]$OutputFile)
$ErrorActionPreference='Stop'
$assembly=[Reflection.Assembly]::ReflectionOnlyLoadFrom($InputExe)
$stream=$assembly.GetManifestResourceStream('Uninstall-CodexProgress.ps1')
if($null -eq $stream){throw 'Installer does not contain the uninstaller resource.'}
try {
    $out=[IO.File]::Open($OutputFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$stream.CopyTo($out)} finally {$out.Dispose()}
} finally {$stream.Dispose()}
'@,[Text.UTF8Encoding]::new($false))
    $extracted=Join-Path $root 'built-Uninstall-CodexProgress.ps1'
    $start=New-IsolatedPS
    foreach($arg in @('-File',$extractor,$exe,$extracted)){[void]$start.ArgumentList.Add($arg)}
    $extractProcess=[Diagnostics.Process]::Start($start)
    try{Check ($extractProcess.WaitForExit(20000) -and $extractProcess.ExitCode -eq 0) 'Cannot extract the candidate uninstaller.'}finally{$extractProcess.Dispose()}
    Check ((Get-FileHash -LiteralPath $extracted -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash) 'The compiled installer does not contain the candidate uninstaller.'
    $engineTest=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Test-InstallEngine.ps1'))
    $start=New-IsolatedPS
    foreach($arg in @('-STA','-File',$engineTest,$exe,$root)){[void]$start.ArgumentList.Add($arg)}
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $engineProcess=[Diagnostics.Process]::Start($start)
    try{
        $engineOut=$engineProcess.StandardOutput.ReadToEndAsync();$engineErr=$engineProcess.StandardError.ReadToEndAsync()
        if(-not $engineProcess.WaitForExit(30000)){throw 'The installer assembly guard test timed out.'}
        if($engineProcess.ExitCode -ne 0){Write-Output $engineOut.Result;Write-Output $engineErr.Result;throw 'The installer assembly guard test failed.'}
        Write-Output $engineOut.Result
    }finally{$engineProcess.Dispose()}
    [IO.File]::Copy($extracted,$uninstaller,$true)
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FallbackTestNative
{
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);
}
'@
    & (Join-Path $PSScriptRoot 'Test-FullInstaller.ps1') -Installer $exe -FixtureRoot $root -ProcessValues $values -SystemPowerShell $ps
    foreach($culture in @('en-US','ru-RU')){
        $start=New-IsolatedPS
        $literal=$uninstaller.Replace("'","''")
        $command="[Threading.Thread]::CurrentThread.CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('$culture'); & '$literal'; exit `$LASTEXITCODE"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        foreach($arg in @('-EncodedCommand',$encoded)){[void]$start.ArgumentList.Add($arg)}
        $process=[Diagnostics.Process]::Start($start)
        try{
            $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
            $dialog=$null;$clock=[Diagnostics.Stopwatch]::StartNew()
            while($null -eq $dialog -and $clock.Elapsed.TotalSeconds -lt 20){
                if($process.HasExited){throw 'The fallback exited before displaying its message.'}
                $dialog=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,$condition)
                if($null -eq $dialog){Start-Sleep -Milliseconds 100}
            }
            Check ($null -ne $dialog) 'The fallback message was not found.'
            Check ($dialog.Current.Name -ceq 'AI task monitor') 'The fallback message had an unexpected title.'
            $all=$dialog.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
            $names=@(foreach($element in $all){$element.Current.Name})
            $expected=if($culture -eq 'ru-RU'){'Удаление не выполнено.'}else{'Uninstallation was not performed.'}
            $preserved=if($culture -eq 'ru-RU'){'подключения сохранены.'}else{'connections were preserved.'}
            Check (@($names|Where-Object {$_.Contains($expected) -and $_.Contains($preserved) -and $_.Contains('%LOCALAPPDATA%\AITaskMonitor')}).Count -gt 0) 'The fallback did not explain that removal was not performed and where files remain.'
            # The hosted UIA provider exposes native message-box controls as
            # panes. Send BM_CLICK only to its uniquely identified OK control.
            $buttons=@($all|Where-Object {$_.Current.Name -ceq 'OK' -and $_.Current.ClassName -ceq 'Button'})
            Check ($buttons.Count -eq 1) 'The fallback dialog has no unique native OK control.'
            $handle=[IntPtr]$buttons[0].Current.NativeWindowHandle
            $owner=[uint32]0
            [void][FallbackTestNative]::GetWindowThreadProcessId($handle,[ref]$owner)
            Check ($handle -ne [IntPtr]::Zero -and $owner -eq $process.Id) 'The synthetic OK control belongs to another process.'
            Check ([FallbackTestNative]::PostMessage($handle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)) 'Cannot activate the synthetic OK control.'
            Check ($process.WaitForExit(10000) -and $process.ExitCode -eq 1) 'The fallback did not exit with the incomplete-removal status.'
        }finally{
            if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(10000)}
            $process.Dispose()
        }
    }
    foreach($entry in $items.GetEnumerator()){
        Check ([IO.File]::Exists([string]$entry.Key) -and [IO.File]::ReadAllText([string]$entry.Key) -ceq [string]$entry.Value) 'A synthetic user file was altered.'
    }
    Check ([IO.File]::Exists($uninstaller) -and [IO.Directory]::Exists($install) -and [IO.Directory]::Exists($junction)) 'Installation files or the synthetic link were removed.'
    Write-Output ('Safe uninstall fallback: explanatory dialog, non-success exit, and {0} synthetic files including modified, unrelated and redirected data preserved.' -f $items.Count)
    Check ($env:GITHUB_SHA -cmatch '^[a-f0-9]{40}$') 'The source revision is missing.'
    $artifactRoot=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP ('aitm-verified-setup-'+$env:GITHUB_SHA)))
    Check ([string]::Equals([IO.Directory]::GetParent($artifactRoot).FullName,[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase) -and -not [IO.Directory]::Exists($artifactRoot) -and -not [IO.File]::Exists($artifactRoot)) 'Unsafe artifact directory.'
    [void][IO.Directory]::CreateDirectory($artifactRoot)
    $artifactExe=Join-Path $artifactRoot 'AITaskMonitorSetup.exe'
    [IO.File]::Copy($exe,$artifactExe,$false)
    $digest=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    Check ((Get-FileHash -LiteralPath $artifactExe -Algorithm SHA256).Hash -ceq $digest) 'The artifact differs from the tested setup.'
    [IO.File]::WriteAllText((Join-Path $artifactRoot 'SHA256SUMS-windows.txt'),($digest.ToLowerInvariant()+'  AITaskMonitorSetup.exe'+[Environment]::NewLine),[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $artifactRoot 'SOURCE-REVISION.txt'),($env:GITHUB_SHA+[Environment]::NewLine),[Text.Encoding]::ASCII)
    Write-Output ('Verified setup SHA-256: '+$digest+'; source: '+$env:GITHUB_SHA)

}finally{
    foreach($scope in @('User','Machine')){
        $before=if($scope -eq 'User'){$beforeUser}else{$beforeMachine};$after=PathState $scope
        if($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind){throw "$scope PATH changed."}
    }
    if([Environment]::GetEnvironmentVariable('Path','Process') -cne $beforeProcess){throw 'Process PATH changed.'}
}
