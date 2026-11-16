param(
    [Parameter(Mandatory)][string]$TestRoot,
    [Parameter(Mandatory)][string]$ExpectedCoreClrHash
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# These markers and path checks prevent accidental execution, not malicious use.
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This test requires a disposable GitHub-hosted Windows runner and the .NET PATH opt-out.'
}

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-HiddenSetup([string]$Executable, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(180000)) {
            $process.Kill($true)
            throw 'The synthetic installer timed out.'
        }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$root = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
Assert-Test ([string]::Equals([IO.Directory]::GetParent($root).FullName, $runnerTemp,
    [StringComparison]::OrdinalIgnoreCase)) 'Synthetic test root must be a direct runner-temp child.'
Assert-Test ([IO.Path]::GetFileName($root) -cmatch '^aitm-selfcontained-([0-9a-f]{32})$') 'Unexpected synthetic root name.'
$nonce = $Matches[1]
$item = [IO.DirectoryInfo]::new($root)
while ($null -ne $item) {
    Assert-Test ($item.Exists -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) 'Synthetic root has a missing or redirected ancestor.'
    $item = $item.Parent
}
$payload = Join-Path $root 'payload'
$emptyRuntime = Join-Path $root 'empty-runtime'
$isolated = Join-Path $root 'isolated'
$install = Join-Path $root 'install'
Assert-Test ([IO.Directory]::Exists($payload) -and [IO.Directory]::Exists($emptyRuntime) -and
    [IO.Directory]::Exists($isolated) -and -not [IO.Directory]::Exists($install) -and -not [IO.File]::Exists($install)) 'Synthetic prerequisites or destination are invalid.'
Assert-Test (@(Get-ChildItem -LiteralPath $emptyRuntime -Force).Count -eq 0) 'The isolated runtime root must be empty.'

$entries = @(Get-ChildItem -LiteralPath $payload -Recurse -Force)
Assert-Test ($entries.Count -gt 0) 'The synthetic payload is empty.'
foreach ($entry in $entries) {
    Assert-Test (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'The synthetic payload contains a reparse point.'
}
$files = @($entries | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
    [pscustomobject]@{
        Relative = [IO.Path]::GetRelativePath($payload, $_.FullName)
        Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
    }
})
$nested = @($files | Where-Object { $_.Relative.Contains('\') })
Assert-Test ($nested.Count -gt 1) 'The installer test requires multiple nested payload files.'
Assert-Test ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $payload 'coreclr.dll')).Hash -ceq $ExpectedCoreClrHash) 'The source CoreCLR does not match the pinned runtime package.'

$names = @('AITM_SC_PAYLOAD', 'AITM_SC_OUTPUT', 'AITM_SC_TEST_ROOT', 'AITM_SC_NONCE', 'AITM_SC_INSTALLER')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $compilerDir = Join-Path $root 'installer-compiler'
    $outputDir = Join-Path $root 'installer-output'
    $compilerAsset = Join-Path $root 'innosetup-7.1.1-x64.exe'
    Assert-Test (-not [IO.Directory]::Exists($compilerDir) -and -not [IO.Directory]::Exists($outputDir) -and
        -not [IO.File]::Exists($compilerAsset)) 'Synthetic compiler paths must be new.'
    $null = [IO.Directory]::CreateDirectory($outputDir)
    $compilerUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe'
    $compilerHash = '8A5A6711C3766A6E5FB74F280BA0E3551E719CE94538D901FDBD1F8F9920B3F0'
    Invoke-WebRequest -Uri $compilerUrl -OutFile $compilerAsset -UseBasicParsing
    Assert-Test ((Get-FileHash -Algorithm SHA256 -LiteralPath $compilerAsset).Hash -ceq $compilerHash) 'Pinned compiler hash mismatch.'
    $signature = Get-AuthenticodeSignature -LiteralPath $compilerAsset
    Assert-Test ($signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match '(^|,\s*)CN=Pyrsys B\.V\.(,|$)') 'Compiler signature is not valid for the expected publisher.'
    $compilerExit = Invoke-HiddenSetup $compilerAsset @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS',
        '/PORTABLE=1', ('/DIR="' + $compilerDir + '"'))
    Assert-Test ($compilerExit -eq 0) 'Portable compiler extraction failed.'
    $iscc = Join-Path $compilerDir 'ISCC.exe'
    Assert-Test ([IO.File]::Exists($iscc)) 'Compiler executable is missing.'

    $env:AITM_SC_PAYLOAD = $payload
    $env:AITM_SC_OUTPUT = $outputDir
    $env:AITM_SC_TEST_ROOT = $root
    $env:AITM_SC_NONCE = $nonce
    $env:AITM_SC_INSTALLER = '1'
    & $iscc '/Qp' (Join-Path $PSScriptRoot 'SelfContainedPreview.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic self-contained installer compilation failed.' }
    $setup = Join-Path $outputDir 'AITM-SelfContainedInstaller-CI-ONLY.exe'
    Assert-Test ([IO.File]::Exists($setup)) 'Synthetic self-contained installer is missing.'
    $quiet = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCLOSEAPPLICATIONS')
    $env:AITM_SC_INSTALLER = '0'
    $guardExit = Invoke-HiddenSetup $setup $quiet
    Assert-Test ($guardExit -ne 0 -and -not [IO.Directory]::Exists($install)) 'Synthetic installer guard failed.'
    $env:AITM_SC_INSTALLER = '1'
    $null = [IO.Directory]::CreateDirectory($install)
    $collision = Join-Path $install 'synthetic-existing-file.txt'
    $collisionBytes = [Text.Encoding]::UTF8.GetBytes('synthetic existing destination')
    [IO.File]::WriteAllBytes($collision, $collisionBytes)
    $collisionExit = Invoke-HiddenSetup $setup $quiet
    Assert-Test ($collisionExit -ne 0 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($collision)) -ceq
        [Convert]::ToBase64String($collisionBytes) -and @(Get-ChildItem -LiteralPath $install -Force).Count -eq 1) 'An existing synthetic destination was modified.'
    [IO.File]::Delete($collision)
    [IO.Directory]::Delete($install)
    $redirect = Join-Path $root 'redirected'
    $redirectExit = Invoke-HiddenSetup $setup ($quiet + @('/DIR="' + $redirect + '"'))
    Assert-Test ($redirectExit -ne 0 -and -not [IO.Directory]::Exists($install) -and
        -not [IO.Directory]::Exists($redirect)) 'Overridden synthetic destination was not rejected.'
    $installExit = Invoke-HiddenSetup $setup $quiet
    Assert-Test ($installExit -eq 0) 'Synthetic self-contained install failed.'
    foreach ($file in $files) {
        $installed = Join-Path $install $file.Relative
        Assert-Test ([IO.File]::Exists($installed) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $installed).Hash -ceq
            $file.Hash) 'Installed payload differs from the published source.'
    }
    foreach ($directory in @($entries | Where-Object { $_.PSIsContainer })) {
        $relative = [IO.Path]::GetRelativePath($payload, $directory.FullName)
        Assert-Test ([IO.Directory]::Exists((Join-Path $install $relative))) 'A published nested directory was not installed.'
    }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $install 'AI Task Monitor.exe'
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.Environment.Clear()
    $values = @{
        SystemRoot=$env:SystemRoot; windir=$env:SystemRoot
        PATH=((Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot)
        DOTNET_ROOT=$emptyRuntime; DOTNET_MULTILEVEL_LOOKUP='0'; DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='0'
        DOTNET_CLI_HOME=(Join-Path $isolated 'dotnet'); DOTNET_CLI_TELEMETRY_OPTOUT='1'
        DOTNET_GENERATE_ASPNET_CERTIFICATE='0'; DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1'
        NUGET_PACKAGES=(Join-Path $isolated 'nuget'); USERPROFILE=(Join-Path $isolated 'profile')
        APPDATA=(Join-Path $isolated 'appdata'); LOCALAPPDATA=(Join-Path $isolated 'localappdata')
        TEMP=(Join-Path $isolated 'temp'); TMP=(Join-Path $isolated 'temp')
    }
    foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'SystemDrive', 'ComSpec')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) { $values[$name] = $value }
    }
    foreach ($key in $values.Keys) { $start.Environment[$key] = [string]$values[$key] }
    $ready = Join-Path $root 'installed-selfcontained-ready.txt'
    $screenshot = Join-Path $root 'installed-selfcontained-preview.png'
    foreach ($argument in @('--offscreen', '--ready-file', $ready, '--snapshot', $screenshot)) { $null = $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(40)
        while (-not [IO.File]::Exists($ready) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }
        Assert-Test (-not $process.HasExited -and [IO.File]::Exists($ready) -and [IO.File]::Exists($screenshot)) 'Installed preview did not open with the empty runtime root.'
        Assert-Test ([string]::Equals([IO.Path]::GetFullPath($process.MainModule.FileName), $start.FileName,
            [StringComparison]::OrdinalIgnoreCase)) 'The installed process executable did not match the installed file.'
        $window = [AitmSelfContainedWindowCheck]::FindOwned($process.Id)
        Assert-Test ($window -ne [IntPtr]::Zero) 'The installed executable did not own its window.'
        $modules = @($process.Modules | Where-Object { $_.ModuleName -in @('hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll', 'clrjit.dll', 'wpfgfx_cor3.dll') })
        $core = @($modules | Where-Object { $_.ModuleName -eq 'coreclr.dll' })
        Assert-Test ($core.Count -eq 1) 'Installed CoreCLR was not observed.'
        $installPrefix = [IO.Path]::GetFullPath($install).TrimEnd('\') + '\'
        foreach ($module in $modules) {
            Assert-Test ([IO.Path]::GetFullPath($module.FileName).StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) 'An observed runtime module came from outside the install directory.'
        }
        Assert-Test ((Get-FileHash -Algorithm SHA256 -LiteralPath $core[0].FileName).Hash -ceq $ExpectedCoreClrHash) 'Installed CoreCLR differs from the pinned runtime package.'
        Assert-Test ([AitmSelfContainedWindowCheck]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) 'Could not request preview shutdown.'
        Assert-Test ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Installed preview did not exit cleanly.'
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        $process.Dispose()
    }

    $uninstallers = @(Get-ChildItem -LiteralPath $install -Filter 'unins???.exe' -File)
    Assert-Test ($uninstallers.Count -eq 1) 'Expected one synthetic uninstaller.'
    # Synthetic user state lives outside the application's installed files.
    $userData = Join-Path $root 'synthetic-user-state'
    [void][IO.Directory]::CreateDirectory($userData)
    $statePath = Join-Path $userData 'settings.json'
    $stateBytes = [Text.Encoding]::UTF8.GetBytes('synthetic user settings')
    [IO.File]::WriteAllBytes($statePath, $stateBytes)

    $modified = Join-Path $install $nested[0].Relative
    $modifiedBytes = [Text.Encoding]::UTF8.GetBytes('synthetic modified installed payload')
    [IO.File]::WriteAllBytes($modified, $modifiedBytes)
    $foreign = Join-Path (Split-Path -Parent $modified) 'synthetic-foreign-file.txt'
    $foreignBytes = [Text.Encoding]::UTF8.GetBytes('synthetic foreign nested file')
    Assert-Test (-not [IO.File]::Exists($foreign)) 'Synthetic foreign fixture already exists.'
    [IO.File]::WriteAllBytes($foreign, $foreignBytes)
    $locked = Join-Path $install $nested[1].Relative
    $lockedHash = (Get-FileHash -LiteralPath $locked -Algorithm SHA256).Hash
    $lockStream = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $uninstallExit = Invoke-HiddenSetup $uninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
        Assert-Test ($uninstallExit -eq 0) 'Synthetic uninstaller failed.'
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([IO.File]::Exists($uninstallers[0].FullName) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert-Test (-not [IO.File]::Exists($uninstallers[0].FullName)) 'Synthetic uninstaller remained.'
        Assert-Test ([IO.File]::Exists($locked)) 'The locked installed file disappeared during uninstall.'
    } finally { $lockStream.Dispose() }
    foreach ($file in $files) {
        if ($file.Relative -ceq $nested[1].Relative) { continue }
        $installed = Join-Path $install $file.Relative
        Assert-Test (-not [IO.File]::Exists($installed)) 'An unlocked installed payload file remained after uninstall.'
    }
    Assert-Test ((Get-FileHash -LiteralPath $locked -Algorithm SHA256).Hash -ceq $lockedHash) 'The locked payload file was changed.'
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($foreign)) -ceq [Convert]::ToBase64String($foreignBytes)) 'Foreign nested file was not preserved.'
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) -ceq [Convert]::ToBase64String($stateBytes)) 'Synthetic user settings changed.'

    # Reinstall only in the same disposable root, then replace one owned subdirectory
    # by a junction to synthetic data outside the installation. This tests whether
    # uninstall follows the redirected path. No user path or real profile is used.
    $retained = [IO.Path]::GetFullPath((Join-Path $root 'retained-first-install'))
    Assert-Test ([string]::Equals([IO.Directory]::GetParent($install).FullName, $root, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([IO.Directory]::GetParent($retained).FullName, $root, [StringComparison]::OrdinalIgnoreCase) -and
        -not [IO.Directory]::Exists($retained) -and -not [IO.File]::Exists($retained)) 'Invalid retained fixture path.'
    Assert-Test (((Get-Item -LiteralPath $install -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Synthetic installation root was redirected.'
    Assert-Test (((Get-Item -LiteralPath $install -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Synthetic installation root was redirected.'
    [IO.Directory]::Move($install, $retained)
    Assert-Test ((Invoke-HiddenSetup $setup $quiet) -eq 0) 'Second synthetic install failed.'
    $oneLevel = @($nested | Where-Object { [IO.Path]::GetDirectoryName($_.Relative) -and
        -not [IO.Path]::GetDirectoryName($_.Relative).Contains('\') } | Select-Object -First 1)
    Assert-Test ($oneLevel.Count -eq 1) 'A one-level nested installed payload file is required.'
    $relativeDirectory = [IO.Path]::GetDirectoryName($oneLevel[0].Relative)
    Assert-Test ($relativeDirectory -cmatch '^[A-Za-z0-9_-]+$') 'Unexpected synthetic directory name.'
    $redirectedDirectory = [IO.Path]::GetFullPath((Join-Path $install $relativeDirectory))
    $savedDirectory = [IO.Path]::GetFullPath((Join-Path $root 'synthetic-saved-payload'))
    $externalDirectory = [IO.Path]::GetFullPath((Join-Path $root 'synthetic-external-data'))
    Assert-Test ([string]::Equals([IO.Directory]::GetParent($redirectedDirectory).FullName, $install, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([IO.Directory]::GetParent($savedDirectory).FullName, $root, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([IO.Directory]::GetParent($externalDirectory).FullName, $root, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Directory]::Exists($redirectedDirectory) -and -not [IO.Directory]::Exists($savedDirectory) -and
        -not [IO.Directory]::Exists($externalDirectory)) 'Invalid synthetic redirection paths.'
    Assert-Test (((Get-Item -LiteralPath $redirectedDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Synthetic payload directory was already redirected.'
    [IO.Directory]::Move($redirectedDirectory, $savedDirectory)
    [void][IO.Directory]::CreateDirectory($externalDirectory)
    $sentinel = Join-Path $externalDirectory ([IO.Path]::GetFileName($oneLevel[0].Relative))
    $sentinelBytes = [Text.Encoding]::UTF8.GetBytes('synthetic outside file must survive')
    [IO.File]::WriteAllBytes($sentinel, $sentinelBytes)
    $null = New-Item -ItemType Junction -Path $redirectedDirectory -Target $externalDirectory
    Assert-Test (((Get-Item -LiteralPath $redirectedDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Synthetic junction was not created.'
    $secondUninstallers = @(Get-ChildItem -LiteralPath $install -Filter 'unins???.exe' -File)
    Assert-Test ($secondUninstallers.Count -eq 1) 'Expected one second synthetic uninstaller.'
    $redirectExit = Invoke-HiddenSetup $secondUninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    Assert-Test ($redirectExit -ne 0 -and [IO.File]::Exists((Join-Path $install 'AI Task Monitor.exe'))) 'An existing redirect should prevent the synthetic uninstall.'
    Assert-Test ([IO.File]::Exists($sentinel) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel)) -ceq
        [Convert]::ToBase64String($sentinelBytes)) 'Uninstall followed a junction and changed external synthetic data.'
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) -ceq [Convert]::ToBase64String($stateBytes)) 'Uninstall changed synthetic user settings during redirection.'

    # Remove only the junction we just created, inside this verified test root.
    # Never recursively delete it or its external target.
    $link = Get-Item -LiteralPath $redirectedDirectory -Force
    Assert-Test (($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and
        [string]::Equals([IO.Path]::GetFullPath([string]$link.Target), $externalDirectory, [StringComparison]::OrdinalIgnoreCase)) 'Synthetic junction target changed.'
    Assert-Test ([string]::Equals([IO.Directory]::GetParent($redirectedDirectory).FullName, $install, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([IO.Directory]::GetParent($savedDirectory).FullName, $root, [StringComparison]::OrdinalIgnoreCase) -and
        ((Get-Item -LiteralPath $install -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
        ((Get-Item -LiteralPath $savedDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Synthetic restoration paths changed.'
    Remove-Item -LiteralPath $redirectedDirectory -Force
    Assert-Test (-not [IO.Directory]::Exists($redirectedDirectory) -and
        [IO.File]::Exists($sentinel)) 'Removing the test junction affected its target.'
    [IO.Directory]::Move($savedDirectory, $redirectedDirectory)
    $recoveryExit = Invoke-HiddenSetup $secondUninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    Assert-Test ($recoveryExit -eq 0) 'Synthetic uninstall did not recover after the junction was removed.'
    foreach ($file in $files) {
        Assert-Test (-not [IO.File]::Exists((Join-Path $install $file.Relative))) 'An installed payload file remained after recovery uninstall.'
    }
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel)) -ceq [Convert]::ToBase64String($sentinelBytes) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) -ceq [Convert]::ToBase64String($stateBytes)) 'Recovery uninstall changed unrelated synthetic data.'
    Write-Output ('Synthetic uninstall: examined {0} installed files including {1} nested files; exit for redirected fixture: {2}.' -f $files.Count, $nested.Count, $redirectExit)
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}

