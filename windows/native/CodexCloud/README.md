# Codex Cloud: bounded synthetic core

This directory contains an isolated, in-memory state machine. It does not start Codex,
read a profile, contact a service, subscribe to a timer, or update the application UI.
The console tests supply their own JSON bytes and do not start a CLI or access an
account. No real-cloud integration or real-cloud coverage is established by these
tests.

## Contract

A caller explicitly enables a source and starts at most one scan. It supplies a page
only in response to the current opaque request, follows the returned request, and
reports failure or cancels when needed. Replayed, late, cross-source and
previous-generation requests do not change published cards. Disabling the source
invalidates the scan and clears only that instance. Snapshots themselves carry
no generation. A future UI owner must serialize snapshot capture and application
with enable/disable changes and scan publications, or attach its own lifecycle
generation and monotonic sequence and discard delayed snapshots. Otherwise a
queued older snapshot could overwrite a newer result or be shown after the source
has been disabled or re-enabled.

A JSON page is at most 1 MiB and has at most 20 tasks. A scan accepts at most five
pages, rejects duplicated IDs and cursor loops, and publishes only after a complete
scan or the fifth page. A failed page, transport failure, cancellation or retention
overflow discards the incoming scan and preserves the previous snapshot while
setting Unavailable. A fifth page with a cursor marks the snapshot Partial;
unseen old cards are retained, while explicit ready and error entries remove
matching old cards. A complete CLI response replaces the previous snapshot; a
missing task is not proof that it completed successfully. Repeated partial scans
are bounded to 256 retained cards; overflow reports failure instead of silently
evicting cards.

Pending, missing and unrecognized statuses produce cards with Unconfirmed=true,
Active=false, no progress and no confirmed plan. Ready and error are both
terminal for the displayed list and do not establish success. IDs in snapshots
are truncated SHA-256 digests, not the original IDs. This is not anonymization:
guessable IDs can be matched by hashing candidates, and the same ID can be linked
across scans. Treat the digests as sensitive data. Titles are intentionally
available for display, whitespace/control characters are normalized, and titles
are limited to 240 UTF-16 code units without splitting a surrogate pair. A missing
title is null; a future UI adapter supplies its localized default. Unknown fields
are not exposed. Parsing rejects invalid UTF-8, duplicate recognized fields,
invalid types, malformed/oversized identifiers and cursors, and malformed or
over-nested JSON. Duplicate recognized fields and a repeated cursor on page five
are rejected conservatively.

Requests expose their opaque cursor only for a future transport; the property is
excluded from default JSON serialization, and ToString() does not reveal it.
Callers must never log cursors, raw pages, credentials, command output, task IDs
(including their digests) or task titles. The parser takes a bounded copy of the
provided bytes and clears that copy;
the caller owns and must not mutate its buffer during the copy. Other managed
strings and the caller's original buffer are not guaranteed to be erased.

Recoverable errors while reading the supplied memory, including access errors,
produce a failed scan. Unexpected exceptions such as OutOfMemoryException are not
suppressed. The calling owner must cancel any unfinished scan after an unexpected
exception when it is able to do so; recovery from actual memory exhaustion is not
guaranteed.

The CLI response can omit tasks outside its own scope, pagination window or
permissions. Neither a successful scan nor an absent card confirms the status of
all cloud work. Old cards retained after an error or partial scan can be stale.

## Required follow-up before connection

A separate owner/transport must invoke the installed, user-authorized official CLI
without a shell, use safe argument handling, bound stdout while reading (not only
after allocation), bound stderr without logging it, validate UTF-8, enforce and
test per-command and whole-scan deadlines, cancel/terminate child processes safely,
and forward only the matching request's result. The released implementation uses
codex cloud list --json --limit 20 with an optional cursor, a 12-second command
limit and a 30-second scan limit; the new component does not itself enforce these
limits. Credentials remain the CLI's responsibility. Real CLI compatibility,
process lifecycle, UI integration, status semantics, behavior across CLI versions,
and actual provider/account coverage require independent checks before enabling
this source. No URL, account, transport, or process is provided here.

## Synthetic hosted CI

Use an isolated hosted Windows runner and its disposable directories. Disable
.NET's global-tools PATH modification for the parent and child processes. With an
empty-source NuGet config and isolated artifacts directory already created:

    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
    dotnet build windows/native/CodexCloud/Tests/CodexCloud.Tests.csproj -c Release --configfile $config --artifacts-path $artifacts -p:NuGetAudit=false --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Codex Cloud build failed.' }
    dotnet (Join-Path $artifacts 'bin/CodexCloud.Tests/release/AITaskMonitor.CodexCloud.Tests.dll')
    if ($LASTEXITCODE -ne 0) { throw 'Codex Cloud synthetic checks failed.' }

The tests exercise the pure state machine and parser, not a real Codex process,
network, account, or GUI. Do not substitute their success for end-to-end testing.
