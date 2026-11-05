# Claude hook translation slice

This is an isolated .NET 10 library, not a connected hook or an installer. It
translates a supplied JSON string and supplied time into the ten-field Claude
event-log record. It does not read files, connect to a pipe, start a process,
load settings, or inspect a user profile. The production application does not
use this library yet.

The limit is 1,048,576 UTF-16 code units, matching the existing hook's input
limit. A caller must enforce that limit while reading: receiving a `string`
does not prevent a caller from allocating an oversized string first. Time is
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
separately from the observed input-decoding difference. The library receives an
already decoded string; a future caller must decode UTF-8 correctly, because
characters already replaced by an upstream decoder cannot be recovered here.

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
No real provider profile, token, named pipe, or application data is used.
