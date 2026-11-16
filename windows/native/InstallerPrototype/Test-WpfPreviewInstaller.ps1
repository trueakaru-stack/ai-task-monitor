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
    $item = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $item) {
        if (-not $item.Exists -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'The runner temporary path has a missing or redirected ancestor.'
        }
        $item = $item.Parent
    }
}

function Invoke-HiddenSetup([string]$Executable, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(90000)) {
            $process.Kill($true)
            throw 'The synthetic installer timed out.'
        }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
Assert-Condition ([IO.Path]::IsPathFullyQualified($runnerTemp)) 'Runner temporary path must be absolute.'
Assert-Condition ($runnerTemp -cmatch '^[A-Za-z]:\\[A-Za-z0-9 _\.\\-]+$') 'Runner temporary path uses unsupported characters.'
Assert-NoReparseAncestors $runnerTemp
$nonce = [Guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-wpf-install-' + $nonce)))
Assert-Condition ([string]::Equals([IO.Directory]::GetParent($testRoot).FullName, $runnerTemp, [StringComparison]::OrdinalIgnoreCase)) 'Test root must be a direct runner-temp child.'
Assert-Condition (-not [IO.Directory]::Exists($testRoot) -and -not [IO.File]::Exists($testRoot)) 'Test root already exists.'

$beforeUser = Read-PathState 'User'
$beforeMachine = Read-PathState 'Machine'
$beforeProcessPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
$names = @('AITM_WPF_PAYLOAD', 'AITM_WPF_OWNERSHIP', 'AITM_WPF_OUTPUT', 'AITM_WPF_TEST_ROOT', 'AITM_WPF_NONCE', 'AITM_WPF_INSTALLER')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    $null = [IO.Directory]::CreateDirectory($testRoot)
    $compilerDirectory = Join-Path $testRoot 'compiler'
    $outputDirectory = Join-Path $testRoot 'installer-output'
    $payloadDirectory = Join-Path $testRoot 'publish'
    $artifacts = Join-Path $testRoot 'artifacts'
    $isolation = Join-Path $testRoot 'isolated'
    foreach ($path in @($outputDirectory, $payloadDirectory, $isolation)) { $null = [IO.Directory]::CreateDirectory($path) }
    foreach ($name in @('profile', 'appdata', 'localappdata', 'temp', 'nuget', 'dotnet')) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $isolation $name))
    }
    Assert-Condition (-not [IO.Directory]::Exists($compilerDirectory) -and -not [IO.File]::Exists($compilerDirectory)) 'Compiler directory already exists.'

    $sdkCommand = Get-Command dotnet.exe -CommandType Application | Select-Object -First 1
    Assert-Condition ($null -ne $sdkCommand) 'The .NET SDK is unavailable.'
    $sdk = Split-Path -Parent $sdkCommand.Source
    $config = Join-Path $isolation 'NuGet.Config'
    [IO.File]::WriteAllText($config, '<configuration><packageSources><clear /></packageSources></configuration>', [Text.UTF8Encoding]::new($false))

    function New-IsolatedStart([string]$Executable) {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $Executable
        $start.WorkingDirectory = $testRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.Environment.Clear()
        $values = @{
            SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
            PATH=($sdk + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
            DOTNET_ROOT=$sdk; DOTNET_MULTILEVEL_LOOKUP='0'; DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
            DOTNET_CLI_HOME=(Join-Path $isolation 'dotnet'); DOTNET_CLI_TELEMETRY_OPTOUT='1'
            DOTNET_GENERATE_ASPNET_CERTIFICATE='0'; DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'
            NUGET_PACKAGES=(Join-Path $isolation 'nuget'); USERPROFILE=(Join-Path $isolation 'profile')
            APPDATA=(Join-Path $isolation 'appdata'); LOCALAPPDATA=(Join-Path $isolation 'localappdata')
            TEMP=(Join-Path $isolation 'temp'); TMP=(Join-Path $isolation 'temp')
        }
        foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'SystemDrive', 'ComSpec')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrEmpty($value)) { $values[$name] = $value }
        }
        foreach ($key in $values.Keys) { $start.Environment[$key] = [string]$values[$key] }
        return $start
    }

    function Invoke-IsolatedDotnet([string[]]$Arguments) {
        $start = New-IsolatedStart (Join-Path $sdk 'dotnet.exe')
        foreach ($argument in $Arguments) { $null = $start.ArgumentList.Add($argument) }
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'The isolated .NET operation timed out.' }
            if ($process.ExitCode -ne 0) { throw ('The isolated .NET operation failed: ' + $stdout.Result + $stderr.Result) }
            return [string]$stdout.Result
        } finally { $process.Dispose() }
    }

    $runtimes = Invoke-IsolatedDotnet @('--list-runtimes')
    Assert-Condition ($runtimes -match '(?m)^Microsoft\.WindowsDesktop\.App 10\.') 'The .NET 10 Windows Desktop Runtime is required.'
    $project = Join-Path (Split-Path -Parent $PSScriptRoot) 'Prototype\Prototype.csproj'
    $publishLog = Invoke-IsolatedDotnet @('publish', $project, '-c', 'Release', '--no-self-contained', '--output', $payloadDirectory,
        '--configfile', $config, '--artifacts-path', $artifacts, '-p:NuGetAudit=false', '-p:UseAppHost=true', '--nologo')
    Write-Output $publishLog.TrimEnd()

    $payloadEntries = @(Get-ChildItem -LiteralPath $payloadDirectory -Force)
    Assert-Condition ($payloadEntries.Count -gt 0 -and @($payloadEntries | Where-Object { $_.PSIsContainer }).Count -eq 0) 'The synthetic payload must contain only flat files.'
    $payloadHashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $payloadEntries) {
        Assert-Condition (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
            $file.Name -cmatch '^[A-Za-z0-9_. -]+$' -and $file.Name -cnotmatch '^unins[0-9]{3}\.') 'Unexpected synthetic payload filename.'
        $payloadHashes.Add($file.Name, (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash)
    }
    Assert-Condition ($payloadHashes.ContainsKey('AI Task Monitor.exe') -and $payloadHashes.ContainsKey('AI Task Monitor.deps.json') -and
        $payloadHashes.ContainsKey('AITaskMonitor.CodexCloud.dll') -and $payloadHashes.ContainsKey('AITaskMonitor.ClaudeReader.dll')) 'Expected published preview files are missing.'

    $ownership = Join-Path $testRoot 'payload-ownership.iss'
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('procedure RemoveInstalledPayload;')
    $lines.Add('begin')
    foreach ($name in ($payloadHashes.Keys | Sort-Object)) {
        $lines.Add(("  RemoveOwnedFile('{0}', '{1}');" -f $name, $payloadHashes[$name]))
    }
    $lines.Add('end;')
    [IO.File]::WriteAllLines($ownership, $lines, [Text.UTF8Encoding]::new($false))

    # Only the pinned signed official compiler is extracted, in portable mode.
    $compilerAsset = Join-Path $testRoot 'innosetup-7.1.1-x64.exe'
    $compilerUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe'
    $expectedHash = '8A5A6711C3766A6E5FB74F280BA0E3551E719CE94538D901FDBD1F8F9920B3F0'
    Invoke-WebRequest -Uri $compilerUrl -OutFile $compilerAsset -UseBasicParsing
    Assert-Condition ((Get-FileHash -Algorithm SHA256 -LiteralPath $compilerAsset).Hash -ceq $expectedHash) 'Pinned compiler hash mismatch.'
    $signature = Get-AuthenticodeSignature -LiteralPath $compilerAsset
    Assert-Condition ($signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match '(^|,\s*)CN=Pyrsys B\.V\.(,|$)') 'Compiler signature is not valid for the expected publisher.'
    $compilerCode = Invoke-HiddenSetup $compilerAsset @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS',
        '/PORTABLE=1', ('/DIR="' + $compilerDirectory + '"'))
    Assert-Condition ($compilerCode -eq 0) 'Portable compiler extraction failed.'
    $iscc = Join-Path $compilerDirectory 'ISCC.exe'
    Assert-Condition ([IO.File]::Exists($iscc)) 'Compiler executable is missing.'

    $env:AITM_WPF_PAYLOAD = $payloadDirectory
    $env:AITM_WPF_OWNERSHIP = $ownership
    $env:AITM_WPF_OUTPUT = $outputDirectory
    $env:AITM_WPF_TEST_ROOT = $testRoot
    $env:AITM_WPF_NONCE = $nonce
    $env:AITM_WPF_INSTALLER = '1'
    & $iscc '/Qp' (Join-Path $PSScriptRoot 'WpfPreview.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic WPF installer compilation failed.' }
    $setup = Join-Path $outputDirectory 'AITM-WpfPreviewInstaller-CI-ONLY.exe'
    Assert-Condition ([IO.File]::Exists($setup)) 'Synthetic WPF installer is missing.'
    $quiet = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCLOSEAPPLICATIONS')
    $install = Join-Path $testRoot 'install'

    $env:AITM_WPF_INSTALLER = '0'
    $guardCode = Invoke-HiddenSetup $setup $quiet
    Assert-Condition ($guardCode -ne 0 -and -not [IO.Directory]::Exists($install)) 'Synthetic installer guard failed.'
    $env:AITM_WPF_INSTALLER = '1'

    $null = [IO.Directory]::CreateDirectory($install)
    $collisionPath = Join-Path $install 'foreign.txt'
    $collisionBytes = [Text.Encoding]::UTF8.GetBytes('synthetic existing destination')
    [IO.File]::WriteAllBytes($collisionPath, $collisionBytes)
    $collisionCode = Invoke-HiddenSetup $setup $quiet
    Assert-Condition ($collisionCode -ne 0 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($collisionPath)) -ceq
        [Convert]::ToBase64String($collisionBytes) -and @(Get-ChildItem -LiteralPath $install -Force).Count -eq 1) 'Existing synthetic destination was modified.'
    [IO.File]::Delete($collisionPath)
    [IO.Directory]::Delete($install)

    $redirect = Join-Path $testRoot 'redirected'
    $redirectCode = Invoke-HiddenSetup $setup ($quiet + @('/DIR="' + $redirect + '"'))
    Assert-Condition ($redirectCode -ne 0 -and -not [IO.Directory]::Exists($install) -and
        -not [IO.Directory]::Exists($redirect)) 'Overridden synthetic destination was not rejected.'

    $installCode = Invoke-HiddenSetup $setup $quiet
    Assert-Condition ($installCode -eq 0) 'Synthetic WPF install failed.'
    foreach ($entry in $payloadHashes.GetEnumerator()) {
        $installed = Join-Path $install $entry.Key
        Assert-Condition ([IO.File]::Exists($installed) -and
            (Get-FileHash -Algorithm SHA256 -LiteralPath $installed).Hash -ceq $entry.Value) 'Installed preview payload differs from the publish output.'
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class AitmWpfInstallerWindowCheck {
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

    $executable = Join-Path $install 'AI Task Monitor.exe'
    $ready = Join-Path $testRoot 'preview-ready.txt'
    $screenshot = Join-Path $testRoot 'installed-preview.png'
    $start = New-IsolatedStart $executable
    foreach ($argument in @('--offscreen', '--ready-file', $ready, '--snapshot', $screenshot)) { $null = $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not [IO.File]::Exists($ready) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        Assert-Condition (-not $process.HasExited -and [IO.File]::Exists($ready) -and [IO.File]::Exists($screenshot)) 'Installed preview did not open.'
        Assert-Condition ([string]::Equals([IO.Path]::GetFullPath($process.MainModule.FileName), $executable,
            [StringComparison]::OrdinalIgnoreCase)) 'Installed process executable did not match the preview.'
        $window = [AitmWpfInstallerWindowCheck]::FindOwned($process.Id)
        Assert-Condition ($window -ne [IntPtr]::Zero) 'The installed process did not own the preview window.'
        Assert-Condition ([AitmWpfInstallerWindowCheck]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) 'Could not request synthetic preview shutdown.'
        Assert-Condition ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Installed preview did not exit cleanly.'
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        $process.Dispose()
    }

    $uninstallers = @(Get-ChildItem -LiteralPath $install -Filter 'unins???.exe' -File)
    Assert-Condition ($uninstallers.Count -eq 1) 'Expected one synthetic WPF uninstaller.'
    $env:AITM_WPF_INSTALLER = '0'
    $null = Invoke-HiddenSetup $uninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    $env:AITM_WPF_INSTALLER = '1'
    Assert-Condition ([IO.File]::Exists($uninstallers[0].FullName)) 'Uninstaller ignored its synthetic CI guard.'
    foreach ($entry in $payloadHashes.GetEnumerator()) {
        $installed = Join-Path $install $entry.Key
        Assert-Condition ([IO.File]::Exists($installed) -and
            (Get-FileHash -Algorithm SHA256 -LiteralPath $installed).Hash -ceq $entry.Value) 'Guarded uninstall altered the preview payload.'
    }
    $modified = Join-Path $install 'AI Task Monitor.deps.json'
    $modifiedBytes = [Text.Encoding]::UTF8.GetBytes('synthetic user-modified payload')
    [IO.File]::WriteAllBytes($modified, $modifiedBytes)
    $foreign = Join-Path $install 'foreign.txt'
    $foreignBytes = [Text.Encoding]::UTF8.GetBytes('synthetic foreign file')
    [IO.File]::WriteAllBytes($foreign, $foreignBytes)
    $dataDir = Join-Path $install 'user-data'
    $null = [IO.Directory]::CreateDirectory($dataDir)
    $data = Join-Path $dataDir 'settings.json'
    $dataBytes = [Text.Encoding]::UTF8.GetBytes('{"synthetic":true}')
    [IO.File]::WriteAllBytes($data, $dataBytes)
    $linkPath = Join-Path $install 'AITaskMonitor.ClaudeReader.dll'
    $outsideCopy = Join-Path $testRoot 'synthetic-outside-payload.bin'
    [IO.File]::Copy($linkPath, $outsideCopy, $false)
    [IO.File]::Delete($linkPath)
    $linkCreated = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $outsideCopy -ErrorAction Stop
        $linkCreated = $true
    } catch {
        Assert-Condition (-not [IO.File]::Exists($linkPath)) 'Symbolic-link fixture was partially created.'
        [IO.File]::Copy($outsideCopy, $linkPath, $false)
        Write-Output 'Symbolic-link preservation was not tested: runner could not create the synthetic link.'
    }
    $locked = Join-Path $install 'AITaskMonitor.CodexCloud.dll'
    $lockStream = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $uninstallCode = Invoke-HiddenSetup $uninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
        Assert-Condition ($uninstallCode -eq 0) 'Synthetic WPF uninstall failed.'
        $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([IO.File]::Exists($uninstallers[0].FullName) -and [DateTime]::UtcNow -lt $cleanupDeadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-Condition (-not [IO.File]::Exists($uninstallers[0].FullName)) 'Synthetic uninstaller remained.'
    } finally { $lockStream.Dispose() }
    Assert-Condition (-not [IO.File]::Exists($executable)) 'Unchanged application executable was not removed.'
    foreach ($entry in $payloadHashes.GetEnumerator()) {
        $installed = Join-Path $install $entry.Key
        if ($entry.Key -in @('AI Task Monitor.deps.json', 'AITaskMonitor.CodexCloud.dll') -or
            ($linkCreated -and $entry.Key -eq 'AITaskMonitor.ClaudeReader.dll')) { continue }
        Assert-Condition (-not [IO.File]::Exists($installed)) 'An unchanged unlocked payload file remained.'
    }
    Assert-Condition ([Convert]::ToBase64String([IO.File]::ReadAllBytes($modified)) -ceq [Convert]::ToBase64String($modifiedBytes)) 'Modified payload was removed or changed.'
    Assert-Condition ([IO.File]::Exists($locked) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $locked).Hash -ceq
        $payloadHashes['AITaskMonitor.CodexCloud.dll']) 'Locked payload was removed or changed.'
    Assert-Condition ([IO.File]::Exists($outsideCopy) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $outsideCopy).Hash -ceq
        $payloadHashes['AITaskMonitor.ClaudeReader.dll']) 'Synthetic file outside the install directory was removed or changed.'
    if ($linkCreated) {
        Assert-Condition ([IO.File]::Exists($linkPath) -and
            (([IO.File]::GetAttributes($linkPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) 'Synthetic symbolic link was removed or changed.'
        Write-Output 'Synthetic symbolic link and its outside target were preserved.'
    }
    Assert-Condition ([Convert]::ToBase64String([IO.File]::ReadAllBytes($foreign)) -ceq [Convert]::ToBase64String($foreignBytes)) 'Foreign file was removed or changed.'
    Assert-Condition ([Convert]::ToBase64String([IO.File]::ReadAllBytes($data)) -ceq [Convert]::ToBase64String($dataBytes)) 'Synthetic user data was removed or changed.'
    Write-Output ('Synthetic WPF installer: published {0} files, installed, launched owned window, and preserved modified, locked and foreign files.' -f $payloadHashes.Count)
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    foreach ($scope in @('User', 'Machine')) {
        $before = if ($scope -eq 'User') { $beforeUser } else { $beforeMachine }
        $after = Read-PathState $scope
        if ($after.Value -cne $before.Value -or $after.Kind -cne $before.Kind) { throw "$scope PATH changed during the synthetic WPF installer test." }
    }
    if ([Environment]::GetEnvironmentVariable('Path', 'Process') -cne $beforeProcessPath) { throw 'Process PATH changed during the synthetic WPF installer test.' }
}

