$ErrorActionPreference = "Stop"
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$appRoot = Join-Path $PSScriptRoot "..\app"
Add-Type -Path (Join-Path $appRoot "AppShellIdentity.cs")
$icon = [IO.Path]::GetFullPath((Join-Path $appRoot "assets\app-icon.ico"))
$launcher = Join-Path $env:WINDIR "notepad.exe"
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "The test launcher is unavailable." }
$window = [Windows.Window]::new()
$window.ShowInTaskbar = $false
$handle = [Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
try {
    [AITaskMonitor.Windows.AppShellIdentity]::Apply($handle, $icon, $launcher)
    if ([AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle, 5) -cne [AITaskMonitor.Windows.AppShellIdentity]::AppId) { throw "The window AppUserModelID was not set." }
    if ([AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle, 3) -cne ($icon + ',0')) { throw "The taskbar icon resource was not set." }
    if ([AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle, 2) -cne ('"' + $launcher + '"')) { throw "The taskbar relaunch target was not set." }
    if ([AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle, 4) -cne "AI task monitor") { throw "The taskbar display name was not set." }
    [AITaskMonitor.Windows.AppShellIdentity]::Clear($handle)
    foreach ($id in @(2, 3, 4, 5)) {
        if ($null -ne [AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle, $id)) { throw "Window identity properties were not cleared." }
    }
    Write-Output "Taskbar identity: AppUserModelID, icon, relaunch target and cleanup verified on a hidden WPF window."
} finally {
    $window.Close()
}
