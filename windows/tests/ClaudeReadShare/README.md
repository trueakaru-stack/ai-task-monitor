# Synthetic regression for Claude log rotation on Windows

This test extracts the current `Read-TailText` function using the Windows
PowerShell parser and runs it in a separate process. A test-only barrier holds
its actual read handle open while a copied `ClaudeTaskHook.ps1` rotates an
artificial log. With the default sharing mode the hook reports the synthetic
sharing violation; with Claude's delete-sharing mode it records `Stop` while
the handle is still open. A subsequent read and a build of the actual Claude
Reader sources must both observe completion. The runner also checks the call
sites and compares text returned with and without delete sharing on synthetic
UTF-8 inputs.

The test copies the hook and Reader sources into a new output directory and
uses a unique test mutex and pipe name. The copied hook has no loop client, so
it does not connect to a pipe. All profiles and application data used by child
processes are synthetic. The runner neither assigns HOME or CODEX_HOME nor
modifies the checkout; it does not clean up its fixtures. NuGet sources are
cleared, but operating-system network access is not blocked.

Requirements: Windows, Windows PowerShell 5.1, Python 3.9 or newer without `-O`,
and the .NET 10 SDK. Keep `run_regression.py`, `ReadState.csproj`, `Program.cs`,
and `NuGet.Config` together. Select an existing checkout and an output
directory outside that checkout:

```powershell
python path/to/run_regression.py --repo 'C:/path/to/AI Task Monitor' `
  --dotnet 'C:/path/to/dotnet.exe' --output-dir 'C:/path/to/synthetic-results'
```

To compare against an older checkout revision as well, add
`--baseline-ref <git-revision>`. The optional revision must contain the old
function shape expected by this experiment; Git must be installed. The normal
test does not depend on Git history. The runner prints source hashes and the
fixture directory.

These synthetic cases exercise one local filesystem and the PowerShell legacy
hook in audit mode. They do not prove reliable delivery under a busy mutex,
process termination, other filesystem failures, or a live Claude integration.
