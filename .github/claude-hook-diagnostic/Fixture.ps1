param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Check([bool]$value,[string]$message){if(-not $value){throw $message}}
Check ($env:CI -ceq 'true' -and $env:GITHUB_ACTIONS -ceq 'true' -and
    $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -ceq '0') 'Disposable hosted Windows required.'
$root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
$runner=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
Check ([string]::Equals([IO.Directory]::GetParent($root).FullName,$runner,[StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($root) -cmatch '^aitm-claude-anchor-[0-9a-f]{32}$') 'Synthetic root rejected.'
for($d=[IO.DirectoryInfo]::new($root);$null -ne $d;$d=$d.Parent){Check (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Redirected root rejected.'}
Check ([string]::Equals([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\'),
    (Join-Path $root 'isolated\temp'),[StringComparison]::OrdinalIgnoreCase)) 'Synthetic temp rejected.'
$install=Join-Path $root 'isolated\localappdata\AITaskMonitor'
Check (-not [IO.Directory]::Exists($install)) 'Synthetic hook directory already exists.'
[void][IO.Directory]::CreateDirectory($install)
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$original=Join-Path $repo 'windows\app\ClaudeTaskHook.ps1'
$hook=Join-Path $install 'ClaudeTaskHook.ps1'
[IO.File]::Copy($original,$hook,$false)
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$stage=Join-Path $install 'ClaudeStageObservation.dll'
$stageSource=Join-Path $repo 'windows\app\ClaudeStageObservation.cs'
$compilerStart=[Diagnostics.ProcessStartInfo]::new($compiler)
$compilerStart.UseShellExecute=$false
$compilerStart.CreateNoWindow=$true
$compilerStart.RedirectStandardOutput=$true
$compilerStart.RedirectStandardError=$true
foreach($item in @('/nologo','/target:library','/platform:anycpu','/reference:System.Web.Extensions.dll',('/out:'+$stage),$stageSource)){
    [void]$compilerStart.ArgumentList.Add($item)
}
$compileProcess=[Diagnostics.Process]::Start($compilerStart)
try {
    $compileOutput=$compileProcess.StandardOutput.ReadToEndAsync()
    $compileError=$compileProcess.StandardError.ReadToEndAsync()
    if(-not $compileProcess.WaitForExit(15000)){$compileProcess.Kill($true);throw 'Synthetic compiler timed out.'}
    if($compileProcess.ExitCode -ne 0 -or -not [IO.File]::Exists($stage)){
        throw ('Synthetic helper compilation failed: '+$compileOutput.Result+$compileError.Result)
    }
} finally {$compileProcess.Dispose()}
function Invoke-Synthetic([string[]]$arguments,[string]$payload,[bool]$capture,[bool]$addPowerShellPath){
    $start=[Diagnostics.ProcessStartInfo]::new()
    $psDirectory=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0'
    $start.FileName=Join-Path $psDirectory 'powershell.exe'
    $start.WorkingDirectory=$root
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true
    $start.RedirectStandardOutput=$capture
    $start.RedirectStandardError=$capture
    $start.Environment.Clear()
    foreach($name in @('SystemRoot','windir','PATH','DOTNET_ROOT','DOTNET_CLI_HOME','USERPROFILE','APPDATA','LOCALAPPDATA',
        'TEMP','TMP','CI','GITHUB_ACTIONS','RUNNER_ENVIRONMENT','RUNNER_OS','RUNNER_TEMP','ProgramFiles','ProgramW6432',
        'ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')){
        $value=[Environment]::GetEnvironmentVariable($name)
        if($null -ne $value){$start.Environment[$name]=$value}
    }
    if($addPowerShellPath){$start.Environment['PATH']=$psDirectory+';'+$start.Environment['PATH']}
    $start.Environment['DOTNET_ADD_GLOBAL_TOOLS_TO_PATH']='0'
    $start.Environment['DOTNET_GENERATE_ASPNET_CERTIFICATE']='0'
    $start.Environment['AI_TASK_MONITOR_AUDIT']='1'
    foreach($argument in $arguments){[void]$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($start)
    try {
        if($capture){$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()}
        $process.StandardInput.WriteLine($payload)
        $process.StandardInput.Close()
        if(-not $process.WaitForExit(8000)){
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            return 'timeout'
        }
        if($capture){return ('exit='+$process.ExitCode+' stdoutLength='+$stdout.Result.Length+' stderrLength='+$stderr.Result.Length+' stderr='+$stderr.Result)}
        return ('exit='+$process.ExitCode+' (output inherited)')
    } finally {$process.Dispose()}
}
$basic=Invoke-Synthetic @('-NoProfile','-NonInteractive','-Command','[Console]::Out.Write([Console]::In.ReadToEnd())') 'synthetic' $true $false
Write-Output ('Simple input, all streams redirected: '+$basic)
$payload='{"hook_event_name":"UserPromptSubmit","session_id":"synthetic-session"}'
$hookArguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$hook)
Write-Output ('Hook, all streams redirected: '+(Invoke-Synthetic $hookArguments $payload $true $false))
Write-Output ('Hook, only stdin redirected: '+(Invoke-Synthetic $hookArguments $payload $false $false))
Write-Output ('Hook, all streams redirected and WinPS in PATH: '+(Invoke-Synthetic $hookArguments $payload $true $true))
$argumentsWithoutNonInteractive=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$hook)
Write-Output ('Hook, no NonInteractive switch: '+(Invoke-Synthetic $argumentsWithoutNonInteractive $payload $true $true))
