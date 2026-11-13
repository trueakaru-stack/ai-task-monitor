# Codex Cloud CLI transport (not connected)

This isolated Windows component accepts an explicitly supplied absolute path to an
executable, an optional cursor, a per-command timeout and cancellation token. It
runs the released CLI shape:

    codex.exe cloud list --json --limit 20 [--cursor=<cursor>]

It uses ProcessStartInfo.ArgumentList, does not invoke a shell, closes stdin and
never reads credentials or writes logs itself. The caller is responsible for
selecting and validating the genuine official executable and its installation.
A fully qualified .exe path is a syntax check, not an authenticity, identity or
race-free filesystem check. As with a normal child process, the executable inherits
the parent's environment and working directory and can access anything allowed to
that account. The caller must trust it and consider the working directory. Cursors
are passed as command-line arguments and may be observable to other local processes;
they must not be logged.

Stdout and stderr are read concurrently and capped during reads at 1 MiB and
64 KiB. Exceeding either cap fails the request and attempts to stop the process.
Successful stdout is validated as strict UTF-8 and returned as bytes; JSON parsing,
pagination, status and task publication belong to a separate owner. Stderr is
always discarded. Nonzero exit, invalid UTF-8, malformed arguments, timeout,
cancellation and expected I/O errors do not publish stdout. A result's diagnostic
string and default JSON serialization exclude stdout; callers must never log
stdout, stderr, raw arguments, paths or cursors.

Dispose a successful result only after consuming it; disposal clears its owned byte
array. Existing copies, managed allocations, inherited handles, process memory and
OS buffers cannot be guaranteed erased. Serialize payload use with disposal.

The timeout starts before Process.Start. Process.Start itself is synchronous and
cannot be interrupted here, so an unresponsive launch can exceed the deadline.
Once it returns, cancellation or deadline triggers an attempted process-tree kill
and up to two further seconds of waiting for the launched process. The result
reports TerminationUnconfirmed if that process's exit cannot be observed. A
positive ExitObserved pertains to the launched process only: descendant exit is not
proven, especially if the parent already exited or a descendant escaped. The
future owner must handle uncertain termination and avoid repeatedly launching
unbounded workers. A caller must also gate late results by scan/request generation.
An owner needs a separate whole-scan deadline; the released controller uses up to
12 seconds per request and 30 seconds per scan. This component permits a timeout of
up to 120 seconds and does not enforce a whole-scan deadline.

Unexpected exceptions, including actual memory exhaustion, may propagate; the
caller must cancel its incomplete scan when possible. This component is not
connected to the application, a CLI, an account or a network during these tests.
The CLI cloud listing is experimental; compatibility across versions and coverage
of desktop and web cloud sessions are unverified. An empty response does not prove
that all cloud tasks are absent.

## Disposable hosted Windows CI only

The test executable requires CI=true, GITHUB_ACTIONS=true,
RUNNER_ENVIRONMENT=github-hosted, RUNNER_OS=Windows, and
DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0. It checks that its own assembly and the fixture
executable belong to the named unique build directory directly under RUNNER_TEMP,
and rejects reparse points along that path. Those checks are safeguards for a
trusted disposable runner, not a security boundary; environment variables can be
forged and filesystem ancestry can race. Do not run these process tests on the
user's computer or on a shared/untrusted runner. The fixture is synthetic and
does not access an account or a network. Its child process inherits the hosted
runner environment, so do not provide real account credentials or CI secrets.

On a disposable GitHub-hosted Windows runner with .NET 10:

    if ($env:CI -ne 'true' -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') { throw 'Hosted Windows required.' }
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = '0'
    $root = Join-Path $env:RUNNER_TEMP ('aitm-cloud-command-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $env:DOTNET_CLI_HOME = Join-Path $root 'dotnet-home'
    $env:NUGET_PACKAGES = Join-Path $root 'packages'
    $config = Join-Path $root 'NuGet.Config'
    [IO.File]::WriteAllText($config, '<configuration><packageSources><clear /></packageSources></configuration>', [Text.UTF8Encoding]::new($false))
    $artifacts = Join-Path $root 'artifacts'
    dotnet build windows/native/CodexCloudCommand/Tests/CodexCloudCommand.Tests.csproj -c Release --configfile $config --artifacts-path $artifacts -p:NuGetAudit=false --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic command build failed.' }
    $tests = Join-Path $artifacts 'bin/CodexCloudCommand.Tests/release/AITaskMonitor.CodexCloudCommand.Tests.dll'
    dotnet $tests $root
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic command checks failed.' }

The tests cover argument boundaries, stdin EOF, concurrent output limits, invalid
UTF-8, exit failure, pre-cancellation, and signalled child cancellation and timeout
with an OS mutex observing the synthetic child's lifetime. They do not launch or
authenticate a real CLI and do not establish actual backend compatibility, child
tree termination in all races, or application readiness.

