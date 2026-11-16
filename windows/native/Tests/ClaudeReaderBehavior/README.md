# Synthetic Claude reader behavior comparison

The same in-memory test program is compiled twice: once with the actual reader
embedded in `windows/app/ClaudeReaderCore.ps1` using the Windows .NET Framework
compiler, and once against `windows/native/ClaudeReader/ClaudeReader.csproj`
using .NET 10. The program accepts only the fixed engine selector and does not
open files, profiles, hooks, accounts or network connections.

The common checks cover current and pre-start sessions, legacy-only sessions,
legacy step-name preservation, quiet and later activity, prompt identity,
generated activity privacy, a malformed current record, inferred and unnamed
old steps, an unambiguous clear stop and 10,000 synthetic events. The test also
records these observed differences:

- A simultaneous active and clear-stop event in one file hides the task in
  the embedded reader; the native reader keeps it unconfirmed.
- Malformed legacy-only input with no current IDs is not inspected by the
  embedded reader; the native reader records source loss, including for a
  later observed session.
- An embedded reader accepts a 129-unit session ID; the native reader
  rejects it rather than merging or truncating it.
- After a previously visible task stops and its history is later lost, the
  embedded reader retains the old step name as unconfirmed; the native reader
  does not retain that stopped name in this scenario. This is an **open C#
  behavior defect** against the agreed preservation of known step names. The
  test reports whether the defect remains; it does not require it to persist.

These are selected behaviors, not an exhaustive diff or proof of equivalence.
Phase-aware events, real hook delivery, arbitrary clock races, file identity,
UI and installer behavior require separate checks.

The earlier native `Test-ClaudeReader.ps1` compared source text and invoked an
old assertion suite that treats an inferred legacy step as confirmed. It now
fails immediately without touching supplied paths or starting an SDK. The
hosted workflow also runs the old PowerShell assertion suite in an isolated
process and requires its documented inferred-step assertion to fail; that
expected failure is not a successful acceptance test.

`.github/workflows/claude-reader-behavior-20261116.yml` checks the exact
checkout, creates a unique disposable Windows runner root and synthetic
profile, clears child environments, sets `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0`,
and compares user, machine and process PATH before and after. It runs the
static PATH guard and verifies the retired launcher with a synthetic SDK probe
whose marker is checked both with and without the marker environment variable.
On a test timeout it requests termination of the directly started process tree
and waits at most five seconds for the root process to exit. A synthetic parent
and child heartbeat check exercises this path. The root-process wait does not
prove that every possible detached or reparented descendant has exited.
No `HOME` or `CODEX_HOME` override is introduced. These controls are for
trusted hosted CI; they do not establish safety against a spoofed environment
or concurrent path replacement.
