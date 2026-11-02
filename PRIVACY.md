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

## Claude Code event data

In the current development sources, new hook events do not include the user's prompt or working-directory path. When no independent task title is available, the interface uses a neutral title. Events can still include a session identifier, tool name, step title, status, timestamp, and generated activity description; step titles and other text may themselves contain sensitive information. Hook input is size-limited and the event log is rotated by size, not by age.

Events written by older versions may still contain prompt text and working-directory paths. The macOS hook writes new events to a separate v2 file and does not remove or rewrite the older file. When a session produces new events, the reader may use matching legacy events to recover its plan without persisting them again. Disconnecting Claude Code removes only the exact hook command installed by AI Task Monitor and preserves unrelated hooks.

On macOS the new event file is `~/Library/Application Support/AI Task Monitor/claude-events-v2.jsonl`; the older file is `claude-events.jsonl` in the same directory. See the `windows` branch for the Windows implementation's paths and diagnostic-journal policy.

## Data transmission

AI Task Monitor does not transmit task data to the developer, OpenAI, Anthropic, Microsoft, or another service. Codex and Claude Code may have their own independent data practices; consult their respective policies.

## Data on macOS

The application reads Codex session data from `~/.codex`. When Claude Code integration is enabled, it stores normalized hook events in the v2 file described above. Connecting or disconnecting changes only application-owned hook entries in `~/.claude/settings.json`; before changing an existing settings file, it creates a uniquely named local backup. Such backups can contain sensitive settings and remain until the user removes them. Unsupported hook structures are not rewritten.

The diagnostic journal is stored separately under `~/Library/Application Support/AI Task Monitor/diagnostics`. It records event time, provider, type and pseudonymous task and event identifiers. It does not record task names, activity or plan text, prompts, commands, tool outputs, or project paths. Task titles shown in the journal filter are read from currently available task data and are not saved to the journal. Its collection depends on observed structured events and is not a complete audit trail.

The diagnostic retention settings allow 1–7 days and 1–10 MB. Cleanup removes the oldest diagnostic records at startup and while the application runs; manual clearing requires confirmation and does not remove the settings, key, provider history, or separate Claude event files. The size and retention settings do not apply to those Claude event files. No background cleanup service is installed.

Identifiers are keyed hashes. On macOS, the installation key is stored as a local owner-only file in an owner-only diagnostic directory; it is not stored in Keychain. The journal itself is not encrypted. Local metadata and independently stored provider data may still be sensitive.

For possible-loop detection, command and working-directory fingerprints use a fresh key in memory on each launch. The fingerprints, key, exit codes and retry history are not written to the diagnostic journal or settings. The configurable limits are stored with the diagnostic settings. A warning does not stop a task and can also flag an intentional retry.

## Removal

Removing the macOS application does not automatically remove its data in Application Support. For Windows removal behavior, see the privacy notice on the `windows` branch. Neither action removes Codex or Claude Code itself.

