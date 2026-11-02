# Architecture

AI Task Monitor normalizes provider-specific task information into one local task model:

- provider and task identity;
- task title and current activity;
- active or completed lifecycle state;
- exact, approximate, or unavailable progress;
- optional ordered plan steps.

The Windows user interface is implemented with WPF. The macOS user interface is implemented with SwiftUI and AppKit window configuration. Both refresh local provider state every two seconds and render expanded, compact, and settings views. Product and privacy information appears as an About section inside Settings. The compact view is a monitoring surface only; settings are available in expanded mode.

Codex integration currently reads local task/session state. Claude Code integration uses an optional lifecycle hook that appends normalized bounded events to a local file. Neither adapter sends task content over the network.

The macOS application reads Codex sessions from `~/.codex`, stores normalized Claude hook events under `~/Library/Application Support/AI Task Monitor`, and uses a floating native window. The application is not App Sandbox-enabled because its purpose requires user-scoped access to provider-owned local task stores. It does not request administrator privileges or network access.

