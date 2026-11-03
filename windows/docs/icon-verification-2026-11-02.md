# Application icon verification — 2026-11-02

## Reference

Figma file `NNKzKQ5N1LXdQaJONFZj3N`, page `0:1`: `AI Task Monitor / App Icon` frames at 16, 32, 48, 64, 128, 256, 512, and 1024 pixels. Each PNG is exported from its corresponding frame, not redrawn or scaled from another size.

## Windows

- The six PNG payloads in `app/assets/app-icon.ico` match the source frame exports byte-for-byte.
- Windows GDI+ rendered the 16 px and 32 px ICO entries with zero pixel differences against their matching Figma exports.
- A synthetic-task WPF preview ran successfully with the icon-loading code enabled. The installer shortcut method was verified with a temporary shortcut.
- Full PowerShell script syntax and the installer C# source were checked.
- The taskbar and notification area were not visually inspected: the local preview window was not exposed to the computer-control surface. The native decoded icon files and WPF preview do not replace that final desktop check.

## macOS

- The exact Figma PNG exports and the `iconutil` iconset mapping are present in the source tree. The build script passes shell syntax checking.
- Finder/Dock rendering and creation of the `.icns` resource have not yet been tested on macOS. A macOS renderer is required for visual acceptance.

No installer or released artifact was rebuilt or replaced during this verification.
