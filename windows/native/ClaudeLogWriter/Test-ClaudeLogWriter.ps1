param(
    [Parameter(Mandatory=$true)][string]$SdkRoot,
    [Parameter(Mandatory=$true)][string]$WorkDirectory,
    [string]$WindowsPowerShell=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe')
)
$ErrorActionPreference='Stop'
function Full([string]$path) { return [IO.Path]::GetFullPath($path).TrimEnd('\','/') }
function IsWithin([string]$path,[string]$root) {
    if([string]::IsNullOrWhiteSpace($root)){return $false}
    $path=Full $path;$root=Full $root
    return $path.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
$sdk=Full $SdkRoot;$work=Full $WorkDirectory;$dotnet=Join-Path $sdk 'dotnet.exe'
$framework=[IO.Path]::GetFullPath($WindowsPowerShell)
foreach($path in @($dotnet,$framework)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'A required SDK or PowerShell executable is missing.'}}
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
foreach($root in @($repository,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA)){
    if(IsWithin $work $root){throw 'Work directory must be outside the repository and user profile.'}
}
$ancestor=[IO.DirectoryInfo]::new($work)
while($null -ne $ancestor){
    if($ancestor.Exists -and (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Reparse-point ancestor is not allowed.'}
    $ancestor=$ancestor.Parent
}
$run=Join-Path $work ('claude-log-writer-tests-'+[guid]::NewGuid().ToString('N'))
foreach($name in @('home','appdata','localappdata','temp','nuget','cache','legacy','fixtures')){New-Item -ItemType Directory -Force -Path (Join-Path $run $name)|Out-Null}
foreach($name in @('ClaudeTaskHook.ps1','ClaudeLoopClient.ps1')){
    $source=Join-Path $repository ('windows/app/'+$name);$destination=Join-Path $run ('legacy/'+$name)
    [IO.File]::Copy($source,$destination,$false)
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -cne (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash){throw 'Synthetic hook copy does not match its source.'}
}
$config=Join-Path $run 'NuGet.Config'
[IO.File]::WriteAllText($config,'<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>')
function Invoke-Isolated([string[]]$arguments){
    foreach($argument in $arguments){if($argument.Contains('"') -or $argument.EndsWith('\')){throw 'Unsupported argument.'}}
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$dotnet;$info.Arguments=($arguments|ForEach-Object{'"'+$_+'"'}) -join ' '
    $info.WorkingDirectory=$run;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.EnvironmentVariables.Clear()
    $values=@{
        SystemRoot=$env:SystemRoot;windir=$env:SystemRoot;PATH=($sdk+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
        DOTNET_ROOT=$sdk;DOTNET_MULTILEVEL_LOOKUP='0';DOTNET_CLI_HOME=(Join-Path $run 'home');DOTNET_CLI_TELEMETRY_OPTOUT='1'
        DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
        DOTNET_NOLOGO='1';DOTNET_GENERATE_ASPNET_CERTIFICATE='0';DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'
        NUGET_PACKAGES=(Join-Path $run 'nuget');USERPROFILE=(Join-Path $run 'home');HOME=(Join-Path $run 'home');CODEX_HOME=(Join-Path $run 'home/codex-fixture')
        APPDATA=(Join-Path $run 'appdata');LOCALAPPDATA=(Join-Path $run 'localappdata');TEMP=(Join-Path $run 'temp');TMP=(Join-Path $run 'temp')
        PSModuleAnalysisCachePath=(Join-Path $run 'cache/ModuleAnalysisCache')
        AITM_LOG_TEST_ROOT=(Join-Path $run 'fixtures')
    }
    foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')){
        $value=[Environment]::GetEnvironmentVariable($name);if(-not [string]::IsNullOrEmpty($value)){$values[$name]=$value}
    }
    foreach($key in $values.Keys){$info.EnvironmentVariables[$key]=[string]$values[$key]}
    $process=[Diagnostics.Process]::Start($info)
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(60000)){$process.Kill();throw 'Synthetic Claude log writer test timed out.'}
        if($process.ExitCode -ne 0){throw "Synthetic Claude log writer test failed:`n$($stdout.Result)`n$($stderr.Result)"}
        if($stdout.Result){Write-Output $stdout.Result.TrimEnd()}
        if($stderr.Result){Write-Output $stderr.Result.TrimEnd()}
    }finally{$process.Dispose()}
}
Invoke-Isolated @('build',(Join-Path $PSScriptRoot 'Tests/ClaudeLogWriter.Tests.csproj'),'--configuration','Release','--configfile',$config,'--artifacts-path',(Join-Path $run 'artifacts'),'-p:NuGetAudit=false','--nologo')
$dll=Join-Path $run 'artifacts/bin/ClaudeLogWriter.Tests/release/AITaskMonitor.ClaudeLogWriter.Tests.dll'
Invoke-Isolated @($dll,(Join-Path $run 'legacy/ClaudeTaskHook.ps1'),(Join-Path $run 'fixtures'),$framework)
Write-Output ('Synthetic artifacts: '+$run)
