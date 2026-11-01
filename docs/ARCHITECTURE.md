# Architecture

AI Task Monitor normalizes provider-specific task information into one local task model:

- provider and task identity;
- task title and current activity;
- active or completed lifecycle state;
- exact, approximate, or unavailable progress;
- optional ordered plan steps.

The Windows user interface is implemented with WPF. It refreshes local provider state every two seconds and renders expanded, compact, and settings views. Product and privacy information appears as an About section inside Settings. The compact view is a monitoring surface only; settings are available in expanded mode.

Codex integration currently reads local task/session state. Claude Code integration uses an optional lifecycle hook that appends normalized bounded events to a local file. Neither adapter sends task content over the network.

The future macOS implementation should reuse the normalized task model and privacy rules but use native macOS windowing, notifications, signing, and sandbox conventions.

