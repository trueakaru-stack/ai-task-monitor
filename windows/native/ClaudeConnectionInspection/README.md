# Claude settings inspection experiment

This is an isolated, read-only C# component. It is **not connected to the
application**, does not find a Claude profile, and must not be used as evidence
that a source is connected or that a hook ran. The caller provides both an
absolute path and the expected command strings. No environment variable or
profile directory is consulted. `InspectBytes` and `InspectStreams` also accept
synthetic input and a supplied read-only stream factory.

## Result contract

`RegisteredInFile` means only that the inspected JSON contains the monitor's
recognized, unfiltered command under each of the 11 event names used by the
existing Windows installer. `PartialInFile` means that some matching command
exists but coverage or a recognized, unfiltered form is missing, or the same
file mentions a potentially relevant restriction. `NotFoundInFile` means that
no exact expected command was found in the supported positions in this file;
it says nothing about other settings files, plugins or sessions. `ReadError`
and `InvalidConfiguration` must never be treated as a disconnect or as absence
of an integration. A missing file is a read error. A caller must not map any of
these results directly to a confirmed source state.

All results contain `OtherSettingsAndPolicyNotInspected` and
`EventDeliveryNotVerified`. The count fields count event names, not running
tasks. An observed `disableAllHooks: true` or `allowManagedHooksOnly: true`
makes an otherwise complete result partial. The latter is a managed-policy
setting: its presence in an arbitrary inspected file does not establish that it
applies. `false` in this file does not exclude a restriction in another scope.
The inspector does not read managed policy, determine effective precedence,
validate the installed Claude version, check the hook executable, or verify
event delivery. The actual settings path can also be redirected by Claude.

Only omitted, `""` and `"*"` matchers are considered unfiltered. Every other
matcher and any additional group or matching-handler property yields partial
coverage, even where a specific event ignores matchers or a particular regular
expression might happen to match all values. This conservative rule may
understate coverage. `type: command`, the command and an optional positive
numeric `timeout` are the supported handler shape. The current command is
compared after trimming, ordinally; the optional legacy command is compared
after trimming, ordinally ignoring case, consistent with the existing Windows
inspector. Other commands do not count. Neither shell equivalence nor path
equivalence is inferred. Unknown keys in unrelated settings are preserved by
not writing them at all; malformed relevant structures, case-colliding keys,
invalid UTF-8 and invalid JSON yield uncertainty rather than a positive result.

The file adapter opens the explicit path read-only with sharing enabled and
compares two separately opened, bounded reads of at most 1 MiB each. Different
bytes or a failed read yield `ReadError`. Matching reads **do not prove an
atomic or current snapshot**: same-length concurrent writes, path replacement,
ABA changes and changes after the reads can still go undetected. The stream
factory must itself be read-only. A blocked stream can block the caller; no
I/O deadline, file identity check or cross-poll continuity is provided. These
limitations, policy inspection and source-lifecycle handling block real
integration. Results contain no paths, command strings, JSON, or exception
messages; callers must also avoid logging their input paths and commands.

`InspectBytes` copies the bounded caller-supplied memory before parsing and
does not clear or modify the caller's memory. Recoverable access errors return
`ReadError`. `InspectStreams` owns its read buffers. These owned byte buffers,
including failed, oversized and different-read cases, are cleared in `finally`
after inspection. Tests retain synthetic references to stream-read buffers and
check this clearing. The memory copy itself is not an atomic snapshot if another
thread writes the caller's memory concurrently. The CLR, JSON parser and input
providers may retain other byte copies or managed strings, which this component
cannot find or guarantee to erase.

The matcher and policy limitations are based on the official
[hooks reference](https://code.claude.com/docs/en/hooks) and
[settings precedence](https://code.claude.com/docs/en/settings). Claude can
change its format or behavior; this experiment does not detect every version.

## Synthetic hosted CI

On an isolated hosted Windows runner with .NET 10 installed, set
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` at job level, including before any SDK
setup step. From the repository root in `pwsh`:

```powershell
$ErrorActionPreference = 'Stop'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = '0'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
$taskDir = Join-Path $env:RUNNER_TEMP ('aitm-claude-inspect-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($taskDir)
$env:DOTNET_CLI_HOME = Join-Path $taskDir 'dotnet-cli'
$env:NUGET_PACKAGES = Join-Path $taskDir 'packages'
$env:TEMP = Join-Path $taskDir 'temp'
$env:TMP = $env:TEMP
$null = [IO.Directory]::CreateDirectory($env:TEMP)
$nugetConfig = Join-Path $taskDir 'NuGet.Config'
[IO.File]::WriteAllText($nugetConfig, '<configuration><packageSources><clear /></packageSources></configuration>', [Text.UTF8Encoding]::new($false))
$project = 'windows/native/ClaudeConnectionInspection/Tests/ClaudeConnectionInspection.Tests.csproj'
$artifacts = Join-Path $taskDir 'artifacts'
dotnet restore $project --configfile $nugetConfig --packages $env:NUGET_PACKAGES --artifacts-path $artifacts --disable-build-servers '-p:Configuration=Release'
if ($LASTEXITCODE -ne 0) { throw 'Synthetic restore failed.' }
dotnet build $project -c Release --no-restore --artifacts-path $artifacts --disable-build-servers
if ($LASTEXITCODE -ne 0) { throw 'Synthetic build failed.' }
$testDll = Join-Path $artifacts 'bin/ClaudeConnectionInspection.Tests/release/AITaskMonitor.ClaudeConnectionInspection.Tests.dll'
dotnet $testDll
if ($LASTEXITCODE -ne 0) { throw 'Synthetic inspection test failed.' }
```

The tests use constructed documents, fake streams and one newly created
synthetic file under the isolated temporary directory. They start no child
process and do not assign `HOME`, `CODEX_HOME` or persistent `PATH`. Test
passing would establish only the simulated cases, not live Claude behavior,
product readiness, or visual acceptance. The component has not yet run in CI.
