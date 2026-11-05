# Isolated native Claude event reader

This .NET 10 library contains the existing pure Claude event reader copied from
the C# block in `windows/app/ClaudeReaderCore.ps1`, with an isolated JSON adapter.
It accepts event-log text and caller-provided times; it does not read files,
install or run a hook, connect to an agent, or update the WPF prototype. The
build test checks the copied source against the existing reader to prevent an
unnoticed divergence. A later native caller must implement bounded and private
file reading, lifecycle, source failures and safe settings changes.

The Framework and native test runs use the same synthetic reader fixtures,
including plan restoration, invalid input, startup observation, privacy and a
10,000-event load. As with the provider adapter, the native parser deliberately
rejects some malformed JSON accepted by the Framework serializer; compatibility
with arbitrary malformed records and real sessions is not established. An
independent synthetic corpus also found different behavior for legacy JSON date
escapes under an artificial numeric culture with a changed negative sign: a
subject or tool can change, and an out-of-range date in an otherwise ignored
field can cause a record to be skipped. Arbitrary custom cultures are not proven
equivalent; the corpus does not establish that the normal hook emits this form.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\native\ClaudeReader\Test-ClaudeReader.ps1 `
  -SdkRoot '<isolated .NET 10 SDK directory>' `
  -WorkDirectory '<directory outside the repository and user profile>' `
  -PwshNet10 '<PowerShell executable running on .NET 10>'
```

PowerShell is a test driver only. Every child process runs in a fresh synthetic
home with a cleared environment, no NuGet feeds, and .NET telemetry and
first-run certificate generation disabled.
