$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0') { throw 'A disposable hosted Windows runner is required.' }
function Check([bool]$ok, [string]$message) { if (-not $ok) { throw $message } }
function Test-CleanupIdentity(
    [int]$expectedParent, [DateTime]$parentStart, [int]$observedParent,
    [DateTime]$observedStart, [DateTime]$openedStart,
    [string]$observedPath, [string]$openedPath, [string]$expectedPath
) {
    return ($observedParent -eq $expectedParent -and
        $observedStart -ge $parentStart.AddMilliseconds(-20) -and
        ($observedStart - $openedStart).Duration().TotalMilliseconds -le 20 -and
        [string]::Equals($observedPath,$expectedPath,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($openedPath,$expectedPath,[StringComparison]::OrdinalIgnoreCase))
}
function PathState([string]$scope) {
    $key = if ($scope -eq 'User') { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false) }
        else { [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false) }
    try { return [pscustomobject]@{ Value=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind=[string]$key.GetValueKind('Path') } }
    finally { $key.Dispose() }
}
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
for ($item=[IO.DirectoryInfo]::new($runnerTemp); $null -ne $item; $item=$item.Parent) {
    Check ($item.Exists -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Runner temp has a redirected ancestor.'
}
$root = [IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-legacy-uninstall-' + [Guid]::NewGuid().ToString('N'))))
Check ([string]::Equals([IO.Directory]::GetParent($root).FullName, $runnerTemp, [StringComparison]::OrdinalIgnoreCase) -and
    -not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'Unsafe synthetic root.'
$beforeUser=PathState 'User'; $beforeMachine=PathState 'Machine'; $beforeProcess=[Environment]::GetEnvironmentVariable('Path','Process')
try {
    [void][IO.Directory]::CreateDirectory($root)
    $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Released-Uninstall-v0.2.7.ps1'))
    Check ([IO.File]::Exists($source)) 'Legacy uninstaller source is missing.'
    # Compare the test fixture with the blob in the released v0.2.7-alpha source.
    # The separate published EXE check verifies the embedded release resource.
    $repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $blob=(git -C $repository hash-object -- .github/legacy-uninstall-ci/Released-Uninstall-v0.2.7.ps1).Trim()
    Check ($LASTEXITCODE -eq 0 -and $blob -ceq '7896cf57683b9ba76243640532c83d930844a2ca') 'Legacy uninstaller differs from the pinned release source.'
    $sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $powershell=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $now=[DateTime]::UtcNow
    $wrongPath=Join-Path $root 'different.exe'
    Check (Test-CleanupIdentity 7 $now 7 $now $now $powershell $powershell $powershell) 'Matching process identity was rejected.'
    Check (-not (Test-CleanupIdentity 7 $now 8 $now $now $powershell $powershell $powershell)) 'Incorrect parent was accepted.'
    Check (-not (Test-CleanupIdentity 7 $now 7 $now $now.AddSeconds(1) $powershell $powershell $powershell)) 'Incorrect process creation time was accepted.'
    Check (-not (Test-CleanupIdentity 7 $now 7 $now $now $wrongPath $powershell $powershell)) 'Incorrect observed process path was accepted.'
    Check (-not (Test-CleanupIdentity 7 $now 7 $now $now $powershell $wrongPath $powershell)) 'Incorrect opened process path was accepted.'
    # Warm the provider before starting a two-second cleanup process.
    $null=Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $PID) -Property ProcessId
    $results=[Collections.Generic.List[object]]::new()
    foreach ($scenario in @('nested-junction','root-junction')) {
        Write-Output ('Starting synthetic scenario: ' + $scenario)
        $case=[IO.Path]::GetFullPath((Join-Path $root $scenario))
        $local=Join-Path $case 'local'; $profile=Join-Path $case 'profile'; $appdata=Join-Path $case 'appdata'
        $temp=Join-Path $case 'temp'; $external=Join-Path $case 'external'
        foreach ($dir in @($local,$profile,$appdata,$temp,$external)) { [void][IO.Directory]::CreateDirectory($dir) }
        $install=[IO.Path]::GetFullPath((Join-Path $local 'AITaskMonitor'))
        Check ([string]::Equals([IO.Directory]::GetParent($case).FullName,$root,[StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([IO.Directory]::GetParent($install).FullName,$local,[StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([IO.Directory]::GetParent($external).FullName,$case,[StringComparison]::OrdinalIgnoreCase)) 'Fixture escaped synthetic root.'
        if ($scenario -eq 'root-junction') {
            $null=New-Item -ItemType Junction -Path $install -Target $external
            $junction=$install
        } else {
            [void][IO.Directory]::CreateDirectory($install)
            $junction=Join-Path $install 'linked'
            $null=New-Item -ItemType Junction -Path $junction -Target $external
        }
        $link=Get-Item -LiteralPath $junction -Force
        Check (($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and
            [string]::Equals([IO.Path]::GetFullPath([string]$link.Target),$external,[StringComparison]::OrdinalIgnoreCase)) 'Fixture junction did not target synthetic data.'
        $sentinel=Join-Path $external 'unrelated.txt'
        $sentinelBytes=[Text.Encoding]::UTF8.GetBytes('synthetic outside data')
        [IO.File]::WriteAllBytes($sentinel,$sentinelBytes)
        $uninstaller=Join-Path $install 'Uninstall-CodexProgress.ps1'
        Copy-Item -LiteralPath $source -Destination $uninstaller
        Check ((Get-FileHash -LiteralPath $uninstaller -Algorithm SHA256).Hash -ceq $sourceHash) 'Copied uninstaller differs from source.'
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$powershell; $start.WorkingDirectory=$case
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.Environment.Clear()
        $values=@{
            SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
            PATH=((Split-Path -Parent $powershell) + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
            USERPROFILE=$profile; APPDATA=$appdata; LOCALAPPDATA=$local; TEMP=$temp; TMP=$temp
            PSModulePath=((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules') + ';' + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))
            DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
        }
        foreach ($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')) {
            $value=[Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrEmpty($value)) { $values[$name]=$value }
        }
        foreach ($key in $values.Keys) { $start.Environment[$key]=[string]$values[$key] }
        # Establish that Windows PowerShell itself starts under the same isolated environment.
        $probe=[Diagnostics.ProcessStartInfo]::new()
        $probe.FileName=$powershell; $probe.WorkingDirectory=$case; $probe.UseShellExecute=$false; $probe.CreateNoWindow=$true
        $probe.Environment.Clear()
        foreach ($key in $values.Keys) { $probe.Environment[$key]=[string]$values[$key] }
        foreach ($arg in @('-NoProfile','-NonInteractive','-Command','exit 0')) { [void]$probe.ArgumentList.Add($arg) }
        $probeProcess=[Diagnostics.Process]::Start($probe)
        try {
            if (-not $probeProcess.WaitForExit(12000)) { throw 'Synthetic PowerShell startup timed out.' }
            Check ($probeProcess.ExitCode -eq 0) 'Synthetic PowerShell startup failed.'
        } finally { $probeProcess.Dispose() }
        Write-Output 'Synthetic PowerShell startup succeeded.'
        foreach ($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$uninstaller)) { [void]$start.ArgumentList.Add($arg) }
        # The released script launches this command asynchronously. Identify and wait for
        # that exact synthetic cleanup. Keep the opened process handle through the wait;
        # never act on a PID after a timeout.
        $literalTarget=$install.Replace("'","''")
        $cleanupCommand="Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$literalTarget' -Recurse -Force"
        $cleanupEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupCommand))
        $process=[Diagnostics.Process]::Start($start)
        $cleanupProcess=$null
        try {
            $ownerId=$process.Id
            $ownerStart=$process.StartTime.ToUniversalTime()
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $candidate=$null
            while ($null -eq $candidate -and $clock.Elapsed.TotalSeconds -lt 15) {
                $matches=@(Get-CimInstance Win32_Process -Filter ("Name = 'powershell.exe' AND ParentProcessId = " + $ownerId) -Property ProcessId,ParentProcessId,CreationDate,ExecutablePath,CommandLine |
                    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($cleanupEncoded) })
                Check ($matches.Count -le 1) 'More than one synthetic cleanup matched.'
                if ($matches.Count -eq 1) { $candidate=$matches[0]; break }
                if ($process.HasExited -and $process.ExitCode -ne 0) { throw 'Synthetic uninstaller failed before cleanup was observed.' }
                Start-Sleep -Milliseconds 50
            }
            Check ($null -ne $candidate) 'The synthetic cleanup process could not be identified in time.'
            try {
                $observedStart=([DateTime]$candidate.CreationDate).ToUniversalTime()
                $observedPath=[IO.Path]::GetFullPath([string]$candidate.ExecutablePath)
                $cleanupProcess=[Diagnostics.Process]::GetProcessById([int]$candidate.ProcessId)
                $cleanupHandle=$cleanupProcess.SafeHandle
                Check (-not $cleanupHandle.IsInvalid -and -not $cleanupHandle.IsClosed) 'The cleanup process handle is unavailable.'
                $openedStart=$cleanupProcess.StartTime.ToUniversalTime()
                $openedPath=[IO.Path]::GetFullPath($cleanupProcess.MainModule.FileName)
            } catch { throw 'The synthetic cleanup process could not be safely opened and identified.' }
            Check (Test-CleanupIdentity $ownerId $ownerStart ([int]$candidate.ParentProcessId) $observedStart $openedStart $observedPath $openedPath $powershell) 'The opened cleanup process identity does not match the observed process.'
            if (-not $process.WaitForExit(20000)) { throw 'Synthetic uninstaller timed out.' }
            $exit=$process.ExitCode
            Check ($exit -eq 0) 'Synthetic uninstaller returned a nonzero exit code.'
            Check ($observedStart -le $process.ExitTime.ToUniversalTime().AddMilliseconds(20)) 'Cleanup started after the uninstaller exited.'
            if (-not $cleanupProcess.WaitForExit(20000)) { throw 'The synthetic cleanup timed out.' }
            $cleanupExit=$cleanupProcess.ExitCode
            Check ($cleanupExit -eq 0) 'Synthetic cleanup returned a nonzero exit code.'
        } finally {
            if ($null -ne $cleanupProcess) { $cleanupProcess.Dispose() }
            $process.Dispose()
        }
        Check (-not [IO.Directory]::Exists($install)) 'The synthetic installation directory was not removed.'
        $preserved=[IO.File]::Exists($sentinel)
        if ($preserved) { $preserved=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel)) -ceq [Convert]::ToBase64String($sentinelBytes) }
        $results.Add([pscustomobject]@{ Scenario=$scenario; Exit=$exit; CleanupExit=$cleanupExit; ExternalPreserved=$preserved })
    }
    foreach ($result in $results) { Write-Output ('Legacy uninstall {0}: exit {1}, cleanup exit {2}, outside synthetic file preserved {3}.' -f $result.Scenario,$result.Exit,$result.CleanupExit,$result.ExternalPreserved) }
    Check (@($results | Where-Object { -not $_.ExternalPreserved }).Count -eq 0) 'Legacy uninstall changed data outside its synthetic installation.'
} finally {
    foreach ($scope in @('User','Machine')) {
        $before=if ($scope -eq 'User') { $beforeUser } else { $beforeMachine }
        $after=PathState $scope
        if ($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind) { throw "$scope PATH changed during the synthetic check." }
    }
    if ([Environment]::GetEnvironmentVariable('Path','Process') -cne $beforeProcess) { throw 'Process PATH changed during the synthetic check.' }
}
