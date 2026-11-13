# Synthetic Windows installer prototype

This isolated prototype packages two text fixtures. It does **not** contain or
install the C# application, update the released product, create shortcuts,
modify hooks, run an old uninstaller, or publish a release. `Prototype.iss`
and the test script must only be built and executed on a disposable hosted
Windows CI runner. The installer and uninstaller check CI environment markers
and an explicit test destination. Those markers can be forged: they are an
accidental-execution guard, not a security or isolation boundary. Do not
download or run the resulting executable on a user's computer.

The test uses the officially released Inno Setup **7.1.1 x64** tool, pinned to
the immutable [`is-7_1_1` release](https://github.com/jrsoftware/issrc/releases/tag/is-7_1_1).
The asset `innosetup-7.1.1-x64.exe` must have SHA-256
`8a5a6711c3766a6e5fb74f280ba0e3551e719ce94538d901fdbd1f8f9920b3f0`
and a valid Authenticode signature from `Pyrsys B.V.`. The script extracts the
compiler in its documented `/PORTABLE=1` mode into a new `RUNNER_TEMP`
directory. The official [tool script](https://raw.githubusercontent.com/jrsoftware/issrc/is-7_1_1/setup.iss)
and [portable-mode implementation](https://raw.githubusercontent.com/jrsoftware/issrc/is-7_1_1/isportable.iss)
show the mode used. The external tool itself is not independently audited.

The synthetic installer uses a separate app ID, requires an explicit temporary
destination that does not already exist, runs per user, creates no uninstall
registry entry, does not close applications, and declares no shortcut, registry,
shell command, hook or launch action. It rejects a different `/DIR` value.
Both fixture payloads use Inno Setup's `uninsneveruninstall`, so they remain on
uninstall even if changed later. This deliberately avoids claiming that deletion
of a replaced file is safe. The uninstaller still removes its own metadata; a
complete product uninstall and its ownership rules are **not implemented**.

The test constructs all inputs beneath a fresh directory in `RUNNER_TEMP` and
does not delete that directory. It checks the guard, an existing destination,
an overridden destination, a fresh install, and uninstall after modifying a
fixture. It checks that a foreign file, test data and dummy legacy settings,
hook, old-uninstaller marker and shortcut marker remain byte-for-byte unchanged.
It compares process, user and machine PATH values before and after, without
printing them. The `.lnk` and hook are only synthetic data, not real shortcuts
or working integrations. No real profile or existing installation is opened.

These checks do not establish an atomic transaction. There is a race between
checking that the target is absent and creating its files; path replacement,
reparse points, parallel installers, crashes, rollback, permissions and
ownership of uninstall metadata have not been proven safe. Ancestor reparse
checks in the CI wrapper do not close those races. Do not use this prototype
for a real installation, update, rollback or migration.

The released Windows monitor installs to a separate legacy folder and runs its
main monitoring code in PowerShell; its Claude hook command can refer to that
folder. The correct handling of a running legacy process, existing shortcuts,
hooks, agent sessions, data migration, mixed versions, safe cutover, recovery,
signing and architecture remains unresolved. The native application is also
incomplete. These are release blockers, regardless of synthetic test results.

## Hosted CI

Run only in a new disposable GitHub-hosted Windows job with a finite job
timeout. From the repository root in `pwsh`:

```powershell
$ErrorActionPreference = 'Stop'
& 'windows/native/InstallerPrototype/Test-SyntheticInstaller.ps1'
```

The script downloads only the pinned official compiler, runs no `dotnet`
process, does not change `HOME`, `CODEX_HOME`, or a PATH variable, and does not
invoke the legacy application's scripts. It performs actual synthetic install
and uninstall operations only after its hosted-runner guard. Do not publish or
reuse its generated executable as a product artifact. The synthetic test passed
in [CI run 43485584276](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43485584276).
This does not establish real installation, migration, rollback or release readiness.

