# Privacy

## Summary

AI Task Monitor processes task information locally on the user's computer. The application does not contain analytics, advertising, remote logging, or its own network client.

## Data read on Windows

- Codex session indexes, task plans, lifecycle state, and local session records stored under the current user's Codex profile.
- Claude Code lifecycle events written by the optional local hook after the user connects Claude Code in Settings.
- Windows application-theme and accent-color settings.

## Data stored on Windows

- Theme preference.
- A bounded local Claude Code event log when the optional integration is enabled.

Claude hook input is size-limited. Stored text is truncated, transcript paths are not retained, and the event log is rotated. Disconnecting Claude Code removes only the exact hook command installed by AI Task Monitor and preserves unrelated hooks.

## Data transmission

AI Task Monitor does not transmit task data to the developer, OpenAI, Anthropic, Microsoft, or another service. Codex and Claude Code may have their own independent data practices; consult their respective policies.

## Data on macOS

The application reads Codex session data from `~/.codex`. When Claude Code integration is enabled, it stores normalized hook events at `~/Library/Application Support/AI Task Monitor/claude-events.jsonl`. Enabling integration modifies only the application-owned hook entries in `~/.claude/settings.json` and first creates a timestamped backup. Disconnecting removes only those owned hook commands.

## Removal

The Windows uninstaller removes the application files, shortcut, and AI Task Monitor local data directory. It does not remove Codex, Claude Code, or unrelated provider settings.

