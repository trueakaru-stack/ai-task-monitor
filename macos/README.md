# AI Task Monitor for macOS

Native SwiftUI alpha for macOS 13 and newer. The application runs locally, stays above ordinary windows, and shows active Codex and Claude Code work in expanded or compact form.

The diagnostic journal, approval-wait status, and loop warnings are not yet available on macOS.

## Behavior

- Activity is inferred from local session events. Old or quiet sessions can be misclassified; completed and stale sessions are filtered on a best-effort basis.
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

For the current test changes, also check the truncated-text tooltip in light and dark themes, in expanded and compact windows, near each edge of the screen. The tooltip should appear above the pointer when there is room, move to stay visible at an edge, and remain absent when the text fits. Share test results and screenshots made with synthetic task data only.

The result is a universal Apple silicon and Intel application inside `dist/AITaskMonitor-macOS-0.3.0-alpha.dmg`.

## Alpha installation

The current public alpha is ad-hoc signed, not notarized with an Apple Developer ID. macOS Gatekeeper can therefore block the first launch. For development review, use Finder's **Open** command from the context menu. A normal trusted release requires an Apple Developer Program certificate and notarization credentials.

## GitHub build

`.github/workflows/macos-build.yml` runs tests, creates the universal app, verifies its bundle and Claude hook, renders native dark/light screenshots, builds the disk image, and uploads the disk image, checksum, and screenshots as workflow artifacts.

