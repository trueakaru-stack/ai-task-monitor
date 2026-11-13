# Isolated native update controller and transport

This .NET 10 library is an **unconnected migration slice**. It is not the
Windows application's updater and does not create an installer. Its
coordinator accepts a transport, release selector and clocks from its caller;
the transport makes a request only when the caller explicitly invokes it.
The caller remains responsible for using the validated release selector,
Store policy, UI presentation and download handling.

The coordinator permits one outstanding request, ignores stale results and
stores a bounded header snapshot before the body completes. A second header
callback or more than 256 values of one category faults the controller instead
of dropping a potentially longer delay. `Stop` prevents publication and
requests cancellation without waiting on the UI caller. A transport or clock
that does not cooperate can keep its one slot occupied; cancellation is not
proof that underlying I/O stopped. Headers that never reach the callback
cannot be preserved. Scheduling is in memory and resets at process restart.

The supplied HTTP transport targets the public GitHub release endpoint. It
disables redirects, cookies, default credentials and authentication, limits
response headers to 64 KiB and the body to 1 MiB, and decodes UTF-8 strictly.
It reports headers before reading the body. The releases endpoint must return
HTTP 200; a 206 partial response is treated as a failed check even when its
body is valid JSON. This differs from the previous Windows transport, which
accepted all 2xx statuses. HTTP 200 confirms a response page, not a complete
release listing. This transport currently fetches only the first page; it does
not follow GitHub pagination, so it must not be treated as a complete update
check. A 200 status alone is not sufficient: the injected selector must
validate the body and URLs. Actual HTTP framing, a server that
mislabels a partial body as 200, TLS, DNS, proxy behavior and live GitHub
responses have not been verified here.

Absolute server deadlines depend on the local clock if a valid server `Date`
is missing; a fast clock can still lead to an early retry. An unrepresentable
numeric retry hint disables automatic checks for the lifetime of the schedule.
System sleep, crashes, concurrent application instances, UI responsiveness,
the installed application and real update downloads remain unverified.

## Synthetic verification

On Windows, use Python 3.9 or later, Git, an isolated .NET 10 SDK and a work
directory outside the checkout, profile and app-data directories:

```powershell
python .\windows\native\UpdateController\Tests\run_synthetic_tests.py `
  --sdk-root '<isolated-sdk-directory>' `
  --work-directory '<new-directory-outside-repository-and-user-profile>'
```

The runner creates a unique synthetic profile and temporary directory, clears
NuGet sources, disables first-run certificate generation, and does not assign
HOME or CODEX_HOME. It rejects a work directory inside the checkout or the
current protected paths. These checks rely on the supplied environment and do
not defend against deliberate alias or link replacement. The test handlers
return synthetic responses without sockets; the operating system network is
not blocked. The initial source verification passed 78 coordinator assertions
and 38 in-memory HTTP assertions. Independent review of the original matching
candidate additionally exercised 204 synthetic cases with the actual release
selector. Those results do not establish application integration or a working
installer.
