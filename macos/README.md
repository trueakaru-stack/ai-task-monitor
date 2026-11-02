# AI Task Monitor for macOS

Native SwiftUI alpha for macOS 13 and newer. The application runs locally, stays above ordinary windows, and shows active Codex and Claude Code work in expanded or compact form.

## Behavior

- Only active sessions are shown. Completed, stopped, and stale sessions are excluded.
- Codex task data is read from the local `~/.codex` session store.
- Claude Code support is optional. The Settings screen adds local hooks to `~/.claude/settings.json` without replacing unrelated hooks.
- A published plan produces ordered stages and an exact completed-stage percentage.
- Without a plan, the current activity remains visible and the percentage is hidden.
- Exact percentages have no prefix; approximate upstream estimates use `≈`.
- Appearance follows macOS by default and can be set to light or dark.
- No administrator rights, cloud tokens, or account login are required.

Task titles, activity, plans, and hook events stay on the Mac. See the repository [privacy notice](../PRIVACY.md).

## Build

Requirements: macOS 13 or newer and a current Xcode installation with Swift 5.10 or newer.

```bash
cd macos
swift test
./scripts/build-app.sh
./scripts/smoke-test.sh "dist/AI Task Monitor.app"
./scripts/create-dmg.sh
```

The result is a universal Apple silicon and Intel application inside `dist/AITaskMonitor-macOS-0.3.0-alpha.dmg`.

## Alpha installation

The current public alpha is ad-hoc signed, not notarized with an Apple Developer ID. macOS Gatekeeper can therefore block the first launch. For development review, use Finder's **Open** command from the context menu. A normal trusted release requires an Apple Developer Program certificate and notarization credentials.

## GitHub build

`.github/workflows/macos-build.yml` runs tests, creates the universal app, verifies its bundle and Claude hook, renders native dark/light screenshots, builds the disk image, and uploads the disk image, checksum, and screenshots as workflow artifacts.

