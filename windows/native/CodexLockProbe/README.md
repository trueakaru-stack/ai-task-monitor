# Synthetic Windows byte-range lock probe

This is an isolated research fixture, not an application component. It does not
discover Codex, inspect user sessions, start an agent, connect to an app server,
or assert a task status. Run it only on a disposable Windows CI runner.

Before creating fixture files or child processes, the program requires
`CI=true`, `GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted`,
`RUNNER_OS=Windows`, `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` and an absolute,
**not yet existing** path named `aitm-lock-probe-<32-hex-guid>`
directly under `RUNNER_TEMP`. It creates the directory atomically and creates
two new fixture files inside it. It refuses paths inside the current user's
profile, common application data, Windows or Program Files, rejects reparse
points in the runner-temp ancestry, and requires a fixed drive. Workers open
only the two generated fixture names, reject reparse-point files and hard links,
and never print paths or contents. Files are left for the disposable runner to
discard; the program does not delete anything.

These checks are safeguards for a trusted, disposable CI runner, not a general
filesystem sandbox. Environment variables can be intentionally forged, and the
checks do not prevent a malicious process from swapping an ancestor directory
after validation. `--worker` is an internal protocol entry point, not an
authenticated capability: its path and naming checks cannot prove that its
directory was created by this parent process. Do not invoke it directly, use a
pre-existing fixture, forge CI variables or use an untrusted shared runner.

Writer and observer are distinct child processes. The writer uses read/write
access with read/write/delete sharing and takes an actual exclusive,
non-blocking byte-range lock from offset zero with both length halves set to
`0xffffffff`. The observer opens for reading with the same sharing and does not
call a lock function. Tests use both a genuinely empty file and a one-byte
file, synchronous and overlapped reads, and pipe barriers. They check an open
writer without a lock, a held lock, reading before a writer starts, continued
attempts to read while the writer opens/locks, and reading after the writer
exits. The concurrent case is a stress attempt: no barrier guarantees that a
read occurs between writer open and lock acquisition or overlaps either system
call. Around
each read with a held lock, a protocol ping verifies the writer is alive with
the same still-open handle after its successful lock request; the ping is not
an independent Windows lock query. Every worker must exit with code zero. The
old read/delete-only sharing mode is a negative control: opening the writer
must fail with `ERROR_SHARING_VIOLATION` and exit normally while that observer
is open.

The displayed `READ_OK` / `READ_ERR` values are observations only. In
particular, zero bytes or `ERROR_HANDLE_EOF` on an empty file does not establish
that its range is unlocked. The nonempty fixture checks that an overlapping
read fails while the writer holds the lock; it does not prove that every error
identifies the lock. A passing stress or interleaving test cannot establish a
universal guarantee across Windows versions, filesystems, or races. A changed,
inaccessible, missing or ambiguous file must be treated as **unknown** by any
future monitor. No production integration is authorised by this experiment.

The program and this README were reviewed statically; they have not been run
locally. Build and execute on a disposable Windows CI runner with .NET 10:

```powershell
if ($env:CI -ne 'true' -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') { throw 'This probe requires a GitHub-hosted Windows runner.' }
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$probeBuild = Join-Path $env:RUNNER_TEMP ('aitm-probe-build-' + [guid]::NewGuid().ToString('N'))
$probeFixture = Join-Path $env:RUNNER_TEMP ('aitm-lock-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeBuild | Out-Null
$env:DOTNET_CLI_HOME = Join-Path $probeBuild 'dotnet-home'
$env:NUGET_PACKAGES = Join-Path $probeBuild 'packages'
$nugetConfig = Join-Path $probeBuild 'NuGet.Config'
Set-Content -LiteralPath $nugetConfig -Encoding utf8 -Value '<configuration><packageSources><clear /></packageSources></configuration>'
dotnet restore .\windows\native\CodexLockProbe\CodexLockProbe.csproj --artifacts-path (Join-Path $probeBuild 'artifacts') --configfile $nugetConfig
if ($LASTEXITCODE -ne 0) { throw 'Synthetic probe restore failed.' }
dotnet build .\windows\native\CodexLockProbe\CodexLockProbe.csproj -c Release --no-restore --artifacts-path (Join-Path $probeBuild 'artifacts')
if ($LASTEXITCODE -ne 0) { throw 'Synthetic probe build failed.' }
$probeDll = Join-Path $probeBuild 'artifacts\bin\CodexLockProbe\release\AITaskMonitor.CodexLockProbe.dll'
dotnet $probeDll --fixture $probeFixture
if ($LASTEXITCODE -ne 0) { throw 'Synthetic probe failed.' }
```

Every process that launches .NET must retain the `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH`
setting, including rebuilt CI environments. The child workers explicitly set it
in their own environments. The commands above use unique build and fixture
directories; no persistent environment variables or registry settings are
changed. A future CI result should record the Windows version, filesystem and
probe revision separately from these fixture observations.
