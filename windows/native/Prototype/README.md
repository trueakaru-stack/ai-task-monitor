# Windows C# prototype

This WPF prototype is not a replacement for the released application. The
normal entry point attempts to detect the previously configured standalone
Windows Claude hook and read its local event journal. Preview and screenshot
scenarios use synthetic data and do not start this detection. In the normal
standalone launch the existing settings screen can read the old theme and
language choices and save explicit display changes to a separate file. Source
actions, About, diagnostics and installed-app updates remain disabled or absent.

The detection reads the existing global Claude settings and the standalone
monitor journal without changing them. It recognizes only the expected hook at
`%LOCALAPPDATA%\AITaskMonitor\ClaudeTaskHook.ps1`; Store hooks, other profile
paths, local project settings and managed policy are not covered. Registration
does not prove effective policy, event delivery or live activity, so every
Claude card is presented as unconfirmed. The settings screen shows an
unconfirmed registration status for an observed or absent global hook and
"No data" for a read error or invalid settings. It does not infer that other
scopes are disconnected. An empty source reports that task status is
unconfirmed rather than claiming that all tasks are absent. A task whose only
known activity predates this monitor launch is not displayed until an eligible
later active event arrives; earlier records may then contribute context. Other
integrations remain synthetic or disabled. The user must already have
authorized and configured the old hook; this prototype neither installs nor
runs it.

There is no local Codex source owner in this preview. A future application
must track the actual connection and confidence of every source when choosing
the empty-state message; the preview's scene-based fallback is not a usable
connected-source status and is not final application behavior.
`CloudSourcePump` is created with no runner
and remains disabled in the normal entry point. The cloud-to-WPF test injects
only its own synthetic executable on a disposable hosted runner; it does not
discover or run a real Codex executable, authenticate an account or contact a
cloud service. Cloud and local Codex cards share the provider tab but are kept
as distinct sources, and every cloud card is marked unconfirmed. An empty cloud
response does not prove that other cloud surfaces have no tasks.

The cloud owner serializes presentation on the window dispatcher, rejects late
results from an old connection generation, bounds a scan to five pages and
coalesces refreshes while one scan is running. Its process-wide lease prevents
another scan while that worker is active and remains blocked for the process
lifetime after a reported unconfirmed exit or unexpected worker exception.
This is conservative and can make cloud monitoring unavailable until restart.
After cancellation, the lease and token source also remain alive until all
cancellation callbacks have finished; this can delay a new scan indefinitely
without blocking the WPF dispatcher if a callback never returns.
The deadline cannot interrupt a blocked synchronous process launch or guarantee
the exit of every descendant; a busy WPF dispatcher can delay timeout handling.
Before any real integration, the future owner must establish the executable's
trust and lifecycle, handle those limitations and verify actual CLI behavior.
The current window close only requests asynchronous cancellation and does not
keep the application process alive until a running child exits. A shutdown
protocol and isolated process-exit test are required before a real runner is
enabled.

The synthetic host test exercises two-page and incomplete responses, failure,
disconnect, late results, timeout, two owners, cancellation and the shared
process lease, including a delayed cancellation callback. It also checks
the scheduling-failure cleanup with a controlled second owner, coexistence
with the Claude source, compact count
grammar, the executable owning its window and sampled process/module absence of
PowerShell. These are test scenarios rather than continuous observation. The
captured screenshots are synthetic WPF evidence, not final visual acceptance.
An immediately reentrant refresh from the busy-lease presentation callback is
ignored to avoid recursive failures; a later explicit refresh or poll retries.
The injected scheduler is a test seam: it must return the scheduled task, or
throw before dispatching any work. A scheduler that starts work and then throws
can violate the lease. The normal path uses `Task.Run`; exceptional scheduling
behavior outside that documented test contract has not been reproduced.

The fixed provider scenarios pass compiled-in sanitized events through the
referenced .NET 10 provider parser, state store and presentation adapter. They
do not accept event JSON or input paths and do not start agents, channels or
observers. The state store is used only on the WPF thread; it is not a
permission boundary, and these tests do not prove real channel security.

The `claude-synthetic` scene runs a built-in event sequence through the Claude
reader and WPF presentation. It labels progress as based on observed steps and
shows an unconfirmed plan without a progress bar or colored step marks. This is
a preview; event-order and hook-result validation remain incomplete.

`ClaudeSourcePump` and `ApplyClaudeSource` can pass an explicitly supplied
synthetic file source into a test window without blocking the WPF thread. The
normal entry point creates this pump only after detecting the known standalone
hook. That registration does not establish a real Claude connection. The owner
supplies an initial connection and reports
every later change through the pump on its dispatcher; it must not notify the
source directly or use a stale connection value from a background read. An
inspection error is not proof of disconnection: until a separate inspector
contract exists, the owner must report that uncertainty as `Partial`. Polls
run one at a time on a worker, while connection notifications, generation
checks and presentation are serialized on the dispatcher. Disconnect hides the
Claude cards immediately; partial status retains the last displayed names as
unconfirmed. Disposal prevents later presentation but does not guarantee an
in-flight file read has physically stopped. A poll has a configurable deadline
(10 seconds by default, from 1 millisecond to 2 minutes). On expiry the pump
immediately marks the displayed result unconfirmed, signals source loss without
waiting for the file lock, and discards that poll's late result. It retains the
last source-owned snapshot as a bounded fallback for previously shown names,
including when a late stop was already read. Each pump allows only one poll
worker; repeated refreshes do not start more while it is blocked or while its
result is being presented. Identical connection notifications have no effect.
A refresh invalidates at most one in-flight result between presentations;
further requests coalesce into a follow-up rather than starving every poll.
A presented snapshot can therefore precede the latest refresh request, for
which a follow-up is scheduled; it is not guaranteed current at presentation.
`RequestRefresh` only asks for another read. It must not be used as a signal
that the connection changed or became unavailable: the owner must separately
report a known disconnect or an uncertain inspection through `NotifyConnection`.
Actual connection changes and timeouts always invalidate the previous result.
When a connection becomes partial or disconnected, the pump passes its last
source-owned snapshot as a bounded fallback without waiting for the read lock;
this can preserve names after an undelivered terminal event. The deadline is
dispatched on the WPF thread and can itself be delayed if that thread is
blocked; elapsed time is checked
again before a result is presented. The deadline does not cancel I/O.

The worker limit applies to a single pump instance. `Dispose` prevents later
presentation but cannot stop a permanently blocked read. The new process owner
enforces one owner and pump for the process lifetime, including after disposal;
the pump class itself does not. Its settings inspection also permits only one
worker at a time and discards results after a timeout. A known removed global
hook or an explicit disconnect immediately clears its visible cards and schedules
retained history for removal without waiting on I/O; other Claude scopes may still exist. A later reconnect admits only events at or
after the disconnect boundary and keeps their status unconfirmed. Future-dated
or delayed events may still cross that boundary. A blocked I/O operation is not
guaranteed to terminate.

`windows/native/Tests/ClaudePump/ClaudePump.Tests.csproj` tests the pump with a
dispatcher and synthetic files without opening a window. Its controlled races
cover a disconnect before a background read, a connection change after a read,
an undelivered terminal result, connection loss during a locked source read,
unchanged notifications, reentrant and continuous refreshes, snapshot
isolation, partial inspection, stalled reads, late stops, bounded worker count
per instance and disposal.
The disposal test pauses after `Poll` returns and before the dispatcher applies
its result; it does not block or test cancellation inside real file I/O. Run
only on disposable hosted Windows with an isolated .NET 10 SDK and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` for every SDK process; the output assembly
is `AITaskMonitor.ClaudePump.Tests.dll`. The file-to-window tests are documented
in the `ClaudeReader` README. Those tests do not establish real Claude session behavior. The separate
registered-hook host test exercises a copied released hook with synthetic input
and an isolated profile; it is not an authenticated Claude test.

The preview can also render a caller-supplied synthetic repeated-error warning
and pass its dismissal back to that caller. It does not start the loop detector
or hook, and the application entry point does not supply these warnings. A
synthetic WPF test in `windows/native/Tests/LoopWarningUi/` covers both layouts,
languages and themes, focus retention and scrolling. Run it only on a disposable
hosted Windows environment with isolated temporary/profile directories and
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` for every SDK process.

The tests exercise programmatic WPF focus; a real active window, physical
keyboard input, visible focus indication, and high-DPI behavior remain
unverified. This preview does not establish feature parity or release readiness.

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
`empty`, `active`, `claude-synthetic`, `state-kimi`, `state-plan`, `state-wait`, `state-unknown`,
`state-gap`, `state-old-plan`, `state-end`, `state-multi`, `state-hermes`,
`state-hermes-wait` or `state-hermes-unknown`, plus `--compact`,
`--offscreen`, `--snapshot <absolute-path>`, `--ready-file <absolute-path>` and
`--exit-after-snapshot`. File output occurs only when explicitly requested.
Snapshot and ready files are created only if absent; an occupied or unwritable
output path causes exit code 3 without overwriting an existing file.
The C# preview includes only a few sample interactions: changing the sample
provider tab, selecting a sample in compact mode, switching layout, minimizing
and closing the window. It makes no claim of feature parity.

