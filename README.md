# AI Task Monitor

AI Task Monitor is an open-source desktop utility for viewing active Codex and Claude Code tasks in one compact window.

The application shows the current action and displays progress only when it can be supported by available task data. Exact progress is shown as a number, estimated progress uses `≈`, and activity without a reliable estimate has no percentage. Settings are available only in the expanded window; compact mode is reserved for monitoring.

## Current status

Version 0.2.0 alpha is under active review. No public installer is published yet.

- `main` contains public documentation and reviewed screenshots.
- `windows` contains the current Windows 11 implementation.
- `macos` is reserved for a future native macOS implementation. It does not yet contain a working application.

## Screenshots

| Expanded | Compact |
| --- | --- |
| ![Expanded dark](screenshots/expanded-dark.png) | ![Compact dark](screenshots/compact-dark.png) |
| ![Expanded light](screenshots/expanded-light.png) | ![Compact light](screenshots/compact-light.png) |

The preview data in these screenshots is synthetic and contains no user task content.

## Privacy

Task information is processed locally. AI Task Monitor does not upload task titles, actions, plans, or logs. Read [PRIVACY.md](PRIVACY.md) for the exact local data paths and behavior.

## Independence

AI Task Monitor is an independent project. It is not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic. Codex and Claude Code are referenced only to identify compatible task sources.

## Releases

Installation packages will be published through GitHub Releases only after reproducible build checks, malware scanning, clean install/uninstall testing, and platform signing are complete.

## License

No open-source license has been selected yet. Until a license is added, the source is available for review but reuse and redistribution are not granted.

