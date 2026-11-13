# Native Claude loop detector

This .NET 10 library is an unfinished part of the Windows migration. A
`ClaudeLoopRegistry` accepts serialized observations or drains the existing
local `Channel` and tracks repeated failures separately for each session. It
supports dismissal, bounded session storage, and conservative resets on known
channel gaps, oversized batches, stopped channels and configuration changes.
Calls to a registry instance must be serialized by its owner.

This code is not connected to the application or a real Claude hook. The
caller must supply a trusted channel lifecycle and map session IDs to task
cards. The current channel does not authenticate a sender using the same
Windows account. The hook's trusted monitor PID, safe installation and
restart behavior are not implemented here. A silently lost event or an event
delayed across a settings change can lead to an incorrect warning; a known
gap instead discards the affected batch. The detector is not a security or
audit boundary.

The synthetic Windows checks in `windows/native/Tests/ClaudeLoop/` use
synthetic observations and unique local pipes; they do not open real Claude
profiles or register hooks. Run them only in a disposable hosted Windows
environment with isolated temporary/profile directories and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` for every SDK process. No dedicated CI run
for these checks is claimed here. They intentionally exercise the known
limitation that delayed events cannot be distinguished from new events. Real
Claude sessions, the complete application, accessibility and the installer
remain unverified.
