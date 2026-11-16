# Synthetic Codex hook evidence

This is an isolated, in-memory experiment for the Windows C# migration. It is
not wired into the monitor and does not implement a hook executable, delivery,
registration, process discovery, authentication, file access, or networking.
It does not inspect or modify a Codex profile. It does not establish that the
installed Codex CLI or Desktop version supports these events.

## Meaning of evidence

The collector accepts a bounded JSON input and retains only the event kind and
the session/turn identifiers needed to correlate events. An accepted
`UserPromptSubmit`, `PreModelRequest`, `Stop`, or `Interrupt` is historical
evidence that the corresponding input was received. It is never proof that a
task is currently running or has completed successfully: both confirmation
properties are always false. In particular, `Stop` is a proposal; another
hook can request continuation. A submitted prompt can also be blocked by
another hook. `PreModelRequest` is a request attempt, not a completed turn.

Background hook invocations may be delayed, arrive out of order, or be lost.
Events are combined as an order-independent set per turn; there is no inferred
chronology, progress, title, successful completion, or last known live state.
Starting or reconnecting mid-session cannot recover an earlier event. Empty
evidence does not mean that no task exists. The caller may mark a known loss;
coverage is always incomplete even if no loss has been detected. Reconnection
invalidates callbacks tied to the prior local connection, but an old upstream
event delivered through the new connection remains indistinguishable from a
new one and stays unconfirmed.

Events with either `agent_id` or `agent_type`, including a null value, are
ignored because they cannot safely be classified as root events. The inspected
Codex source omits these fields when no subagent is involved. Unknown events
are ignored. Malformed input and capacity overflow mark an observation gap;
new evidence is refused once the session or per-session turn bound is reached.
Existing entries are retained for the lifetime of the collector, including
after disconnect; a future owner must explicitly decide their lifetime and UI
policy. This component must not by itself create persistent task cards.

It does not read rollout files, so log size does not affect this parser. This
also means it cannot recover missed events, choose among multiple rollouts for
a thread, or determine which rollout is current.

## Privacy and concurrency

Only identifiers and event kinds are retained in memory. Identifiers are
sensitive metadata: normal JSON serialization and `ToString` omit them, but
the properties are available to the caller for correlation and must not be
logged or exposed. This is not a security boundary: an untrusted sender could
place other text in identifier fields. Authenticating a future transport and
validating its source is a separate requirement.

Codex input may include prompt text, assistant messages, paths, or other
private content. The parser scans the caller-owned UTF-8 input to validate it
but does not retain or log the payload or unknown field values. The caller
must keep that buffer stable during parsing and take responsibility for its
disposal and clearing; managed strings and runtime memory cannot be promised
to be securely erased. The synthetic tests use invented data only.

Operations on one collector are synchronized in memory. An old local
connection cannot change evidence after disconnect or replacement returns.
No lock is taken on Codex files or processes; this standalone library has no
connection to the Codex writer.

## Upstream contract and future registration

Source inspection was pinned to the public Codex CLI 0.169.0 release commit
[`d32063f96c2dff1dc96af839b3952abb6acfeda4`](https://github.com/openai/codex/tree/d32063f96c2dff1dc96af839b3952abb6acfeda4).
The [hook documentation](https://learn.chatgpt.com/docs/hooks) describes
background hooks and Desktop trust review; support and configuration must be
verified against the user's actual installed versions before any integration.
The [event implementations](https://github.com/openai/codex/tree/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/src/events)
show the relevant fields and separate root/subagent event types. The
[`Stop` implementation](https://github.com/openai/codex/blob/d32063f96c2dff1dc96af839b3952abb6acfeda4/codex-rs/hooks/src/events/stop.rs)
allows a hook to request continuation.

A future plugin could bundle its own hook definitions alongside existing
hooks, subject to user trust and independent compatibility and safety testing.
No plugin is installed here. The examined marketplace-add implementation
rewrites shared configuration, and there is no established protection against
simultaneous writes; do not assume that installation preserves a concurrent
change. For a non-waiting observer, the docs describe asynchronous command
hooks, which still consume resources, can queue, and can be cancelled at
session end. `SessionEnd` is synchronous and is not used here. Actual command
quoting, hook trust, transport security, cancellation and CLI/Desktop behavior
remain unverified.

## Verification scope

The test program is restricted to a disposable GitHub-hosted Windows runner
with `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0`. It checks invented event payloads,
out-of-order and concurrent delivery, reconnection, gaps, bounds, and privacy
of the public snapshot representation. It does not launch Codex, exercise a
real hook, prove Desktop compatibility, validate a transport, or test the UI.

The candidate passed 194 synthetic checks in [CI run 43835982092](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43835982092).
