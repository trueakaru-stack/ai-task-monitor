# Isolated Codex loop tracker

This .NET 10 library is an **unconnected migration slice**. It accepts typed,
caller-supplied synthetic or previously validated events, a comparison key and
timestamps. It does not discover or read sessions, install hooks, open user
settings, make network requests, or connect itself to the application.

One tracker belongs to one session. **It is not thread-safe.** A caller must
serialize every operation on each instance, including reading or changing its
properties, copying and disposing it. Concurrent `Copy` and `Update` can throw.
The caller must also avoid mutating an event's command array during `Update`.
The future adapter must preserve input types and timestamps, handle source gaps
and unavailable or incomplete input safely, and prevent stale work from being
applied. Changing the threshold or window clears the current failure sequence
while retaining the bounded duplicate history. Copies own separate state.

The tracker retains keyed hashes instead of raw commands, paths and event IDs.
It copies its key and clears that copy on disposal. Raw input strings and
temporary managed strings may remain in memory; this is not secure input
erasure, encryption, or a general redactor. The caller must protect its own
key and avoid logging private inputs.

One-element command arrays are supported: Windows source `150672b` fixed the
previous detector's unwrapping bug. The typed adapter must preserve such arrays
for this behavior to work. For compatibility, the inherited event-ID regular
expression accepts a final newline; it is not a general validation boundary.

## Synthetic verification

Use Python 3.9 or newer, Git, an isolated .NET 10 SDK, and the Windows
PowerShell 5.1 executable already present on Windows. These are test tools;
the library has no runtime dependency on Git, Python or PowerShell. Run the
tests from a Git checkout or worktree, with absolute paths to the SDK, reference
directory and work directory. From the repository root, run:

```powershell
python .\windows\native\CodexLoop\Tests\run_synthetic_tests.py `
  --sdk-root '<isolated-sdk-directory>' `
  --reference-directory '<checkout-of-windows-app-source>' `
  --work-directory '<new-directory-outside-repository-and-user-profile>'
```

Before creating any work directory, the runner discovers the source repository
through a local Git query and rejects paths inside it. `USERPROFILE`, `APPDATA`
and `LOCALAPPDATA` must each name an existing absolute directory; `HOME`, if
present, must meet the same requirement. The runner resolves these directories
and rejects work paths inside them. If the repository or a required directory
cannot be verified, it stops without creating the work directory.

The profile guard relies on these environment variables. It does not identify
other users' profiles, prove that the variables were not deliberately changed,
or protect against a junction being swapped concurrently after validation. Use
a trusted local work directory outside all profiles and repositories.

The runner verifies the SHA-256 of the normalized `LoopDetection.ps1` and
`DiagnosticPolicy.ps1` source from `150672b` before creating its work directory,
copies them to a synthetic test directory, disables SDK telemetry and first-run
certificate generation, clears NuGet package sources, and compares 9,158
operations against the actual legacy functions. Checks include one-item arrays, thresholds, expiry,
dismissal, deduplication and eviction, settings changes, copied state, size
limits, unusual strings and out-of-order synthetic events. An independent
reviewer repeated the comparisons and separately checked copy, settings and key
cleanup. Scalar command rejection is separately covered by the Windows
`Test-LoopDetection.ps1`; this library's typed input cannot represent a scalar
command. Concurrent access, a source JSON adapter, real agent sessions,
application integration and the Windows installer are not verified by this
library's tests.
