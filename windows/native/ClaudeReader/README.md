# Native Claude event reader

This .NET 10 library is an unfinished part of the Windows migration. `Reader`
interprets phase-aware Claude events, while `SessionReader` retains known step
names as unconfirmed after a detected loss. A new user message is not assumed to
start a different plan when the intervening history is missing. Known old and
new names may therefore appear together without confirmed status or progress.
This also applies when the same step ID is reused for different observed
names, including when both arrive before the first read. Without observed loss
or session uncertainty, an ordinary rename keeps its latest name. Retained
history is limited to 128 entries per session and is marked incomplete when
bounded; an overlong ID is represented internally by a SHA-256 identity and
also marks the retained plan incomplete. Values no longer present or observed
cannot be recovered.

`ClaudeFileSource` reads caller-supplied journal paths and connection state. It
limits each read to 4 MiB, waits for complete UTF-8 lines, and keeps previous
names when it detects a read error, truncation, or a changed tail at the previous
file boundary. This detects particular changes, not every possible replacement
or loss. Its memory of loss does not survive a process restart. It does not
discover a real profile, register hooks, or start itself in the application.

The phase-aware format must not be passed to the old reader: an older monitor
can misinterpret a phase event as a confirmed step. A separate journal and an
explicitly tested migration are required before the new hook can be connected.
A clear Stop event also does not prove that a different hook did not block the
stop; subsequent activity can make the task visible again. A failed writer may
be unable to record its own loss.
When no source-wide loss is known, an ambiguous later event without observed
activity does not by itself revive a card after a clear Stop. After a known
source-wide loss the retained fallback can remain visible as unconfirmed.
Later observed activity can show the card again, with uncertainty retained
where the source does not prove the full history.

The synthetic file tests create a new directory inside the process temporary
directory and accept no external event or fixture arguments. The WPF checks use
the same checked-in fixture and require Windows. They do not launch a real agent
or register hooks:

```powershell
dotnet run --project .\windows\native\Tests\ClaudeFileSource\ClaudeFileSource.Tests.csproj -c Release
dotnet run --project .\windows\native\Tests\ClaudeFileUi\ClaudeFileUi.Tests.csproj -c Release
dotnet run --project .\windows\native\Tests\ClaudeTitleRetention\ClaudeTitleRetention.Tests.csproj -c Release
```

Set the test process's temporary and profile directories to a disposable
location when isolation is required. `Test-ClaudeReader.ps1` is the earlier
source-identity check for the legacy embedded reader; the phase-aware native
reader intentionally diverges, so that older check is not an acceptance test for
this version. Real Claude sessions, final application integration and installer
behavior remain unverified.
