param(
    [Parameter(Mandatory=$true)][string]$PublishedSource,
    [Parameter(Mandatory=$true)][string]$OutputFile,
    [Parameter(Mandatory=$true)][string]$FixtureRoot,
    [Parameter(Mandatory=$true)][ValidateSet('dark','light')][string]$Theme,
    [Parameter(Mandatory=$true)][ValidateSet('ru','en')][string]$Language,
    [Parameter(Mandatory=$true)][ValidateSet('old-plan','gap','unknown','multi')][string]$Scene
)
try {
    $isolatedInvocationConfirmed = & {
        param([string]$scriptPath, [string]$scriptDirectory)
        $ErrorActionPreference = 'Stop'
        function Assert-PrototypeIsolatedInvocation { throw 'The test safety helper did not load.' }
        $null = . (Join-Path $scriptDirectory '../Assert-PrototypeIsolatedInvocation.ps1')
        $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $confirmation = @(Assert-PrototypeIsolatedInvocation -ProcessArguments ([Environment]::GetCommandLineArgs()) `
                -ScriptPath $scriptPath -ExecutablePath $currentProcess.MainModule.FileName `
                -PowerShellRoot $PSHOME -Edition $PSVersionTable.PSEdition)
            if ($confirmation.Count -ne 1 -or $confirmation[0] -isnot [bool] -or -not $confirmation[0]) {
                throw 'The test safety helper did not confirm an isolated invocation.'
            }
        } finally { $currentProcess.Dispose() }
        return $true
    } $PSCommandPath $PSScriptRoot
} catch { throw "Prototype safety guard failed: $($_.Exception.Message)" }
if ($isolatedInvocationConfirmed -ne $true) { throw 'Prototype safety guard failed to confirm an isolated invocation.' }

# Reference capture body starts below the invocation guard.
$ErrorActionPreference = 'Stop'
function IsWithin([string]$path, [string]$root) {
    $path = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
    $root = [IO.Path]::GetFullPath($root).TrimEnd('\','/')
    return $path.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
$fixture = [IO.Path]::GetFullPath($FixtureRoot)
$output = [IO.Path]::GetFullPath($OutputFile)
$sourcePath = [IO.Path]::GetFullPath($PublishedSource)
if (-not (IsWithin $output $fixture)) { throw 'Reference output must be inside the isolated fixture directory.' }
foreach ($profile in @($env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA)) {
    if (-not [string]::IsNullOrWhiteSpace($profile) -and ((IsWithin $fixture $profile) -or (IsWithin $sourcePath $profile))) {
        throw 'Reference inputs and outputs must be outside the user profile.'
    }
}
foreach ($path in @($fixture,[IO.Path]::GetDirectoryName($output),[IO.Path]::GetDirectoryName($sourcePath))) {
    $ancestor = [IO.DirectoryInfo]::new($path)
    while ($null -ne $ancestor) {
        if ($ancestor.Exists -and (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Reference paths must not have a reparse-point ancestor.' }
        $ancestor = $ancestor.Parent
    }
}
if (([IO.File]::GetAttributes($sourcePath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The reference source must not be a reparse point.' }
$fakeHome = Join-Path $fixture 'published-reference-fixture/home'
$fakeAppData = Join-Path $fixture 'published-reference-fixture/appdata'
$fakeLocalData = Join-Path $fixture 'published-reference-fixture/localappdata'
$fakeTemp = Join-Path $fixture 'published-reference-fixture/temp'
foreach ($path in @($fakeHome,$fakeAppData,$fakeLocalData,$fakeTemp)) { [void][IO.Directory]::CreateDirectory($path) }
$env:USERPROFILE=$fakeHome; $env:HOME=$fakeHome; $env:APPDATA=$fakeAppData; $env:LOCALAPPDATA=$fakeLocalData
$env:CODEX_HOME=Join-Path $fakeHome 'codex-fixture'; $env:TEMP=$fakeTemp; $env:TMP=$fakeTemp
$env:PATH=(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot
$env:PSModulePath=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules'
$env:PSModuleAnalysisCachePath=Join-Path $fakeTemp 'ModuleAnalysisCache'
$expected = 'D289D809B093E3F9F7588E6C262E76FF49C9386DA39593278C4EFC61523023C9'
if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -cne $expected) { throw 'The published reference source does not match revision 1c44076.' }
$prototypeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach ($path in @('integrations','ClaudeRetention.cs','Configure-OpenCodeIntegration.ps1')) {
    if (Test-Path -LiteralPath (Join-Path $prototypeRoot $path)) { throw 'The isolated reference root contains provider files.' }
}
$source = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
$quotedRoot = "'" + $prototypeRoot.Replace("'","''") + "'"
$source = $source.Replace('$PSScriptRoot', $quotedRoot)
$old = '[IO.File]::Create($SnapshotFile)'
$new = '[IO.File]::Open($SnapshotFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)'
if ($source.IndexOf($old, [StringComparison]::Ordinal) -lt 0 -or
    $source.IndexOf($old, [StringComparison]::Ordinal) -ne $source.LastIndexOf($old, [StringComparison]::Ordinal)) {
    throw 'The published snapshot write expression changed.'
}
$source = $source.Replace($old, $new)
# Do not show a tray icon while the isolated reference window is rendered.
$trayOn = '$tray.Visible=$true'
if ($source.IndexOf($trayOn, [StringComparison]::Ordinal) -lt 0 -or
    $source.IndexOf($trayOn, [StringComparison]::Ordinal) -ne $source.LastIndexOf($trayOn, [StringComparison]::Ordinal)) {
    throw 'The published tray expression changed.'
}
$source = $source.Replace($trayOn, '$tray.Visible=$false')
$arguments = @{
    SnapshotFile = $output; PreviewActiveTasks = 1; CompactMode = $true
    ThemeOverride = $Theme; LanguageOverride = $Language; PreviewMotion = 'off'; PreviewOffscreen = $true
}
switch ($Scene) {
    'old-plan' { $arguments.PreviewScenario='planned'; $arguments.PreviewPlanUnconfirmed=$true }
    'gap' { $arguments.PreviewScenario='planned'; $arguments.PreviewPlanUnconfirmed=$true; $arguments.PreviewUnconfirmed=$true }
    'unknown' { $arguments.PreviewScenario='unplanned'; $arguments.PreviewUnconfirmed=$true }
    'multi' { $arguments.PreviewScenario='unplanned'; $arguments.PreviewActiveTasks=3 }
}
& ([ScriptBlock]::Create($source)) @arguments
