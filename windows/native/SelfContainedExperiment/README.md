# Self-contained WPF preview experiment

This CI-only experiment publishes the existing C# WPF preview for `win-x64`
with a bundled .NET runtime. It is not a release, an installer, or a completed
monitor. Real sources, settings and shutdown behavior are still incomplete.

`Test-SelfContainedPreview.ps1` runs only on a new disposable GitHub-hosted
Windows runner. It downloads Microsoft's SDK 10.0.404 ZIP, checks the SHA-512
in the official [10.0.15 release metadata](https://github.com/dotnet/core/blob/main/release-notes/10.0/10.0.15/release.json),
validates archive paths and extracts it under a new runner-temp directory. A
temporary checkout-local `global.json` pins the SDK with roll-forward disabled.
The test pins `RuntimeFrameworkVersion` to 10.0.15 and restores only through the
official NuGet feed, using a fresh isolated package cache and required NuGet
signature validation against the Microsoft author-signing certificate
`9A1B131BEE0605433056A4EA3815478A8E177961A968C6C0027C1093D1FEB630`,
[published by Microsoft](https://devblogs.microsoft.com/dotnet/microsoft-author-signing-certificate-update-2026/).
Package identities and SHA-512 values are saved in a
synthetic inventory; other SDK-selected packages may be needed. No machine or
user-wide SDK installation is performed.

Every .NET process has `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0`; the runtime, CLI
state, package cache, temporary directory and Windows profile locations are
isolated. The test compares registry PATH values and types and process PATH
before and after. It does not assign HOME or CODEX_HOME. Hosted-runner markers
are an accidental-execution guard, not an isolation boundary; never run this
test on the user's machine.

The test launches the published executable with `DOTNET_ROOT` set to a new empty
directory and a process PATH that excludes the SDK. It checks that the process
owns the preview window, that the loaded CoreCLR and any observed host/WPF
runtime modules come from the published payload, and that the CoreCLR version
matches the pin. It inventories every payload file, nested directory, size and
SHA-256 without copying to a user profile. The generated screenshot is synthetic
evidence and is not visual acceptance. A self-contained application still has
Windows system dependencies; updating its bundled runtime requires rebuilding
and redeploying the application.

No install/uninstall is performed by this experiment. The inventory is an input
to a separate CI-only installer investigation: nested files and directories,
reparse points, locked or replaced files, ownership, interrupted installation
and safe removal need their own controls and tests. Never treat the experimental
payload or its build output as a release or publish it to users.

