# Isolated Codex session index reader

This .NET 10 library is an **unconnected migration slice**. It does not
discover a Codex profile, enumerate real lock files, read session transcripts,
start PowerShell, contact a service, write the index, or connect itself to the
application. The caller supplies an absolute index path, previously observed
IDs, and IDs whose locks were independently determined to be held or
unavailable. The caller must choose a trusted path: this reader is not a
filesystem sandbox and does not prevent links from resolving outside it.

For canonical JSON objects with string IDs and optional string or null
`thread_name` and `updated_at`, the reader returns the ID, title, original
timestamp string and a locally interpreted calendar date when the date parses.
It retains the latest matching ID in the last 50 lines, and looks further back
only for observed or held/unavailable lock IDs missing from that tail. IDs are
matched without case; the historical lookup uses the same quoted-text filter
as the reference, so an escaped ID can be missed when no matching literal
appears elsewhere on its line. The historical cache uses full path, byte
length and last-write UTC ticks. Rewriting a file without changing those
attributes can therefore leave a cached value stale, as in the reference.
Order is not a compatibility contract.

`HasUnsupportedRows` signals malformed or noncanonical rows in the tail or
any line of a historical scan, plus invalid IDs supplied by the caller. A row
with a missing, null, empty or otherwise invalid ID is unsupported; blank lines
are ignored. The reader rejects IDs outside `[A-Za-z0-9_-]{1,128}` with a
strict end-of-string match. Windows PowerShell 5.1 can accept a final line
feed or non-ASCII case variants; such IDs are not passed through. PowerShell
also accepts some JavaScript-style non-JSON records and coerces non-string
fields. This reader does not reproduce those forms; they set the unsupported
flag. A future source controller must define how that flag affects uncertainty
before integrating this reader. It must not interpret an unsupported row as
proof that its task does not exist.

Missing, inaccessible, locked, incorrectly encoded and oversized-history sources throw
`CodexIndexUnavailableException` with no original path or line in the
exception. One deliberate correction to the reference is transactional
historical caching: a failed scan does not publish negative results. The
reference can instead return a cached negative result on the next unchanged
read after a failed scan. A valid long tail row is not subject to the
history-only 1,048,576 UTF-16-code-unit limit.

UTF-8 without BOM and BOM-marked UTF-8, UTF-16 LE/BE and UTF-32 LE/BE use
strict decoders. Invalid byte sequences fail the read instead of being
silently replaced, unlike the PowerShell reference. A correctly encoded
U+FFFD remains valid content. A UTF-8 tail lookup does not decode earlier,
unread bytes; it cannot report corruption there until a historical scan reads
them. BOM-marked UTF-16/32 tail lookups decode forward through the file.

IDs, titles and timestamp strings can contain private information. They remain
available to the caller and may remain in memory in the cache. The reader does
not log, persist or send them; its entry `ToString()` does not expose their
values. This is not encryption, secure erasure, or a general-purpose redactor.
Callers must avoid logging or disclosing fields. Error messages in the test
runner refer only to synthetic case names.

Each reader serializes its own calls and cache updates. Tail and historical
scans are separate file operations with read/write/delete sharing: concurrent
changes can produce results drawn from different moments, and a successful
read is not an atomic snapshot. The library does not detect every change made
while a file is read. The historical scan validates every line, which may cost
more CPU than the reference's filter-first scan. Its historical scan, regular
expression and tail-line allocation have no global size, duration or
cancellation limit; large or hostile files can consume memory or block the
calling thread. Do not use this reader on a UI thread without additional
design and verification.

## Verification

On Windows, use an isolated .NET 10 SDK, the pinned PowerShell reference and
an empty work directory outside the repository and user profile:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
  -File '.\windows\native\CodexIndex\Test-CodexIndex.ps1' `
  -SdkRoot '<isolated-sdk-directory>' -WorkDirectory '<isolated-work-directory>' `
  -ReferenceSource '<pinned-CodexProgress.ps1>'
```

The runner requires reference SHA-256
`DD9A401DFABDFC68623A8503746EF7808F154C0E606588CE9143F07A31FEDDB8`,
copies and rechecks it, clears package sources and uses synthetic home,
temporary and fixture directories. It extracts the actual `Prop`,
`Lock-State` and `Codex-IndexCandidates` functions and compares their
synthetic outputs with the native reader. Checks cover 50-line boundaries,
history lookup and cache changes, IDs, Unicode titles, timestamps with
offsets, BOM-marked encodings, line endings, a historical line at and above
the size limit, malformed rows and missing IDs, invalid byte sequences and
valid U+FFFD in tail and history, held locks, missing files, a synthetic
Windows ACL denial and restoration, concurrent calls and 150 synthetic replacements.
The intentional failed-cache and noncanonical differences are asserted
separately. The native long-tail test uses a row above 1 MiB; the reference
long-tail check uses 64 KiB because `Get-Content -Tail` is slow on unusually
long lines. These tests do not establish equivalence for all cultures, date
formats, malformed data, filesystems or concurrent interleavings, and do not
exercise real agents or profiles.
