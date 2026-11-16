# Synthetic local Codex hook transport

This is a separate Windows experiment, not a configured source in AI Task
Monitor. It provides a helper executable and an in-memory controller using the
existing `CodexHookEvidence` component. There is no installer, discovery,
registration, settings change, profile read, persistent queue, UI connection,
or real Codex invocation. The endpoint name is supplied explicitly in the
synthetic tests; how an installed hook securely finds the correct controller
has not been designed or verified.

## Data flow and limits

The helper reads at most 1,048,577 bytes from stdin. If the payload exceeds
1 MiB, is malformed, refers to a subagent, or cannot be delivered, it is
discarded. The existing evidence parser extracts an event kind, session ID,
and turn ID. The helper sends only those three fields, framed with a bounded
4-byte length, to the local controller. The receiver accepts no additional
fields and bounds the frame to 4 KiB. Prompt text, assistant responses,
working paths, commands, and API tokens are neither written to a log nor sent
as separate payload fields. The raw input can contain them and exists in the
helper's memory while parsing; buffers are cleared on normal paths, but the
runtime, OS, forced termination, and caller-owned input cannot be guaranteed
to erase every copy. Identifiers themselves are sensitive metadata and remain
in memory for correlation. No transport authentication prevents another
process of the same user from putting arbitrary text into identifier fields.

The helper produces no intentional stdout or stderr and returns zero on its
expected failure paths. After managed startup it waits at most two seconds for
its background worker, including a potentially unclosed stdin. The client and
controller each use a 350 ms I/O deadline. OS scheduling and executable
startup are outside those bounds; an actual hook must independently use Codex's
asynchronous mode and a Codex-side timeout. Async hooks still consume
resources, can queue, and may be cancelled. This code alone does not prove
that an installed hook cannot affect Codex.

One client is served at a time. Simultaneous helpers can time out or be lost;
there is no queue, retry, or acknowledgement. A successful write is not proof
that the controller processed it. Frames from different invocations may arrive
out of order. The controller marks a known malformed, truncated, or timed-out
frame as a gap, but cannot know about a helper that never connected or a
missing upstream event. Existing evidence always reports incomplete coverage.
Starting during a session cannot reconstruct earlier events. `Stop` remains a
proposal, not confirmed completion; events never prove current activity.
Evidence stays in the collector after controller stop and should not be used
by itself to create persistent cards. Retention and UI policy remain open.

## Windows boundary

The server creates an overlapped, first-instance named pipe with one instance,
an explicit protected DACL granting the current Windows user SID access, and
`PIPE_REJECT_REMOTE_CLIENTS`. The helper connects to the local machine and
checks that the pipe's actual owner SID equals its own user SID before sending.
The owner is set explicitly to the current user SID, rather than relying on
the token's default owner, which can be a group. Failure to verify the owner
causes a quiet drop. A random 128-bit pipe name reduces accidental collisions;
first-instance creation refuses an already occupied name.

This boundary is based on Windows access controls, not a claim of protection
from the same account, administrators, privileged processes, SID
impersonation, or an already compromised machine. A same-user process can
forge events, occupy the endpoint, read the pipe name when it is passed as an
argument, or create a fake server. No authorization token is used. A second
user/remote-connection penetration test has not been run. The hosted test
reads the actual DACL and checks the first-instance collision behavior; it does
not prove all Windows security configurations or impersonation cases.

The mechanism uses the Windows APIs documented for
[named pipe security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
and [`CreateNamedPipeW`](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createnamedpipew).
No named pipe is created outside the controller's lifetime. Stop disconnects
the collector before closing the pipe; late deliveries cannot mutate it.

## Verification scope

The synthetic tests require a disposable GitHub-hosted Windows runner and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0`. They launch only the new helper with
invented payloads, inspect the frame and DACL, check collision, ordering,
truncated and oversized frames, concurrency, missing server, unclosed stdin,
and repeated stop. They do not launch Codex, test a real hook or an installed
Desktop/CLI version, validate installation and endpoint discovery, or render
the application. A live integration still requires independent security and
lifecycle review, registration design, compatibility checks, and UI acceptance.
