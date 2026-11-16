$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Check([bool]$ok,[string]$message){ if(-not $ok){throw $message} }
function PathState([string]$scope) {
    $key = if ($scope -eq 'User') { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$false) }
        else { [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$false) }
    try { [pscustomobject]@{ Value=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind=[string]$key.GetValueKind('Path') } }
    finally { $key.Dispose() }
}
Check ($env:CI -ceq 'true' -and $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -ceq '0') 'Requires disposable hosted Windows.'
$beforeUser=PathState 'User'; $beforeMachine=PathState 'Machine'; $beforeProcess=[Environment]::GetEnvironmentVariable('Path','Process')
try {
    $temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
    for($p=[IO.DirectoryInfo]::new($temp);$null -ne $p;$p=$p.Parent) {
        Check ($p.Exists -and (($p.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Runner temp contains a redirected ancestor.'
    }
    $root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-published-exe-'+[guid]::NewGuid().ToString('N'))))
    Check ([string]::Equals([IO.Directory]::GetParent($root).FullName,$temp,[StringComparison]::OrdinalIgnoreCase) -and -not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'Unsafe fixture root.'
    [void][IO.Directory]::CreateDirectory($root)
    $profile=Join-Path $root 'profile'; $local=Join-Path $root 'local'; $roaming=Join-Path $root 'roaming'; $tmp=Join-Path $root 'temp'
    foreach($p in @($profile,$local,$roaming,$tmp)) {[void][IO.Directory]::CreateDirectory($p)}
    $install=[IO.Path]::GetFullPath((Join-Path $local 'AITaskMonitor'))
    Check ([string]::Equals([IO.Directory]::GetParent($install).FullName,$local,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture installation.'
    [void][IO.Directory]::CreateDirectory($install)
    $exe=Join-Path $root 'published-0.2.7-alpha.exe'
    Invoke-WebRequest -Uri 'https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.2.7-alpha/AITaskMonitorSetup-0.2.7-alpha.exe' -OutFile $exe
    Check ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ceq '5AE065837FFEAAB6D958AB917EA946572AD4DF2412240BD77DEFA086F918C2B2') 'Published EXE checksum did not match pinned release.'
    $ps=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $values=@{
        SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
        PATH=((Split-Path -Parent $ps)+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot)
        USERPROFILE=$profile; LOCALAPPDATA=$local; APPDATA=$roaming; TEMP=$tmp; TMP=$tmp
        PSModulePath=((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))
        DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'; DOTNET_GENERATE_ASPNET_CERTIFICATE='0'
        DOTNET_CLI_HOME=$tmp; NUGET_PACKAGES=(Join-Path $tmp 'nuget')
    }
    foreach($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')){
        $v=[Environment]::GetEnvironmentVariable($name); if(-not [string]::IsNullOrEmpty($v)){$values[$name]=$v}
    }
    function New-IsolatedPS {
        $s=[Diagnostics.ProcessStartInfo]::new(); $s.FileName=$ps; $s.WorkingDirectory=$root
        $s.UseShellExecute=$false; $s.CreateNoWindow=$true; $s.Environment.Clear()
        foreach($key in $values.Keys){$s.Environment[$key]=[string]$values[$key]}
        foreach($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass')){[void]$s.ArgumentList.Add($arg)}
        return $s
    }
    $extractor=Join-Path $root 'extract.ps1'
    [IO.File]::WriteAllText($extractor,@'
param([string]$InputExe,[string]$OutputFile)
$ErrorActionPreference='Stop'
$assembly=[Reflection.Assembly]::ReflectionOnlyLoadFrom($InputExe)
$stream=$assembly.GetManifestResourceStream('Uninstall-CodexProgress.ps1')
if($null -eq $stream){throw 'Published EXE does not contain the uninstaller resource.'}
try {
    $out=[IO.File]::Open($OutputFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$stream.CopyTo($out)} finally {$out.Dispose()}
} finally {$stream.Dispose()}
'@,[Text.UTF8Encoding]::new($false))
    $extracted=Join-Path $install 'Uninstall-CodexProgress.ps1'
    $start=New-IsolatedPS
    foreach($arg in @('-File',$extractor,$exe,$extracted)){[void]$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start)
    try {Check ($process.WaitForExit(20000) -and $process.ExitCode -eq 0) 'Could not extract the uninstaller by reflection-only loading.'} finally {$process.Dispose()}
    $source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\windows\app\Uninstall-CodexProgress.ps1'))
    $actual=[IO.File]::ReadAllText($extracted).Replace([string][char]13+[char]10,[string][char]10)
    $expected=[IO.File]::ReadAllText($source).Replace([string][char]13+[char]10,[string][char]10)
    Check ($actual -ceq $expected) 'Published EXE uninstaller differs from the checked source.'
    $unrelated=Join-Path $install 'unrelated.txt'
    $nested=Join-Path $install 'unrelated-folder'
    [void][IO.Directory]::CreateDirectory($nested)
    $nestedFile=Join-Path $nested 'user-data.txt'
    $outside=Join-Path $root 'outside.txt'
    [IO.File]::WriteAllText($unrelated,'synthetic unrelated file')
    [IO.File]::WriteAllText($nestedFile,'synthetic nested unrelated file')
    [IO.File]::WriteAllText($outside,'synthetic external file')
    $start=New-IsolatedPS
    foreach($arg in @('-File',$extracted)){[void]$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start)
    try {Check ($process.WaitForExit(20000) -and $process.ExitCode -eq 0) 'Released uninstaller did not start successfully.'} finally {$process.Dispose()}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while([IO.Directory]::Exists($install) -and $clock.Elapsed.TotalSeconds -lt 20){Start-Sleep -Milliseconds 100}
    Check (-not [IO.Directory]::Exists($install)) 'Released uninstaller did not remove the synthetic installation.'
    Check (-not [IO.File]::Exists($unrelated) -and -not [IO.File]::Exists($nestedFile)) 'The inside sentinel unexpectedly survived.'
    Check ([IO.File]::ReadAllText($outside) -ceq 'synthetic external file') 'The unrelated file outside the fixture installation changed.'
    Write-Output 'Published 0.2.7 EXE SHA-256 matched; reflection-extracted uninstaller matched source. Running only that script removed unrelated files inside the synthetic installation and preserved the outside sentinel.'
} finally {
    foreach($scope in @('User','Machine')){
        $before=if($scope -eq 'User'){$beforeUser}else{$beforeMachine};$after=PathState $scope
        if($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind){throw "$scope PATH changed."}
    }
    if([Environment]::GetEnvironmentVariable('Path','Process') -cne $beforeProcess){throw 'Process PATH changed.'}
}
