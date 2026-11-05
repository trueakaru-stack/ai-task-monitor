# Isolated Codex session discovery

This .NET 10 library is an unconnected migration slice. The caller supplies an
absolute sessions root, parsed index entries and, optionally, a monotonic
clock and filesystem implementation. The library does not read `CODEX_HOME`,
the user profile, the session index or session contents, start PowerShell, or
connect itself to the application. The caller is responsible for selecting a
trusted root. A caller-supplied network path or a filesystem link may lead
outside the physical directory; this library is not a filesystem sandbox.

`Find` accepts only `[A-Za-z0-9_-]{1,128}` and returns a file path or `null`.
It throws `SessionDiscoveryUnavailableException` for supported filesystem
access errors; an unavailable source must not be treated as an empty source.
`BeginCycle` validates all entries before changing state, clears short dated
misses, updates date hints and records index versions. The caller supplies the
same parsed calendar date that the published index reader would use; date and
timezone parsing are not implemented in this slice. Duplicate IDs are folded
to the last entry, like the published index map. Unlike the old internal
function, invalid public IDs are rejected before they reach filesystem calls.

The object synchronizes discovery, index updates and diagnostics with one gate.
Positive paths are rechecked, dated misses expire after one second or at the
next cycle, and absent IDs share one recursive snapshot. Index changes for
unresolved IDs restore the five-second retry and a 30-second hot period without
forcing an early scan. Recursive retries grow from 5 to 10, 20, 40 and at most
60 seconds when the hot period has elapsed. Failure remains an error until a
scheduled scan succeeds. The default clock uses `Stopwatch`; tests inject time.
On the tested Windows PowerShell 5.1 host, dated lookup excludes Hidden files,
including Hidden plus System, but includes a file with System alone. The shared
recursive fallback still includes both Hidden and System files. A synthetic
two-file ordinary match selected the same result in both implementations on
this filesystem; this does not establish ordering on other filesystems.

Like the published implementation, this slice does **not** bound the number
of files or duration of one recursive scan, nor the total cache size. A large
tree can consume memory and keep other callers waiting for the gate. Tests
measure scan counts, not performance or UI responsiveness. File ordering when
several names match, link and reparse-point traversal, unusual filesystems,
network shares, all Windows ACL combinations, and races between enumeration
and filesystem mutation have not been fully compared with Windows PowerShell
5.1. A single real `ListDirectory` denial/recovery and injected error paths
are tested on synthetic directories.

The caller still needs index reading and parsing, source-wide error handling,
lock inspection, lifecycle state, UI integration and packaging. This library
alone does not monitor agents or preserve previously shown tasks after an
unavailable source.

## Verification

On Windows, use an isolated .NET 10 SDK, a trusted reference source and an
empty work directory outside the repository and user profile:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
  -File '.\windows\native\CodexDiscovery\Test-CodexDiscovery.ps1' `
  -SdkRoot '<isolated-sdk-directory>' -WorkDirectory '<isolated-work-directory>' `
  -ReferenceSource '<published-CodexProgress.ps1>'
```

The runner creates a unique synthetic home, temporary and NuGet directories,
disables telemetry and first-run certificate generation, and clears NuGet
sources. It checks copied reference files by SHA-256, runs the existing
`Test-CodexSessionDiscovery.ps1` on the copied reference, then executes the
actual extracted `Session-File` and index-refresh block to produce filesystem
scenarios. The C# tests replay those operations in separate synthetic roots and
compare paths, source failures, scan decisions and retry intervals. Additional
checks cover unsafe IDs, timing boundaries, concurrency and ACL recovery. The
PowerShell processes are test drivers only; no PowerShell is used by the C#
library.
