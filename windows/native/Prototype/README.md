# Windows C# prototype

This is an isolated WPF preview, not a replacement for the released application.
It uses fixed synthetic events or two hard-coded sample tasks, or an empty list. It does not read agent
profiles, monitor activity, connect providers, save preferences, implement
settings, manage diagnostics or update the installed application. The settings
button is intentionally inactive. No installer is modified.

The fixed provider scenarios pass compiled-in sanitized events through the
referenced .NET 10 provider parser, state store and presentation adapter. They
do not accept event JSON or input paths and do not start agents, channels or
observers. The state store is used only on the WPF thread; it is not a
permission boundary, and these tests do not prove real channel security.

`PublishedWindow.xaml` is the WPF markup extracted from
`windows/app/CodexProgress.ps1` at revision `1c44076`, with the later approved
feedback-copy icon alignment applied and the PowerShell
interpolations filled with preview values. The About version expression is
evaluated as `0.2.6 alpha`, matching the published interface; the About view
is not yet connected in this prototype. `Squircle.cs` ports the
published contour formula. The icon is the published `app-icon.ico`.

To build and run the isolated process and snapshot checks in Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\native\Prototype\Test-Prototype.ps1 `
  -SdkRoot '<isolated .NET SDK directory>' `
  -WorkDirectory '<test directory outside the user profile and repository>' `
  -ReferenceDirectory '<published WPF screenshots, if available>' `
  -PublishedSource '<published CodexProgress.ps1, if available>'
```

The test process uses PowerShell as an external test runner. The application
itself is a separate C# executable; the test checks the window owner, samples
its process descendants and checks for the PowerShell engine. The build is
framework-dependent and requires the isolated .NET 10 runtime through
`DOTNET_ROOT`; it is not a self-contained installer or release build.

Each invocation creates its own `prototype-<id>` directory within the supplied
work directory; existing files alongside it are not overwritten. The runner
requires absolute paths and verifies the current `USERPROFILE`, `APPDATA` and
`LOCALAPPDATA` directories, as well as `HOME` when set, before creating output.
It rejects work paths inside those locations or the checkout and rejects
extended/device paths and reparse-point ancestors of protected, checkout and work directories. These
checks rely on the caller's environment, do not identify other users' profiles,
and cannot guarantee detection of alternate path aliases (such as short names
or mapped drives) or concurrent path replacement. Use a trusted local
directory outside all profiles and repositories.

The tests save synthetic frames under that invocation's `runs/<id>` directory.
In addition to the 12 original frames, they check fixed provider
scenarios, WPF-visible status text, stable selection, and compact layouts in
both themes and languages. Passing `-ReferenceDirectory` compares the original
frames and the Kimi and retained-plan scenarios with the published captures.
The optional published source is checked against the exact revision hash and
renders compact references under an isolated root containing no provider files.
The test changes the reference renderer's output to create-new and hides its
tray icon; its WPF geometry is unchanged. Without `-PublishedSource`, compact
provider reference comparison is reported as not run.
The comparison masks the expected task-title, activity and plan-metadata
differences and checks those semantics separately; it does not establish visual
equivalence inside masked regions or in hover, focus and high-DPI states.

Options are `--theme dark|light`, `--language ru|en`, `--scene` followed by
`empty`, `active`, `state-kimi`, `state-plan`, `state-wait`, `state-unknown`,
`state-gap`, `state-old-plan`, `state-end`, `state-multi`, `state-hermes`,
`state-hermes-wait` or `state-hermes-unknown`, plus `--compact`,
`--offscreen`, `--snapshot <absolute-path>`, `--ready-file <absolute-path>` and
`--exit-after-snapshot`. File output occurs only when explicitly requested.
Snapshot and ready files are created only if absent; an occupied or unwritable
output path causes exit code 3 without overwriting an existing file.
The C# preview includes only a few sample interactions: changing the sample
provider tab, selecting a sample in compact mode, switching layout, minimizing
and closing the window. It makes no claim of feature parity.
