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
foreach($profile in @($env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA)){if(IsWithin $work $profile){throw 'Work directory is inside user data.'}}
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if(IsWithin $work $repository){throw 'Work directory is inside the repository.'}
$ancestor=[IO.DirectoryInfo]::new($work)
while($null -ne $ancestor){
    if($ancestor.Exists -and (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Reparse-point ancestor is not allowed.'}
    $ancestor=$ancestor.Parent
}
$run=Join-Path $work ('codex-discovery-tests-'+[guid]::NewGuid().ToString('N'))
foreach($name in @('home','appdata','localappdata','temp','nuget','cache','legacy','native')){
    New-Item -ItemType Directory -Force -Path (Join-Path $run $name)|Out-Null
}
$config=Join-Path $run 'NuGet.Config'
[IO.File]::WriteAllText($config,'<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>')
function Invoke-Isolated([string]$executable,[string[]]$arguments,[string]$inputText=''){
    foreach($argument in $arguments){if($argument.Contains('"') -or $argument.EndsWith('\')){throw 'Unsupported test argument.'}}
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$executable;$info.Arguments=($arguments|ForEach-Object{'"'+$_+'"'}) -join ' '
    $info.WorkingDirectory=$run;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.EnvironmentVariables.Clear()
    $values=@{
        SystemRoot=$env:SystemRoot;windir=$env:SystemRoot;PATH=($sdk+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
        DOTNET_ROOT=$sdk;DOTNET_MULTILEVEL_LOOKUP='0';DOTNET_CLI_HOME=(Join-Path $run 'home');DOTNET_CLI_TELEMETRY_OPTOUT='1'
        DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
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
        if($inputText){$process.StandardInput.Write($inputText)}
        $process.StandardInput.Close()
        if(-not $process.WaitForExit(90000)){$process.Kill();throw 'Synthetic discovery test timed out.'}
        if($process.ExitCode -ne 0){throw "Synthetic discovery test failed:`n$($stdout.Result)`n$($stderr.Result)"}
        if($stderr.Result){Write-Host $stderr.Result.TrimEnd()}
        return [string]$stdout.Result
    }finally{$process.Dispose()}
}
$build=Invoke-Isolated $dotnet @('build',(Join-Path $PSScriptRoot 'Tests/CodexDiscovery.Tests.csproj'),'--configuration','Release',
    '--configfile',$config,'--artifacts-path',(Join-Path $run 'artifacts'),'-p:NuGetAudit=false','--nologo')
Write-Host $build.TrimEnd()
$referenceSuite=Join-Path $run 'reference-suite'
foreach($name in @('app','tests')){New-Item -ItemType Directory -Path (Join-Path $referenceSuite $name)|Out-Null}
$originalTest=Join-Path $repository 'windows/tests/Test-CodexSessionDiscovery.ps1'
$copiedTest=Join-Path $referenceSuite 'tests/Test-CodexSessionDiscovery.ps1'
$copiedReference=Join-Path $referenceSuite 'app/CodexProgress.ps1'
[IO.File]::Copy($originalTest,$copiedTest,$false)
[IO.File]::Copy($reference,$copiedReference,$false)
foreach($pair in @(@($originalTest,$copiedTest),@($reference,$copiedReference))){
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $pair[0]).Hash -cne (Get-FileHash -Algorithm SHA256 -LiteralPath $pair[1]).Hash){throw 'Reference copy verification failed.'}
}
$legacy=Invoke-Isolated $framework @('-NoProfile','-ExecutionPolicy','Bypass','-File',$copiedTest)
Write-Host $legacy.TrimEnd()
$fixtures=Invoke-Isolated $framework @('-NoProfile','-ExecutionPolicy','Bypass','-File',
    (Join-Path $PSScriptRoot 'Tests/Write-DiscoveryFixtures.ps1'),'-ReferenceSource',$copiedReference,'-FixtureRoot',(Join-Path $run 'legacy'))
$dll=Join-Path $run 'artifacts/bin/CodexDiscovery.Tests/release/AITaskMonitor.CodexDiscovery.Tests.dll'
$result=Invoke-Isolated $dotnet @($dll,(Join-Path $run 'native')) $fixtures
Write-Host $result.TrimEnd()
Write-Host ('Synthetic artifacts: '+$run)
