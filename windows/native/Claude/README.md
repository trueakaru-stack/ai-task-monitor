# Isolated native Claude loop channel

This Windows-only .NET 10 library links the existing protected Claude loop
channel without changing the Framework application. It is an unconnected
migration slice: it does not install a hook, monitor a user session, implement
the warning logic, or connect to the WPF prototype. The existing Framework hook
is invoked only as a synthetic test client. The finished application still
needs its own compatible native hook and safe configuration migration.

The local compatibility adapter uses the same bounded JSON parser as the
native provider prototype. Tests compare its accepted sanitized protocol with
the Framework parser and exercise the actual channel. The native parser is
stricter for some malformed JSON, such as a leading zero in a number; it does
not claim byte-for-byte behavior for invalid input or untested timestamp and
encoding forms. An independent parser corpus also found a difference for a
legacy JSON date escape in an optional field under a custom numeric culture;
the existing hook sends an empty field for that event, but arbitrary clients
have not been proven equivalent.

The isolated tests use unique synthetic pipe names and homes, inspect the
actual handle and ACL, check parser cases against the Framework implementation,
run synthetic events through the real legacy hook, and exercise 1,000 ordered
frames, a partial-frame timeout, shutdown and key rotation. They do not test a
remote computer, another Windows account, a real Claude session, or every
possible channel race. Test drivers use PowerShell; the library does not host
or invoke it.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\native\Claude\Test-Claude.ps1 `
  -SdkRoot '<isolated .NET 10 SDK directory>' `
  -WorkDirectory '<directory outside the repository and user profile>'
```

The test driver creates a fresh fixture directory, clears inherited process
environment variables before builds and synthetic hook execution, disables
telemetry and first-run certificate generation, and uses no NuGet feeds.
