# Isolated Claude configuration transformation

This .NET 10 library prepares a JSON change for the native Windows migration.
It is **not connected to the application** and does not read, write, back up or
lock settings files, launch Claude, or install hooks. The caller supplies a
settings JSON string and the exact current and legacy monitor commands.

The transformation adds the monitor's eleven event groups or removes only its
recognized commands. Values of other settings and unchanged foreign hook
groups are copied as raw JSON; when a group contains both a monitor command and
foreign commands, the latter and the group's other values are retained as raw
JSON. Object and array formatting may change. An unchanged request returns the
original string. A leading BOM is retained. Unrecognized or ambiguous
structures, invalid UTF-16 commands, and attempts to remove the last command
from a group with other fields are rejected without returning an edited JSON
document. Some configurations accepted by older versions may therefore require
manual attention. This does not establish compatibility with every Claude
version or configuration.

This library alone does not protect against concurrent writers, partial writes,
filesystem links, crashes, access-control problems or incomplete migration.
Before integrating it, the caller needs strict decoding and size limits,
file-change handling, backup and recovery, an appropriate write protocol, and
independent testing. Task titles or settings passed to it may be sensitive;
the library does not intentionally log, persist or send them.

To run the synthetic offline checks, use a trusted .NET 10 SDK and an existing
work directory outside the repository and user profiles:

```powershell
python -I -B .\windows\native\ClaudeConfig\Tests\run_synthetic_tests.py `
  --sdk-root '<absolute SDK directory>' --work-directory '<absolute test directory>'
```

The runner creates a fresh directory, clears NuGet sources, and uses isolated
profile, application-data, temporary, SDK-home and package directories for
child processes. It does not assign `HOME` or `CODEX_HOME`. This is a synthetic
check, not an OS-level network sandbox or a real Claude integration test. Path
guards depend on the supplied environment and cannot identify every other
user's profile or every path alias; choose a trusted local work directory. The
runner refuses to start when the current profile or application-data paths are
missing, relative or inaccessible.
