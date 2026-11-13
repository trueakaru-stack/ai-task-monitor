param(
    [Parameter(Mandatory=$true)][string]$SdkRoot,
    [Parameter(Mandatory=$true)][string]$WorkDirectory,
    [string]$ReferenceDirectory = '',
    [string]$PublishedSource = ''
)

& {
    param([string]$scriptPath, [string]$scriptDirectory)
    . (Join-Path $scriptDirectory 'Assert-PrototypeIsolatedInvocation.ps1')
    $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
    try {
        Assert-PrototypeIsolatedInvocation -ProcessArguments ([Environment]::GetCommandLineArgs()) `
            -ScriptPath $scriptPath -ExecutablePath $currentProcess.MainModule.FileName `
            -PowerShellRoot $PSHOME -Edition $PSVersionTable.PSEdition
    } finally { $currentProcess.Dispose() }
} $PSCommandPath $PSScriptRoot

$ErrorActionPreference = 'Stop'
function Absolute-TestPath([string]$value, [string]$label) {
    if ([string]::IsNullOrWhiteSpace($value) -or -not [IO.Path]::IsPathRooted($value) -or
        $value -match '^[A-Za-z]:(?:$|[^\\/])' -or $value -match '^[\\/](?![\\/])' -or
        $value -match '^[\\/]{2}[?.][\\/]') {
        throw "$label must be an absolute path."
    }
    return [IO.Path]::GetFullPath($value)
}
function Assert-NoReparseAncestors([string]$path) {
    $ancestor = [IO.DirectoryInfo]::new($path)
    while ($null -ne $ancestor) {
        if ($ancestor.Exists -and (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Test and protected directories must not have a reparse-point ancestor.'
        }
        $ancestor = $ancestor.Parent
    }
}
$sdk = Absolute-TestPath $SdkRoot 'SDK directory'
$workBase = Absolute-TestPath $WorkDirectory 'Work directory'
$dotnet = Join-Path $sdk 'dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) { throw 'The isolated .NET SDK is missing.' }
foreach ($name in @('USERPROFILE','APPDATA','LOCALAPPDATA','HOME')) {
    $profile = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ($name -eq 'HOME' -and $null -eq $profile) { continue }
    $profilePath = (Absolute-TestPath $profile $name).TrimEnd('\','/')
    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) { throw "Cannot verify protected directory: $name." }
    Assert-NoReparseAncestors $profilePath
    $workPath = $workBase.TrimEnd('\','/')
    if ($workPath.Equals($profilePath, [StringComparison]::OrdinalIgnoreCase) -or
        $workPath.StartsWith($profilePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The work directory must be outside the current user profile and application data.'
    }
}
$sourceRoot = Absolute-TestPath $PSScriptRoot 'Source directory'
$repository = (Absolute-TestPath (Join-Path $sourceRoot '../../..') 'Repository directory').TrimEnd('\','/')
$workPath = $workBase.TrimEnd('\','/')
if ($workPath.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
    $workPath.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The work directory must be outside the repository.'
}
Assert-NoReparseAncestors $repository
Assert-NoReparseAncestors $workBase
$systemRoot = $env:SystemRoot
$systemValues = @{}
foreach ($name in @('ProgramFiles','ProgramFiles(x86)','ProgramW6432','ProgramData','ALLUSERSPROFILE','SystemDrive','ComSpec')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrEmpty($value)) { $systemValues[$name] = $value }
}
foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) { [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process') }
foreach ($name in $systemValues.Keys) { [Environment]::SetEnvironmentVariable($name, $systemValues[$name], 'Process') }
$env:SystemRoot = $systemRoot
$env:windir = $systemRoot
$env:PATH = (Join-Path $systemRoot 'System32') + ';' + $systemRoot
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + ';' + (Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\Modules')
[IO.Directory]::CreateDirectory($workBase) | Out-Null
$work = Join-Path $workBase ('prototype-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
@('home','appdata','localappdata','temp','nuget','obj','bin','runs') | ForEach-Object {
    New-Item -ItemType Directory -Force -Path (Join-Path $work $_) | Out-Null
}
$run = Join-Path (Join-Path $work 'runs') ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$env:DOTNET_ROOT = $sdk
$env:DOTNET_MULTILEVEL_LOOKUP = '0'
$env:DOTNET_CLI_HOME = Join-Path $work 'home'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = '0'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:NUGET_PACKAGES = Join-Path $work 'nuget'
$env:USERPROFILE = Join-Path $work 'home'
$env:APPDATA = Join-Path $work 'appdata'
$env:LOCALAPPDATA = Join-Path $work 'localappdata'
$env:TEMP = Join-Path $work 'temp'
$env:TMP = $env:TEMP
$env:PSModuleAnalysisCachePath = Join-Path $work 'temp/ModuleAnalysisCache'
$config = Join-Path $work 'NuGet.Config'
$configStream = [IO.File]::Open($config, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $configBytes = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>')
    $configStream.Write($configBytes, 0, $configBytes.Length)
} finally { $configStream.Dispose() }

$artifacts = Join-Path $work 'artifacts'
& $dotnet build (Join-Path $PSScriptRoot 'Prototype.csproj') --configuration Release --configfile $config `
    --artifacts-path $artifacts -p:NuGetAudit=false --nologo
if ($LASTEXITCODE -ne 0) { throw 'Prototype build failed.' }
$exe = Join-Path $artifacts 'bin\Prototype\release\AI Task Monitor.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The application executable is missing.' }
& $dotnet build (Join-Path $PSScriptRoot 'Tests/Prototype.Tests.csproj') --configuration Release --configfile $config `
    --artifacts-path $artifacts -p:NuGetAudit=false --nologo
if ($LASTEXITCODE -ne 0) { throw 'Synthetic WPF test build failed.' }
& $dotnet (Join-Path $artifacts 'bin/Prototype.Tests/release/AITaskMonitor.Prototype.Tests.dll')
if ($LASTEXITCODE -ne 0) { throw 'Synthetic event-to-WPF checks failed.' }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PrototypeNativeTest {
    private delegate bool EnumCallback(IntPtr handle, IntPtr state);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr state);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr handle, StringBuilder text, int count);
    public static IntPtr FindWindow(uint target) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((handle, state) => {
            uint owner;
            GetWindowThreadProcessId(handle, out owner);
            if (owner != target || !IsWindowVisible(handle)) return true;
            var title = new StringBuilder(256);
            GetWindowText(handle, title, title.Capacity);
            if (title.ToString() != "AI task monitor") return true;
            found = handle;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Start-Preview([string[]]$arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.WorkingDirectory = $run
    $info.UseShellExecute = $false
    # All caller-supplied paths are generated inside the isolated test directory.
    $info.Arguments = ($arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' '
    return [Diagnostics.Process]::Start($info)
}

function Wait-PreviewExit($process, [int]$timeoutMs) {
    if (-not $process.WaitForExit($timeoutMs)) { $process.Kill(); throw 'Preview timed out.' }
    if ($process.ExitCode -ne 0) { throw ('Preview failed with exit code ' + $process.ExitCode) }
}

function Assert-NoPowerShellDescendant([int]$processId) {
    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    $queue.Enqueue($processId)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        foreach ($child in @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId=$parent"))) {
            if ($child.Name -imatch '^(powershell|pwsh)(\.exe)?$') { throw 'A PowerShell child was found.' }
            $queue.Enqueue([int]$child.ProcessId)
        }
    }
}

function Find-AutomationId($root, [string]$id) {
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    return $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}

function Test-TextVisible($root, [string]$name) {
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $name)
    return $null -ne $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}

function Invoke-Control($root, [string]$id) {
    $element = Find-AutomationId $root $id
    if ($null -eq $element) { throw ('Automation control missing: ' + $id) }
    $pattern = $element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
}

$ready = Join-Path $run 'owner-ready.txt'
$ownerSnapshot = Join-Path $run 'owner.png'
$process = Start-Preview @('--theme','dark','--language','en','--scene','active','--offscreen','--snapshot',$ownerSnapshot,'--ready-file',$ready)
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $ready) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }
    if (-not (Test-Path -LiteralPath $ready) -or $process.HasExited) { throw 'Application did not create a live window.' }
    $process.Refresh()
    $handle = [PrototypeNativeTest]::FindWindow([uint32]$process.Id)
    if ($handle -eq [IntPtr]::Zero -or -not [PrototypeNativeTest]::IsWindowVisible($handle)) { throw 'The window is not visible.' }
    [uint32]$owner = 0
    [void][PrototypeNativeTest]::GetWindowThreadProcessId($handle, [ref]$owner)
    if ($owner -ne $process.Id) { throw 'The window is owned by a different process.' }
    if (-not [string]::Equals([IO.Path]::GetFullPath($process.MainModule.FileName), [IO.Path]::GetFullPath($exe), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The window owner is not the prototype executable.'
    }
    for ($i = 0; $i -lt 5; $i++) { Assert-NoPowerShellDescendant $process.Id; Start-Sleep -Milliseconds 200 }
    $modules = @($process.Modules | ForEach-Object { $_.ModuleName })
    if ($modules -icontains 'System.Management.Automation.dll') { throw 'The PowerShell engine was loaded.' }
    Write-Output ('Window owner: ' + $process.ProcessName + ', PID ' + $process.Id + '; no PowerShell child or engine observed.')

    $ui = [Windows.Automation.AutomationElement]::FromHandle($handle)
    $compactControl = Find-AutomationId $ui 'MinimizeButton'
    if ($null -eq $compactControl -or $compactControl.Current.Name -ne 'Compact view') { throw 'English accessibility label is incorrect.' }
    Invoke-Control $ui 'SampleProvider-codex'
    if (Test-TextVisible $ui 'Claude Code task') { throw 'The Codex sample filter still shows the Claude sample.' }
    Invoke-Control $ui 'SampleProvider-claude'
    if (-not (Test-TextVisible $ui 'Claude Code task')) { throw 'The Claude sample filter did not show its task.' }
    Invoke-Control $ui 'MinimizeButton'
    Invoke-Control $ui 'SampleTask-1'
    if (-not (Test-TextVisible $ui 'Claude Code task')) { throw 'The compact sample selector did not show its task.' }
    Invoke-Control $ui 'ExpandButton'
    if ($null -eq (Find-AutomationId $ui 'MinimizeButton')) { throw 'The preview did not return to the expanded layout.' }
    Invoke-Control $ui 'CloseButton'
    if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) { throw 'The preview did not close cleanly.' }
    Write-Output 'English accessibility label, synthetic provider filters, compact selection, layout transitions and close passed via UI Automation.'
} finally {
    if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
    $process.Dispose()
}

$scenarioTexts = [ordered]@{
    'state-kimi' = @('Kimi Code task','Status unconfirmed')
    'state-plan' = @('DeepSeek Harness task','Working','Step 5 of 8')
    'state-wait' = @('DeepSeek Harness task','Waiting for confirmation','Step 5 of 8')
    'state-unknown' = @('DeepSeek Harness task','Status unconfirmed')
    'state-gap' = @('DeepSeek Harness task','Status unconfirmed')
    'state-old-plan' = @('DeepSeek Harness task','Working')
    'state-end' = @('No active tasks')
    'state-multi' = @('DeepSeek Harness task','OpenCode task')
    'state-hermes' = @('Hermes Agent task','Working')
    'state-hermes-wait' = @('Hermes Agent task','Waiting for confirmation')
    'state-hermes-unknown' = @('Hermes Agent task','Status unconfirmed')
}
foreach ($scene in $scenarioTexts.Keys) {
    $signal = Join-Path $run ($scene + '-ready.txt')
    $p = Start-Preview @('--theme','dark','--language','en','--scene',$scene,'--offscreen','--ready-file',$signal)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath $signal) -and -not $p.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100; $p.Refresh()
        }
        if (-not (Test-Path -LiteralPath $signal) -or $p.HasExited) { throw ('Scenario did not open: ' + $scene) }
        $handle = [PrototypeNativeTest]::FindWindow([uint32]$p.Id)
        if ($handle -eq [IntPtr]::Zero) { throw ('Scenario window missing: ' + $scene) }
        $ui = [Windows.Automation.AutomationElement]::FromHandle($handle)
        foreach ($text in $scenarioTexts[$scene]) {
            if (-not (Test-TextVisible $ui $text)) { throw ('Expected scenario text missing: ' + $scene + ', ' + $text) }
        }
        if ($scene -in @('state-kimi','state-unknown','state-gap','state-old-plan','state-hermes-unknown') -and (Test-TextVisible $ui 'Step 5 of 8')) {
            throw ('Unconfirmed scenario claimed a current step: ' + $scene)
        }
        Invoke-Control $ui 'CloseButton'
        if (-not $p.WaitForExit(5000) -or $p.ExitCode -ne 0) { throw ('Scenario did not close: ' + $scene) }
    } finally {
        if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) }
        $p.Dispose()
    }
}
Write-Output 'Eleven built-in provider scenarios displayed their expected state text through UI Automation.'

foreach ($theme in @('dark','light')) {
    foreach ($language in @('ru','en')) {
        foreach ($scene in @('empty','active')) {
            $image = Join-Path $run ("$theme-$language-$scene.png")
            $p = Start-Preview @('--theme',$theme,'--language',$language,'--scene',$scene,'--offscreen','--snapshot',$image,'--exit-after-snapshot')
            try { Wait-PreviewExit $p 20000 } finally { $p.Dispose() }
            $bitmap = [Drawing.Bitmap]::new($image)
            try { if ($bitmap.Width -ne 590 -or $bitmap.Height -ne 760) { throw 'Unexpected expanded frame dimensions.' } } finally { $bitmap.Dispose() }
        }
        $image = Join-Path $run ("$theme-$language-compact.png")
        $p = Start-Preview @('--theme',$theme,'--language',$language,'--scene','active','--compact','--offscreen','--snapshot',$image,'--exit-after-snapshot')
        try { Wait-PreviewExit $p 20000 } finally { $p.Dispose() }
        $bitmap = [Drawing.Bitmap]::new($image)
        try { if ($bitmap.Width -ne 390 -or $bitmap.Height -ne 198) { throw 'Unexpected compact frame dimensions.' } } finally { $bitmap.Dispose() }
        foreach ($scene in @('state-kimi','state-plan','state-wait','state-unknown','state-gap','state-old-plan','state-end','state-multi','state-hermes','state-hermes-wait','state-hermes-unknown')) {
            $image = Join-Path $run ("$theme-$language-$scene.png")
            $p = Start-Preview @('--theme',$theme,'--language',$language,'--scene',$scene,'--offscreen','--snapshot',$image,'--exit-after-snapshot')
            try { Wait-PreviewExit $p 20000 } finally { $p.Dispose() }
            $bitmap = [Drawing.Bitmap]::new($image)
            try { if ($bitmap.Width -ne 590 -or $bitmap.Height -ne 760) { throw ('Unexpected scenario dimensions: ' + $scene) } } finally { $bitmap.Dispose() }
        }
        foreach ($scene in @('state-kimi','state-gap','state-old-plan','state-multi','state-hermes-wait')) {
            $image = Join-Path $run ("$theme-$language-$scene-compact.png")
            $p = Start-Preview @('--theme',$theme,'--language',$language,'--scene',$scene,'--compact','--offscreen','--snapshot',$image,'--exit-after-snapshot')
            try { Wait-PreviewExit $p 20000 } finally { $p.Dispose() }
            $expectedHeight = switch ($scene) { 'state-gap' { 182 }; 'state-old-plan' { 182 }; 'state-multi' { 198 }; default { 162 } }
            $bitmap = [Drawing.Bitmap]::new($image)
            try { if ($bitmap.Width -ne 390 -or $bitmap.Height -ne $expectedHeight) { throw ('Unexpected compact scenario dimensions: ' + $scene) } } finally { $bitmap.Dispose() }
        }
        Write-Output ("Synthetic frames rendered: $theme / $language")
    }
}

$marker = [byte[]](0,13,10,65,66,67,128,255)
foreach ($kind in @('snapshot','ready')) {
    $occupied = Join-Path $run ('occupied-' + $kind + '.bin')
    [IO.File]::WriteAllBytes($occupied, $marker)
    $image = if ($kind -eq 'snapshot') { $occupied } else { Join-Path $run 'ready-collision-image.png' }
    $arguments = @('--offscreen','--snapshot',$image,'--exit-after-snapshot')
    if ($kind -eq 'ready') { $arguments += @('--ready-file',$occupied) }
    $p = Start-Preview $arguments
    try {
        if (-not $p.WaitForExit(20000)) { $p.Kill(); throw 'Occupied output test timed out.' }
        if ($p.ExitCode -ne 3) { throw 'An occupied output path was not rejected.' }
    } finally { $p.Dispose() }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($occupied)) -cne [Convert]::ToBase64String($marker)) {
        throw 'An occupied synthetic file was changed.'
    }
}

$racePath = Join-Path $run 'snapshot-race.png'
$one = Start-Preview @('--offscreen','--snapshot',$racePath,'--exit-after-snapshot')
$two = Start-Preview @('--offscreen','--snapshot',$racePath,'--exit-after-snapshot')
try {
    if (-not $one.WaitForExit(20000) -or -not $two.WaitForExit(20000)) { throw 'Output race test timed out.' }
    if ((@($one.ExitCode,$two.ExitCode) | Sort-Object) -join ',' -cne '0,3') { throw 'Concurrent output creation was not exclusive.' }
    $bitmap = [Drawing.Bitmap]::new($racePath)
    try { if ($bitmap.Width -ne 590 -or $bitmap.Height -ne 760) { throw 'The winning snapshot is invalid.' } } finally { $bitmap.Dispose() }
} finally {
    foreach ($p in @($one,$two)) { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) }; $p.Dispose() }
}

[xml]$layout = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PublishedWindow.xaml'), [Text.Encoding]::UTF8)
$about = $layout.SelectSingleNode("//*[local-name()='TextBlock' and @*[local-name()='Name']='AboutVersionText']")
if ($null -eq $about -or -not $about.GetAttribute('Text').EndsWith('0.2.6 alpha')) { throw 'The published About version text is incorrect.' }
Write-Output 'Existing output files were preserved; concurrent snapshot creation was exclusive; About version text matches the published value.'

if ($PublishedSource) {
    $referenceShell = Join-Path $systemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $capture = Join-Path $PSScriptRoot 'Tests/Capture-PublishedCompact.ps1'
    foreach ($theme in @('dark','light')) {
        foreach ($language in @('ru','en')) {
            foreach ($scene in @('old-plan','gap','unknown','multi')) {
                $output = Join-Path $run ("reference-$theme-$language-$scene-compact.png")
                $info = New-Object Diagnostics.ProcessStartInfo
                $info.FileName = $referenceShell; $info.WorkingDirectory = $run; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
                $referenceArguments = @('-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',$capture,'-PublishedSource',$PublishedSource,'-OutputFile',$output,'-FixtureRoot',$run,'-Theme',$theme,'-Language',$language,'-Scene',$scene)
                foreach ($argument in $referenceArguments) { if ($argument.Contains('"') -or $argument.EndsWith('\')) { throw 'Unsupported reference argument.' } }
                $info.Arguments = ($referenceArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
                $p = [Diagnostics.Process]::Start($info)
                try { Wait-PreviewExit $p 30000 } finally { $p.Dispose() }
            }
            Write-Output ("Published compact references rendered: $theme / $language")
        }
    }
}

if ($ReferenceDirectory) {
    if (-not (Test-Path -LiteralPath $ReferenceDirectory -PathType Container)) { throw 'The published reference directory is missing.' }
    $comparison = @{ReferenceDirectory=$ReferenceDirectory;FramesDirectory=$run}
    if ($PublishedSource) { $comparison.CompareCompact = $true }
    & (Join-Path $PSScriptRoot 'Tests/Compare-ReferenceFrames.ps1') @comparison
    Write-Output 'Reference comparisons passed outside the documented title, activity and plan-metadata masks.'
} else {
    Write-Output 'Reference comparison was not run: specify -ReferenceDirectory.'
}
if (-not $PublishedSource) { Write-Output 'Published compact scenario comparison was not run: specify -PublishedSource.' }

$invalidCases = @(
    @('--theme','invalid'),
    @('--scene','{}'),
    @('--scene',(Join-Path $run 'not-an-input.json'))
)
foreach ($arguments in $invalidCases) {
    $bad = Start-Preview $arguments
    try {
        if (-not $bad.WaitForExit(10000)) { $bad.Kill(); throw 'Invalid-argument check timed out.' }
        if ($bad.ExitCode -ne 2) { throw 'Invalid arguments or external event inputs were not rejected.' }
    } finally { $bad.Dispose() }
}
Write-Output ('Synthetic frames and argument validation passed: ' + $run)
