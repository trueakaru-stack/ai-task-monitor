# Codex Cloud CLI transport (not connected)

This isolated Windows component accepts an explicitly supplied absolute path to an
executable, an optional cursor, a per-command timeout and cancellation token. It
runs the released CLI shape:

    codex.exe cloud list --json --limit 20 [--cursor=<cursor>]

It uses ProcessStartInfo.ArgumentList, does not invoke a shell, closes stdin and
never reads credentials or writes logs itself. The caller is responsible for
selecting and validating the genuine official executable and its installation.
A fully qualified .exe path is a syntax check, not an authenticity, identity or
race-free filesystem check. The child inherits the parent's environment and can
access other paths allowed to its account. The transport's working directory is
not a general sandbox.

The official Codex CLI source for
[rust-v0.169.0-alpha.11.1](https://github.com/openai/codex/blob/rust-v0.169.0-alpha.11.1/codex-rs/cloud-tasks/src/util.rs)
appends to a relative error.log. That version's cloud code can write an account
identifier and input/output pagination cursors there
([authentication](https://github.com/openai/codex/blob/rust-v0.169.0-alpha.11.1/codex-rs/cloud-tasks/src/lib.rs),
[listing](https://github.com/openai/codex/blob/rust-v0.169.0-alpha.11.1/codex-rs/cloud-tasks-client/src/http.rs)).
This is source inspection, not a real authenticated test or a statement about
other CLI versions.

The candidate creates a unique temporary directory atomically, holds its
validated non-reparse ancestors, denies creation of files and directories to
the current user and verifies that denial before launch. It accepts only a
fixed local drive and fails closed if validation fails. It removes only its
own empty directory by handle, never its contents recursively. Only one workspace
may be in use at once. If removal fails or the launched child's exit cannot be
confirmed, further launches are disabled for the lifetime of the process.
A retained directory remains subject to its access rules.

These controls target accidental relative writes such as the inspected error.log;
they do not prevent a child running as the same user from accessing or writing
other locations, modifying security rules it owns, or launching descendants.
They are not proof of behavior across filesystems, accounts or CLI versions.
Cursors are passed as command-line arguments and may be observable to other local
processes; they must not be logged.

Changing the child's current directory may change which trusted project
configuration layers Codex loads. The inspected CLI passes its current directory
to [the configuration loader](https://github.com/openai/codex/blob/rust-v0.169.0-alpha.11.1/codex-rs/config/src/loader/mod.rs).
The inspected cloud-list command has no independent cwd option that was shown to
preserve that context. Actual cloud-list compatibility and provider coverage
remain unverified; the synthetic tests cannot establish them.

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
and up to two further seconds of waiting for the launched process. The limit
applies to the asynchronous exit wait, not to the synchronous tree enumeration,
kill calls or stream disposal; total cleanup time is not strictly bounded.
An aggregate of expected termination errors triggers a direct-child kill attempt
and still requires observing that child's exit; unexpected exceptions propagate.
The result
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

The CI-only runner at `.github/cloud-acl-ci/Run.ps1` builds and runs the tests
with an isolated profile, temporary directory and NuGet cache. It verifies the
user, machine and process PATH before and after the tests, and sets
DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0 for every child environment. Invoke it only on a
disposable GitHub-hosted Windows runner; it must not be run on the user's computer.

The synthetic fixtures exercise bounded output, cursor argument boundaries,
cancellation, a non-writable child working directory, unchanged original working
directory, rejected unavailable and redirected temporary directories, single
workspace ownership and failed-cleanup behavior. They do not launch or authenticate
a real Codex CLI and do not establish actual backend compatibility, descendant
termination in all races, or application readiness.
