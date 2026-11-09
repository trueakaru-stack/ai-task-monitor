# Isolated local Codex lifecycle reducer

This .NET 10 library is an unconnected migration slice. It accepts typed,
synthetic lifecycle events, a caller-provided lock observation, source update
time and monitor start time. It does not open files, discover sessions, inspect
locks, use a clock, connect to a provider, or perform network operations. One
immutable `LifecycleState` belongs to one session; the future caller owns
session identity, sequencing and synchronization.

`Incremental` means each supplied event is a complete, ordered continuation of
the preceding state. `FullHistory` discards lifecycle data and replays supplied
history while retaining the session's observation flag. The future reader must
detect truncation, file replacement, missed ranges, partial lines and source
errors; the reducer cannot prove that an input batch is complete or authentic.
It accepts only fields already selected by the caller, including the raw start
timestamp needed for the existing start key, and never stores full records.

The state reports an unreadable lock as a source error, not as a free lock. The
existing app separately marks previously displayed source tasks unconfirmed on
a source error; that source-wide behavior is not implemented here. Matching the
published reader, a terminal without a turn ID may close a known turn, and a
repeated start for an already completed turn can reactivate it. This slice does
not establish protection from delayed or duplicate lifecycle records. It also
does not implement discovery, long-history recovery, plans, activity text,
manual overrides, presentation, source permissions, or real agent monitoring.

Turn identifiers are matched exactly. A case-only mismatch is treated as a
source error because the identifier contract does not guarantee that the two
spellings identify the same turn. When the source is present, a turn ID with a control character, Unicode formatting character or
invalid UTF-16 rejects the whole batch as a source error, including a malformed
start or cached ID. When the source is absent, its events are ignored and an
unknown snapshot is returned instead. This
conservatively differs from the legacy invariant-culture comparison, which may ignore such characters
and affect a different turn. The caller must not turn this error into a
confirmed result. A valid full-history replay can replace a malformed cached
ID; an incremental batch cannot. This does not validate every possible future
Codex identifier or authenticate the source.

The differential test runs the published PowerShell lifecycle functions using
in-memory fake sessions and lock states, and compares their outputs with this
library. Explicit expected results and separate C# state checks supplement that
comparison. No real Codex profile is involved. Run with a trusted source file:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\native\Codex\Test-Codex.ps1 `
  -SdkRoot '<isolated .NET 10 SDK directory>' `
  -WorkDirectory '<directory outside the repository and user profile>' `
  -ReferenceSource '<published CodexProgress.ps1>'
```

Each run uses a new isolated home, temporary and package directory, disables
telemetry and first-run certificate generation, and clears NuGet sources. The
work directory must be outside the current profile, application data, and any
configured HOME or CODEX_HOME directories; neither variable is assigned by the
child test processes. The PowerShell executable is a test driver only; the
library does not depend on it.
