# Synthetic display preferences

This isolated layer is not connected to the preview window or the installed
application. It does not discover a user profile or choose the standard or
Store edition's paths. The caller must supply two distinct absolute paths in
trusted directories; target and lock paths must also differ from the legacy
path. The legacy file is opened for reading only. The first successful save
creates the separate target from the legacy document and updates one display
field. If a target already exists, it takes precedence and the legacy file is
not read. Later changes to the old file are not synchronized.

The supported modes are `theme` = `system`, `dark`, `light` and `language` =
`system`, `ru`, `en`. Reading accepts case variants as the released PowerShell
implementation does. Unknown properties and values, including large numbers
and the type of `codexCloudEnabled`, are preserved; JSON formatting and property
name escaping can change. Both UTF-8 with a BOM and UTF-8 without a BOM are
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
replace. A concurrent in-place update of the legacy file can produce a stale or
mixed snapshot even when its length is unchanged; a mixed snapshot can still be
valid JSON. The length checks do not establish a consistent read. Opening the
legacy file without write/delete sharing would also block the released version's
`File.Replace` while the read is open; its theme handler ignores save failure.
That alternative has therefore not been adopted. Changes to the legacy file
after migration are not synchronized. The adapter is not a filesystem sandbox
and does not protect against concurrent replacement of path ancestors or aliases
in an untrusted directory.
The guarantees of rename, replace, and durability depend on the filesystem;
power-loss recovery and uncooperative writers have not been verified. Failed
temporary-file cleanup is best effort, so an I/O failure may leave that file in
the trusted target directory.

Unknown properties may contain sensitive data. This experiment copies them
into the new target and may temporarily copy them into a temporary file. The
effective permissions of the target directory, new file and replaced file have
not been checked, and no retention or cleanup policy for the migrated copy has
been established. These are blockers before using real settings.

This does not migrate all application behavior. In particular, the released
Claude hook reads its retention setting from the old file; that setting must
move together with a replacement hook. Diagnostic data is stored separately.
No UI controls, other settings, installer or real agent source are connected.

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
The Windows-only sharing fixture checks both the rejected concurrent writer and
the resulting conflict with a legacy-style file replacement. It uses only
synthetic files and is not part of the adapter's actual reading policy.
They do not assign `HOME` or `CODEX_HOME`, launch agents, or change persistent
`PATH`. Tests use only synthetic data and do not establish visual fidelity,
live interoperability, full migration, or release readiness.
