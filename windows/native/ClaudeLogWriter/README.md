# Isolated native Claude event writer

This .NET 10 library is an unconnected migration slice. It accepts a
`ClaudeEventRecord` already produced by the Claude hook translator and appends
one JSON line. It does not install or run a hook, select a user profile, read
settings or secrets, start PowerShell, notify the loop channel, or connect to
the application. The library can write to the explicit directory passed by its
caller; use only isolated synthetic directories for the current tests.

## Contract

The caller supplies an existing absolute drive-letter directory, a local named
mutex, and a rotation limit. The writer does not create the directory. Unlike
the old hook, UNC paths and static reparse-point directory components are
rejected. A drive letter can refer to a mapped network drive; the writer does
not distinguish mapped drives, and they have not been tested.
The event file name is fixed to `claude-events-v2.jsonl`. Only Claude records
with non-null fields are accepted; serialization writes the same ten fields,
UTF-8 without BOM and CRLF after each compact JSON record. The translator
restricts which input fields reach this record, but an allowed field can still
contain sensitive text. This writer is not a secret scrubber.

The caller must supply the same mutex name as every cooperating writer and
cleaner. The legacy hook and retention worker use
`Local\CodexTasksClaudeEvents`; the synthetic tests instead require a random
`Local\AITM.Test.Writer.<guid>` name and never touch the real application
mutex. The writer waits at most two seconds, returns `Busy` without writing on
timeout, and releases the mutex it acquired. An abandoned mutex is released
and the exception propagates without writing, as in the existing hook. Other
I/O and path exceptions propagate; a future hook must handle them without
blocking the agent. This library does not itself implement that fail-open
process boundary.

The supplied limit is zero to disable rotation, or an integral decimal
megabyte between 1,000,000 and 100,000,000 bytes. The caller is responsible for
resolving settings: the old hook uses 10,000,000 bytes if settings are absent,
1–100 MB when configured, and disables rotation when settings are invalid while
continuing to append. Here no settings file is read. If the existing file is
already larger than the supplied limit, rotation takes its last 90%, discards
through the first LF when present, writes a unique temporary file, replaces the
old file, then appends the new record. Like the old hook, a file exactly at the
limit is not rotated until a later write; an appended record can make it exceed
the limit. If the retained tail has no LF, it is kept even if it is incomplete.

The JSON encoders may escape some characters differently from Windows
PowerShell; tests compare normal event fields semantically, not all possible
serialized bytes. Different encodings can change byte counts and therefore the
precise rotation point. Legacy malformed or unusual on-disk data and every
encoding are not claimed to be byte-identical.

## Security and failure limits

Existing final-file reparse points and ordinary directory ancestry are checked
before use, and temporary files are created with a unique name. These pathname
checks are not a defense against an attacker concurrently replacing paths.
Hard links and filesystem ACLs are not checked. Appends and replacement are not
a transaction: an I/O error can leave a partial append, or a rotated file without
the subsequent event. Temporary-file cleanup is best effort. Crash durability,
uncooperative writers, adversarial path races, and other Windows accounts are
not established. Do not use this slice as a production file-security boundary
without a separate handle-based design and review.

## Synthetic verification

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\native\ClaudeLogWriter\Test-ClaudeLogWriter.ps1 `
  -SdkRoot '<isolated .NET 10 SDK directory>' `
  -WorkDirectory '<directory outside the repository and user profile>'
```

The runner uses an isolated home and offline NuGet configuration, copies and
hash-verifies the existing PowerShell hook for differential tests, and uses
unique test mutexes and test pipe names. It exercises synthetic boundary and
rotation cases, busy and abandoned mutexes, separate concurrent native and
legacy processes, and static symbolic links where permitted. The writer itself
does not invoke PowerShell. Symbolic-link coverage depends on the host; test
output must be checked for skips. ACL access-denial tests are not included. No
real Claude session or profile is used.
