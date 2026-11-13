param(
    [Parameter(Mandatory=$true)][string]$SdkRoot,
    [Parameter(Mandatory=$true)][string]$WorkDirectory,
    [Parameter(Mandatory=$true)][string]$PwshNet10,
    [string]$NodeExecutable = (Get-Command node.exe -ErrorAction Stop).Source,
    [string]$WindowsPowerShell = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
)
$ErrorActionPreference = 'Stop'

function FullPath([string]$path) { return [IO.Path]::GetFullPath($path).TrimEnd('\','/') }
function IsWithin([string]$path, [string]$root) {
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    $path = FullPath $path; $root = FullPath $root
    return $path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-NoReparseAncestors([string]$path) {
    $current = [IO.DirectoryInfo]::new($path)
    while ($null -ne $current) {
        if ($current.Exists -and (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'The test work directory must not have a reparse-point ancestor.'
        }
        $current = $current.Parent
    }
}

$sdk = FullPath $SdkRoot
$work = FullPath $WorkDirectory
$pwsh = [IO.Path]::GetFullPath($PwshNet10)
$node = [IO.Path]::GetFullPath($NodeExecutable)
$frameworkShell = [IO.Path]::GetFullPath($WindowsPowerShell)
$dotnet = Join-Path $sdk 'dotnet.exe'
foreach ($path in @($dotnet,$pwsh,$frameworkShell,$node)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A required SDK, PowerShell or Node executable is missing.' }
}
foreach ($profileRoot in @($env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA)) {
    if (IsWithin $work $profileRoot) { throw 'The work directory must be outside the user profile and application data.' }
}
Assert-NoReparseAncestors $work
$project = Join-Path $PSScriptRoot 'Providers.csproj'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if (IsWithin $work $repo) { throw 'The work directory must be outside the repository.' }
$source = Join-Path $repo 'windows/app/integrations/ProviderEventState.cs'
$tests = Join-Path $repo 'windows/tests'
$run = Join-Path $work ('provider-tests-' + [Guid]::NewGuid().ToString('N'))
foreach ($name in @('home','appdata','localappdata','temp','nuget','cache','obj','bin','fixtures')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $run $name) | Out-Null
}
$config = Join-Path $run 'NuGet.Config'
[IO.File]::WriteAllText($config, '<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>')

function Invoke-Isolated([string]$executable, [string[]]$arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $executable
    $info.WorkingDirectory = $run
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $arguments) {
        if ($argument.Contains('"') -or $argument.EndsWith('\')) { throw 'Unsupported quote or trailing backslash in an argument.' }
    }
    $info.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    # Do not inherit agent credentials, runtime startup hooks or user package settings.
    $info.EnvironmentVariables.Clear()
    $values = @{
        SystemRoot = $env:SystemRoot; windir = $env:SystemRoot
        PATH = ($sdk + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
        DOTNET_ROOT = $sdk; DOTNET_MULTILEVEL_LOOKUP = '0'; DOTNET_CLI_HOME = (Join-Path $run 'home')
        DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
        DOTNET_CLI_TELEMETRY_OPTOUT = '1'; DOTNET_NOLOGO = '1'; DOTNET_GENERATE_ASPNET_CERTIFICATE = '0'
        DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = '1'; DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
        NUGET_PACKAGES = (Join-Path $run 'nuget')
        USERPROFILE = (Join-Path $run 'home'); HOME = (Join-Path $run 'home')
        APPDATA = (Join-Path $run 'appdata'); LOCALAPPDATA = (Join-Path $run 'localappdata')
        CODEX_HOME = (Join-Path $run 'home/codex-fixture'); TEMP = (Join-Path $run 'temp'); TMP = (Join-Path $run 'temp')
        PSModuleAnalysisCachePath = (Join-Path $run 'cache/ModuleAnalysisCache')
        PSModulePath = ((Join-Path (Split-Path -Parent $pwsh) 'Modules') + ';' + (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules'))
    }
    foreach ($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) { $values[$name] = $value }
    }
    foreach ($key in $values.Keys) { $info.EnvironmentVariables[$key] = [string]$values[$key] }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'An isolated build or test process timed out.' }
        if ($stdout.Result) { Write-Host $stdout.Result.TrimEnd() }
        if ($stderr.Result) { Write-Host $stderr.Result.TrimEnd() }
        if ($process.ExitCode -ne 0) { throw ('An isolated build or test failed with exit code ' + $process.ExitCode) }
    } finally { $process.Dispose() }
}

$obj = ($run.Replace('\','/') + '/obj/')
$bin = ($run.Replace('\','/') + '/bin/')
Invoke-Isolated $dotnet @('build',$project,'--configuration','Release','--configfile',$config,
    ('-p:BaseIntermediateOutputPath=' + $obj),('-p:BaseOutputPath=' + $bin),'-p:NuGetAudit=false','--nologo')
$assembly = Join-Path $run 'bin/Release/net10.0/AITaskMonitor.ProviderState.dll'
if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) { throw 'The native state library was not built.' }
Invoke-Isolated $node @((Join-Path $PSScriptRoot 'Tests/Make-SyntheticProviderFixtures.mjs'),(Join-Path $run 'fixtures'))

foreach ($fixture in @('Test-ExternalProviderState.ps1','Test-HermesObserverState.ps1')) {
    $fixturePath = Join-Path $tests $fixture
    Write-Host ('Framework fixture: ' + $fixture)
    Invoke-Isolated $frameworkShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixturePath)
    Write-Host ('Native fixture: ' + $fixture)
    Invoke-Isolated $pwsh @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Tests/Run-NativeFixture.ps1'),'-AssemblyPath',$assembly,'-FixturePath',$fixturePath)
}
$boundary = Join-Path $PSScriptRoot 'Tests/Test-ParserBoundaries.ps1'
Write-Host 'Framework parser boundaries:'
Invoke-Isolated $frameworkShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$boundary,'-Runtime','framework','-StateSource',$source,'-AssemblyPath',$assembly,'-FixtureDirectory',(Join-Path $run 'fixtures'))
Write-Host 'Native parser boundaries:'
Invoke-Isolated $pwsh @('-NoProfile','-File',$boundary,'-Runtime','native','-StateSource',$source,'-AssemblyPath',$assembly,'-FixtureDirectory',(Join-Path $run 'fixtures'))
Write-Host ('Isolated test artifacts: ' + $run)
