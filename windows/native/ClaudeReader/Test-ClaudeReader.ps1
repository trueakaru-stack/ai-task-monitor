param(
    [Parameter(Mandatory=$true)][string]$SdkRoot,
    [Parameter(Mandatory=$true)][string]$WorkDirectory,
    [Parameter(Mandatory=$true)][string]$PwshNet10,
    [string]$WindowsPowerShell = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
)
$ErrorActionPreference='Stop'
function FullPath([string]$path){return [IO.Path]::GetFullPath($path).TrimEnd('\','/')}
function IsWithin([string]$path,[string]$root){
    if([string]::IsNullOrWhiteSpace($root)){return $false}
    $path=FullPath $path;$root=FullPath $root
    return $path.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
$sdk=FullPath $SdkRoot;$work=FullPath $WorkDirectory
$dotnet=Join-Path $sdk 'dotnet.exe';$pwsh=[IO.Path]::GetFullPath($PwshNet10)
$framework=[IO.Path]::GetFullPath($WindowsPowerShell)
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$source=Join-Path $repository 'windows/app/ClaudeReaderCore.ps1'
$reader=Join-Path $PSScriptRoot 'Reader.cs'
$tests=Join-Path $repository 'windows/tests/Test-ClaudeReader.ps1'
foreach($file in @($dotnet,$pwsh,$framework,$source,$reader,$tests)){
    if(-not (Test-Path -LiteralPath $file -PathType Leaf)){throw 'A test prerequisite is missing.'}
}
foreach($root in @($repository,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA)){
    if(IsWithin $work $root){throw 'The test directory must be outside the repository and user profile.'}
}
$ancestor=[IO.DirectoryInfo]::new($work)
while($null -ne $ancestor){
    if($ancestor.Exists -and (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){
        throw 'The test directory must not have a reparse-point ancestor.'
    }
    $ancestor=$ancestor.Parent
}
$existing=[IO.File]::ReadAllText($source)
$match=[regex]::Match($existing,"(?ms)-TypeDefinition @'\r?\n(?<code>.*?)\r?\n'@")
if(-not $match.Success){throw 'The existing embedded reader could not be found.'}
$expected=$match.Groups['code'].Value.Replace("`r`n","`n").TrimEnd("`r","`n")
$actual=[IO.File]::ReadAllText($reader).Replace("`r`n","`n").TrimEnd("`r","`n")
if(-not [string]::Equals($actual,$expected,[StringComparison]::Ordinal)){
    throw 'The native reader differs from the published embedded reader.'
}
$run=Join-Path $work ('claude-reader-tests-'+[Guid]::NewGuid().ToString('N'))
foreach($folder in @('home','appdata','localappdata','temp','nuget','cache')){
    New-Item -ItemType Directory -Force -Path (Join-Path $run $folder) | Out-Null
}
$config=Join-Path $run 'NuGet.Config'
[IO.File]::WriteAllText($config,'<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>')
function Invoke-Isolated([string]$executable,[string[]]$arguments){
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$executable;$info.WorkingDirectory=$run
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $arguments){if($argument.Contains('"') -or $argument.EndsWith('\')){throw 'Unsupported test argument.'}}
    $info.Arguments=($arguments | ForEach-Object {'"'+$_+'"'}) -join ' '
    $info.EnvironmentVariables.Clear()
    $values=@{
        SystemRoot=$env:SystemRoot;windir=$env:SystemRoot
        PATH=($sdk+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
        DOTNET_ROOT=$sdk;DOTNET_MULTILEVEL_LOOKUP='0';DOTNET_CLI_HOME=(Join-Path $run 'home')
        DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
        DOTNET_CLI_TELEMETRY_OPTOUT='1';DOTNET_NOLOGO='1';DOTNET_GENERATE_ASPNET_CERTIFICATE='0'
        DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1';DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'
        NUGET_PACKAGES=(Join-Path $run 'nuget');USERPROFILE=(Join-Path $run 'home');HOME=(Join-Path $run 'home')
        APPDATA=(Join-Path $run 'appdata');LOCALAPPDATA=(Join-Path $run 'localappdata')
        CODEX_HOME=(Join-Path $run 'home/codex-fixture');TEMP=(Join-Path $run 'temp');TMP=(Join-Path $run 'temp')
        PSModuleAnalysisCachePath=(Join-Path $run 'cache/ModuleAnalysisCache')
        PSModulePath=((Join-Path (Split-Path -Parent $pwsh) 'Modules')+';'+(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules'))
    }
    foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')){
        $value=[Environment]::GetEnvironmentVariable($name)
        if(-not [string]::IsNullOrEmpty($value)){$values[$name]=$value}
    }
    foreach($key in $values.Keys){$info.EnvironmentVariables[$key]=[string]$values[$key]}
    $process=[Diagnostics.Process]::Start($info)
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(60000)){$process.Kill();throw 'An isolated build or test timed out.'}
        if($process.ExitCode -ne 0){throw "Isolated process failed ($($process.ExitCode)).`n$($stdout.Result)`n$($stderr.Result)"}
        if($stdout.Result){Write-Host $stdout.Result.TrimEnd()}
        if($stderr.Result){Write-Host $stderr.Result.TrimEnd()}
    }finally{$process.Dispose()}
}
Invoke-Isolated $dotnet @('build',(Join-Path $PSScriptRoot 'ClaudeReader.csproj'),
    '--configuration','Release','--configfile',$config,'--artifacts-path',(Join-Path $run 'artifacts'),
    '-p:NuGetAudit=false','--nologo')
$assembly=Join-Path $run 'artifacts/bin/ClaudeReader/release/AITaskMonitor.ClaudeReader.dll'
if(-not (Test-Path -LiteralPath $assembly -PathType Leaf)){throw 'The native reader was not built.'}
Invoke-Isolated $framework @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$tests)
Invoke-Isolated $pwsh @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Run-NativeReaderTests.ps1'),
    '-Assembly',$assembly,'-Tests',$tests)
Write-Host ('Copied source matched; isolated test artifacts: '+$run)
