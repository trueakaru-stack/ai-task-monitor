# AI Task Monitor for macOS

Native SwiftUI alpha for macOS 13 and newer. The application runs locally, stays above ordinary windows, and shows active Codex and Claude Code work in expanded or compact form.

The local diagnostic journal records minimal event metadata. A configurable, non-blocking warning can flag repeated Codex or Claude Code command failures. A reliable approval-wait signal is not currently available.

## Behavior

- Activity is inferred from local session events. A session that started before the monitor is hidden until a new event is observed. A previously observed session can become unconfirmed when fresh evidence is unavailable. Source errors are displayed separately from an empty task list.
- Codex task data is read from the local `~/.codex` session store.
- Claude Code support is optional. The Settings screen adds local hooks to `~/.claude/settings.json` without replacing unrelated hooks.
- A published plan produces ordered stages and an exact completed-stage percentage.
- Without a plan, the current activity remains visible and the percentage is hidden.
- Exact percentages have no prefix; approximate upstream estimates use `≈`.
- Appearance follows macOS by default and can be set to light or dark.
- No administrator rights, cloud tokens, or account login are required.

## Diagnostics

- Settings provide a local journal with a task filter, confirmed manual clearing, and adjustable limits of 1–7 days and 1–10 MB. Automatic cleanup runs at startup and while the application is open; no background service is installed.
- The journal stores event time, source, type, and pseudonymous identifiers, not task text, prompts, commands, output, or project paths. The separate Claude event files are not governed by the journal's limits. See [privacy details](../PRIVACY.md).
- The possible-loop warning defaults to five identical command failures with the same nonzero exit code within ten minutes. The repeat count is configurable from 3 to 10 and the interval from 1 to 30 minutes. It can be dismissed, never stops a task, and may also identify intentional retries.
- Diagnostic tool events and loop detection depend on events the monitor can observe. Claude Code uses a bounded local channel while the monitor is running; unfamiliar failure formats and unobserved file changes can prevent a correct warning. Codex processing is bounded to the recent session-file tail and the last 4,096 matching tool events per refresh, so the journal is not a complete audit trail.

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

The result is a universal Apple silicon and Intel application inside `dist/AITaskMonitor-macOS-0.3.3-alpha.dmg`.

## Alpha installation

The current public alpha is ad-hoc signed, not notarized with an Apple Developer ID. macOS Gatekeeper can therefore block the first launch. For development review, use Finder's **Open** command from the context menu. A normal trusted release requires an Apple Developer Program certificate and notarization credentials.

## GitHub build

`.github/workflows/macos-build.yml` can run tests and render native dark/light screenshots. With `[tests-only]` in a commit message it skips the application and disk-image build. Other configured runs can create the universal app, verify its bundle and Claude hook, and upload the disk image, checksum, and screenshots as workflow artifacts.

