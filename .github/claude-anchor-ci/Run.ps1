$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'A disposable hosted Windows runner with the PATH opt-out is required.'
}
function Check([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Read-PathState([string]$scope) {
    $key = if ($scope -eq 'User') { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false) }
           else { [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false) }
    try {
        [pscustomobject]@{
            Value = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Kind = [string]$key.GetValueKind('Path')
        }
    } finally { $key.Dispose() }
}
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
Check ([IO.Path]::IsPathFullyQualified($runnerTemp)) 'Runner temp must be absolute.'
for ($dir=[IO.DirectoryInfo]::new($runnerTemp); $null -ne $dir; $dir=$dir.Parent) {
    Check ($dir.Exists -and (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Runner temp has a redirected ancestor.'
}
$root = [IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-claude-anchor-' + [Guid]::NewGuid().ToString('N'))))
Check ([string]::Equals([IO.Directory]::GetParent($root).FullName, $runnerTemp, [StringComparison]::OrdinalIgnoreCase)) 'Synthetic root must be a direct runner-temp child.'
Check (-not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'Synthetic root already exists.'
$beforeUser = Read-PathState 'User'
$beforeMachine = Read-PathState 'Machine'
$beforeProcess = [Environment]::GetEnvironmentVariable('Path', 'Process')
try {
    $null = [IO.Directory]::CreateDirectory($root)
    $isolation = Join-Path $root 'isolated'
    foreach ($name in @('profile','appdata','localappdata','temp','nuget','dotnet')) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $isolation $name))
    }
    $command = Get-Command dotnet.exe -CommandType Application | Select-Object -First 1
    Check ($null -ne $command) 'A hosted .NET SDK is unavailable.'
    $dotnet = $command.Source
    $sdk = Split-Path -Parent $dotnet
    $config = Join-Path $root 'NuGet.Config'
    [IO.File]::WriteAllText($config, '<configuration><packageSources><clear /></packageSources></configuration>', [Text.UTF8Encoding]::new($false))
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $artifacts = Join-Path $root 'artifacts'

    function Invoke-Isolated([string[]]$arguments, [string]$executable = '', [string]$working = '') {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = if ($executable) { $executable } else { $dotnet }
        $start.WorkingDirectory = if ($working) { $working } else { $repositoryRoot }
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment.Clear()
        $values = @{
            SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
            PATH=($sdk + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
            DOTNET_ROOT=$sdk; DOTNET_MULTILEVEL_LOOKUP='0'; DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
            DOTNET_CLI_HOME=(Join-Path $isolation 'dotnet'); DOTNET_CLI_TELEMETRY_OPTOUT='1'
            DOTNET_GENERATE_ASPNET_CERTIFICATE='0'; DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'
            DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'; DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER='1'
            NUGET_PACKAGES=(Join-Path $isolation 'nuget'); USERPROFILE=(Join-Path $isolation 'profile')
            APPDATA=(Join-Path $isolation 'appdata'); LOCALAPPDATA=(Join-Path $isolation 'localappdata')
            TEMP=(Join-Path $isolation 'temp'); TMP=(Join-Path $isolation 'temp')
            CI=$env:CI; GITHUB_ACTIONS=$env:GITHUB_ACTIONS; RUNNER_ENVIRONMENT=$env:RUNNER_ENVIRONMENT
            RUNNER_OS=$env:RUNNER_OS; RUNNER_TEMP=$env:RUNNER_TEMP
        }
        foreach ($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrEmpty($value)) { $values[$name] = $value }
        }
        foreach ($key in $values.Keys) { $start.Environment[$key] = [string]$values[$key] }
        foreach ($argument in $arguments) { $null = $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(180000)) { $process.Kill($true); throw 'The hosted test timed out.' }
            if ($process.ExitCode -ne 0) { throw ('The hosted test failed: ' + $stdout.Result + $stderr.Result) }
            return [string]$stdout.Result
        } finally { $process.Dispose() }
    }

    $install = Join-Path $isolation 'localappdata\AITaskMonitor'
    [void][IO.Directory]::CreateDirectory($install)
    $hookSource = Join-Path $repositoryRoot 'windows\app\ClaudeTaskHook.ps1'
    $hook = Join-Path $install 'ClaudeTaskHook.ps1'
    Check ([IO.File]::Exists($hookSource) -and -not [IO.File]::Exists($hook)) 'Synthetic hook fixture rejected.'
    [IO.File]::Copy($hookSource, $hook, $false)
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    Check ([IO.File]::Exists($compiler)) 'Hosted .NET Framework compiler is unavailable.'
    $stage = Join-Path $install 'ClaudeStageObservation.dll'
    $stageSource = Join-Path $repositoryRoot 'windows\app\ClaudeStageObservation.cs'
    $compile = Invoke-Isolated -arguments @('/nologo', '/target:library', '/platform:anycpu',
        '/reference:System.Web.Extensions.dll', ("/out:" + $stage), $stageSource) -executable $compiler
    Check ([IO.File]::Exists($stage)) 'Synthetic hook helper did not compile.'
    if ($compile.Trim()) { Write-Output $compile.TrimEnd() }

    $projects = @(
        @{ Project='windows\native\Tests\ClaudeFileSource\ClaudeFileSource.Tests.csproj'; Assembly='bin\ClaudeFileSource.Tests\release\ClaudeFileSource.Tests.dll' },
        @{ Project='windows\native\Tests\ClaudeFileIdentity\ClaudeFileIdentity.Tests.csproj'; Assembly='bin\ClaudeFileIdentity.Tests\release\ClaudeFileIdentity.Tests.dll' },
        @{ Project='windows\native\Tests\ClaudePump\ClaudePump.Tests.csproj'; Assembly='bin\ClaudePump.Tests\release\AITaskMonitor.ClaudePump.Tests.dll' },
        @{ Project='windows\native\Tests\ClaudeFileUi\ClaudeFileUi.Tests.csproj'; Assembly='bin\ClaudeFileUi.Tests\release\AITaskMonitor.Prototype.Tests.dll' }
        @{ Project='windows\native\Tests\ClaudeRuntimeHost\ClaudeRuntimeHost.Tests.csproj'; Assembly='bin\ClaudeRuntimeHost.Tests\release\AITaskMonitor.Prototype.Tests.dll' }
    )
    foreach ($item in $projects) {
        $project = Join-Path $repositoryRoot $item.Project
        $build = Invoke-Isolated @('build', $project, '-c', 'Release', '--configfile', $config,
            '--artifacts-path', $artifacts, '-p:NuGetAudit=false', '--nologo')
        Write-Output $build.TrimEnd()
        $assembly = Join-Path $artifacts $item.Assembly
        Check ([IO.File]::Exists($assembly)) 'A synthetic test assembly is missing.'
        $output = Invoke-Isolated @($assembly)
        Write-Output $output.TrimEnd()
    }
    Write-Output 'Claude journal checks used synthetic files only.'
} finally {
    foreach ($scope in @('User','Machine')) {
        $before = if ($scope -eq 'User') { $beforeUser } else { $beforeMachine }
        $after = Read-PathState $scope
        if ($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind) { throw "$scope PATH changed during the hosted test." }
    }
    if ([Environment]::GetEnvironmentVariable('Path', 'Process') -cne $beforeProcess) { throw 'Process PATH changed during the hosted test.' }
}
