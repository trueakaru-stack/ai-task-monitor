# Synthetic display preferences

The adapter reads old display values without writing the old settings file.
Each explicit choice is stored in a separate target: selecting only a theme
writes only `theme`, and selecting only a language writes only `language`.
For an absent target field, a read uses the corresponding old field, or the
system mode if the old field or file is absent. An existing target field takes
precedence. A missing or unreadable old file is not the same condition: access
errors and invalid documents are reported instead of silently using defaults.
The adapter never copies unrelated old properties into the new file.

The caller supplies distinct absolute legacy and target paths in trusted
directories. The path helper reproduces the published standalone and Store
directory conventions. `ForApplication` accepts an executable directory and
user roots, checks Windows package identity and the published Store marker, and
currently enables only an unpackaged standalone launch with no marker. A
packaged process, marker, unknown identity or inaccessible application
directory makes the service unavailable instead of choosing the wrong edition.
The standalone `LOCALAPPDATA` root must already be a plain directory; the
factory does not create a missing or redirected root.
No native C# Store package has yet been built or verified. The target and its lock are separate. Reading an existing target directory can create its lock
file; a missing directory is created only when a selection is saved. The
existing `Initialize(theme, language)` operation remains available to an
explicit caller but is not required for normal individual selections.
Package identity uses Windows' `GetCurrentPackageFullName` contract:
[Microsoft documentation](https://learn.microsoft.com/windows/msix/detect-package-identity).

The window can receive an injected adapter and expose the existing theme and
language controls. The application entry point does not yet create or inject
one; synthetic previews use an explicitly supplied fixture. Other settings and
sources are not connected by this change.

The supported modes are `theme` = `system`, `dark`, `light` and `language` =
`system`, `ru`, `en`. Reading accepts case variants as the released PowerShell
implementation does. Unknown properties and values, including large numbers
and the type of `codexCloudEnabled`, in an already-existing target are preserved;
JSON formatting and property name escaping can change. Both UTF-8 with a BOM and UTF-8 without a BOM are
accepted. Invalid UTF-8, malformed JSON, non-object roots and duplicate keys
at any depth, including case collisions, are rejected without a settings
write. Names containing a Unicode replacement character are also rejected to
avoid silently changing an ambiguous key. The document limit is 1 MiB and
depth 64; the layer can reject inputs accepted by the released version rather
than rewrite them. System-theme and system-language resolution take explicit
caller-supplied values, not OS data.

The target uses a separate lock file for cooperating instances of this adapter,
compares the complete captured bytes under that lock, writes a unique temporary
file and flushes it before a same-directory move or replace. Conflicts return a
status instead of overwriting the newer target. The lock is advisory to other
programs: a writer that ignores it can race between the comparison and the
replace. The legacy reader opens with read/write/delete sharing and checks two
bounded reads. A concurrent in-place change can still create a stale or mixed
snapshot, including valid JSON; these checks do not prove atomicity. An atomic
replacement can also happen after the read. A later load rereads missing fields,
but no live synchronization or writer cooperation is guaranteed. The adapter is not a filesystem sandbox
and does not protect against concurrent replacement of path ancestors or aliases
in an untrusted directory.
The guarantees of rename, replace, and durability depend on the filesystem;
power-loss recovery and uncooperative writers have not been verified. Failed
temporary-file cleanup is best effort, so an I/O failure may leave that file in
the trusted target directory.

An existing target may contain sensitive unknown properties, and an update may
temporarily copy them into a temporary file. The effective permissions of the
target directory, new file and replaced file have not been checked, and no
retention or cleanup policy for such copies has been established. These remain
open limitations before using real settings. A cooperating lock does not exclude
unrelated writers of an existing target.

This does not migrate all application behavior. In particular, the released
Claude hook reads its retention setting from the old file; that setting must
move together with a replacement hook. Diagnostic data is stored separately.
Only the injected display controls are connected by this slice. Other settings,
the installer and real agent sources are not connected by it.

For hosted Windows CI with .NET 10 already installed, set
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` at job level. From the repository root in
`pwsh`, use an isolated temporary directory and an empty NuGet source list:

```powershell
$ErrorActionPreference = 'Stop'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = '0'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
$taskDir = Join-Path $env:RUNNER_TEMP ('aitm-settings-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($taskDir)
$workDir = Join-Path $taskDir 'work'
$null = [IO.Directory]::CreateDirectory($workDir)
$env:DOTNET_CLI_HOME = Join-Path $taskDir 'dotnet-cli'
$env:NUGET_PACKAGES = Join-Path $taskDir 'packages'
$env:TEMP = Join-Path $taskDir 'temp'
$env:TMP = $env:TEMP
$null = [IO.Directory]::CreateDirectory($env:TEMP)
$nugetConfig = Join-Path $taskDir 'NuGet.Config'
[IO.File]::WriteAllText($nugetConfig, '<configuration><packageSources><clear /></packageSources></configuration>', [Text.UTF8Encoding]::new($false))
$project = 'windows/native/Prototype/Tests/DisplayPreferences/DisplayPreferences.Tests.csproj'
$artifacts = Join-Path $taskDir 'artifacts'
dotnet restore $project --configfile $nugetConfig --packages $env:NUGET_PACKAGES --artifacts-path $artifacts --disable-build-servers '-p:Configuration=Release'
if ($LASTEXITCODE -ne 0) { throw 'Synthetic restore failed.' }
dotnet build $project -c Release --no-restore --artifacts-path $artifacts --disable-build-servers
if ($LASTEXITCODE -ne 0) { throw 'Synthetic build failed.' }
$testDll = Join-Path $artifacts 'bin/DisplayPreferences.Tests/release/AITaskMonitor.DisplayPreferences.Tests.dll'
dotnet $testDll $workDir
if ($LASTEXITCODE -ne 0) { throw 'Synthetic preferences test failed.' }
```

The tests create a unique fixture directory under the supplied work directory
and do not delete it. They reject paths inside the current checkout, current
profile/application-data directories, and reparse-point ancestors. These are
not a general filesystem sandbox and depend on environment and path evidence.
The tests exercise individual choices, fallback from a synthetic old file,
invalid and inaccessible old input, target changes during a read, first-run
directory creation, foreign target fields and separate edition roots. A Windows
sharing fixture holds a synthetic writer open while the adapter reads and also
demonstrates why a strict read share would interfere with a legacy replacement.
The fixtures do not prove an atomic snapshot under an uncooperative writer.
They do not assign `HOME` or `CODEX_HOME`, launch agents, or change persistent
`PATH`. Tests use only synthetic data and do not establish visual fidelity,
live interoperability, full migration, or release readiness.

The individual-choice adapter passed 80 synthetic checks and a WPF build in
[Windows CI run 43856015300](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43856015300).
That run did not read real settings or exercise the settings screen.
