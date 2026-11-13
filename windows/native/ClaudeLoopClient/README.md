# Isolated Claude loop packet builder

This .NET 10 library builds a sanitized Claude loop observation from an input
JSON string and a caller-supplied 32-byte channel key. It is an unconnected
migration slice: it does not select a profile, open files, create a mutex, start
processes, identify a monitor, connect to a pipe or register a hook. A caller
must separately establish a trusted channel, read the actual handshake key,
bound transport times and handle event loss. This library does not prove that a
receiver is genuine or that a warning is accurate.

The classifications follow `windows/app/ClaudeLoopClient.ps1`: prompt and stop
events produce `stop`; matching file edits produce `edit`; shell start, success
and nonzero exit produce `start`, `success` and `failed`; interrupted or
malformed shell observations produce `reset`. Unknown events produce no packet.
For `PostToolUse`, an absent `tool_response`, or an object without `interrupted`,
retains the legacy assumption of success. A present non-object `tool_response`
(including null) instead produces `reset`; this is deliberately more cautious
than the legacy fallback. A present `interrupted` must be boolean false to
produce success. For failures, an absent `is_interrupt` retains the legacy false
default; a present value must be boolean false or the result is `reset`. Missing
or malformed required command, directory, tool ID or exit-code evidence also
produces `reset`. A failed classification or packet build does not prove that
no event occurred and must not be treated as a successful observation.

Only the validated session and tool IDs, kind, optional numeric exit code and
optional keyed fingerprint are deliberately serialized. The raw JSON, command,
working directory and error text are not added to the packet or logs. The
fingerprint is HMAC-SHA256 of the legacy canonical UTF-8 representation; the
two lengths count UTF-16 code units, as in PowerShell. The body is compact JSON
with a four-byte little-endian byte-length prefix; the body limit is 4096 bytes.
The caller-owned key is not changed. Temporary byte buffers containing the key,
command or path are cleared where possible, but managed input strings and runtime
copies cannot be securely erased by this API.

The input is limited to 1,048,576 UTF-16 code units and 32 nesting levels; IDs
are ASCII letters, digits, underscores or hyphens, 1–128 characters. Commands
and working directories are nonempty strings of at most 131,072 and 32,768
UTF-16 code units. The JSON adapter rejects duplicate names case-insensitively,
requires string identifiers and exact field names, and rejects a trailing LF in
IDs. These conservative checks can reject inputs that PowerShell converts or
looks up case-insensitively. They match the restrictions needed by the existing
bounded phase classifier for normal Claude events, but exact equivalence across
all malformed or unusual PowerShell values is not claimed.

`Tests/ClaudeLoopClient.Tests.csproj` is a synthetic console test with a fixed
test key, known HMAC vector, classification and limit cases. The test process
accepts no external input and itself opens no files or pipes and starts no
processes. Build tooling can write artifacts and caches; run it only in a
disposable CI environment with isolated temporary, SDK-home and package paths,
cleared child environments without `HOME` or `CODEX_HOME`, and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0`. PowerShell differential testing, receiver
interoperability, channel security, actual Claude sessions, integration and
installer behavior remain unverified until independently exercised. No .NET or
GUI was run locally for this slice.
