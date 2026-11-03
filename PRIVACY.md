# Privacy

## Summary

AI Task Monitor processes task information locally on the user's computer. The application does not contain analytics, advertising, or remote logging. It checks public GitHub releases for updates as described below.

## Data read on Windows

- Codex session indexes, task plans, lifecycle state, and local session records stored under the current user's Codex profile.
- Claude Code lifecycle events written by the optional local hook after the user connects Claude Code in Settings.
- Windows application-theme and accent-color settings.

## Data stored on Windows

- Theme preference.
- A bounded local Claude Code event log when the optional integration is enabled.
- A separate local diagnostic journal and its retention settings.

## Windows diagnostic journal

The diagnostic journal is stored under `%LOCALAPPDATA%\CodexTaskProgress\diagnostics`. It records the event time, provider, event type and pseudonymous task and event identifiers. The current Windows implementation records task and source-state changes, generic Codex tool starts and finishes when the corresponding source events can be paired, and command failures only when the source supplies a structured failed status and nonzero exit code. It does not record prompts, commands, tool output, task names, step text or project paths in this journal. It does not infer a tool error from arbitrary output. Task names used by the on-screen filter are read from the currently available source data and are not added to the diagnostic journal.

Settings permit retention from one to seven days and a journal size from 1 to 10 MB. The oldest diagnostic events are removed to meet the configured limits while the application runs and on its next launch; no separate cleanup service runs in the background. Manual clearing requires confirmation and affects this diagnostic journal, not Codex history or the separate Claude Code event log.

If the Windows diagnostic file contains an unsupported or incomplete record, automatic updates and cleanup stop instead of silently discarding that record. The user can still clear a recognized journal after confirmation; an unrelated file without the diagnostic format marker is not replaced.

Task identifiers are keyed hashes. The installation key is protected for the current Windows user using Windows Data Protection; the diagnostic event file itself is not encrypted. On first creation, the application restricts the diagnostic directory to the current user and Windows SYSTEM. Existing directory permissions are not silently changed. Local metadata and independently stored provider files can still be sensitive.

## Possible-loop warning on Windows

The optional warning compares recent command-failure events within each observed Codex or Claude Code task. To recognize repeated commands, the application calculates a keyed fingerprint of the command and working directory in memory using a fresh key on each launch. For Claude Code, the hook uses a local Windows named pipe restricted to the current user and SYSTEM; it sends a keyed fingerprint, a session and tool identifier, event type, and, when available, the exit code. It does not send the command, working directory or error output through the pipe. Other processes running as the same user are within the same local trust boundary.

The fingerprints, key, exit codes and repetition history are not written to the diagnostic journal, Claude event files or settings. The configurable repetition count and time window are stored with the diagnostic settings. The warning is a heuristic: missing events, unrecognized error formats and file changes outside the observed edit tools can affect it. It does not stop or modify a task and can occasionally identify an intentional retry.

## macOS diagnostic journal

The macOS implementation stores diagnostic metadata separately under `~/Library/Application Support/AI Task Monitor/diagnostics`, with the same selectable retention and size limits and a confirmed clear action. It records event time, provider, type and pseudonymous task and event identifiers, not task names, activity or plan text, prompts, commands, tool outputs or project paths. Structured event collection is bounded to the recent session-file tail and is not a complete audit trail. The limits do not apply to the separate Claude event files.

On macOS the key for pseudonymous identifiers is stored as an owner-only file in an owner-only diagnostic directory, not in Keychain. The journal itself is not encrypted. The Codex and Claude Code loop comparisons use fresh in-memory keys per launch and do not persist command fingerprints, exit codes or retry history. Claude's local socket is owner-only, and peers are checked against the current user. Removing the macOS application does not automatically remove its Application Support data.

## Claude Code event data

In the current development sources, new hook events do not include the user's prompt or working-directory path. When no independent task title is available, the interface uses a neutral title. Events can still include a session identifier, tool name, step title, status, timestamp, and generated activity description; step titles and other text may themselves contain sensitive information. Hook input is size-limited and the event log is rotated by size, not by age.

Events written by older versions may still contain prompt text and working-directory paths. The new hook writes to a separate v2 file and does not remove or rewrite the older file. When a session produces new events, the reader may use matching legacy events to recover its plan without persisting them again. Disconnecting Claude Code removes only the exact hook command installed by AI Task Monitor and preserves unrelated hooks.

The new event file is `%LOCALAPPDATA%\CodexTaskProgress\claude-events-v2.jsonl` on Windows and `~/Library/Application Support/AI Task Monitor/claude-events-v2.jsonl` on macOS by default. The older file is `claude-events.jsonl` in the same directory. The diagnostic journal's age and size controls do not apply to either Claude event file.

## Data transmission

AI Task Monitor does not transmit task data to the developer, OpenAI, Anthropic, Microsoft, or another service. Codex and Claude Code may have their own independent data practices; consult their respective policies.

In the standalone Windows and macOS editions, at startup and once every 24 hours while open, the application requests the public release list from GitHub without authentication or cookies. GitHub receives the network request and IP address; no task titles, activity, prompts, commands, paths, identifiers, or journal contents are sent. The app checks only for a newer release with a package for the current platform, including alpha releases. Downloads open in the user's browser only after the user chooses «Скачать»; installation remains manual. Choosing «Позже» suppresses that version until the next application launch. The app does not display the notification in compact mode. The Microsoft Store edition does not check GitHub for EXE updates; Microsoft Store manages its updates.

«Отзывы и предложения» opens a preaddressed email draft in the user's mail application. No task or diagnostic information is inserted, and the user decides whether to write and send the message.

## Removal

The Windows uninstaller removes the application files and shortcut but leaves AI Task Monitor's settings, Claude event files, and diagnostic journal in the local data directory. It does not remove Codex, Claude Code, or unrelated provider settings.

