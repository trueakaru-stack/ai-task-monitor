# Synthetic provider confidence experiment

This directory contains an isolated experiment, not a fix connected to the
application. `Prototype` holds a state copy and selected runtime functions used
only by these synthetic tests. The
production integration files, sender protocol and application behavior are
unchanged. Do not package or link these copies into the application.

The model holds DeepSeek unconfirmed before its first scope baseline. A scope
that sent a frame before that baseline stays unconfirmed after it; overflow in
this pre-baseline accounting makes the whole provider unconfirmed. The model
also holds a previously observed source or DeepSeek scope unconfirmed after a
visible reconnect or gap, and does not hide an existing
unconfirmed card on a terminal frame. A synthetic test checks that an already
drained frame applied after the observed transition does not confirm activity;
it does not establish thread safety or atomicity for real consumers. Separate
synthetic scopes and another provider are checked independently.

This is intentionally **not** the approved recovery behavior. The experiment
has no proof that an agent completely restarted and never clears uncertainty
while its store exists. Uncertainty is also lost when the monitor process or
controller is fully stopped. Reconnects between polls are not observed, and
the first trusted scopes are an assumption rather than verified ownership.
New scopes after that baseline remain unconfirmed even if they may be healthy.
The prototype detects duplicate namespaces present in a single profile scan,
but cannot prove ownership against stale senders or collisions absent from the
scan. If capacity prevents creating an uncertain card, the prototype returns
failure, while the copied runtime currently discards that return value. In the
opposite direction, when 256 cards already exist, a confirmed DeepSeek event
can evict a previously observed unconfirmed OpenCode card while `Apply`
returns success. An isolated test reproduces that known defect; it is not a
passing product acceptance criterion. Capacity loss policy remains unresolved.

The prototype runtime test does not replace or validate the full production
group flow. It also imports two production functions read-only into a separate
synthetic scenario with a fake channel: when no sources are allowed, the real
`Read-ExternalProviderGroupSnapshot` calls the production stop function and
clears the store. That counterexample confirms the real group still loses its
uncertainty history. Both the group flow and capacity issue block product use.

OpenCode documents that [plugin setup and unload have their own lifecycle](https://opencode.ai/docs/build/plugins/server),
and that the plugin location does not identify every session it can observe.
DeepSeek documents [profiles and a dynamic plugin tree](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md).
Neither establishes that a new plugin instance proves a complete agent restart.
On Windows, [the pipe client PID](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeclientprocessid)
and [process creation time](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes)
are possible evidence, but mapping the process and all remaining senders to a
specific profile has not been verified.

For an isolated Windows hosted CI runner with .NET 10 already installed, set
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` at job level, including any SDK setup
steps. From the repository root in `pwsh`, run:

```powershell
$ErrorActionPreference = 'Stop'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = '0'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
$taskDir = Join-Path $env:RUNNER_TEMP ('aitm-confidence-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($taskDir)
$env:DOTNET_CLI_HOME = Join-Path $taskDir 'dotnet-cli'
$env:NUGET_PACKAGES = Join-Path $taskDir 'packages'
$env:TEMP = Join-Path $taskDir 'temp'
$env:TMP = $env:TEMP
$null = [IO.Directory]::CreateDirectory($env:TEMP)
$nugetConfig = Join-Path $taskDir 'NuGet.Config'
[IO.File]::WriteAllText($nugetConfig, '<configuration><packageSources><clear /></packageSources></configuration>', [Text.UTF8Encoding]::new($false))
$project = 'windows/native/ProviderConfidence/ProviderConfidence.Tests.csproj'
$artifacts = Join-Path $taskDir 'artifacts'
dotnet restore $project --configfile $nugetConfig --packages $env:NUGET_PACKAGES --artifacts-path $artifacts --disable-build-servers '-p:Configuration=Release'
if ($LASTEXITCODE -ne 0) { throw 'Synthetic restore failed.' }
dotnet build $project -c Release --no-restore --artifacts-path $artifacts --disable-build-servers
if ($LASTEXITCODE -ne 0) { throw 'Synthetic build failed.' }
$testDll = Join-Path $artifacts 'bin/ProviderConfidence.Tests/release/AITaskMonitor.ProviderConfidence.Tests.dll'
dotnet $testDll
if ($LASTEXITCODE -ne 0) { throw 'Synthetic state test failed.' }
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'windows/native/ProviderConfidence/Test-ProviderConfidenceRuntime.ps1'
if ($LASTEXITCODE -ne 0) { throw 'Synthetic runtime test failed.' }
```

The assembly uses only in-memory synthetic events. The fresh Windows PowerShell
5.1 process compiles the prototype state, uses fake channels and synthetic
profile data, and reads the two production runtime functions without changing
them; it opens no pipe or real profile. The test sources do not assign
`HOME`, `CODEX_HOME` or a persistent `PATH`, or launch `dotnet` themselves.
They do not rebuild a child environment; the CI job's flag is inherited. The
platform compiler used by `Add-Type` has not been independently audited. Neither
test demonstrates live-agent behavior, restart recovery, installer readiness
or visual fidelity.

The isolated experiment ran in [Windows CI run 43461323619](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43461323619): 828 in-memory checks passed, including the known eviction counterexample, and the runtime test reproduced the production group-stop loss. These results do not mean that reconnect recovery is fixed.
