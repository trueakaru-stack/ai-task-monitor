$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0') { throw 'A disposable hosted Windows runner is required.' }
function Check([bool]$ok, [string]$message) { if (-not $ok) { throw $message } }
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
    $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\windows\app\Uninstall-CodexProgress.ps1'))
    Check ([IO.File]::Exists($source)) 'Legacy uninstaller source is missing.'
    $sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $results=[Collections.Generic.List[object]]::new()
    foreach ($scenario in @('nested-junction','root-junction')) {
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
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        $start.Environment.Clear()
        $values=@{
            SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
            PATH=((Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
            USERPROFILE=$profile; APPDATA=$appdata; LOCALAPPDATA=$local; TEMP=$temp; TMP=$temp
            DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
        }
        foreach ($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')) {
            $value=[Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrEmpty($value)) { $values[$name]=$value }
        }
        foreach ($key in $values.Keys) { $start.Environment[$key]=[string]$values[$key] }
        foreach ($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$uninstaller)) { [void]$start.ArgumentList.Add($arg) }
        $process=[Diagnostics.Process]::Start($start)
        try {
            $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(20000)) { $process.Kill($true); throw 'Synthetic uninstaller timed out.' }
            $exit=$process.ExitCode
        } finally { $process.Dispose() }
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while ([IO.File]::Exists($uninstaller) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Start-Sleep -Milliseconds 500
        $preserved=[IO.File]::Exists($sentinel)
        if ($preserved) { $preserved=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel)) -ceq [Convert]::ToBase64String($sentinelBytes) }
        $results.Add([pscustomobject]@{ Scenario=$scenario; Exit=$exit; ExternalPreserved=$preserved })
    }
    foreach ($result in $results) { Write-Output ('Legacy uninstall {0}: exit {1}, outside synthetic file preserved {2}.' -f $result.Scenario,$result.Exit,$result.ExternalPreserved) }
    Check (@($results | Where-Object { -not $_.ExternalPreserved }).Count -eq 0) 'Legacy uninstall changed data outside its synthetic installation.'
} finally {
    foreach ($scope in @('User','Machine')) {
        $before=if ($scope -eq 'User') { $beforeUser } else { $beforeMachine }
        $after=PathState $scope
        if ($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind) { throw "$scope PATH changed during the synthetic check." }
    }
    if ([Environment]::GetEnvironmentVariable('Path','Process') -cne $beforeProcess) { throw 'Process PATH changed during the synthetic check.' }
}
