# Application icon: Windows verification

The supplied Figma icon is reused without alteration. The title-bar icon is 16 × 16 device-independent pixels, vertically centered, and separated from the title by 16 pixels, following the Windows title-bar guidance. Both full and compact windows were rendered from the current WPF source at 96 DPI in dark and light themes with synthetic task data. The icon is visible beside the title in all four fixtures; existing task cards and title controls retain their layout. The image does not accept focus or pointer input.

`Test-AppShellIdentity.ps1` verifies the application identity, taskbar icon resource, relaunch target and property cleanup on a hidden WPF window. `Test-AppIcon.ps1` verifies the Figma-derived ICO frames, tray frame and installer shortcut icon.

The user supplied a screenshot of the temporary preview on the actual Windows desktop on 2026-11-02. It shows the same application icon in the title bar and as a separate taskbar icon. The screenshot is not included in the repository because it also shows the user's desktop. The WPF snapshots and this screenshot do not establish real keyboard behavior, high-DPI behavior, or screen-reader behavior.

Reference: [Microsoft Windows app title bar](https://learn.microsoft.com/en-us/windows/apps/design/basics/titlebar-design).
