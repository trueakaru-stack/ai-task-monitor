$ErrorActionPreference = "Stop"

$assets = Join-Path (Join-Path $PSScriptRoot "..\app") "assets"
$iconPath = Join-Path $assets "app-icon.ico"
$bytes = [IO.File]::ReadAllBytes($iconPath)
$sizes = @(16, 32, 48, 64, 128, 256)

if ([BitConverter]::ToUInt16($bytes, 0) -ne 0 -or
    [BitConverter]::ToUInt16($bytes, 2) -ne 1 -or
    [BitConverter]::ToUInt16($bytes, 4) -ne $sizes.Count) {
    throw "Invalid application ICO header."
}

for ($i = 0; $i -lt $sizes.Count; $i++) {
    $entry = 6 + 16 * $i
    $size = [int]$bytes[$entry]
    if ($size -eq 0) { $size = 256 }
    $length = [BitConverter]::ToUInt32($bytes, $entry + 8)
    $offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
    $expected = [IO.File]::ReadAllBytes((Join-Path $assets "icon-$size.png"))
    if ($size -ne $sizes[$i] -or $length -ne $expected.Length -or $offset + $length -gt $bytes.Length) {
        throw "Invalid ICO entry for $size pixels."
    }
    for ($j = 0; $j -lt $expected.Length; $j++) {
        if ($bytes[$offset + $j] -ne $expected[$j]) {
            throw "ICO entry $size does not match the Figma export."
        }
    }
}

Add-Type -AssemblyName System.Drawing
$trayIcon = [Drawing.Icon]::new($iconPath, 16, 16)
try {
    if ($trayIcon.Width -ne 16 -or $trayIcon.Height -ne 16) {
        throw "The notification-area icon has unexpected dimensions."
    }
} finally {
    $trayIcon.Dispose()
}

Add-Type -AssemblyName PresentationCore
$decoder = [Windows.Media.Imaging.BitmapDecoder]::Create(
    [Uri]::new($iconPath, [UriKind]::Absolute),
    [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
    [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
if (@($decoder.Frames | Where-Object { $_.PixelWidth -eq 32 -and $_.PixelHeight -eq 32 }).Count -ne 1) {
    throw "The taskbar icon frame cannot be decoded."
}

Add-Type -AssemblyName System.Windows.Forms
$installerPath = Join-Path (Join-Path $PSScriptRoot "..\app") "CodexProgressInstaller.cs"
$types = Add-Type -Path $installerPath -ReferencedAssemblies "System.Windows.Forms" -PassThru
$installer = $types | Where-Object { $_.Name -eq "CodexProgressInstaller" }
$method = $installer.GetMethod("CreateShortcut", [Reflection.BindingFlags]"NonPublic,Static")
if ($null -eq $method) { throw "Installer shortcut method is unavailable." }
$shortcutPath = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-icon-test-" + [Guid]::NewGuid().ToString("N") + ".lnk")
$targetPath = Join-Path $PSHOME "powershell.exe"
try {
    [string[]]$shortcutArguments = @($shortcutPath, $targetPath, $PSScriptRoot, $iconPath)
    [void]$method.Invoke($null, $shortcutArguments)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    if ($shortcut.IconLocation -ne ($iconPath + ",0")) {
        throw "Installer shortcut does not point at the application icon."
    }
} finally {
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath }
}

Write-Output "Application icon: Figma entries, tray, WPF frame, and installer shortcut verified."
