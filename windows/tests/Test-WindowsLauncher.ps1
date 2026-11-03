param([string]$EvidenceDirectory="")
$ErrorActionPreference = "Stop"
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\app"))
$installedRoot = Join-Path $env:LOCALAPPDATA "AITaskMonitor"
$compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path -LiteralPath $compiler)) { throw "Windows C# compiler not found." }
$installedAvailable=Test-Path -LiteralPath (Join-Path $installedRoot "CodexProgress.ps1") -PathType Leaf
$buildSource=[IO.File]::ReadAllText((Join-Path $appRoot "Build-Installer-v2.ps1"))
$installerSource=[IO.File]::ReadAllText((Join-Path $appRoot "CodexProgressInstaller.cs"))
if (-not $buildSource.Contains('/target:winexe') -or -not $buildSource.Contains('/resource:$launcher,AI task monitor.exe')) { throw "The installer build does not include the GUI launcher." }
if (-not $installerSource.Contains('Extract("AI task monitor.exe", launcher)') -or $installerSource.Contains('AI task monitor.cmd')) { throw "The installer still uses the command-script entry point." }

$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai task monitor launcher test-"+[Guid]::NewGuid().ToString("N"))))
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $root.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($root)
$allFinished = $true
$lockOwner = $null
try {
    $probe = Join-Path $root "console probe.exe"
    $testOutput=Join-Path $root "release output"
    $testBuildTemp=Join-Path $root "release intermediate"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appRoot "Build-Installer-v2.ps1") -OutputDirectory $testOutput -BuildTempDirectory $testBuildTemp | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "The isolated release build failed." }
    $launcher=Join-Path $testBuildTemp "AI task monitor.exe"
    $installer=Join-Path $testOutput "AITaskMonitorSetup.exe"
    if (-not (Test-Path -LiteralPath $launcher) -or -not (Test-Path -LiteralPath $installer)) { throw "The isolated release build is incomplete." }
    & $compiler /nologo /target:winexe /optimize+ "/out:$probe" (Join-Path $PSScriptRoot "ConsoleAssociationProbe.cs")
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probe)) { throw "Console-association probe did not compile." }
    $bytes = [IO.File]::ReadAllBytes($launcher)
    $peOffset = [BitConverter]::ToInt32($bytes,0x3c)
    if ([BitConverter]::ToUInt16($bytes,$peOffset+24+68) -ne 2) { throw "The release launcher must use the Windows GUI subsystem." }
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($installer))
    if ($assembly.GetManifestResourceNames() -notcontains "AI task monitor.exe") { throw "The release installer does not contain the GUI launcher." }
    $installerType=$assembly.GetType("CodexProgressInstaller",$true)
    $extract=$installerType.GetMethod("Extract",[Reflection.BindingFlags]"NonPublic,Static")
    $extractedLauncher=Join-Path $root "extracted launcher.exe"
    [string[]]$extractArguments=@("AI task monitor.exe",$extractedLauncher)
    [void]$extract.Invoke($null,$extractArguments)
    if ((Get-FileHash -LiteralPath $extractedLauncher -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash) { throw "The installed launcher resource differs from the release launcher." }
    $shortcutPath=Join-Path $root "test shortcut.lnk"
    $icon=Join-Path $appRoot "assets\app-icon.ico"
    $createShortcut=$installerType.GetMethod("CreateShortcut",[Reflection.BindingFlags]"NonPublic,Static")
    [string[]]$shortcutArguments=@($shortcutPath,$extractedLauncher,$root,$icon)
    [void]$createShortcut.Invoke($null,$shortcutArguments)
    $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    if ($shortcut.TargetPath -ne $extractedLauncher -or $shortcut.WorkingDirectory -ne $root) { throw "The installed shortcut does not target the GUI launcher." }

    $fixtureCodexHome = Join-Path $root "synthetic codex home"
    $locks = Join-Path $fixtureCodexHome "thread-writer-locks"
    $now = Get-Date
    $sessionDirectory = Join-Path (Join-Path (Join-Path (Join-Path $fixtureCodexHome "sessions") $now.ToString("yyyy")) $now.ToString("MM")) $now.ToString("dd")
    [void][IO.Directory]::CreateDirectory($sessionDirectory)
    [void][IO.Directory]::CreateDirectory($locks)
    $sessionId = "synthetic-active"
    $sessionFile = Join-Path $sessionDirectory ("rollout-"+$sessionId+".jsonl")
    $indexLine = @{id=$sessionId;thread_name="Synthetic active monitoring task";updated_at=$now.ToString("o")} | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $fixtureCodexHome "session_index.jsonl"),($indexLine+"`n"),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($sessionFile,('{"type":"event_msg","payload":{"type":"task_started"}}'+"`n"),[Text.UTF8Encoding]::new($false))
    $lockPath = Join-Path $locks ($sessionId+".lock")
    $lockOwner = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)

    $versions=if($installedAvailable){@("installed-release-copy","current-source")}else{@("current-source")}
    if(-not $installedAvailable){Write-Output "Installed release not found; the copied-release check was skipped."}
    foreach ($version in $versions) {
        $fixture = Join-Path $root $version
        [void][IO.Directory]::CreateDirectory($fixture)
        $sourceRoot = if ($version -eq "installed-release-copy") { $installedRoot } else { $appRoot }
        Get-ChildItem -LiteralPath $sourceRoot -Filter "*.ps1" -File | Copy-Item -Destination $fixture
        foreach($sourceName in @("AppShellIdentity.cs","ClaudeLoopChannel.cs")){
            $codeSource=Join-Path $sourceRoot $sourceName
            if(Test-Path -LiteralPath $codeSource -PathType Leaf){Copy-Item -LiteralPath $codeSource -Destination $fixture}
        }
        if (Test-Path -LiteralPath (Join-Path $sourceRoot "assets") -PathType Container) { Copy-Item -LiteralPath (Join-Path $sourceRoot "assets") -Destination $fixture -Recurse }
        $fixtureLauncher = Join-Path $fixture "AI task monitor.exe"
        Copy-Item -LiteralPath $extractedLauncher -Destination $fixtureLauncher
        $snapshot = Join-Path $root ($version+".png")
        $data = Join-Path $root ($version+" data")
        $diagnostic = Join-Path $data "diagnostics"
        [void][IO.Directory]::CreateDirectory($data)
        $arguments = '-SnapshotFile "'+$snapshot+'" -ThemeOverride dark'
        $readyPath=Join-Path $root ($version+"-ready.signal")
        if ($version -eq "current-source") { $arguments += ' -DiagnosticDirectory "'+$diagnostic+'" -PreviewStartupReadyFile "'+$readyPath+'" -PreviewStartupDelayMilliseconds 3000' }
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $fixtureLauncher
        $start.Arguments = $arguments
        $start.WorkingDirectory = $fixture
        $start.UseShellExecute = $false
        $start.EnvironmentVariables["CODEX_HOME"] = $fixtureCodexHome
        $start.EnvironmentVariables["LOCALAPPDATA"] = $data
        $start.EnvironmentVariables["USERPROFILE"] = $data
        $allFinished = $false
        $launched = [Diagnostics.Process]::Start($start)
        $launcherId = $launched.Id
        $child = $null
        for ($attempt=0; $attempt -lt 100 -and $null -eq $child; $attempt++) {
            $children = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId="+$launcherId) -ErrorAction Stop)
            if (@($children|Where-Object Name -eq "cmd.exe").Count -gt 0) { throw "The launcher started cmd.exe." }
            $child = @($children|Where-Object Name -eq "powershell.exe"|Select-Object -First 1)[0]
            if ($null -eq $child) { Start-Sleep -Milliseconds 40 }
        }
        if ($null -eq $child) { throw "The launcher did not create a directly observable PowerShell child for $version." }
        $powerShell = [Diagnostics.Process]::GetProcessById([int]$child.ProcessId)
        [void]$powerShell.Handle
        $probeStart = New-Object Diagnostics.ProcessStartInfo
        $probeStart.FileName = $probe
        $probeStart.Arguments = [string]$child.ProcessId
        $probeStart.UseShellExecute = $false
        $probeProcess = [Diagnostics.Process]::Start($probeStart)
        if (-not $probeProcess.WaitForExit(5000)) { throw "The console-association probe did not finish for $version." }
        if ($probeProcess.ExitCode -ne 0) { throw "PowerShell had a visible console or its console state could not be verified for $version (probe exit $($probeProcess.ExitCode))." }
        if($version -eq "current-source"){
            $readyWatch=[Diagnostics.Stopwatch]::StartNew()
            while(-not (Test-Path -LiteralPath $readyPath) -and $readyWatch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 40}
            if(-not (Test-Path -LiteralPath $readyPath)){throw "The isolated monitor did not report startup readiness."}
            $newEvent=@{timestamp=[DateTime]::UtcNow.ToString("o");type="event_msg";payload=@{type="agent_reasoning";text="Synthetic activity"}}|ConvertTo-Json -Compress
            [IO.File]::AppendAllText($sessionFile,($newEvent+"`n"),[Text.UTF8Encoding]::new($false))
        }
        if (-not $launched.WaitForExit(5000) -or $launched.ExitCode -ne 0) { throw "The GUI launcher did not exit cleanly for $version." }
        $descendants=@{}
        $timer=[Diagnostics.Stopwatch]::StartNew()
        do {
            foreach($descendant in @(Get-CimInstance Win32_Process -Filter ("ParentProcessId="+$child.ProcessId))) {
                $descendantId=[int]$descendant.ProcessId
                if($descendants.ContainsKey($descendantId)){continue}
                try {
                    $observed=[Diagnostics.Process]::GetProcessById($descendantId)
                    [void]$observed.Handle
                    $descendants[$descendantId]=$observed
                    if($descendant.Name -in @("cmd.exe","powershell.exe","pwsh.exe","csc.exe","conhost.exe")){
                        $probeStart.Arguments=[string]$descendantId
                        $nestedProbe=[Diagnostics.Process]::Start($probeStart)
                        if($nestedProbe.WaitForExit(5000) -and $nestedProbe.ExitCode -eq 1){throw "A child console was visible for $version."}
                    }
                } catch [ArgumentException] { }
            }
            $finished=$powerShell.WaitForExit(100)
        } while(-not $finished -and $timer.ElapsedMilliseconds -lt 30000)
        if (-not $finished) { throw "The monitor did not finish its snapshot for $version; the test process was not terminated." }
        foreach($observed in $descendants.Values){if(-not $observed.WaitForExit(5000)){throw "A test child process did not exit for $version; it was not terminated."}}
        if ($powerShell.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $snapshot)) { throw "The monitor did not render its test snapshot for $version (exit $($powerShell.ExitCode), snapshot $(Test-Path -LiteralPath $snapshot))." }
        $allFinished = $true
        if ($version -eq "current-source") {
            . (Join-Path $appRoot "DiagnosticPolicy.ps1")
            . (Join-Path $appRoot "DiagnosticStore.ps1")
            $events = @(Read-DiagnosticEvents -Directory $diagnostic -Now ([DateTimeOffset]::UtcNow) -RetentionDays 7 -MaximumBytes 10000000)
            if (@($events|Where-Object type -eq "task_observed").Count -ne 1) { throw "The launched source did not observe the live synthetic Codex task." }
        }
        if ($EvidenceDirectory) {
            if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) { [void][IO.Directory]::CreateDirectory($EvidenceDirectory) }
            Copy-Item -LiteralPath $snapshot -Destination (Join-Path $EvidenceDirectory ($version+".png"))
        }
        Write-Output "$version`: GUI launcher -> PowerShell; no visible console; monitor exited normally."
    }
} finally {
    if ($null -ne $lockOwner) { $lockOwner.Dispose() }
    if ($allFinished -and (Test-Path -LiteralPath $root)) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    if (-not $allFinished) { Write-Warning "Test files were preserved until all test processes have exited: $root" }
}
