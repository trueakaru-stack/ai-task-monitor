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
that the launched executable owns that window and closes it cleanly. It checks
that the uninstaller refuses to act when its hosted-CI guard is disabled. The test
then modifies one payload file, locks another and adds unrelated files and data.
During synthetic uninstall, unchanged unlocked payload files are removed while
the modified file, locked file and unrelated data are retained. When the hosted
runner permits creating a symbolic link, it also replaces one owned path with a
synthetic link to an outside copy and checks that both survive; otherwise the
test reports that coverage as not run. The test checks
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

## Candidate self-contained follow-up, not yet built

The .NET 10 release current on 2026-11-16 is runtime 10.0.15 and SDK 10.0.404.
In a new disposable hosted Windows runner, download the official
`dotnet-sdk-10.0.404-win-x64.zip` from the URL in Microsoft's
[release metadata](https://github.com/dotnet/core/blob/main/release-notes/10.0/10.0.15/release.json),
verify the published SHA-512
`330ddd2665b43cd2e428216a0d8ea1ac7bb19b5434fdc530e62010dc3b52823a620bf95489d628e1ed6f5122401793ee4887cca4a019122361a1231497f632ee`,
then extract it only into a new runner-temp directory. Set the .NET PATH opt-out
before every SDK process, isolate profile/temp/cache directories, and select
SDK 10.0.404 with a `global.json` containing `rollForward: disable` in the
disposable checkout. Confirm the SDK and target versions there.

The candidate publish arguments are `-r win-x64 --self-contained true` and
`-p:RuntimeFrameworkVersion=10.0.15`; Microsoft documents that the latter pins
the exact runtime for [self-contained deployments](https://learn.microsoft.com/en-us/dotnet/core/versions/selection).
Restore may require the official NuGet packages
[`Microsoft.NETCore.App.Runtime.win-x64` 10.0.15](https://www.nuget.org/packages/Microsoft.NETCore.App.Runtime.win-x64/10.0.15)
and [`Microsoft.WindowsDesktop.App.Runtime.win-x64` 10.0.15](https://www.nuget.org/packages/Microsoft.WindowsDesktop.App.Runtime.win-x64/10.0.15),
and possibly additional SDK-selected packages. Use only the official feed and a
new isolated package cache; verify the resolved package identities and signatures.
Do not claim the exact pack set until a real restore is inspected.

Verify the installed executable on a clean hosted machine with an empty isolated
`DOTNET_ROOT`, and inspect its loaded runtime module paths to confirm they come
from the packaged application. The current experiment accepts only flat payloads;
support for any nested runtime or localization files needs separate guarded
ownership and removal tests. Self-contained removes the separate .NET runtime
installation requirement, not Windows system requirements. Security updates to
the bundled runtime require an application rebuild and redeployment. Nothing in
this plan is an already tested self-contained package or authorizes a release.

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

