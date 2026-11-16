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
    # Compile the real installer; the separate full test executes it in a synthetic profile.
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
    $generated=@(Get-ChildItem -LiteralPath $build -Filter 'Uninstall-generated-*.ps1' -File)
    Check ($generated.Count -eq 1 -and (Get-FileHash -LiteralPath $extracted -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $generated[0].FullName -Algorithm SHA256).Hash) 'The compiled installer does not contain its generated uninstaller.'
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
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FallbackTestNative
{
    public delegate bool EnumWindowsCallback(IntPtr handle, IntPtr parameter);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr handle, System.Text.StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr handle, System.Text.StringBuilder text, int capacity);
    [StructLayout(LayoutKind.Sequential)]
    public struct WindowRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr handle, out WindowRect rect);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PrintWindow(IntPtr handle, IntPtr deviceContext, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PostMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);
}
'@
    & (Join-Path $PSScriptRoot 'Test-FullInstaller.ps1') -Installer $exe -FixtureRoot $root -ProcessValues $values -SystemPowerShell $ps
    & (Join-Path $PSScriptRoot '..\safe-uninstall-ci\Test.ps1')
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
