# Privacy

## Summary

AI Task Monitor processes task information locally on the user's computer. The application does not contain analytics, advertising, or remote logging. It checks public GitHub releases for updates as described below.

## Data read on macOS

- Codex session indexes, task plans, lifecycle state, and local session records stored under the current user's Codex profile.
- Claude Code lifecycle events written by the optional local hook after the user connects Claude Code in Settings.
- macOS appearance, language and accent-color settings.

## Data stored on macOS

- Theme and language preferences.
- A bounded local Claude Code event log when the optional integration is enabled.

## Claude Code event data

New hook events do not include the user's prompt or working-directory path. When no independent task title is available, the interface uses a neutral title. Events can still include a session identifier, tool name, step title, status, timestamp, and generated activity description; step titles and other text may themselves contain sensitive information. Hook input is size-limited.

Events written by older versions may still contain prompt text and working-directory paths. The macOS hook writes new events to a separate v2 file. When a session produces new events, the reader may use matching legacy events to recover its plan without persisting them again. Disconnecting Claude Code removes only the exact hook command installed by AI Task Monitor and preserves unrelated hooks.

On macOS the new event file is `~/Library/Application Support/AI Task Monitor/claude-events-v2.jsonl`; the older file is `claude-events.jsonl` in the same directory. Separate controls set their combined retention to 1–30 days and 1–100 MB; defaults are 7 days and 10 MB. The application removes the oldest recognized complete events during operation and at the next launch. The hook also bounds the current file by the chosen size; temporary increases are possible between checks. Busy, invalid, incomplete or linked files are not automatically pruned. No background cleanup service is installed. See the `windows` branch for its paths and policies.

## Data transmission

AI Task Monitor does not transmit task data to the developer, OpenAI, Anthropic, Microsoft, or another service. Codex and Claude Code may have their own independent data practices; consult their respective policies.

At startup and once every 24 hours while open, the application requests the public release list from GitHub without authentication or cookies. GitHub receives the network request and IP address; no task titles, activity, prompts, commands, paths, identifiers, or journal contents are sent. The app checks only for a newer release with a package for the current platform, including alpha releases. Downloads open in the user's browser only after the user chooses «Скачать»; installation remains manual. Choosing «Позже» suppresses that version until the next application launch. The app does not display the notification in compact mode.

«Отзывы и предложения» displays a selectable email address and offers a preaddressed draft through the system's `mailto:` handler. A browser may open if it is configured as that handler; the address can instead be copied. No task or diagnostic information is inserted, and the user decides whether to write and send the message.

## Data on macOS

The application reads Codex session data from `~/.codex`. When Claude Code integration is enabled, it stores normalized hook events in the v2 file described above. Connecting or disconnecting changes only application-owned hook entries in `~/.claude/settings.json`; before changing an existing settings file, it creates a uniquely named local backup. The application deletes its own backups older than 30 days but retains the newest regardless of age. Backups can contain sensitive settings. Unsupported hook structures are not rewritten.

The diagnostic journal is stored separately under `~/Library/Application Support/AI Task Monitor/diagnostics`. It records event time, provider, type and pseudonymous task and event identifiers. It does not record task names, activity or plan text, prompts, commands, tool outputs, or project paths. Task titles shown in the journal filter are read from currently available task data and are not saved to the journal. Its collection depends on observed structured events and is not a complete audit trail.

The diagnostic retention settings allow 1–7 days and 1–10 MB. Cleanup removes the oldest diagnostic records at startup and while the application runs; manual clearing requires confirmation and does not remove the settings, key, provider history, or separate Claude event files. The size and retention settings do not apply to those Claude event files. No background cleanup service is installed.

Identifiers are keyed hashes. On macOS, the installation key is stored as a local owner-only file in an owner-only diagnostic directory; it is not stored in Keychain. The journal itself is not encrypted. Local metadata and independently stored provider data may still be sensitive.

For possible-loop detection in Codex and Claude Code, command and working-directory fingerprints use a fresh key in memory on each launch. Claude's short-lived hook communicates with the running monitor through a local Unix-domain socket in an owner-only directory under `/private/tmp`. The endpoint checks that its peer runs as the current user. The hook sends only a keyed fingerprint, session and tool identifiers, event type, and a reliably parsed exit code; it does not send the command, working directory or error output through the socket. Other processes running under the same account share that trust boundary. The directory may retain an empty ownership-lock file; it contains no key or event data.

The fingerprints, key, exit codes and retry history are not written to the diagnostic journal, Claude event files or settings. The configurable limits are stored with the diagnostic settings. A warning is heuristic, does not stop a task and can also flag an intentional retry. Missing events, unfamiliar error formats and file changes outside observed editing tools can affect detection.

## Removal

Removing the macOS application does not automatically remove its data in Application Support. For Windows removal behavior, see the privacy notice on the `windows` branch. Neither action removes Codex or Claude Code itself.

