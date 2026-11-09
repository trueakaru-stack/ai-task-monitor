param(
    [Parameter(Mandatory=$true)][string]$SdkRoot,
    [Parameter(Mandatory=$true)][string]$WorkDirectory,
    [Parameter(Mandatory=$true)][string]$ReferenceSource,
    [string]$WindowsPowerShell = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
)
$ErrorActionPreference = 'Stop'

function FullPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -le $root.Length) { return $root }
    return $full.TrimEnd('\','/')
}
function IsWithin([string]$path, [string]$root) {
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    $path = FullPath $path; $root = FullPath $root
    $prefix = if ($root.EndsWith('\') -or $root.EndsWith('/')) { $root } else { $root + [IO.Path]::DirectorySeparatorChar }
    return $path.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
}

$sdk = FullPath $SdkRoot
$work = FullPath $WorkDirectory
$dotnet = Join-Path $sdk 'dotnet.exe'
$reference = [IO.Path]::GetFullPath($ReferenceSource)
$framework = [IO.Path]::GetFullPath($WindowsPowerShell)
foreach ($path in @($dotnet,$reference,$framework)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A required SDK, reference source or PowerShell executable is missing.' }
}
function ProtectedDirectory([string]$name, [bool]$required) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($required) { throw 'A required protected directory is unavailable.' }
        return $null
    }
    if ($value -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)' -or
        $value.StartsWith('\\?\') -or $value.StartsWith('\\.\')) {
        throw 'A protected directory is not absolute.'
    }
    $resolved = FullPath $value
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw 'A protected directory is unavailable.' }
    return $resolved
}
foreach ($name in @('USERPROFILE','APPDATA','LOCALAPPDATA','HOME','CODEX_HOME')) {
    $profilePath = ProtectedDirectory $name ($name -in @('USERPROFILE','APPDATA','LOCALAPPDATA'))
    if ($profilePath -and (IsWithin $work $profilePath)) { throw 'The work directory must be outside protected directories.' }
}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if (IsWithin $work $repository) { throw 'The work directory must be outside the repository.' }
$ancestor = [IO.DirectoryInfo]::new($work)
while ($null -ne $ancestor) {
    if ($ancestor.Exists -and (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'The work directory must not have a reparse-point ancestor.'
    }
    $ancestor = $ancestor.Parent
}

$run = Join-Path $work ('codex-state-tests-' + [Guid]::NewGuid().ToString('N'))
foreach ($name in @('home','appdata','localappdata','temp','nuget','cache')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $run $name) | Out-Null
}
$config = Join-Path $run 'NuGet.Config'
[IO.File]::WriteAllText($config, '<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>')

function Invoke-Isolated([string]$executable,[string[]]$arguments,[string]$inputText='') {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $executable; $info.WorkingDirectory = $run
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($argument in $arguments) {
        if ($argument.Contains('"') -or $argument.EndsWith('\')) { throw 'Unsupported quote or trailing backslash in a test argument.' }
    }
    $info.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.EnvironmentVariables.Clear()
    $values = @{
        SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
        PATH=($sdk + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
        DOTNET_ROOT=$sdk; DOTNET_MULTILEVEL_LOOKUP='0'; DOTNET_CLI_HOME=(Join-Path $run 'home')
        DOTNET_CLI_TELEMETRY_OPTOUT='1'; DOTNET_NOLOGO='1'; DOTNET_GENERATE_ASPNET_CERTIFICATE='0'
        DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'; DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'
        NUGET_PACKAGES=(Join-Path $run 'nuget'); USERPROFILE=(Join-Path $run 'home')
        APPDATA=(Join-Path $run 'appdata'); LOCALAPPDATA=(Join-Path $run 'localappdata')
        TEMP=(Join-Path $run 'temp'); TMP=(Join-Path $run 'temp')
        PSModuleAnalysisCachePath=(Join-Path $run 'cache/ModuleAnalysisCache')
        PSModulePath=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')
    }
    foreach ($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) { $values[$name] = $value }
    }
    foreach ($key in $values.Keys) { $info.EnvironmentVariables[$key] = [string]$values[$key] }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if ($inputText) { $process.StandardInput.Write($inputText) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'An isolated build or test process timed out.' }
        if ($process.ExitCode -ne 0) { throw "Isolated process failed ($($process.ExitCode)).`n$($stdout.Result)`n$($stderr.Result)" }
        if ($stderr.Result) { Write-Host $stderr.Result.TrimEnd() }
        return [string]$stdout.Result
    } finally { $process.Dispose() }
}

$build = Invoke-Isolated $dotnet @('build',(Join-Path $PSScriptRoot 'Tests/Codex.Tests.csproj'),
    '--configuration','Release','--configfile',$config,'--artifacts-path',(Join-Path $run 'artifacts'),
    '-p:NuGetAudit=false','--nologo')
Write-Host $build.TrimEnd()
$assembly = Join-Path $run 'artifacts/bin/Codex.Tests/release/AITaskMonitor.CodexState.Tests.dll'
if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) { throw 'The synthetic test executable was not built.' }
$fixtures = Invoke-Isolated $framework @('-NoProfile','-ExecutionPolicy','Bypass','-File',
    (Join-Path $PSScriptRoot 'Tests/Write-LifecycleFixtures.ps1'),'-ReferenceSource',$reference)
$result = Invoke-Isolated $dotnet @($assembly) $fixtures
Write-Host $result.TrimEnd()
Write-Host ('Isolated test artifacts: ' + $run)
