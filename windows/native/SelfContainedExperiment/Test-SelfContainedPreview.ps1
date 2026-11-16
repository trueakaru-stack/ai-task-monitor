$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Accidental-execution guard only; environment markers are not a security boundary.
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This test requires a disposable GitHub-hosted Windows runner and the .NET PATH opt-out.'
}

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Read-PathState([string]$Scope) {
    $key = if ($Scope -eq 'User') {
        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    } else {
        [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    }
    try {
        return [pscustomobject]@{
            Value = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Kind = [string]$key.GetValueKind('Path')
        }
    } finally { $key.Dispose() }
}

function Assert-NoReparseAncestors([string]$Path) {
    $directory = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $directory) {
        if (-not $directory.Exists -or (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Runner temporary path has a missing or redirected ancestor.'
        }
        $directory = $directory.Parent
    }
}

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
Assert-Condition ([IO.Path]::IsPathFullyQualified($runnerTemp)) 'Runner temporary path must be absolute.'
Assert-Condition ($runnerTemp -cmatch '^[A-Za-z]:\\[A-Za-z0-9 _\.\\-]+$') 'Runner temporary path uses unsupported characters.'
Assert-NoReparseAncestors $runnerTemp
$testRoot = [IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-selfcontained-' + [Guid]::NewGuid().ToString('N'))))
Assert-Condition ([string]::Equals([IO.Directory]::GetParent($testRoot).FullName, $runnerTemp,
    [StringComparison]::OrdinalIgnoreCase)) 'Test root must be a direct runner-temp child.'
Assert-Condition (-not [IO.Directory]::Exists($testRoot) -and -not [IO.File]::Exists($testRoot)) 'Test root already exists.'

$beforeUser = Read-PathState 'User'
$beforeMachine = Read-PathState 'Machine'
$beforeProcessPath = [Environment]::GetEnvironmentVariable('Path', 'Process')

try {
    $null = [IO.Directory]::CreateDirectory($testRoot)
    $sdkRoot = Join-Path $testRoot 'sdk'
    $sdkArchive = Join-Path $testRoot 'dotnet-sdk-10.0.404-win-x64.zip'
    $payload = Join-Path $testRoot 'payload'
    $artifacts = Join-Path $testRoot 'artifacts'
    $emptyRuntime = Join-Path $testRoot 'empty-runtime'
    $isolated = Join-Path $testRoot 'isolated'
    foreach ($directory in @($sdkRoot, $payload, $emptyRuntime, $isolated)) { $null = [IO.Directory]::CreateDirectory($directory) }
    foreach ($name in @('profile', 'appdata', 'localappdata', 'temp', 'nuget', 'dotnet')) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $isolated $name))
    }

    # Microsoft release metadata for SDK 10.0.404 / runtime 10.0.15, dated 2026-11-10.
    $sdkUrl = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.404/dotnet-sdk-10.0.404-win-x64.zip'
    $sdkHash = '330DDD2665B43CD2E428216A0D8EA1AC7BB19B5434FDC530E62010DC3B52823A620BF95489D628E1ED6F5122401793EE4887CCA4A019122361A1231497F632EE'
    Invoke-WebRequest -Uri $sdkUrl -OutFile $sdkArchive -UseBasicParsing
    Assert-Condition ((Get-FileHash -Algorithm SHA512 -LiteralPath $sdkArchive).Hash -ceq $sdkHash) 'Pinned SDK archive hash mismatch.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $prefix = [IO.Path]::GetFullPath($sdkRoot).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($sdkArchive)
    try {
        foreach ($entry in $archive.Entries) {
            $relative = $entry.FullName.Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) { throw 'Unexpected SDK archive entry.' }
            $resolved = [IO.Path]::GetFullPath((Join-Path $sdkRoot $relative))
            if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'SDK archive entry escapes its target.' }
            $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
            if ((($attributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'SDK archive contains a symbolic link.' }
        }
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($sdkArchive, $sdkRoot)
    $dotnet = Join-Path $sdkRoot 'dotnet.exe'
    Assert-Condition ([IO.File]::Exists($dotnet)) 'Pinned SDK executable is missing.'

    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $globalJson = Join-Path $repositoryRoot 'global.json'
    Assert-Condition (-not [IO.File]::Exists($globalJson)) 'The disposable checkout already contains global.json.'
    [IO.File]::WriteAllText($globalJson, '{"sdk":{"version":"10.0.404","rollForward":"disable","allowPrerelease":false}}', [Text.UTF8Encoding]::new($false))
    $nugetConfig = Join-Path $testRoot 'NuGet.Config'
    $configText = '<configuration><packageSources><clear /><add key="nuget.org" value="https://api.nuget.org/v3/index.json" /></packageSources><config><add key="signatureValidationMode" value="require" /></config></configuration>'
    [IO.File]::WriteAllText($nugetConfig, $configText, [Text.UTF8Encoding]::new($false))

    function New-IsolatedStart([string]$Executable, [string]$RuntimeRoot, [bool]$IncludeSdk) {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $Executable
        $start.WorkingDirectory = $repositoryRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.Environment.Clear()
        $systemPath = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
        if ($IncludeSdk) { $systemPath = $sdkRoot + ';' + $systemPath }
        $values = @{
            SystemRoot=$env:SystemRoot; windir=$env:SystemRoot; PATH=$systemPath
            DOTNET_ROOT=$RuntimeRoot; DOTNET_MULTILEVEL_LOOKUP='0'; DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
            DOTNET_CLI_HOME=(Join-Path $isolated 'dotnet'); DOTNET_CLI_TELEMETRY_OPTOUT='1'
            DOTNET_GENERATE_ASPNET_CERTIFICATE='0'; DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'
            DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1'; DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER='1'
            NUGET_PACKAGES=(Join-Path $isolated 'nuget'); USERPROFILE=(Join-Path $isolated 'profile')
            APPDATA=(Join-Path $isolated 'appdata'); LOCALAPPDATA=(Join-Path $isolated 'localappdata')
            TEMP=(Join-Path $isolated 'temp'); TMP=(Join-Path $isolated 'temp')
        }
        foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'SystemDrive', 'ComSpec')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrEmpty($value)) { $values[$name] = $value }
        }
        foreach ($key in $values.Keys) { $start.Environment[$key] = [string]$values[$key] }
        return $start
    }

    function Invoke-IsolatedDotnet([string[]]$Arguments) {
        $start = New-IsolatedStart $dotnet $sdkRoot $true
        foreach ($argument in $Arguments) { $null = $start.ArgumentList.Add($argument) }
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(360000)) { $process.Kill($true); throw 'The isolated .NET operation timed out.' }
            if ($process.ExitCode -ne 0) { throw ('The isolated .NET operation failed: ' + $stdout.Result + $stderr.Result) }
            return [string]$stdout.Result
        } finally { $process.Dispose() }
    }

    $version = (Invoke-IsolatedDotnet @('--version')).Trim()
    Assert-Condition ($version -ceq '10.0.404') 'The isolated SDK version differs from the pinned release.'
    $project = Join-Path $repositoryRoot 'windows\native\Prototype\Prototype.csproj'
    $publishLog = Invoke-IsolatedDotnet @('publish', $project, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true',
        '--output', $payload, '--configfile', $nugetConfig, '--artifacts-path', $artifacts,
        '-p:RuntimeFrameworkVersion=10.0.15', '-p:NuGetAudit=false', '-p:UseAppHost=true', '--nologo')
    Write-Output $publishLog.TrimEnd()

    $exe = Join-Path $payload 'AI Task Monitor.exe'
    $deps = Join-Path $payload 'AI Task Monitor.deps.json'
    Assert-Condition ([IO.File]::Exists($exe) -and [IO.File]::Exists($deps)) 'Published preview entrypoint or dependency metadata is missing.'
    $dependencyText = [IO.File]::ReadAllText($deps)
    Assert-Condition ($dependencyText.Contains('Microsoft.NETCore.App.Runtime.win-x64/10.0.15') -and
        $dependencyText.Contains('Microsoft.WindowsDesktop.App.Runtime.win-x64/10.0.15')) 'Published runtime pack versions differ from the pin.'

    $entries = @(Get-ChildItem -LiteralPath $payload -Recurse -Force)
    Assert-Condition ($entries.Count -gt 0) 'Published self-contained payload is empty.'
    foreach ($entry in $entries) {
        Assert-Condition (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Published payload contains a reparse point.'
    }
    $payloadFiles = @($entries | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        [pscustomobject]@{
            RelativePath = [IO.Path]::GetRelativePath($payload, $_.FullName).Replace('\', '/')
            Size = $_.Length
            Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        }
    })
    $payloadDirectories = @($entries | Where-Object { $_.PSIsContainer } | ForEach-Object {
        [IO.Path]::GetRelativePath($payload, $_.FullName).Replace('\', '/')
    })

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AitmSelfContainedWindowCheck {
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    public static IntPtr FindOwned(int processId) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, state) => {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner != (uint)processId || !IsWindowVisible(window)) return true;
            var text = new StringBuilder(128); GetWindowText(window, text, text.Capacity);
            if (text.ToString() != "AI task monitor") return true;
            found = window; return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@

    $ready = Join-Path $testRoot 'selfcontained-ready.txt'
    $screenshot = Join-Path $testRoot 'selfcontained-preview.png'
    $start = New-IsolatedStart $exe $emptyRuntime $false
    $start.WorkingDirectory = $testRoot
    foreach ($argument in @('--offscreen', '--ready-file', $ready, '--snapshot', $screenshot)) { $null = $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $runtimeModules = @()
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(40)
        while (-not [IO.File]::Exists($ready) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        Assert-Condition (-not $process.HasExited -and [IO.File]::Exists($ready) -and [IO.File]::Exists($screenshot)) 'Self-contained preview did not open with an empty runtime root.'
        Assert-Condition ([string]::Equals([IO.Path]::GetFullPath($process.MainModule.FileName), $exe,
            [StringComparison]::OrdinalIgnoreCase)) 'The preview process executable did not match the published file.'
        $window = [AitmSelfContainedWindowCheck]::FindOwned($process.Id)
        Assert-Condition ($window -ne [IntPtr]::Zero) 'The published executable did not own its window.'
        $wantedModules = @('hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll', 'clrjit.dll', 'wpfgfx_cor3.dll')
        $runtimeModules = @($process.Modules | Where-Object { $_.ModuleName -in $wantedModules } | ForEach-Object {
            [pscustomobject]@{ Name = $_.ModuleName; Path = [IO.Path]::GetFullPath($_.FileName) }
        })
        Assert-Condition (@($runtimeModules | Where-Object { $_.Name -eq 'coreclr.dll' }).Count -eq 1) 'Loaded coreclr.dll was not observed.'
        $payloadPrefix = [IO.Path]::GetFullPath($payload).TrimEnd('\') + '\'
        foreach ($module in $runtimeModules) {
            Assert-Condition ($module.Path.StartsWith($payloadPrefix, [StringComparison]::OrdinalIgnoreCase)) 'A loaded runtime module came from outside the published payload.'
        }
        $coreRuntime = $runtimeModules | Where-Object { $_.Name -eq 'coreclr.dll' } | Select-Object -First 1
        $productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($coreRuntime.Path).ProductVersion
        Assert-Condition ($productVersion -match '^10\.0\.15(?:\+|$)') 'Loaded CoreCLR product version differs from the runtime pin.'
        Assert-Condition ([AitmSelfContainedWindowCheck]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) 'Could not request preview shutdown.'
        Assert-Condition ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Self-contained preview did not exit cleanly.'
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        $process.Dispose()
    }

    $packageFiles = @(Get-ChildItem -LiteralPath (Join-Path $isolated 'nuget') -Recurse -File -Filter '*.nupkg' | ForEach-Object {
        [pscustomobject]@{ RelativePath = [IO.Path]::GetRelativePath((Join-Path $isolated 'nuget'), $_.FullName).Replace('\', '/');
            Sha512 = (Get-FileHash -Algorithm SHA512 -LiteralPath $_.FullName).Hash }
    })
    $report = [pscustomobject]@{
        SdkVersion = $version; RuntimeVersion = '10.0.15'; SdkArchiveSha512 = $sdkHash
        PayloadFiles = $payloadFiles; PayloadDirectories = $payloadDirectories
        LoadedRuntimeModuleNames = @($runtimeModules | ForEach-Object { $_.Name })
        RuntimeModulesFromPayload = $true; NugetPackages = $packageFiles
    }
    $reportPath = Join-Path $testRoot 'selfcontained-inventory.json'
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Output ('Self-contained preview: SDK {0}, runtime 10.0.15, {1} files, {2} directories; window owned by executable with CoreCLR loaded from payload.' -f
        $version, $payloadFiles.Count, $payloadDirectories.Count)
} finally {
    foreach ($scope in @('User', 'Machine')) {
        $before = if ($scope -eq 'User') { $beforeUser } else { $beforeMachine }
        $after = Read-PathState $scope
        if ($after.Value -cne $before.Value -or $after.Kind -cne $before.Kind) { throw "$scope PATH changed during the self-contained preview test." }
    }
    if ([Environment]::GetEnvironmentVariable('Path', 'Process') -cne $beforeProcessPath) { throw 'Process PATH changed during the self-contained preview test.' }
}

