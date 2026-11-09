# macOS provider v1 isolation candidate

These are frozen test-only copies for an isolated GitHub-hosted macOS runner.
The workflow overlays them on the pinned `cf9dce5` source baseline only in the
disposable runner. They do not change the product, installer or user settings.

The candidate attempts to isolate profile scopes and conservatively retain
unconfirmed v1 cards. It does not implement the user-selected restart action,
prove event freshness or restore history after a monitor restart. The initial
v1 stream, actual agent sessions and real-world delivery are unverified. A
passing synthetic run and release compile are not evidence of a release or a
complete integration.

The runner uses a synthetic home, denies IP networking, and allows local Unix
sockets for its test fixtures. A probe must demonstrate both restrictions
before tests begin. Candidate source review and acceptance remain separate.
