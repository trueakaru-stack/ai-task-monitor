param([Parameter(Mandatory=$true)][string]$ReferenceSource)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0') { throw 'A disposable hosted Windows runner is required.' }
function Check([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Read-PathState([string]$scope) {
    $key = if ($scope -eq 'User') { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false) }
        else { [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false) }
    try { return [pscustomobject]@{ Value=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind=[string]$key.GetValueKind('Path') } }
    finally { $key.Dispose() }
}
$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
for ($dir=[IO.DirectoryInfo]::new($runnerTemp); $null -ne $dir; $dir=$dir.Parent) {
    Check ($dir.Exists -and (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Runner temp has a redirected ancestor.'
}
$root=[IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-codex-index-' + [Guid]::NewGuid().ToString('N'))))
Check ([string]::Equals([IO.Directory]::GetParent($root).FullName,$runnerTemp,[StringComparison]::OrdinalIgnoreCase) -and
    -not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'Unsafe synthetic root.'
$reference=[IO.Path]::GetFullPath($ReferenceSource)
Check ($reference.StartsWith($runnerTemp+'\',[StringComparison]::OrdinalIgnoreCase)) 'The reference must be under runner temp.'
for ($dir=[IO.FileInfo]::new($reference).Directory; $null -ne $dir; $dir=$dir.Parent) {
    Check ($dir.Exists -and (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Reference has a redirected ancestor.'
}
Check ([IO.File]::Exists($reference) -and (([IO.File]::GetAttributes($reference) -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Reference is missing or redirected.'
Check ((Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash -ceq 'DD9A401DFABDFC68623A8503746EF7808F154C0E606588CE9143F07A31FEDDB8') 'Pinned reference hash mismatch.'
$beforeUser=Read-PathState 'User'; $beforeMachine=Read-PathState 'Machine'; $beforeProcess=[Environment]::GetEnvironmentVariable('Path','Process')
try {
    [void][IO.Directory]::CreateDirectory($root)
    foreach ($name in @('profile','appdata','localappdata','temp','nuget','dotnet','fixtures','legacy')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $name))
    }
    $repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $dotnet=(Get-Command dotnet.exe -CommandType Application | Select-Object -First 1).Source
    $python=(Get-Command python.exe -CommandType Application | Select-Object -First 1).Source
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sdk=Split-Path -Parent $dotnet
    $config=Join-Path $root 'NuGet.Config'
    [IO.File]::WriteAllText($config,'<configuration><packageSources><clear /></packageSources></configuration>',[Text.UTF8Encoding]::new($false))
    function Invoke-Isolated([string]$executable, [string[]]$arguments, [string]$expectedError='') {
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$executable; $start.WorkingDirectory=$root; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.Environment.Clear()
        $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
        $values=@{
            SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
            PATH=($sdk+';'+(Split-Path -Parent $python)+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
            DOTNET_ROOT=$sdk; DOTNET_MULTILEVEL_LOOKUP='0'; DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
            DOTNET_CLI_HOME=(Join-Path $root 'dotnet'); DOTNET_CLI_TELEMETRY_OPTOUT='1'; DOTNET_GENERATE_ASPNET_CERTIFICATE='0'
            DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'; DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'; DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER='1'
            NUGET_PACKAGES=(Join-Path $root 'nuget'); USERPROFILE=(Join-Path $root 'profile')
            APPDATA=(Join-Path $root 'appdata'); LOCALAPPDATA=(Join-Path $root 'localappdata'); TEMP=(Join-Path $root 'temp'); TMP=(Join-Path $root 'temp')
            CI=$env:CI; GITHUB_ACTIONS=$env:GITHUB_ACTIONS; RUNNER_ENVIRONMENT=$env:RUNNER_ENVIRONMENT; RUNNER_OS=$env:RUNNER_OS; RUNNER_TEMP=$env:RUNNER_TEMP
            PSModulePath=((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))
        }
        foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')) {
            $value=[Environment]::GetEnvironmentVariable($name)
            if(-not [string]::IsNullOrEmpty($value)) { $values[$name]=$value }
        }
        foreach($name in $values.Keys) { $start.Environment[$name]=[string]$values[$name] }
        foreach($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
        $process=[Diagnostics.Process]::Start($start)
        try {
            $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(180000)) { throw 'An isolated test timed out.' }
            if($expectedError) {
                if($process.ExitCode -eq 0 -or -not $stderr.Result.Contains($expectedError)) { throw 'An unsafe synthetic test path was not refused as expected.' }
                return ''
            }
            if($process.ExitCode -ne 0) { throw ('An isolated test failed: '+$stdout.Result+$stderr.Result) }
            if($stderr.Result) { Write-Host $stderr.Result.TrimEnd() }
            return [string]$stdout.Result
        } finally { $process.Dispose() }
    }
    Write-Output ((Invoke-Isolated $python @('-B',(Join-Path $repository 'windows\tests\Test-DotnetPathSafety.py'))).TrimEnd())
    $project=Join-Path $repository 'windows\native\CodexIndex\Tests\CodexIndex.Tests.csproj'
    $artifacts=Join-Path $root 'artifacts'
    $build=Invoke-Isolated $dotnet @('build',$project,'-c','Release','--configfile',$config,'--artifacts-path',$artifacts,'-p:NuGetAudit=false','--nologo')
    Write-Output $build.TrimEnd()
    $fixture=Invoke-Isolated $powershell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',
        (Join-Path $repository 'windows\native\CodexIndex\Tests\Write-IndexFixtures.ps1'),'-ReferenceSource',$reference,'-FixtureRoot',(Join-Path $root 'legacy'))
    $fixturePath=Join-Path $root 'synthetic-fixtures.json'
    [IO.File]::WriteAllText($fixturePath,$fixture,[Text.UTF8Encoding]::new($false))
    $assembly=Join-Path $artifacts 'bin\CodexIndex.Tests\release\AITaskMonitor.CodexIndex.Tests.dll'
    Check ([IO.File]::Exists($assembly)) 'Synthetic index assembly is missing.'
    $sentinel=Join-Path $root 'profile\untouched.txt'
    [IO.File]::WriteAllText($sentinel,'synthetic user data',[Text.UTF8Encoding]::new($false))
    $null=Invoke-Isolated $dotnet @($assembly,$fixturePath,(Join-Path $root 'profile')) 'Fixture, assembly and output must belong to the same unique temporary root.'
    Check ([IO.File]::ReadAllText($sentinel) -ceq 'synthetic user data') 'The rejected synthetic profile was changed.'
    Write-Output 'Synthetic profile output was refused and its sentinel remained unchanged.'
    Write-Output ((Invoke-Isolated $dotnet @($assembly,$fixturePath,(Join-Path $root 'fixtures'))).TrimEnd())
    Write-Output 'Only synthetic index files and a pinned historical source were read.'
} finally {
    foreach($scope in @('User','Machine')) {
        $before=if($scope -eq 'User'){$beforeUser}else{$beforeMachine}; $after=Read-PathState $scope
        if($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind) { throw "$scope PATH changed during the synthetic check." }
    }
    if([Environment]::GetEnvironmentVariable('Path','Process') -cne $beforeProcess) { throw 'Process PATH changed during the synthetic check.' }
}
