$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This guard prevents accidental local execution; it is not an isolation boundary.
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This test is restricted to a disposable GitHub-hosted Windows runner.'
}

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Setup([string]$Executable, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    return $process.ExitCode
}

function Assert-Bytes([string]$Path, [byte[]]$Expected, [string]$Message) {
    Assert-Condition ([IO.File]::Exists($Path)) $Message
    $actual = [IO.File]::ReadAllBytes($Path)
    Assert-Condition ([Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($Expected)) $Message
}

function Assert-NoReparseAncestors([string]$Path) {
    $item = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $item) {
        if (-not $item.Exists -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Runner temporary path has a missing or redirected ancestor.'
        }
        $item = $item.Parent
    }
}

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
Assert-Condition ([IO.Path]::IsPathFullyQualified($runnerTemp)) 'Runner temporary path must be absolute.'
Assert-Condition ($runnerTemp -cmatch '^[A-Za-z]:\\[A-Za-z0-9 _\.\\-]+$') 'Runner temporary path uses unsupported characters.'
Assert-NoReparseAncestors $runnerTemp
$nonce = [Guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path $runnerTemp ('aitm-installer-synthetic-' + $nonce)))
Assert-Condition ($testRoot.StartsWith($runnerTemp + '\', [StringComparison]::OrdinalIgnoreCase)) 'Test directory is outside runner temporary storage.'
Assert-Condition (-not [IO.Directory]::Exists($testRoot) -and -not [IO.File]::Exists($testRoot)) 'Test directory already exists.'

$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$processPathBefore = [Environment]::GetEnvironmentVariable('Path', 'Process')
$names = @('AITM_SYNTHETIC_OUTPUT', 'AITM_SYNTHETIC_INSTALLER', 'AITM_SYNTHETIC_NONCE', 'AITM_SYNTHETIC_DESTINATION')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    $null = [IO.Directory]::CreateDirectory($testRoot)
    $compilerDirectory = Join-Path $testRoot 'compiler'
    $outputDirectory = Join-Path $testRoot 'build-output'
    $legacyDirectory = Join-Path $testRoot 'legacy-synthetic'
    $null = [IO.Directory]::CreateDirectory($outputDirectory)
    $null = [IO.Directory]::CreateDirectory($legacyDirectory)
    Assert-Condition (-not [IO.Directory]::Exists($compilerDirectory) -and -not [IO.File]::Exists($compilerDirectory)) 'Compiler directory already exists.'

    # Fixed official immutable release and its published SHA-256. The tool is
    # extracted in portable mode only inside the disposable runner directory.
    $compilerAsset = Join-Path $testRoot 'innosetup-7.1.1-x64.exe'
    $url = 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe'
    $expectedHash = '8A5A6711C3766A6E5FB74F280BA0E3551E719CE94538D901FDBD1F8F9920B3F0'
    Invoke-WebRequest -Uri $url -OutFile $compilerAsset -UseBasicParsing
    Assert-Condition ((Get-FileHash -Algorithm SHA256 -LiteralPath $compilerAsset).Hash -ceq $expectedHash) 'Pinned compiler hash mismatch.'
    $signature = Get-AuthenticodeSignature -LiteralPath $compilerAsset
    Assert-Condition ($signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match '(^|,\s*)CN=Pyrsys B\.V\.(,|$)') 'Compiler signature was not valid for the expected publisher.'
    $compilerCode = Invoke-Setup $compilerAsset @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS',
        '/PORTABLE=1', ('/DIR="' + $compilerDirectory + '"'))
    Assert-Condition ($compilerCode -eq 0) 'Portable compiler extraction failed.'
    $iscc = Join-Path $compilerDirectory 'ISCC.exe'
    Assert-Condition ([IO.File]::Exists($iscc)) 'Compiler executable is missing.'

    $env:AITM_SYNTHETIC_OUTPUT = $outputDirectory
    $env:AITM_SYNTHETIC_INSTALLER = '1'
    $env:AITM_SYNTHETIC_NONCE = $nonce
    & $iscc '/Qp' (Join-Path $PSScriptRoot 'Prototype.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic installer compilation failed.' }
    $setup = Join-Path $outputDirectory 'AITM-InstallerPrototype-CI-ONLY.exe'
    Assert-Condition ([IO.File]::Exists($setup)) 'Synthetic installer is missing.'
    $quiet = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCLOSEAPPLICATIONS')

    # These are dummy files under RUNNER_TEMP, not actual profiles or shortcuts.
    $legacyFiles = @{}
    foreach ($name in @('settings.json', 'claude-hooks.json', 'ClaudeTaskHook.ps1', 'old-uninstaller.ps1', 'old-shortcut.lnk')) {
        $path = Join-Path $legacyDirectory $name
        $content = switch -Exact ($name) {
            'settings.json' { '{"theme":"dark","language":"en","unknown":"preserve"}' }
            'claude-hooks.json' { '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"SYNTHETIC-LEGACY-HOOK"}]}]}}' }
            'ClaudeTaskHook.ps1' { '# Synthetic hook marker; never executed.' }
            'old-uninstaller.ps1' { '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "uninstaller-invoked.marker"), "unexpected")' }
            'old-shortcut.lnk' { 'Synthetic shortcut marker; not a Windows shortcut.' }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($content)
        [IO.File]::WriteAllBytes($path, $bytes)
        $legacyFiles[$path] = $bytes
    }

    $env:AITM_SYNTHETIC_DESTINATION = Join-Path $testRoot 'guarded'
    $env:AITM_SYNTHETIC_INSTALLER = '0'
    $guardCode = Invoke-Setup $setup $quiet
    Assert-Condition ($guardCode -ne 0 -and -not [IO.Directory]::Exists($env:AITM_SYNTHETIC_DESTINATION)) 'CI guard did not reject installation.'
    $env:AITM_SYNTHETIC_INSTALLER = '1'

    $collision = Join-Path $testRoot 'collision'
    $null = [IO.Directory]::CreateDirectory($collision)
    $collisionFile = Join-Path $collision 'payload.txt'
    $foreignBefore = [Text.Encoding]::UTF8.GetBytes('foreign pre-existing file')
    [IO.File]::WriteAllBytes($collisionFile, $foreignBefore)
    $env:AITM_SYNTHETIC_DESTINATION = $collision
    $collisionCode = Invoke-Setup $setup $quiet
    Assert-Condition ($collisionCode -ne 0) 'Existing destination must be rejected.'
    Assert-Bytes $collisionFile $foreignBefore 'Existing destination was modified.'
    Assert-Condition (@(Get-ChildItem -LiteralPath $collision -Force).Count -eq 1) 'Existing destination gained installer files.'

    $expected = Join-Path $testRoot 'expected'
    $redirect = Join-Path $testRoot 'redirected'
    $env:AITM_SYNTHETIC_DESTINATION = $expected
    $redirectCode = Invoke-Setup $setup ($quiet + @('/DIR="' + $redirect + '"'))
    Assert-Condition ($redirectCode -ne 0 -and -not [IO.Directory]::Exists($expected) -and
        -not [IO.Directory]::Exists($redirect)) 'An overridden destination was not rejected.'

    $install = Join-Path $testRoot 'fresh'
    $env:AITM_SYNTHETIC_DESTINATION = $install
    $installCode = Invoke-Setup $setup $quiet
    Assert-Condition ($installCode -eq 0) 'Fresh synthetic install failed.'
    $payload = Join-Path $install 'payload.txt'
    $manifest = Join-Path $install 'manifest.txt'
    Assert-Bytes $payload ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Fixtures\payload.txt'))) 'Installed synthetic payload is incorrect.'
    Assert-Bytes $manifest ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Fixtures\manifest.txt'))) 'Installed synthetic manifest is incorrect.'
    $uninstallers = @(Get-ChildItem -LiteralPath $install -Filter 'unins???.exe' -File)
    Assert-Condition ($uninstallers.Count -eq 1) 'Expected exactly one synthetic uninstaller.'

    $env:AITM_SYNTHETIC_DESTINATION = $redirect
    $null = Invoke-Setup $uninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    Assert-Condition ([IO.File]::Exists($uninstallers[0].FullName) -and [IO.File]::Exists($payload)) 'Uninstaller did not reject the wrong test destination.'
    $env:AITM_SYNTHETIC_DESTINATION = $install

    $modifiedPayload = [Text.Encoding]::UTF8.GetBytes('synthetic user-modified payload')
    [IO.File]::WriteAllBytes($payload, $modifiedPayload)
    $foreignPath = Join-Path $install 'foreign.txt'
    $foreignBytes = [Text.Encoding]::UTF8.GetBytes('synthetic foreign file')
    [IO.File]::WriteAllBytes($foreignPath, $foreignBytes)
    $dataDirectory = Join-Path $install 'user-data'
    $null = [IO.Directory]::CreateDirectory($dataDirectory)
    $dataPath = Join-Path $dataDirectory 'settings.json'
    $dataBytes = [Text.Encoding]::UTF8.GetBytes('{"synthetic":true}')
    [IO.File]::WriteAllBytes($dataPath, $dataBytes)
    $uninstallCode = Invoke-Setup $uninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    Assert-Condition ($uninstallCode -eq 0) 'Synthetic uninstall failed.'
    Assert-Bytes $payload $modifiedPayload 'Modified payload was removed or changed.'
    Assert-Bytes $foreignPath $foreignBytes 'Foreign file was removed or changed.'
    Assert-Bytes $dataPath $dataBytes 'Synthetic user data was removed or changed.'
    Assert-Bytes $manifest ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Fixtures\manifest.txt'))) 'Retained manifest changed.'
    foreach ($entry in $legacyFiles.GetEnumerator()) { Assert-Bytes $entry.Key $entry.Value 'Synthetic legacy data was modified.' }
    Assert-Condition (-not [IO.File]::Exists((Join-Path $legacyDirectory 'uninstaller-invoked.marker'))) 'Synthetic old uninstaller was invoked.'
    Assert-Condition (-not [IO.File]::Exists($uninstallers[0].FullName)) 'Synthetic uninstaller remained after uninstall.'
    Write-Output 'Synthetic installer: guarded build, install, rejection and uninstall checks passed.'
}
finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    $userPathAfter = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePathAfter = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $processPathAfter = [Environment]::GetEnvironmentVariable('Path', 'Process')
    if ($userPathAfter -cne $userPathBefore -or $machinePathAfter -cne $machinePathBefore -or
        $processPathAfter -cne $processPathBefore) { throw 'A PATH value changed during the synthetic test.' }
}

