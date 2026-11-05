param(
    [Parameter(Mandatory=$true)][string]$SdkRoot,
    [Parameter(Mandatory=$true)][string]$WorkDirectory,
    [Parameter(Mandatory=$true)][string]$ReferenceSource,
    [string]$WindowsPowerShell=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe')
)
$ErrorActionPreference='Stop'
function Full([string]$path){return [IO.Path]::GetFullPath($path).TrimEnd('\','/')}
function IsWithin([string]$path,[string]$root){
    if([string]::IsNullOrWhiteSpace($root)){return $false}
    $path=Full $path;$root=Full $root
    return $path.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
$sdk=Full $SdkRoot;$work=Full $WorkDirectory;$dotnet=Join-Path $sdk 'dotnet.exe'
$reference=[IO.Path]::GetFullPath($ReferenceSource);$framework=[IO.Path]::GetFullPath($WindowsPowerShell)
foreach($path in @($dotnet,$framework,$reference)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'A required SDK, reference or PowerShell executable is missing.'}}
$expectedReference='DD9A401DFABDFC68623A8503746EF7808F154C0E606588CE9143F07A31FEDDB8'
if((Get-FileHash -Algorithm SHA256 -LiteralPath $reference).Hash -cne $expectedReference){throw 'The pinned PowerShell reference hash does not match.'}
foreach($profile in @($env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA)){if(IsWithin $work $profile){throw 'The work directory is inside user data.'}}
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if(IsWithin $work $repository){throw 'The work directory is inside the repository.'}
$ancestor=[IO.DirectoryInfo]::new($work)
while($null -ne $ancestor){
    if($ancestor.Exists -and (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'A reparse-point ancestor is not allowed.'}
    $ancestor=$ancestor.Parent
}
$run=Join-Path $work ('codex-index-tests-'+[guid]::NewGuid().ToString('N'))
foreach($name in @('home','appdata','localappdata','temp','nuget','cache','legacy','native')){
    New-Item -ItemType Directory -Force -Path (Join-Path $run $name)|Out-Null
}
$config=Join-Path $run 'NuGet.Config'
[IO.File]::WriteAllText($config,'<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>')
function Invoke-Isolated([string]$executable,[string[]]$arguments){
    foreach($argument in $arguments){if($argument.Contains('"') -or $argument.EndsWith('\')){throw 'Unsupported test argument.'}}
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$executable;$info.Arguments=($arguments|ForEach-Object{'"'+$_+'"'}) -join ' '
    $info.WorkingDirectory=$run;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.EnvironmentVariables.Clear()
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $values=@{
        SystemRoot=$env:SystemRoot;windir=$env:SystemRoot;PATH=($sdk+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
        DOTNET_ROOT=$sdk;DOTNET_MULTILEVEL_LOOKUP='0';DOTNET_CLI_HOME=(Join-Path $run 'home');DOTNET_CLI_TELEMETRY_OPTOUT='1'
        DOTNET_NOLOGO='1';DOTNET_GENERATE_ASPNET_CERTIFICATE='0';DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'
        NUGET_PACKAGES=(Join-Path $run 'nuget');USERPROFILE=(Join-Path $run 'home');HOME=(Join-Path $run 'home');CODEX_HOME=(Join-Path $run 'home/codex-fixture')
        APPDATA=(Join-Path $run 'appdata');LOCALAPPDATA=(Join-Path $run 'localappdata');TEMP=(Join-Path $run 'temp');TMP=(Join-Path $run 'temp')
        PSModuleAnalysisCachePath=(Join-Path $run 'cache/ModuleAnalysisCache');PSModulePath=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')
    }
    foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')){
        $value=[Environment]::GetEnvironmentVariable($name);if(-not [string]::IsNullOrEmpty($value)){$values[$name]=$value}
    }
    foreach($key in $values.Keys){$info.EnvironmentVariables[$key]=[string]$values[$key]}
    $process=[Diagnostics.Process]::Start($info)
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if(-not $process.WaitForExit(90000)){$process.Kill();throw 'The synthetic index test timed out.'}
        if($process.ExitCode -ne 0){throw "Synthetic index test failed:`n$($stdout.Result)`n$($stderr.Result)"}
        if($stderr.Result){Write-Host $stderr.Result.TrimEnd()}
        return [string]$stdout.Result
    }finally{$process.Dispose()}
}
$build=Invoke-Isolated $dotnet @('build',(Join-Path $PSScriptRoot 'Tests/CodexIndex.Tests.csproj'),'--configuration','Release',
    '--configfile',$config,'--artifacts-path',(Join-Path $run 'artifacts'),'-p:NuGetAudit=false','--nologo')
Write-Host $build.TrimEnd()
$copiedReference=Join-Path $run 'pinned-CodexProgress.ps1'
[IO.File]::Copy($reference,$copiedReference,$false)
if((Get-FileHash -Algorithm SHA256 -LiteralPath $copiedReference).Hash -cne $expectedReference){throw 'The reference copy hash does not match.'}
$fixtures=Invoke-Isolated $framework @('-NoProfile','-ExecutionPolicy','Bypass','-File',
    (Join-Path $PSScriptRoot 'Tests/Write-IndexFixtures.ps1'),'-ReferenceSource',$copiedReference,'-FixtureRoot',(Join-Path $run 'legacy'))
$fixturePath=Join-Path $run 'synthetic-fixtures.json'
[IO.File]::WriteAllText($fixturePath,$fixtures,[Text.UTF8Encoding]::new($false))
$dll=Join-Path $run 'artifacts/bin/CodexIndex.Tests/release/AITaskMonitor.CodexIndex.Tests.dll'
$result=Invoke-Isolated $dotnet @($dll,$fixturePath,(Join-Path $run 'native'))
Write-Host $result.TrimEnd()
Write-Host ('Synthetic artifacts: '+$run)
