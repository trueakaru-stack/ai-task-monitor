# Isolated Windows update integration

This migration slice connects the existing release selector and retry-aware
update coordinator. It is not wired to the Windows application, and it does
not implement a network transport, UI, downloads, installation, or persistence.
The caller supplies the transport, clocks, timeout, and application lifetime.

The adapter uses the existing Windows selector without weakening its validation.
Malformed responses remain failures; a valid response without a trusted newer
installer remains a successful check without an update. The coordinator retains
its existing retry, cancellation and previously available update semantics.

`Tests/UpdateIntegration.Tests.csproj` exercises the combined path using only
synthetic responses and an injected in-memory transport. It checks trusted and
untrusted URLs, missing updates, invalid metadata, retry scheduling and late
responses after stopping. No socket, installer, profile or user settings are
needed by the test program. These tests do not establish live GitHub behavior,
application integration, visual fidelity or installer readiness.

Run tests on a disposable Windows CI runner with an isolated .NET 10 SDK and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` set for every SDK process. Build the test
project with an isolated artifacts directory and a NuGet configuration with no
package sources, then execute `AITaskMonitor.UpdateIntegration.Tests.dll` from
the generated `UpdateIntegration.Tests/release` output directory. Preserve the
same opt-out in any child environment; do not run the tests through an older
unverified launcher on a user machine.
