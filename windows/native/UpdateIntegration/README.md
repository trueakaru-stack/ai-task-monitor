# Isolated Windows update integration

This migration slice connects the existing release selector, retry-aware
coordinator and bounded GitHub HTTP transport in a separately owned service.
It is not wired to the Windows application and does not implement UI,
downloads, installation, or persistence.

The caller must explicitly choose `Standalone` or `Store`. Standalone creates
the transport and coordinator but makes no request until the caller invokes
`StartIfDueAsync`; the caller supplies clocks and timeout. Store constructs
neither the external transport nor the coordinator, has no update snapshot,
and never starts a check. Identifying the installed distribution correctly is
the future application's responsibility; this slice does not detect it.
Unknown and default channel values are rejected.

The caller drives checks at application startup and periodically thereafter;
this service does not create a timer or schedule operating-system wakeups.
The coordinator determines whether a requested check is due, and its retry
state remains in memory. `StopAsync` immediately prevents new publication,
requests cancellation and disposes the transport off the caller's thread; the
returned task completes when disposal completes. It does not promise that an
uncooperative in-flight handler has completed: the coordinator retains its one
occupied slot until that attempt and cancellation callbacks actually finish.
Repeated `StopAsync` and `DisposeAsync` reuse the same disposal task. The
optional injected HTTP handler factory is a test seam; omitting it uses the
existing restricted production handler. An injected handler is not a security
boundary and can implement different behavior.

The adapter uses the existing Windows selector without weakening its validation.
Malformed responses remain failures; a valid response without a matching newer
release asset remains a successful check without an update. The coordinator retains
its existing retry, cancellation and previously available update semantics.
The native transport accepts only HTTP 200 for the releases list; a 206 partial
response is a failed check rather than a successful empty update list.

The selector checks the release metadata and download URL but does not prove
that the selected `.exe` or `.msi` asset is an installer. It does not check
the package architecture, verify signatures or hashes, or filter GitHub's
prerelease flag. The existing version ordering can therefore offer a newer
prerelease to a stable installation; this slice preserves that legacy behavior.
Package identity, architecture and artifact verification remain unresolved
before a release asset can be offered to users as the application's update.

`Tests/UpdateIntegration.Tests.csproj` exercises the coordinator with an
in-memory transport and the service through an injected fake
`HttpMessageHandler`. It checks trusted and untrusted URLs, an already current
version, invalid metadata, an oversized body, server-directed retries,
transport failures, timeout cancellation, competing checks, Store isolation
and late responses after stop.
No socket, installer, profile or user settings are needed by the test program;
the operating-system network itself is not blocked. These tests do not
establish live GitHub/TLS/proxy behavior, application integration, visual
fidelity or installer readiness.

Run tests on a disposable Windows CI runner with an isolated .NET 10 SDK and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` set for every SDK process. Build the test
project with an isolated artifacts directory and a NuGet configuration with no
package sources, then execute `AITaskMonitor.UpdateIntegration.Tests.dll` from
the generated `UpdateIntegration.Tests/release` output directory. Preserve the
same opt-out in any child environment; do not run the tests through an older
unverified launcher on a user machine.

Before product use, the application still needs a verified distribution
channel, a process-lifetime owner, a startup and periodic check driver, safe
presentation of a selected update and the user-approved download flow. The
actual installer and Store packages, shutdown behavior, live HTTP behavior,
existing interface and end-to-end update path remain unverified.

The Windows PATH safety workflow runs these synthetic checks on a disposable
Windows runner. It compares the persistent user and machine PATH values before
and after the test; it does not establish application or installer readiness.
