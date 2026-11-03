# Windows implementation

The Windows 11 version uses PowerShell 5.1, WPF, and a small native launcher. It supports expanded and compact always-on-top views, system/light/dark themes, Codex task discovery, and optional Claude Code hooks.

The current source also provides a local diagnostic journal and a configurable possible-loop warning for repeated Codex or Claude Code command failures. Claude monitoring uses events received after the monitor starts; unsupported or missing events may not be detected. The warning is heuristic, may flag intentional retries, and never stops a task. The journal excludes prompts, commands, output, task titles, and project paths; see [the privacy notice](../PRIVACY.md) for storage and retention details.

New builds create a Start-menu shortcut to the native Windows GUI launcher. It starts the monitor's PowerShell process without a visible console. An older installation retains its `.cmd` shortcut until updated; opening a `.cmd` file directly can still open Windows Terminal.

The current unsigned alpha installer is available from [GitHub Releases](https://github.com/trueakaru-stack/ai-task-monitor/releases). Windows may show a SmartScreen warning because the package has no trusted code-signing certificate yet.

Build locally from Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\app\Build-Installer-v2.ps1
```

The output is `windows\app\dist\AITaskMonitorSetup.exe`. Build output is ignored by Git; release binaries belong in GitHub Releases rather than the source tree.

