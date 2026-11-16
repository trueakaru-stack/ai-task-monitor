$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'A disposable hosted Windows runner with PATH opt-out is required.'
}
function Check([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Read-PathState([string]$scope) {
    $key = if ($scope -eq 'User') { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false) }
           else { [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false) }
    try {
        [pscustomobject]@{
            Value = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Kind = [string]$key.GetValueKind('Path')
        }
    } finally { $key.Dispose() }
}
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
Check ([IO.Path]::IsPathFullyQualified($runnerTemp)) 'Runner temp must be absolute.'
for ($dir=[IO.DirectoryInfo]::new($runnerTemp); $null -ne $dir; $dir=$dir.Parent) {
    Check ($dir.Exists -and (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Runner temp has a redirected ancestor.'
}
$root = [IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-claude-id-proof-' + [Guid]::NewGuid().ToString('N'))))
Check ([string]::Equals([IO.Directory]::GetParent($root).FullName, $runnerTemp, [StringComparison]::OrdinalIgnoreCase)) 'Synthetic root must be a direct runner-temp child.'
Check (-not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'Synthetic root already exists.'
$beforeUser = Read-PathState 'User'
$beforeMachine = Read-PathState 'Machine'
$beforeProcess = [Environment]::GetEnvironmentVariable('Path', 'Process')
$firewallName = $null
try {
    [void][IO.Directory]::CreateDirectory($root)
    $isolation = Join-Path $root 'isolated'
    foreach ($name in @('profile','appdata','localappdata','temp','nuget','dotnet','claude','work','package')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $isolation $name))
    }
    $version = $env:AITM_CLAUDE_VERSION
    switch ($version) {
        '2.1.101' {
            $url = 'https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.101.tgz'
            $expected = 'abVVCKMDKl9jHzgoUhhBVAQY2fKVdLt13ag5EEDlybRUCRL+rEAZfBxOdQnKZbzH1AUW5VwqiELeMHFauO51DQ=='
        }
        '2.1.273' {
            $url = 'https://registry.npmjs.org/@anthropic-ai/claude-code-win32-x64/-/claude-code-win32-x64-2.1.273.tgz'
            $expected = '1NmQNk18bb58Ud6Z0ob5KxJRixDBzUifry3KXpHnKFxG0Df5h9ko6MlvRNuL+6ROmmgycLhYRl5jBZqwc0USQw=='
        }
        default { throw 'An unsupported synthetic CLI version was requested.' }
    }
    $archive = Join-Path $root ('official-claude-' + $version + '.tgz')
    Invoke-WebRequest -Uri $url -OutFile $archive -MaximumRedirection 3
    $stream = [IO.File]::OpenRead($archive)
    $hasher = [Security.Cryptography.SHA512]::Create()
    try { $actual = [Convert]::ToBase64String($hasher.ComputeHash($stream)) }
    finally { $hasher.Dispose(); $stream.Dispose() }
    Check ($actual -ceq $expected) 'Official Claude package failed its pinned SHA-512 integrity check.'
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    Check ([IO.File]::Exists($tar)) 'Hosted archive inspector unavailable.'
    $names = @(& $tar -tzf $archive)
    Check ($LASTEXITCODE -eq 0 -and $names.Count -gt 0 -and $names.Count -lt 1000) 'Archive listing failed.'
    foreach ($entry in $names) {
        Check ($entry -cmatch '^package/' -and $entry -cnotmatch '(^|/)\.\.(/|$)' -and
            $entry -cnotmatch '[\\:]') 'Unsafe archive entry rejected.'
    }
    $details = @(& $tar -tvzf $archive)
    Check ($LASTEXITCODE -eq 0 -and $details.Count -eq $names.Count) 'Archive type inspection failed.'
    foreach ($entry in $details) { Check ($entry -cmatch '^[-d]') 'Archive links or special entries rejected.' }
    $destination = Join-Path $isolation 'package'
    & $tar -xzf $archive -C $destination
    Check ($LASTEXITCODE -eq 0) 'Archive extraction failed.'
    $node = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
    Check ([IO.File]::Exists($node)) 'Hosted Node unavailable.'
    $entry = ''
    if ($version -ceq '2.1.101') {
        $exe = $node
        $entry = Join-Path $destination 'package\cli.js'
        Check ([IO.File]::Exists($entry)) 'Pinned Claude JavaScript entry point missing.'
    } else {
        $exe = Join-Path $destination 'package\claude.exe'
        Check ([IO.File]::Exists($exe)) 'Pinned Claude executable missing.'
    }
    $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    Check ([IO.File]::Exists($node) -and [IO.File]::Exists($gitBash)) 'Hosted Node or Git Bash unavailable.'
    $script = Join-Path $PSScriptRoot 'Harness.cjs'
    Check ([IO.File]::Exists($script)) 'Synthetic harness missing.'

    # Deny outbound connections from the Claude executable. Windows may exempt loopback. This
    # rule exists only in the disposable hosted VM, and is removed in finally.
    $firewallName = 'AITM-claude-id-' + [Guid]::NewGuid().ToString('N')
    $null = New-NetFirewallRule -Name $firewallName -DisplayName $firewallName -Direction Outbound -Action Block -Enabled True -Profile Any -Program $exe -RemoteAddress 'Any'
    $rule = Get-NetFirewallRule -Name $firewallName
    Check ($rule.Enabled -eq 'True' -and $rule.Direction -eq 'Outbound' -and $rule.Action -eq 'Block') 'Synthetic outbound block unavailable.'
    $applicationFilter = $rule | Get-NetFirewallApplicationFilter
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    Check ([string]::Equals([string]$applicationFilter.Program, $exe, [StringComparison]::OrdinalIgnoreCase)) 'Unexpected executable in outbound block.'
    $addressText = @($addressFilter.RemoteAddress) -join ','
    Check ($addressText -ceq 'Any') 'Unexpected remote addresses in outbound block.'


    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $node
    $start.WorkingDirectory = Join-Path $isolation 'work'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment.Clear()
    $values = @{
        SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
        PATH=((Split-Path -Parent $node) + ';' + (Split-Path -Parent $gitBash) + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
        PSModulePath=((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules') + ';' + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))
        DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'; DOTNET_GENERATE_ASPNET_CERTIFICATE='0'; DOTNET_CLI_TELEMETRY_OPTOUT='1'
        DOTNET_CLI_HOME=(Join-Path $isolation 'dotnet'); NUGET_PACKAGES=(Join-Path $isolation 'nuget')
        USERPROFILE=(Join-Path $isolation 'profile'); APPDATA=(Join-Path $isolation 'appdata')
        LOCALAPPDATA=(Join-Path $isolation 'localappdata'); TEMP=(Join-Path $isolation 'temp'); TMP=(Join-Path $isolation 'temp')
        CLAUDE_CONFIG_DIR=(Join-Path $isolation 'claude'); CLAUDE_CODE_GIT_BASH_PATH=$gitBash
        AITM_TEST_ROOT=(Join-Path $isolation 'work'); AITM_CLAUDE_EXE=$exe; AITM_CLAUDE_ENTRY_SCRIPT=$entry; AITM_CLAUDE_VERSION=$version
        CI=$env:CI; GITHUB_ACTIONS=$env:GITHUB_ACTIONS; RUNNER_ENVIRONMENT=$env:RUNNER_ENVIRONMENT; RUNNER_OS=$env:RUNNER_OS
    }
    foreach ($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec','PATHEXT')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) { $values[$name] = $value }
    }
    foreach ($key in $values.Keys) { $start.Environment[$key] = [string]$values[$key] }
    [void]$start.ArgumentList.Add($script)
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(240000)) { $process.Kill($true); throw 'Synthetic identifier probe timed out.' }
        Write-Output $stdout.Result
        if ($process.ExitCode -ne 0) { throw ('Synthetic identifier probe failed: ' + $stderr.Result) }
    } finally { $process.Dispose() }
    Write-Output 'Pinned synthetic Claude ID probe finished with an isolated profile.'
} finally {
    if ($firewallName) {
        $existing = Get-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue
        if ($null -ne $existing) { $existing | Remove-NetFirewallRule }
    }
    foreach ($scope in @('User','Machine')) {
        $before = if ($scope -eq 'User') { $beforeUser } else { $beforeMachine }
        $after = Read-PathState $scope
        if ($before.Value -cne $after.Value -or $before.Kind -cne $after.Kind) { throw "$scope PATH changed during the hosted test." }
    }
    if ([Environment]::GetEnvironmentVariable('Path', 'Process') -cne $beforeProcess) { throw 'Process PATH changed during the hosted test.' }
    Write-Output 'User, machine and process PATH remained unchanged.'
}
