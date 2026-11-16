$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0') { throw 'A disposable hosted Windows runner is required.' }
function Check([bool]$condition,[string]$message) { if(-not $condition) { throw $message } }
function Read-PathState([string]$scope) {
    $key=if($scope -eq 'User'){[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$false)}
        else{[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$false)}
    try{return [pscustomobject]@{Value=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);Kind=[string]$key.GetValueKind('Path')}}
    finally{$key.Dispose()}
}
$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
for($dir=[IO.DirectoryInfo]::new($runnerTemp);$null -ne $dir;$dir=$dir.Parent){
    Check ($dir.Exists -and (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Runner temp has a redirected ancestor.'
}
$root=[IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-claude-behavior-'+[Guid]::NewGuid().ToString('N'))))
Check ([string]::Equals([IO.Directory]::GetParent($root).FullName,$runnerTemp,[StringComparison]::OrdinalIgnoreCase) -and
    -not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'Unsafe synthetic root.'
$beforeUser=Read-PathState 'User';$beforeMachine=Read-PathState 'Machine';$beforeProcess=[Environment]::GetEnvironmentVariable('Path','Process')
try{
    [void][IO.Directory]::CreateDirectory($root)
    foreach($name in @('profile','appdata','localappdata','temp','nuget','dotnet','legacy')){
        [void][IO.Directory]::CreateDirectory((Join-Path $root $name))
    }
    $repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $dotnet=(Get-Command dotnet.exe -CommandType Application | Select-Object -First 1).Source
    $python=(Get-Command python.exe -CommandType Application | Select-Object -First 1).Source
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $sdk=Split-Path -Parent $dotnet
    Check ([IO.File]::Exists($compiler)) 'The hosted Framework compiler is unavailable.'
    $config=Join-Path $root 'NuGet.Config'
    [IO.File]::WriteAllText($config,'<configuration><packageSources><clear /></packageSources></configuration>',[Text.UTF8Encoding]::new($false))
    function Invoke-Isolated([string]$executable,[string[]]$arguments,[string]$expectedError='',[switch]$withoutProbeMarker,[int]$timeoutMilliseconds=180000){
        Check ($timeoutMilliseconds -ge 1 -and $timeoutMilliseconds -le 180000) 'An isolated timeout is invalid.'
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$executable;$start.WorkingDirectory=$root;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Environment.Clear()
        $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        $values=@{
            SystemRoot=$env:SystemRoot;windir=$env:SystemRoot
            PATH=($sdk+';'+(Split-Path -Parent $python)+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
            DOTNET_ROOT=$sdk;DOTNET_MULTILEVEL_LOOKUP='0';DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
            DOTNET_CLI_HOME=(Join-Path $root 'dotnet');DOTNET_CLI_TELEMETRY_OPTOUT='1';DOTNET_GENERATE_ASPNET_CERTIFICATE='0'
            DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1';DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER='1'
            NUGET_PACKAGES=(Join-Path $root 'nuget');USERPROFILE=(Join-Path $root 'profile')
            APPDATA=(Join-Path $root 'appdata');LOCALAPPDATA=(Join-Path $root 'localappdata');TEMP=(Join-Path $root 'temp');TMP=(Join-Path $root 'temp')
            AITM_SYNTHETIC_SDK_MARKER=(Join-Path $root 'unexpected-sdk-launch.txt')
            AITM_SYNTHETIC_TIMEOUT_DIRECTORY=(Join-Path $root 'timeout-fixture')
            CI=$env:CI;GITHUB_ACTIONS=$env:GITHUB_ACTIONS;RUNNER_ENVIRONMENT=$env:RUNNER_ENVIRONMENT;RUNNER_OS=$env:RUNNER_OS;RUNNER_TEMP=$env:RUNNER_TEMP
            PSModulePath=((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))
        }
        foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')){
            $value=[Environment]::GetEnvironmentVariable($name)
            if(-not [string]::IsNullOrEmpty($value)){$values[$name]=$value}
        }
        if($withoutProbeMarker){$values.Remove('AITM_SYNTHETIC_SDK_MARKER')}
        foreach($name in $values.Keys){$start.Environment[$name]=[string]$values[$name]}
        foreach($argument in $arguments){[void]$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::Start($start)
        Check ($null -ne $process) 'An isolated process could not be started.'
        try{
            # The Process instance and its handle belong to this invocation;
            # do not find or terminate a process by a separately looked-up PID.
            $handle=$process.SafeHandle
            Check (-not $handle.IsInvalid -and -not $handle.IsClosed) 'An isolated process handle is unavailable.'
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit($timeoutMilliseconds)){
                try{$process.Kill($true)}catch{throw 'The timed-out isolated process tree could not be terminated.'}
                if(-not $process.WaitForExit(5000)){throw 'The timed-out isolated process did not exit within five seconds.'}
                throw 'An isolated test timed out.'
            }
            if($expectedError){
                if($process.ExitCode -eq 0 -or -not $stderr.Result.Contains($expectedError)){throw 'The expected isolated failure did not occur.'}
                return ''
            }
            if($process.ExitCode -ne 0){throw ('An isolated test failed: '+$stdout.Result+$stderr.Result)}
            if($stderr.Result){Write-Host $stderr.Result.TrimEnd()}
            return [string]$stdout.Result
        }finally{$process.Dispose()}
    }
    Write-Output ((Invoke-Isolated $python @('-B',(Join-Path $repository 'windows\tests\Test-DotnetPathSafety.py'))).TrimEnd())

    $fakeSdk=Join-Path $root 'fake-sdk';[void][IO.Directory]::CreateDirectory($fakeSdk)
    $probeSource=Join-Path $root 'sdk-probe.cs'
    $probe=@'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
internal static class SdkProbe {
    private static int Main(string[] args) {
        if (args.Length == 1 && (args[0] == "tree-parent" || args[0] == "tree-child")) {
            string directory = Environment.GetEnvironmentVariable("AITM_SYNTHETIC_TIMEOUT_DIRECTORY");
            if (String.IsNullOrEmpty(directory) || !Directory.Exists(directory)) return 2;
            if (args[0] == "tree-parent") {
                var start = new ProcessStartInfo(typeof(SdkProbe).Assembly.Location, "tree-child");
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                using (Process child = Process.Start(start)) {
                    if (child == null) return 3;
                    File.WriteAllText(Path.Combine(directory, "parent-ready"), "started");
                    Thread.Sleep(Timeout.Infinite);
                }
            }
            File.WriteAllText(Path.Combine(directory, "child-ready"), "started");
            while (true) {
                File.AppendAllText(Path.Combine(directory, "heartbeat"), ".");
                Thread.Sleep(100);
            }
        }
        string marker = Environment.GetEnvironmentVariable("AITM_SYNTHETIC_SDK_MARKER");
        if (String.IsNullOrEmpty(marker)) marker = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "unexpected-sdk-launch.txt");
        File.WriteAllText(marker, "invoked");
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($probeSource,$probe,[Text.UTF8Encoding]::new($false))
    $fakeDotnet=Join-Path $fakeSdk 'dotnet.exe'
    $null=Invoke-Isolated $compiler @('/nologo','/target:exe',('/out:'+$fakeDotnet),$probeSource)
    Check ([IO.File]::Exists($fakeDotnet)) 'The synthetic SDK probe was not built.'
    $probeMarker=[IO.Path]::GetFullPath((Join-Path $root 'unexpected-sdk-launch.txt'))
    $fallbackMarker=[IO.Path]::GetFullPath((Join-Path $fakeSdk 'unexpected-sdk-launch.txt'))
    function Confirm-AndRemoveMarker([string]$path,[string]$expectedDirectory){
        $absolute=[IO.Path]::GetFullPath($path)
        Check ([string]::Equals([IO.Directory]::GetParent($absolute).FullName,$expectedDirectory,[StringComparison]::OrdinalIgnoreCase) -and
            [IO.File]::Exists($absolute) -and
            (([IO.File]::GetAttributes($absolute) -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -eq 0) -and
            [IO.File]::ReadAllText($absolute) -ceq 'invoked') 'The synthetic SDK marker is absent or unsafe.'
        [IO.File]::Delete($absolute)
        Check (-not [IO.File]::Exists($absolute)) 'The synthetic SDK marker could not be removed.'
    }
    Check (-not [IO.File]::Exists($probeMarker) -and -not [IO.File]::Exists($fallbackMarker)) 'An SDK probe marker already exists.'
    $null=Invoke-Isolated -executable $fakeDotnet -arguments @()
    Confirm-AndRemoveMarker $probeMarker $root
    $null=Invoke-Isolated -executable $fakeDotnet -arguments @() -withoutProbeMarker
    Confirm-AndRemoveMarker $fallbackMarker $fakeSdk
    Write-Output 'Synthetic SDK positive controls created both markers; both were safely removed.'

    # A direct synthetic parent starts one synthetic child. The heartbeat must
    # stop after the timeout cleanup; it never accesses a real profile.
    $timeoutDirectory=Join-Path $root 'timeout-fixture'
    [void][IO.Directory]::CreateDirectory($timeoutDirectory)
    $timedOut=$false
    try{$null=Invoke-Isolated -executable $fakeDotnet -arguments @('tree-parent') -timeoutMilliseconds 4000}
    catch{if($_.Exception.Message -ceq 'An isolated test timed out.'){$timedOut=$true}else{throw}}
    $heartbeat=Join-Path $timeoutDirectory 'heartbeat'
    Check ($timedOut -and [IO.File]::Exists((Join-Path $timeoutDirectory 'parent-ready')) -and
        [IO.File]::Exists((Join-Path $timeoutDirectory 'child-ready')) -and [IO.File]::Exists($heartbeat)) 'Synthetic timeout process tree was not observed.'
    $heartbeatBefore=([IO.FileInfo]::new($heartbeat)).Length
    Start-Sleep -Milliseconds 600
    $heartbeatAfter=([IO.FileInfo]::new($heartbeat)).Length
    Check ($heartbeatBefore -gt 0 -and $heartbeatAfter -eq $heartbeatBefore) 'A synthetic descendant continued after timeout cleanup.'
    Write-Output 'Synthetic timeout terminated the parent and stopped its child heartbeat.'
    $null=Invoke-Isolated $powershell @('-NoProfile','-NonInteractive','-Command','exit 0')
    $beforeLauncher=@(Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object {$_.FullName} | Sort-Object)
    $forbiddenWork=Join-Path $root 'launcher-must-not-create'
    $retired=Join-Path $repository 'windows\native\ClaudeReader\Test-ClaudeReader.ps1'
    $null=Invoke-Isolated $powershell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$retired,
        '-SdkRoot',$fakeSdk,'-WorkDirectory',$forbiddenWork,'-PwshNet10',$powershell,'-WindowsPowerShell',$powershell) 'The legacy Claude reader test launcher is disabled'
    $afterLauncher=@(Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object {$_.FullName} | Sort-Object)
    Check (($beforeLauncher -join "`n") -ceq ($afterLauncher -join "`n") -and
        -not [IO.File]::Exists($probeMarker) -and -not [IO.File]::Exists($fallbackMarker) -and
        -not [IO.Directory]::Exists($forbiddenWork)) 'The retired launcher created data or started the synthetic SDK.'
    Write-Output 'Retired Claude launcher refused before creating files or starting the synthetic SDK.'

    # The original legacy assertions predate phase-aware reader semantics.
    $oldTest=Join-Path $repository 'windows\tests\Test-ClaudeReader.ps1'
    $null=Invoke-Isolated $powershell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$oldTest) 'Legacy plan data was not preserved for the observed session.'
    Write-Output 'Original legacy test fails its old inferred-step assertion against the current embedded reader.'

    $embeddedPath=Join-Path $repository 'windows\app\ClaudeReaderCore.ps1'
    $nativePath=Join-Path $repository 'windows\native\ClaudeReader\Reader.cs'
    $embedded=[IO.File]::ReadAllText($embeddedPath)
    $match=[regex]::Match($embedded,"(?ms)-TypeDefinition @'\r?\n(?<code>.*?)\r?\n'@")
    Check ($match.Success) 'The actual embedded reader source was not found.'
    $embeddedCode=$match.Groups['code'].Value.Replace("`r`n","`n").TrimEnd("`r","`n")
    $nativeCode=[IO.File]::ReadAllText($nativePath).Replace("`r`n","`n").TrimEnd("`r","`n")
    Write-Output ('Embedded and native reader sources are identical: '+[string]::Equals($embeddedCode,$nativeCode,[StringComparison]::Ordinal))
    $extracted=Join-Path $root 'legacy\EmbeddedReader.cs'
    [IO.File]::WriteAllText($extracted,$embeddedCode,[Text.UTF8Encoding]::new($false))
    $fixture=Join-Path $repository 'windows\native\Tests\ClaudeReaderBehavior\Program.cs'
    $embeddedExe=Join-Path $root 'legacy\embedded-behavior.exe'
    $compile=Invoke-Isolated $compiler @('/nologo','/target:exe','/reference:System.Web.Extensions.dll',('/out:'+$embeddedExe),$extracted,$fixture)
    if($compile.Trim()){Write-Output $compile.TrimEnd()}
    Check ([IO.File]::Exists($embeddedExe)) 'The embedded behavior fixture did not compile.'
    Write-Output ((Invoke-Isolated $embeddedExe @('embedded')).TrimEnd())

    $project=Join-Path $repository 'windows\native\Tests\ClaudeReaderBehavior\ClaudeReaderBehavior.Tests.csproj'
    $artifacts=Join-Path $root 'artifacts'
    $build=Invoke-Isolated $dotnet @('build',$project,'-c','Release','--configfile',$config,'--artifacts-path',$artifacts,'-p:NuGetAudit=false','--nologo')
    Write-Output $build.TrimEnd()
    $assembly=Join-Path $artifacts 'bin\ClaudeReaderBehavior.Tests\release\ClaudeReaderBehavior.Tests.dll'
    Check ([IO.File]::Exists($assembly)) 'The native behavior fixture did not compile.'
    Write-Output ((Invoke-Isolated $dotnet @($assembly,'native')).TrimEnd())
    Write-Output 'Claude reader behavior was tested only with synthetic in-memory events.'
}finally{
    foreach($scope in @('User','Machine')){
        $before=if($scope -eq 'User'){$beforeUser}else{$beforeMachine};$after=Read-PathState $scope
        if($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind){throw "$scope PATH changed during the hosted test."}
    }
    if([Environment]::GetEnvironmentVariable('Path','Process') -cne $beforeProcess){throw 'Process PATH changed during the hosted test.'}
}
