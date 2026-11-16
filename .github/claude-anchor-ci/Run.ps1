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

    $pwsh = (Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source
    Check ([IO.File]::Exists($pwsh)) 'Hosted PowerShell is unavailable.'
    $fixture = Join-Path $repositoryRoot '.github\claude-anchor-ci\Fixture.ps1'
    $output = Invoke-Isolated -arguments @('-NoProfile', '-NonInteractive', '-File', $fixture, '-Root', $root) -executable $pwsh
    Write-Output $output.TrimEnd()
    Write-Output 'Claude anchor feasibility used synthetic files only.'
} finally {
    foreach ($scope in @('User','Machine')) {
        $before = if ($scope -eq 'User') { $beforeUser } else { $beforeMachine }
        $after = Read-PathState $scope
        if ($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind) { throw "$scope PATH changed during the hosted test." }
    }
    if ([Environment]::GetEnvironmentVariable('Path', 'Process') -cne $beforeProcess) { throw 'Process PATH changed during the hosted test.' }
}
