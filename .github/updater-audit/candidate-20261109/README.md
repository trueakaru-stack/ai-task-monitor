# macOS updater candidate: test fixture only

These files are a frozen, line-ending-normalized copy of an experimental
updater and synthetic tests. They are not application source and do not
replace or publish an installer. The associated workflow checks their
hashes, overlays them onto the pinned application source on a disposable
macOS runner, blocks network during tests, and runs the release test suites.

The candidate still has an unresolved boundary when cancellation wins before
a response callback registers its headers. A crash or failure of both storage
copies can also lose a pending server delay. The workflow checks compilation
and the included synthetic tests; it does not prove real network behavior,
durable storage under all failures, or readiness for integration.
