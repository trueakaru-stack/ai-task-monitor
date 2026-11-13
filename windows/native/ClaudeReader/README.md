# Native Claude event reader

This .NET 10 library is an unfinished part of the Windows migration. `Reader`
interprets phase-aware Claude events, while `SessionReader` retains known step
names as unconfirmed after a detected loss. A new user message is not assumed to
start a different plan when the intervening history is missing. Known old and
new names may therefore appear together without confirmed status or progress.
This also applies when the same step ID is reused for different observed
names, including when both arrive before the first read. Without observed loss
or session uncertainty, an ordinary rename keeps its latest name. Retained
history is limited to 128 entries per session and is marked incomplete when
bounded; an overlong step ID is represented internally by a SHA-256 identity and
also marks the retained plan incomplete. Values no longer present or observed
cannot be recovered.

Session IDs are limited to 128 UTF-16 code units, matching the length limit in
the installed hook. A longer session ID is rejected before it can enter event
state or retained-card dictionaries; it is not truncated or converted into a
shared placeholder. The rejected event marks source-wide loss, so the
unsupported session cannot be displayed as a confirmed card. Previously visible
cards and bounded names remain unconfirmed, even when the same snapshot contains
a stop. Existing session IDs within the limit retain their exact identity;
separate IDs are not merged. The length bound does not establish that every
other aspect of a historic or independently produced event is trustworthy.

`ClaudeFileSource` reads caller-supplied journal paths and connection state. It
limits each read to 4 MiB and only parses complete UTF-8 lines. If a bounded
snapshot ends with an incomplete line, including after complete events, it
retains known cards and step titles with unconfirmed activity and unknown step
statuses. An incomplete snapshot does not advance the stateful session reader,
but source loss discovered in its complete lines is recorded immediately and
survives later completion or truncation. A completed append can restore
confirmation if no loss was detected. The legacy journal is inspected for
source loss even with no current IDs, while legacy-only events cannot create
cards. A read error, truncation, or change in the previously observed bounded
window records source loss and retains names as unconfirmed for this reader's
lifetime. Each poll reads that bounded window twice through separately opened
handles, including the byte before its start when present, and compares the
captured bytes. It also compares the previously observed range using a SHA-256
digest, rather than checking only the last 128 bytes. A pure append after the
captured length can wait for the next poll. Moving the 4 MiB window past
previously observed full records also records loss because
those records may contain needed plan evidence. A first read of a journal larger
than 4 MiB likewise marks its unseen prefix as loss, even when the retained tail
starts exactly at a line boundary. This conservatively keeps large-journal plans
unconfirmed; names that were never observed cannot be reconstructed.

An observed `Disconnected` or `Partial` connection also records source-wide
loss. Disconnected snapshots hide cards while keeping bounded known names;
after a partial connection or reconnection, retained cards and newly read events
are unconfirmed. A later event or an unchanged journal cannot prove that its
writer belongs to the new connection, and even a delayed stop cannot erase a
previously visible card. This uncertainty remains for this reader's lifetime;
it does not affect a separate source instance. A first direct `Connected` poll
without a previously observed interruption keeps its ordinary behavior.

Conflicting active and stopped events for one session at the same instant are
not ordered by their positions in either journal. The affected card remains
visible and unconfirmed on repeated reads; other sessions are not downgraded.
Different time-zone offsets representing that same instant are treated equally.
While the conflict remains in the readable journal, a later clear stop does not
resolve it. Equal-time events with matching active states do not cause this
ambiguity; a strictly later clear stop in an otherwise unambiguous history can
end its session normally.

The future owner must call `NotifyConnection` promptly for every connection
change, including while a poll is in progress, and then use `Poll(utcNow)` to
read the latest signalled state. Each result carries a generation; `IsCurrent`
rejects a result from an older connection signal or another source. A signal
detected during the read produces a hidden or unconfirmed result and retains
names from before the read. `IsCurrent` alone cannot make checking and UI
presentation atomic: the owner must serialize notifications, the check and
presentation, and serialize polls. A connection change never reported to the
source cannot be detected. The prototype pump uses this contract in synthetic
tests, but the application entry point does not start it and live in-flight
protection remains unverified.

Pending snapshots use the session reader's existing retention rules: at most
256 cards and 128 retained steps per card, with bounded step titles and IDs.
An incomplete retained plan is flagged and retention overflow marks the source
unavailable and unconfirmed rather than silently confirming a partial view.
These bounds also apply to fallback cards after a failure during a pending read.

During a poll, Windows `FILE_ID_INFO` is compared across the two simultaneously
open handles; unsupported or invalid identities are treated as loss. When a
journal exists, the file source also reports loss on non-Windows systems where
this identity check is unavailable. Missing optional files do not request an
identity; the separate event parser is not restricted by this check. This does
not make a concurrent read atomic. A same-prefix replacement between polls, or
after the second handle opens, can still go undetected. IDs can be reused, and
coordinated ABA changes, changes between checking the two files, or a writer
that never records an event can also remain undetected. An append after
the captured length may only be seen on the next poll. The source cannot tell a
live partial write from a permanently interrupted one, cannot guarantee a future
completion or notice every writer failure, and its memory of loss does not
survive a process restart. It does not discover a real profile, register hooks,
or start itself in the application. Synthetic tests of bounded input and known
failures do not establish behavior for a real Claude installation.

Do not connect this reader to real profiles until the remaining file identity
gap and the other documented integration limitations are handled.

The phase-aware format must not be passed to the old reader: an older monitor
can misinterpret a phase event as a confirmed step. A separate journal and an
explicitly tested migration are required before the new hook can be connected.
A clear Stop event also does not prove that a different hook did not block the
stop; subsequent activity can make the task visible again. A failed writer may
be unable to record its own loss.
When no source-wide loss is known, an ambiguous later event without observed
activity does not by itself revive a card after a clear Stop. After a known
source-wide loss the retained fallback can remain visible as unconfirmed.
Later observed activity can show the card again, with uncertainty retained
where the source does not prove the full history.

The synthetic file tests create a new directory inside the process temporary
directory and accept no external event or fixture arguments. The
`claude-file-source` job in `.github/workflows/windows-dotnet-path-safety.yml`
runs them on disposable hosted Windows with a cleared child environment,
synthetic temporary/profile directories and `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0`.
The candidate passed 164 file-source checks and 22 file-identity checks in
[CI run 43477294258](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43477294258),
using synthetic files on one hosted Windows filesystem.

The WPF file and title-retention checks require Windows and a similarly isolated
test environment; they were not run by that job. Do not invoke old local test
runners without reviewing their environment handling. `Test-ClaudeReader.ps1`
is an earlier source-identity check for the legacy embedded reader, not an
acceptance test for this version. Real Claude sessions, final application
integration and installer behavior remain unverified.
