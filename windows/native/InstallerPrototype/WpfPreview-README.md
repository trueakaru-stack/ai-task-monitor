# Synthetic WPF preview installer

This is a CI-only installation experiment. It publishes and packages the actual
current C# WPF preview, not the released monitor or a finished application. The
preview still has no live source runner, working settings or release installer.
Its process owns the preview window. No release, shortcut, hook, registry uninstall
entry, legacy uninstaller or existing installation is created or modified.

The package is framework-dependent: it requires an installed compatible .NET 10
Windows Desktop Runtime on x64. The test uses the runtime already present on a
disposable GitHub-hosted Windows runner. This does not establish compatibility
with machines missing the runtime or with another architecture.

`Test-WpfPreviewInstaller.ps1` publishes into a new runner-temp directory using
an isolated process environment, an empty NuGet source list and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` for every .NET process. It downloads only the
official Inno Setup 7.1.1 x64 release with pinned SHA-256 and a valid signature,
and extracts the compiler in portable mode. The generated setup and test harness
both require hosted-CI markers and a unique runner-temp target. Those markers
can be forged and are accidental-execution guards, not a security boundary.
Never build or run this experiment on a user computer or publish its output.

The test rejects an occupied or redirected install destination, installs the
published files into a new temporary directory, verifies their hashes, and
starts `AI Task Monitor.exe` with an offscreen window in the runner. It verifies
that the launched executable owns that window and closes it cleanly. The test
then modifies one payload file, locks another and adds unrelated files and data.
During synthetic uninstall, unchanged unlocked payload files are removed while
the modified file, locked file and unrelated data are retained. The test checks
user, machine and process PATH before and after; it does not change HOME or
CODEX_HOME. Its screenshot is test evidence, not final visual acceptance.

The uninstaller has a compiler-generated list of exact payload names and hashes.
For each name it opens the file with read and delete access and restrictive share
mode, refuses directory/reparse handles, hashes the same opened handle and asks
Windows to delete through that handle only on an exact match. Failed opens,
unknown file types, hash failures and mismatches are retained. This narrows a
check/delete race on the tested Windows filesystem; it does not prove ownership
of an unrelated file replaced with identical bytes. It does not protect against
all parent-directory replacement, hard-link, alternate-stream, metadata or
filesystem races. Inno's own uninstaller metadata has separate ownership and
deletion behavior. The tests do not exercise every filesystem or contention
case. A locked or changed file is left behind, and this prototype removes its own
uninstaller even in that case, so it is not a complete retryable uninstall.

Real installation still needs a verified version strategy, runtime provisioning,
safe coexistence and recovery for the PowerShell release, an atomic upgrade and
rollback design, shortcut and Claude hook migration, handling of a live legacy
or cloud child process, explicit ownership rules, signing and complete product
and visual acceptance. The existing legacy uninstaller must not be called as a
substitute. These remain release blockers regardless of this synthetic test.

## Hosted CI only

On a fresh disposable GitHub-hosted Windows runner, with
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` set at job level and the exact source revision
checked out into a separate temporary directory, run:

```powershell
& 'windows/native/InstallerPrototype/Test-WpfPreviewInstaller.ps1'
```

The script uses a unique direct child of `RUNNER_TEMP`, retains that directory
for runner disposal and checks the temporary path for reparse-point ancestors.
Do not download, reuse, distribute or run its generated setup as a product.

