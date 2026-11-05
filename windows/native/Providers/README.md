# Isolated provider state library

This project compiles the existing `windows/app/integrations/ProviderEventState.cs`
state machine for .NET 10. The Framework build continues using
`System.Web.Script.Serialization.JavaScriptSerializer`; the .NET 10 build uses
the local `SafeJsonDeserializer`. The library contains no event channel,
profile discovery, settings, UI, account access or provider activation.

The parser accepts the sanitized provider event protocol, not raw agent
payloads. The existing state store is not thread-safe and does not itself
enforce the provider allowlist or profile scope; those responsibilities remain
with the future controller and transport. The library is not yet connected to
the WPF prototype or any real source.

The .NET 10 parser intentionally rejects some non-standard JSON that the
Framework parser accepts, including leading-zero and plus-signed numbers,
single-quoted strings, non-JSON whitespace, and literal isolated UTF-16
surrogates. Escaped isolated surrogates are replaced. These differences do not
establish complete compatibility for every possible input.

To build offline and run both existing state suites plus synthetic parser and
state boundaries, call `Test-Providers.ps1` with:

```powershell
& '<repository>\windows\native\Providers\Test-Providers.ps1' `
  -SdkRoot '<isolated .NET 10 SDK directory>' `
  -WorkDirectory '<directory outside the user profile>' `
  -PwshNet10 '<PowerShell executable running on .NET 10>'
```

Windows PowerShell 5.1 is used for the existing Framework fixtures; override
`-WindowsPowerShell` if needed. Node.js is used to generate synthetic events
through the existing OpenCode and DeepSeek sanitizers; override
`-NodeExecutable` if it is not on PATH. PowerShell and Node.js are test drivers
only, not library dependencies. Each test run creates a new directory under the
provided work directory, sets isolated home/cache/temp paths for child
processes, disables the first-run HTTPS certificate and clears NuGet sources.
No package feed or user agent profile is needed. The test rejects work paths
inside the current user profile and paths with reparse-point ancestors.
