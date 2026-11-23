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
$root = [IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-update-host-' + [Guid]::NewGuid().ToString('N'))))
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
    $repositoryDirectory = [IO.DirectoryInfo]::new($repositoryRoot)
    $sourceRoot = $repositoryDirectory.Parent
    Check ($repositoryDirectory.Exists -and $repositoryDirectory.Name -ceq 'source' -and
        $null -ne $sourceRoot -and $null -ne $sourceRoot.Parent -and
        $sourceRoot.Name.StartsWith('aitm-update-source-', [StringComparison]::Ordinal) -and
        [string]::Equals($sourceRoot.Parent.FullName, $runnerTemp, [StringComparison]::OrdinalIgnoreCase)) 'Source checkout must be inside its dedicated runner-temp directory.'
    foreach ($directory in @($repositoryDirectory, $sourceRoot)) {
        Check ($directory.Exists -and (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Source checkout has a redirected directory.'
    }
    # Select .NET 10 for this disposable checkout, even if the runner also has a newer SDK.
    $sdkSettings = '{"sdk":{"version":"10.0.100","rollForward":"latestFeature","allowPrerelease":false}}'
    $sdkSettingsBytes = [Text.UTF8Encoding]::new($false).GetBytes($sdkSettings)
    $sdkSettingsFile = [IO.File]::Open((Join-Path $sourceRoot.FullName 'global.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $sdkSettingsFile.Write($sdkSettingsBytes, 0, $sdkSettingsBytes.Length) } finally { $sdkSettingsFile.Dispose() }
    $artifacts = Join-Path $root 'artifacts'

    function Invoke-Isolated([string[]]$arguments) {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $dotnet
        $start.WorkingDirectory = $repositoryRoot
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

    $sdkVersion = (Invoke-Isolated @('--version')).Trim()
    Check ($sdkVersion -match '^10\.') 'The hosted SDK is not .NET 10.'
    $project = Join-Path $repositoryRoot 'windows\native\Tests\UpdateHost\UpdateHost.Tests.csproj'
    $build = Invoke-Isolated @('build', $project, '-c', 'Release', '--configfile', $config,
        '--artifacts-path', $artifacts, '-p:NuGetAudit=false', '--nologo')
    Write-Output $build.TrimEnd()
    $assembly = Join-Path $artifacts 'bin\UpdateHost.Tests\release\AITaskMonitor.Prototype.Tests.dll'
    Check ([IO.File]::Exists($assembly)) 'The synthetic test assembly is missing.'
    $output = Invoke-Isolated @($assembly, $root)
    Write-Output $output.TrimEnd()
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.png' -File)
    Check ($files.Count -eq 12) 'The twelve requested synthetic frames were not captured.'
    $summary = [pscustomobject]@{
        SdkVersion=$sdkVersion; Synthetic=$true; RealNetworkUsed=$false
        Frames=@($files | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash } })
    }
    [IO.File]::WriteAllText((Join-Path $root 'synthetic-update-frames.json'), ($summary | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
} finally {
    foreach ($scope in @('User','Machine')) {
        $before = if ($scope -eq 'User') { $beforeUser } else { $beforeMachine }
        $after = Read-PathState $scope
        if ($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind) { throw "$scope PATH changed during the hosted test." }
    }
    if ([Environment]::GetEnvironmentVariable('Path', 'Process') -cne $beforeProcess) { throw 'Process PATH changed during the hosted test.' }
}
