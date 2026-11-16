param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0') {
    throw 'Disposable hosted Windows is required.'
}
$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
if ([IO.Directory]::GetParent($root).FullName -cne $runnerTemp -or
    [IO.Path]::GetFileName($root) -cnotmatch '^aitm-cloud-command-[0-9a-f]{32}$' -or
    -not [IO.Directory]::Exists($root)) { throw 'Synthetic test root rejected.' }
for($item=New-Object IO.DirectoryInfo($root); $null -ne $item; $item=$item.Parent) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Redirected root rejected.' }
}
$expectedTemp=Join-Path $root 'isolated\temp'
if ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -cne $expectedTemp) {
    throw 'Synthetic temporary directory rejected.'
}
$original=Join-Path $root 'original-cwd-legacy'
if ([IO.Path]::GetFullPath([Environment]::CurrentDirectory).TrimEnd('\') -cne $original) {
    throw 'Synthetic initial directory rejected.'
}
$sentinel=Join-Path $original 'error.log'
[IO.File]::WriteAllText($sentinel,'synthetic-original')
$fixture=Join-Path $root 'legacy-synthetic-cloud.exe'
if ([IO.File]::Exists($fixture) -or [IO.Directory]::Exists($fixture)) { throw 'Synthetic executable exists.' }
$program=@'
using System;
using System.IO;
public static class SyntheticCloud {
    public static int Main(string[] args) {
        if (Environment.GetEnvironmentVariable("CI") != "true" ||
            Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
            Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" ||
            Environment.GetEnvironmentVariable("RUNNER_OS") != "Windows" ||
            Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") != "0") return 20;
        string fixtureRoot=Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd('\\');
        string runnerTemp=Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP")).TrimEnd('\\');
        DirectoryInfo rootParent=Directory.GetParent(fixtureRoot);
        if (rootParent == null || !String.Equals(rootParent.FullName,runnerTemp,StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFileName(fixtureRoot).StartsWith("aitm-cloud-command-",StringComparison.Ordinal)) return 24;
        File.WriteAllText(Path.Combine(fixtureRoot,"legacy-launched.txt"),"synthetic-started");
        if (args.Length != 5 || args[0] != "cloud" || args[1] != "list" ||
            args[2] != "--json" || args[3] != "--limit" || args[4] != "20") return 21;
        string temp=Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\');
        string cwd=Path.GetFullPath(Environment.CurrentDirectory).TrimEnd('\\');
        DirectoryInfo parent=Directory.GetParent(cwd);
        string name=Path.GetFileName(cwd);
        if (parent == null || !String.Equals(parent.FullName,temp,StringComparison.OrdinalIgnoreCase) ||
            !name.StartsWith("aitm-cloud-",StringComparison.Ordinal) || name.Length != 43) return 22;
        try {
            using (var file=new FileStream("error.log",FileMode.Append,FileAccess.Write)) { }
            return 23;
        }
        catch (UnauthorizedAccessException) { }
        Console.Write("{\"tasks\":[],\"cursor\":null}");
        return 0;
    }
}
'@
Add-Type -TypeDefinition $program -OutputAssembly $fixture -OutputType ConsoleApplication
$source=Join-Path $PSScriptRoot '..\..\windows\app\integrations\CodexCloudProcess.cs'
Add-Type -Path $source
$request=New-Object AITaskMonitor.CodexCloud.Command($fixture,$null,15000)
$deadline=[DateTime]::UtcNow.AddSeconds(20)
while(-not $request.Completed -and [DateTime]::UtcNow -lt $deadline){ Start-Sleep -Milliseconds 20 }
if(-not $request.Completed){ $request.Cancel(); throw 'Legacy synthetic process timed out.' }
$result=$request.GetResult()
$request.Dispose()
if(-not $result.Ok -or $result.Json -cne '{"tasks":[],"cursor":null}') { throw 'Legacy protected process failed.' }
if([IO.File]::ReadAllText($sentinel) -cne 'synthetic-original') { throw 'Original directory changed.' }
if(@([IO.Directory]::GetDirectories($expectedTemp,'aitm-cloud-*')).Count -ne 0) { throw 'Completed workspace remained.' }
$marker=Join-Path $root 'legacy-launched.txt'
if(-not [IO.File]::Exists($marker)) { throw 'Synthetic child did not run.' }
[IO.File]::Delete($marker)
$oldTemp=[Environment]::GetEnvironmentVariable('TEMP')
$oldTmp=[Environment]::GetEnvironmentVariable('TMP')
$missing=Join-Path $root 'missing-temp-legacy'
if([IO.Directory]::Exists($missing)) { throw 'Unexpected synthetic temp.' }
try {
    [Environment]::SetEnvironmentVariable('TEMP',$missing)
    [Environment]::SetEnvironmentVariable('TMP',$missing)
    $failed=New-Object AITaskMonitor.CodexCloud.Command($fixture,$null,15000)
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while(-not $failed.Completed -and [DateTime]::UtcNow -lt $deadline){ Start-Sleep -Milliseconds 20 }
    if(-not $failed.Completed){ $failed.Cancel(); throw 'Legacy failure test timed out.' }
    $failedResult=$failed.GetResult()
    $failed.Dispose()
    if($failedResult.Ok -or [IO.File]::Exists($marker)) { throw 'Unsafe legacy launch was not blocked.' }
} finally {
    [Environment]::SetEnvironmentVariable('TEMP',$oldTemp)
    [Environment]::SetEnvironmentVariable('TMP',$oldTmp)
}
if([IO.File]::ReadAllText($sentinel) -cne 'synthetic-original') { throw 'Failed setup changed original directory.' }
Write-Output 'Legacy Cloud workspace: protected child, original sentinel and cleanup passed.'
