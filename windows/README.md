# Windows implementation

The Windows 11 version uses PowerShell 5.1, WPF, and a small native launcher. It supports expanded and compact always-on-top views, system/light/dark themes, Codex task discovery, and optional Claude Code hooks.

The current unsigned alpha installer is available from [GitHub Releases](https://github.com/trueakaru-stack/ai-task-monitor/releases). Windows may show a SmartScreen warning because the package has no trusted code-signing certificate yet.

Build locally from Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\app\Build-Installer-v2.ps1
```

The output is `windows\app\dist\AITaskMonitorSetup.exe`. Build output is ignored by Git; release binaries belong in GitHub Releases rather than the source tree.

