# Claude hook translation slice

This is an isolated .NET 10 library, not a connected hook or an installer. It
translates a supplied JSON string and supplied time into the ten-field Claude
event-log record. It does not open files, connect to a pipe, start a process,
load settings, or inspect a user profile. The production application does not
use this library yet.

The limit is 1,048,576 UTF-16 code units, matching the existing hook's input
limit. `ClaudeHookInputReader.ReadAsync` provides an isolated, bounded reader
for a supplied stream; neither it nor the translator is connected to the
application. A caller that supplies a `string` directly must enforce the
limit while reading rather than allocating an oversized string first. Time is
supplied by the caller and rendered in UTC. The only output properties are
`timestamp`, `provider`, `session_id`, `event`, `active`, `activity`,
`task_id`, `task_subject`, `task_status`, and `tool_name`. Input fields such
as prompt, working directory, command, transcript path, and tool response do
not have output properties. This is not a general secret scrubber: an allowed
field, including a task subject, can itself contain sensitive text.

Subject and tool names use the existing whitespace normalization and limits.
If a UTF-16 surrogate pair straddles a truncation boundary, the new code cuts
one code unit earlier before appending `...`; the result remains within the
same limit without retaining a broken surrogate. Valid Unicode in retained
text is preserved. The translator rejects selected fields containing objects or
arrays, malformed Unicode, invalid JSON, and nesting beyond its parser limit.
These are deliberate restrictions; compatibility with malformed or unusual
numeric inputs is not claimed.

On the Windows host used for this test, sending raw UTF-8 to the existing
PowerShell hook produced corrupted non-ASCII output. The new translator
preserved that test input. This observation applies only to the tested host and
launch method. Differential Unicode fixtures send equivalent ASCII JSON with
Unicode escapes to the unchanged hook, so the comparison tests translation
separately from the observed input-decoding difference. The translator receives
an already decoded string; characters already replaced by an upstream decoder
cannot be recovered here. The optional reader accepts the byte stream directly.

## Input reader contract

`ClaudeHookInputReader.ReadAsync` reads the caller-supplied stream to EOF using
strict UTF-8. It removes exactly one leading UTF-8 BOM, preserves later U+FEFF
characters, and counts the remaining UTF-16 code units, including both halves
of a supplementary character. Empty input returns an empty string. Malformed or
truncated UTF-8 and text over the limit return `null`, with no partial result;
the reader can stop without draining the remainder. Fixed-size byte and
character buffers are used, and the text is checked before each append.

The caller owns the stream: the reader does not dispose it on success, invalid
input, cancellation, or I/O failure. Cancellation and I/O exceptions propagate;
the reader passes the cancellation token to the stream and checks it between
reads. An outstanding read can be cancelled promptly only if that stream
supports cancellation or is closed by its owner. This component provides no
timeout and does not close the stream to force one. It neither logs nor writes
the supplied input, but decoded text and buffers exist temporarily in memory.

Unlike this reader, the old PowerShell hook reads `Console.In` using the
encoding selected for that process. On the Windows host and launch method in
the synthetic comparison, that encoding was CP866 and raw UTF-8 became
corrupted; other hosts may differ. The new reader accepts UTF-8 only and
rejects malformed byte sequences rather than trying CP866 or replacing
invalid bytes. Stripping an initial UTF-8 BOM is also an explicit reader
contract, not a claim about the old console decoder.

## Synthetic verification

On Windows, use an installed, isolated .NET 10 SDK and choose a work directory
outside the repository and user profile:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
  -File '.\windows\native\ClaudeHook\Test-ClaudeHook.ps1' `
  -SdkRoot '<isolated-sdk-directory>' -WorkDirectory '<isolated-work-directory>'
```

The runner creates a unique test directory and offline NuGet configuration,
copies the actual two hook scripts, verifies those copies by SHA-256, and
launches the copied hook with synthetic homes and unique test pipe and mutex
names. It compares every output field except the separately injected timestamp,
checks privacy and size boundaries, and reports the host's direct UTF-8 result.
It also exercises the new reader using synthetic fragmented streams, limits,
invalid encodings, BOMs, cancellation, and stream ownership. No real provider
profile, token, named pipe, or application data is used.
