# Synthetic Claude file identity checks

This isolated test project exercises the Windows file-identity check with
synthetic files. It does not start Claude, discover a profile, open a window,
or access an agent journal. The normal lookup compares the full 128-bit file
ID and 64-bit volume serial returned by `GetFileInformationByHandleEx` with
`FileIdInfo` while both read handles are open. An injected lookup tests failure,
unsupported or sentinel IDs, and differences in every part of that identity.
Both handles are released at the end of each read.

The tests include an ordinary append and an atomic replacement during a read
whose new file has the complete old byte prefix plus an appended event. The
replacement must be treated as loss even though byte comparisons alone would
accept its captured prefix. The tests require Windows and a filesystem that
supports `FileIdInfo`; the real unsupported-filesystem path remains unverified.
See the [Windows FILE_ID_INFO documentation](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info).

This comparison is limited to two simultaneously open handles during one poll.
The source does not retain a handle or file identity across polls. Replacement
between polls with the same prefix can remain undetected; file IDs can also be
reused after a file is deleted. A path can be replaced after the second handle
opens, even before the final comparison, leaving both handles attached to the
old file. Changes after the final comparison and coordinated ABA changes also
remain possible. Identity relies on the filesystem returning meaningful,
distinct values; network and unusual filesystems have not been verified. This
is not a proof of an atomic read or permission to connect real profiles. Before
product use, a cross-poll identity policy, noninterference with the writer, host
integration and live behavior still require independent evidence.

For disposable hosted Windows CI with .NET 10 already installed, set
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` at job level. From the repository root in
`pwsh`, use isolated directories and an empty NuGet source list:

```powershell
$ErrorActionPreference = 'Stop'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = '0'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = '0'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
$taskDir = Join-Path $env:RUNNER_TEMP ('aitm-file-identity-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($taskDir)
$env:DOTNET_CLI_HOME = Join-Path $taskDir 'dotnet-cli'
$env:NUGET_PACKAGES = Join-Path $taskDir 'packages'
$env:TEMP = Join-Path $taskDir 'temp'
$env:TMP = $env:TEMP
$null = [IO.Directory]::CreateDirectory($env:TEMP)
$nugetConfig = Join-Path $taskDir 'NuGet.Config'
[IO.File]::WriteAllText($nugetConfig, '<configuration><packageSources><clear /></packageSources></configuration>', [Text.UTF8Encoding]::new($false))
$project = 'windows/native/Tests/ClaudeFileIdentity/ClaudeFileIdentity.Tests.csproj'
$artifacts = Join-Path $taskDir 'artifacts'
dotnet restore $project --configfile $nugetConfig --packages $env:NUGET_PACKAGES --artifacts-path $artifacts --disable-build-servers '-p:Configuration=Release'
if ($LASTEXITCODE -ne 0) { throw 'Synthetic restore failed.' }
dotnet build $project -c Release --no-restore --artifacts-path $artifacts --disable-build-servers
if ($LASTEXITCODE -ne 0) { throw 'Synthetic build failed.' }
$assembly = Join-Path $artifacts 'bin/ClaudeFileIdentity.Tests/release/ClaudeFileIdentity.Tests.dll'
dotnet $assembly
if ($LASTEXITCODE -ne 0) { throw 'Synthetic identity checks failed.' }
```

The test creates a unique directory beneath the isolated process temporary
directory and does not delete it. It does not assign `HOME` or `CODEX_HOME`,
launch agents, open sockets, or alter the persistent `PATH`. A test pass would
not establish application, installer, UI, or real-provider readiness.
