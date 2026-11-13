# Synthetic Codex source integration

This is an experimental, synthetic-only migration slice. The controller is
`internal` and visible only to its synthetic test assembly; it must not be
linked into the application or used with real profiles. The caller supplies an
absolute index path, a sessions root, a lock-observation function, the monitor
start time, a clock and any IDs whose locks are held or unavailable. The slice
combines the existing index reader, session discovery and lifecycle reducer.
It does not discover a profile, inspect real lock files, start an agent, connect
to the application, make network requests or write source files.

The journal reader reads at most 1 MiB and 8,192 lines. It requires complete
UTF-8 lines, parseable JSON and a first `session_meta` record whose `payload.id`
exactly matches the index ID. This check follows the identity comparison in
the [official Codex rollout reader](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/list.rs#L1297-L1311);
it does not authenticate a file or establish which of multiple files with the
same ID is current. Only the known start, completion and abort event types are
accepted. Each needs an unambiguous turn ID and an explicitly zoned timestamp
at or before the caller's clock. A terminal must match the open turn; a
non-null error, unknown event or unknown top-level record makes the journal
uncertain. The only non-lifecycle record currently ignored is
`token_usage_record`, which [Codex defines as a top-level record](https://github.com/openai/codex/blob/main/codex-rs/history/src/rollout_payload.rs#L32-L74)
for [per-response usage](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs#L2416-L2427).
The reader requires its payload to be an object but does not validate its full
schema or infer a turn's status from it. Other rollout types are unsupported
even if Codex recognizes them. Case-colliding key fields are rejected.
Lifecycle timestamps must increase strictly in journal
order. Equal instants, including equivalent timestamps in different time
zones, are ambiguous and are rejected along with decreasing timestamps. A
start reusing an already closed turn ID is rejected, including differences
in letter case; a distinct later turn may still be accepted. These conservative
restrictions intentionally do not claim compatibility with every Codex version
or event type. Equal timestamps may occur in real data; this policy can leave
such sessions unconfirmed until a verified ordering or recovery policy exists.

The source returns currently active or previously visible unconfirmed tasks;
a supported completion or interruption removes its card but keeps a bounded
history anchor. IDs and titles may contain private data and must not be logged
or disclosed. The exported test state contains only status and uncertainty,
not the reducer's turn key or timestamps. The controller does not log source
paths, records, IDs or titles; it does not promise secure memory erasure.

Any unavailable or unsupported index causes source-wide uncertainty for the
controller's remaining lifetime. The same applies if the supplied clock moves
backwards between refreshes, even if it remains later than monitor start. An
unchanged clock is accepted; regressions between observations cannot be seen.
A journal error, missing identity, unknown
lock, changed lock observation, ambiguous record, changed prefix, truncation or
replacement retains only the affected previously visible task as unconfirmed.
The affected session does not automatically regain confirmed status, even if
an unchanged prefix or a later start appears: this slice has no independently
verified process-generation or recovery evidence. A never-visible failed
session is not invented as a confirmed task. Healthy independent sessions stay
confirmed. A missing lock ID or capacity overflow marks the result incomplete;
already tracked healthy sessions may still be read, while new IDs are not
confirmed after capacity has been sealed. Up to 128 session/loss anchors are
retained for the controller's lifetime.

Fresh index and discovery helpers prevent their internal per-ID caches from
growing across refreshes, but their individual historical index reads and
recursive discovery scans remain unbounded. The journal checks also do not make
a read atomic: same-length concurrent replacement with unchanged metadata can
escape detection, and a replacement before first observation cannot be seen.
Official Codex can have multiple rollout files with the same session ID and
resolves the active one using information this slice does not have; see the
[official rollout resolver](https://github.com/openai/codex/blob/main/codex-rs/thread-store/src/local/thread_rollout_resolver.rs#L67-L108).
The existing discovery helper can choose the wrong such file even after its
metadata ID is checked. Supplied paths may resolve through links, and a lock
callback may block or interfere with a writer. These are blockers for real
use, not claims of safety or completeness. Reliable file selection, safe lock
observation, bounded source reads, restart recovery, actual event compatibility,
presentation and live-agent behavior remain unverified.

`Tests/CodexSource.Tests.csproj` creates only unique synthetic fixtures beneath
an existing caller-supplied work directory. The test refuses work inside known
profile/application-data directories and rejects reparse-point ancestors; the
checks are not a general filesystem sandbox. It does not delete fixtures,
change registry settings, launch an agent or make a network request.

Run on an isolated Windows CI runner with .NET 10 and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` in every SDK process. Build
`windows/native/CodexSource/Tests/CodexSource.Tests.csproj` with an isolated
artifacts directory and an empty NuGet configuration, then run
`AITaskMonitor.CodexSource.Tests.dll` from
`<artifacts>/bin/CodexSource.Tests/release/`, passing an existing absolute
synthetic work directory outside profiles and the source checkout. The tests
cover start, completion, interruption, separate sessions, loss and lock
transitions, metadata identity, ambiguous records, clock boundaries, bounded
tracking, replacement and uncertainty. They do not establish a working monitor,
safe real lock inspection, visual fidelity or installer readiness.
