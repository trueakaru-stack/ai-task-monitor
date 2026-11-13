# Deliver the Windows C# application

This is a living ExecPlan governed by the local workspace standard `D:\Codex\PLANS.md`. That standard is local to the user's workspace, not part of this repository; the required project context and operating steps are included below for a contributor who cannot access it. Keep progress, decisions, evidence, and remaining work current until the agreed application is delivered. The plan records already approved requirements; it does not authorize changes to user profiles, external accounts, or published releases beyond the user's instructions.

## Purpose / Big Picture

Replace the released Windows PowerShell-hosted monitor with a standalone C# application whose own `AI Task Monitor.exe` owns its window, preserves the accepted interface and monitoring features, and has a usable installer. A tester should be able to install it, connect the supported sources, follow real tasks, change settings, receive accurate uncertainty and update information, and remove it without damaging unrelated settings. An isolated component or a screenshot alone is not that outcome.

## Progress

- [x] (2026-11-13 14:41Z) Integrated the published Windows 0.2.7-alpha source and the PATH-safe test launchers into the primary `windows` branch. The dedicated [CI run](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43445103177) passed the launcher guard and SDK first-use checks.
- [x] (2026-11-13 14:56Z) Connected the native release selector and update coordinator in `windows/native/UpdateIntegration/`. A disposable Windows CI run built the code and passed 42 synthetic assertions; it has no connection to the application UI or a real network transport.
- [x] (2026-11-13 15:05Z) Added continuity and delivery guidance to the project and Codex profile.
- [x] (2026-11-13 16:04Z) Independently reviewed and integrated invocation guards for both the prototype test and its reference-capture helper into `windows`. Their 43 synthetic checks and the primary-branch PATH safety workflow passed in disposable Windows CI.
- [x] (2026-11-13 15:56Z) Independently reviewed and integrated the synthetic Codex index-to-lifecycle slice into `windows`; its isolated Windows CI build passed 667 assertions. The separate lock-probe experiment is also retained on the primary branch and can be run manually in hosted CI.
- [ ] Establish a reliable Codex source path in C#, including bounded journal reading, lifecycle handling, lock observation, source errors, and uncertainty. The integrated slice is synthetic only; real locks and profiles are not approved for unsafe probing.
- [ ] Resolve the provider-channel reconnection race and retain per-source and per-profile uncertainty without affecting healthy sources.
- [ ] Integrate and verify the accepted Claude Code, OpenCode, DeepSeek, Hermes, Kimi, and available official cloud-monitoring behavior. Distinguish local and cloud support and do not invent unsupported statuses.
- [ ] Wire real sources, settings, diagnostics, update checks, compact and expanded windows, and lifecycle management into the C# application.
- [ ] Build, verify, and publish a Windows C# installer only when the agreed functionality and acceptance checks pass. Verify the requested visual material for Windows and macOS separately.
- [ ] Prepare the requested accurate feature description for presenting the completed application to testers, including actual supported sources and limitations.

## Surprises & Discoveries

- The repository's `main` branch contains project documentation. The source branches are `windows` and `macos`; the Windows branch previously lagged the published 0.2.7-alpha tag. The primary Windows branch now includes that published source and the test safety fixes.
- A .NET SDK first use with a fresh `DOTNET_CLI_HOME` could append temporary tool paths to the persistent Windows user PATH. The test launchers now explicitly disable that behavior; historical scripts in `D:\Codex\AI Task Monitor Audit` still require inspection before execution.
- The C# WPF program in `windows/native/Prototype/` is a synthetic preview, not a functional replacement. It has no real profile discovery, provider activation, settings, journal, updater, or installer integration.
- A synthetic provider-channel test reproduced an old reconnection race: a connection opened before a provider transition can be accepted under the new generation. A shared channel or source-wide gap must not invalidate an unrelated provider or a healthy profile.
- The untracked `windows/native/CodexLock/` candidate in the older working copy can block a real Codex writer. Do not use it as a production lock observer without a noninterference design and evidence.
- Current official Codex source uses a writer byte-range lock and permits shared file access; the old candidate's narrower sharing can interfere with the writer. No documented passive Win32 query for that lock was found in the reviewed sources. A held writer lock alone does not prove an active turn; absence or read failure must not be treated as task completion.
- A read-only observation was evaluated with synthetic writer/observer processes and empty/nonempty temporary files in hosted Windows CI. On Windows build 26100 with NTFS, a read against the held lock reported error 33 in the tested combinations. Read behavior at EOF and byte-range locks is not sufficiently specified to infer a free lock from an empty read; any inconclusive result remains unknown, and one filesystem experiment is not a general Windows guarantee.
- The published Claude hook emits `stage_phase` and `stage_version` used by the native reader to confirm observed task steps. The current C# hook contract does not yet preserve those fields, so connecting it directly would lose step confirmation; contract parity and end-to-end verification are in progress.
- The official Codex App Server provides thread metadata and status events, but status belongs to a particular server instance; visibility of sessions owned by another CLI or Desktop process is not established. `notLoaded`, a read error, or EOF must not be interpreted as a completed task. See the [App Server documentation](https://developers.openai.com/codex/app-server/) and [status implementation](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/thread_status.rs).
- Independent review of the initial synthetic Codex source found that session discovery can match an ID that is a suffix of another ID, that dropping completed-session history can revive an old turn after truncation, and that a lock or read interruption cannot by itself justify confirming the old turn again. These cases must be corrected and tested before the slice is integrated.
- A held or unavailable lock ID absent from the index must make the source incomplete; it must not invalidate unrelated confirmed sessions. The existing index/discovery caches can also grow across repeated calls, so per-call input limits alone are not a memory bound. Current official Codex source permits rollout filenames containing both a thread ID and a rollout ID after `thread/revert`; a simple filename suffix is not a sufficient identity contract.
- Current Codex `session_meta.payload.id` identifies the thread, but a reverted thread can have multiple rollouts with that same ID; the official resolver uses live-writer information or SQLite rather than selecting the first match. Confirming session identity alone does not prove which rollout is current.
- The initial synthetic journal reader rejects files larger than 1 MiB. For a first-seen long-running session this cannot produce a task card; a real monitor needs a bounded tail and verified lifecycle recovery, or an explicit source-unavailable indication rather than a fabricated task.
- The released installer writes into `%LOCALAPPDATA%\AITaskMonitor`, creates a Start-menu shortcut, and preserves `%LOCALAPPDATA%\CodexTaskProgress` on uninstall. Its existing uninstall uses PowerShell; a fully native replacement must preserve the data and approved integration behavior without claiming unsupported cleanup.
- Source inspection and the 0.2.7-alpha release notes show that the existing uninstaller removes the installation directory wholesale and that a late file lock or write failure can leave a partially updated installation. The latter is a code-based risk, not a reproduced incident. Preserve unrelated files inside the installation directory and verify interrupted updates and safe recovery in a disposable environment.
- The published Windows source reports version `0.2.7-alpha`, while the C# preview fixes its About text at `0.2.6 alpha`. Application, installer, About, and update selection must use a verified common version source before release.

## Accepted source behavior

- Hermes is connected manually through its own manager after the application and background services are closed. If the monitor starts after Hermes and cannot confirm a task, wait for a Hermes restart rather than displaying a potentially permanent unconfirmed card.
- Kimi is connected manually through its own menu. Its incomplete or out-of-order notifications are shown with an unconfirmed status. Cloud Codex tasks with an ambiguous combined status are also unconfirmed. For OpenCode and DeepSeek, events arriving after reconnection remain unconfirmed until the relevant agent is fully restarted.
- Claude Code hooks are connected only after every installed copy is updated to at least 2.1.101 and programs that edit its shared settings are closed. Local hooks do not imply support for cloud sessions in Claude Desktop; add cloud support only through a reliable official mechanism.
- If Claude plan membership is unconfirmed, keep known names but suppress the progress bar and colored completion marks. If the known steps are confirmed but plan completeness is unknown, show progress over known steps with that limitation. After loss of events retain known names with an unconfirmed-plan indication. Count every visible task card, including unconfirmed cards, in the provider tabs.
- Preserve the existing update policy: a standalone installation checks for updates through the application, while a Store installation relies on Store updates and must not start the external updater.

## Decision Log

- Decision: Use C# for the Windows application and keep the existing approved visual design and functionality.
  Rationale: The user requested a standalone Windows process and explicitly chose C# over restarting the work in C++.
  Date/Author: 2026-11-13, user and Codex.
- Decision: Treat the `windows` branch as the primary integration destination for Windows source and preserve the dirty original checkout.
  Rationale: The repository documents platform-specific source branches; the user requested verified work in the primary branch, not a permanently separate test branch.
  Date/Author: 2026-11-13, user and Codex.
- Decision: Represent unknown, delayed, incomplete, or disconnected-source results according to the user's source-specific decisions and preserve source/profile isolation. In the specified Hermes late-start case, wait for a restart instead of retaining a potentially permanent unconfirmed card.
  Rationale: A false active, completed, or fully confirmed task is worse than admitting missing evidence.
  Date/Author: 2026-11-13, user and Codex.
- Decision: Use disposable hosted CI and explicit `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` for risky .NET checks; do not alter the user's persistent PATH or repurpose HOME/CODEX_HOME.
  Rationale: The previously observed first-use behavior damaged the user's PATH; a passing compile is not a reason to risk a repeat.
  Date/Author: 2026-11-13, user and Codex.

## Outcomes & Retrospective

The Windows source branch and test safety have been repaired. The native update adapter and a synthetic Codex source slice are independently reviewed and covered by CI; neither is wired into the product. Full native monitoring, preservation of the existing UI and features, a C# installer, real integration checks, and final visual acceptance remain open.

## Open Questions and Blockers

- A production Codex lock observer is blocked until a method is shown not to interfere with the writer and ambiguous results are handled as unknown. A disposable synthetic probe passed on one CI environment; it must not be applied to user files merely because that run succeeded.
- Choosing the current rollout after a revert requires reliable writer or state-database evidence. Matching `session_meta.payload.id` alone is insufficient when multiple rollouts belong to one thread. Synthetic source work may continue without connecting real profiles.
- The original clipboard reference files are unavailable at their recorded paths. Existing screenshots are candidate evidence only until matched to the accepted design; final visual acceptance needs the authoritative references and actual Windows/macOS renderers.
- A complete native installer build command and clean-machine acceptance evidence do not exist yet. Installer planning and isolated verification can continue without installing anything on the user's computer.

## Context and Orientation

The original working copy at `D:\Codex\AI Task Monitor` has pre-existing tracked and untracked work. Preserve it. The clean managed worktree for the current Windows source is `C:\Users\truea\.codex\worktrees\windows-main-continuation\AI Task Monitor`, detached at the fetched `windows` revision; it is a workspace, not a replacement for the primary branch. Fetch and verify the remote branch before integrating any source change.

`windows/app/` holds the released PowerShell/WPF application and its agent integrations. `windows/native/Prototype/` contains the C# preview and a reference WPF layout. `windows/native/CodexIndex/`, `CodexDiscovery/`, and `Codex/` are separate C# readers/reducers; none is a complete real Codex source. `windows/native/ClaudeReader/` interprets Claude lifecycle events but is not started against a real profile. `windows/native/Providers/` contains provider-state work. `windows/native/UpdateIntegration/` combines the validated release selector with the retry-aware coordinator using an injected transport.

An agent source is an integration that observes a particular assistant. A scope is a sanitized identifier for one connected profile. An unconfirmed task is a task retained or observed when the source cannot prove its current state. Never expose raw task data, paths, tokens, or profile contents in logs or CI artifacts.

## Plan of Work

Start with a bounded, synthetic Codex source path that links the checked-in index reader, session discovery, journal decoding, and lifecycle reducer. Pass test roots and lock observations explicitly; treat unavailable or unsupported input as uncertainty. Do not open real locks in a way that blocks writers. Only promote this path to real profile discovery after its noninterference, privacy, lifecycle, and error behavior are verified.

In parallel, investigate the shared provider channel's authorization-generation boundary and design scoped loss reporting. Reconnect behavior must not silently confirm a delayed event or degrade another healthy source/profile. Validate both the legacy Framework and native implementations where shared code affects both.

Connect each source and its configuration to the WPF application only after its contract and tests are ready. Preserve the accepted full/compact layouts, themes, languages, task cards, progress uncertainty, update dialog, controls, diagnostics, and profile isolation. Use actual user-visible data only locally and with authorized sources; synthetic fixtures are not proof of real integration.

Finally, integrate versioning, update transport and install/uninstall behavior, then produce the requested installer, visual-control material, and a truthful feature description for testers. Follow the user's existing publication authorization once acceptance is satisfied. Do not call an alpha package a release-ready C# application solely because it builds.

## Milestones

1. A synthetic Codex file and index travel through the native source pipeline to accurate active, complete, and uncertain results. Tests cover unrelated sessions, error recovery, bounded input, and partial writes.
2. Reconnecting one provider or profile cannot confirm a stale event or invalidate an unrelated healthy source; synthetic concurrency tests and independent review demonstrate the boundary.
3. Each accepted source is integrated into the real C# host with safe configuration and lifecycle behavior. Real tests are performed only with the necessary authorized environment and are reported separately from synthetic tests.
4. The native UI and settings preserve the approved interface. Compare actual rendered output with verified references at matching size and scale, covering relevant themes, languages, compact/expanded views and states. Prepare the requested visual-control video for both platforms when the final renderers and references are available.
5. A clean installation, launch, update notification, upgrade, uninstall, preservation of unrelated settings and files, and recovery after a partially failed upgrade are verified. Publish the Windows installer and required source once all applicable checks pass; disclose signing/notarization status from actual evidence.

## Concrete Steps

Work from the managed worktree named above. Confirm the base using `git status --short --branch` and `git rev-parse HEAD`; inspect original dirty changes before copying any of them. Run the read-only launcher guard with the local isolated Python runtime:

```powershell
& 'D:\Codex\AI Task Monitor Audit\python-3.14.10-fixture\runtime\python.exe' -B windows/tests/Test-DotnetPathSafety.py
```

Expected: six checks report `OK`; this is static coverage of known launcher patterns, not proof of arbitrary code safety. Where the local runtime path does not exist, use Python 3.9 or later as `python -B windows/tests/Test-DotnetPathSafety.py`. For C# builds and behavior tests use a disposable hosted Windows runner with the opt-out set on every .NET process, an empty NuGet configuration, synthetic roots, and before/after persistent PATH comparisons. The workflow `.github/workflows/windows-dotnet-path-safety.yml` demonstrates this for the update adapter. Never run an old audit script merely because its parent environment has the opt-out: the script may rebuild its child environment.

Inside that disposable CI job, with `$taskConfig` naming its empty NuGet configuration and `$taskArtifacts` its new isolated artifacts directory, the currently verified update component is built and exercised with:

```powershell
dotnet build windows/native/UpdateIntegration/Tests/UpdateIntegration.Tests.csproj -c Release --configfile "$taskConfig" --artifacts-path "$taskArtifacts" -p:NuGetAudit=false --nologo
dotnet "$taskArtifacts/bin/UpdateIntegration.Tests/release/AITaskMonitor.UpdateIntegration.Tests.dll"
```

Expected: a successful build and `Update integration: 42 synthetic assertions passed.` The same protected CI environment will build `windows/native/CodexSource/Tests/CodexSource.Tests.csproj` and run `$taskArtifacts/bin/CodexSource.Tests/release/AITaskMonitor.CodexSource.Tests.dll` with an existing absolute synthetic work directory as its sole argument. Record the actual assertion count and CI run after that test exists. No build command for a complete C# installer exists yet; define and test that command when its implementation is ready instead of reusing the legacy PowerShell installer builder.

Before publication, verify the exact primary branch commit and applicable CI results. Use a review/staging branch only as an intermediate verification mechanism, then integrate the verified authorized changes into `windows` without moving or discarding the older local work.

## Validation and Acceptance

Required technical evidence includes successful bounded parsing and lifecycle tests, explicit failure/uncertainty checks, profile-isolation and reconnect-race regressions, installation/upgrade/removal tests in an isolated environment, and an application process check showing the intended executable owns the window. Test both successful and failed SDK first use without persistent PATH changes.

Required behavior evidence includes real supported agent tasks, settings persistence, diagnostics, update notifications, offline/error handling, and a reliable distinction between local, cloud, confirmed, and unconfirmed states. Record what was actually exercised; unsupported cloud sources remain unverified unless an official reliable method exists.

Visual acceptance is separate: compare the final native renderer with the authoritative approved Windows reference at matching viewport and scale, including light/dark and expanded/compact states, typography, controls, corners, shadows, alignment and overflow. Review the reported Windows copy-icon alignment and check the Mac copy icon; match Windows tabs to the accepted Mac treatment; verify the task-card right margin without a scrollbar, full and compact corner contours, and the update-download button shadow. On Mac, give selectors equal width based on the widest selector and retain the existing log-button sizes. Localize application-generated labels and agreed sample text, while retaining source-supplied task text in its original language.

The user-supplied screenshots in the conversation and the approved published application are the references. The original clipboard image files are currently unavailable at their recorded temporary paths. Older macOS 0.3.1 captures exist under `D:\Codex\AI Task Monitor Previews\macos-0.3.1-reference-45f9db74a99247aaae172a11568c0993\files\docs\verification`; additional 2026-11-04 captures are under `D:\Codex\AI Task Monitor Audit\2026-11-04-macos-ci-ed1e9cb\files\docs\verification`. The eight similarly named captures in each location have different Git blob hashes from the corresponding images on the current `macos` branch. That establishes a byte difference, not a visual difference or acceptance. Their applicability to later accepted corrections is not yet established. Recover equivalent authoritative source images and obtain renderer access before claiming the affected comparison. Record any untested hover, keyboard, accessibility, high-DPI, or responsive state. The user's requested Windows and Mac visual-control video is a separate deliverable after suitable renderers and references are available.

## Idempotence and Recovery

Use unique disposable fixture directories; inspect their resolved paths before any recursive cleanup. Do not overwrite user data, restore a whole registry value, alter actual agent settings during synthetic tests, or print secrets. Preserve the original dirty checkout and its untracked files. Review source and CI diffs before remote integration; if the remote branch moved, inspect the new head instead of forcing it. Temporary CI branches and synthetic results are not releases.

## Artifacts and Notes

- Windows PATH and update-adapter synthetic checks: [GitHub Actions run 43447567773](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43447567773).
- Prototype and reference-capture invocation protection and synthetic Codex source checks on the primary branch: [GitHub Actions run 43458792217](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43458792217). A separate [synthetic lock experiment](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43455454275) was performed on one Windows/NTFS environment. These are not evidence of real agent monitoring or visual acceptance.
- A saved synthetic reproduction of the provider generation race is under `D:\Codex\AI Task Monitor Audit\windows-provider-channel-generation-fix-20261109\baseline-output.txt`; it is not evidence of a real user incident.
- Previous published Windows and macOS artifacts are 0.2.7-alpha and 0.3.8-alpha, respectively. Their availability does not prove that the requested native Windows migration is complete.

## Interfaces and Dependencies

The implementation uses C#/.NET 10 and WPF for Windows. The native Codex source must consume the existing `CodexIndexReader`, `SessionDiscovery`, and `CodexLifecycleReducer` contracts or explicitly document a verified replacement. Lock inspection must be nonblocking for the real writer. Provider events retain sanitized identifiers and explicit uncertainty. The update path uses `ReleaseSelector`, `UpdateCoordinator`, and `UpdateRetry` with an injected transport; existing code is not yet wired into the application. No new package or external service is approved merely by this plan.

## Revision Note

- 2026-11-13: Created the plan from the user's accepted C# migration, test-safety decisions, published source state, and verified synthetic evidence.
- 2026-11-13: Added findings about installer data preservation, interrupted updates, and the version mismatch; these affect installer and update acceptance.
- 2026-11-13: Recorded the user's individual Hermes, Kimi, Codex, OpenCode, DeepSeek, and Claude uncertainty decisions and the accepted visual corrections; identified unavailable reference files as a visual-verification limitation. Required preservation of unrelated installation-directory files and safe recovery from a partially failed upgrade.
- 2026-11-13: Recorded the Store update policy and reproducible isolated commands for the existing update tests and the in-progress Codex source test.
- 2026-11-13: Added independently identified Codex source identity and stale-lifecycle failures as blockers for integration.
- 2026-11-13: Added missing-index lock IDs, cross-refresh cache bounds, and the current Codex rollout-filename variant to the source acceptance criteria.
- 2026-11-13: Recorded the verified Codex writer-lock and session metadata contracts and the unresolved noninterfering lock observation and rollout selection requirements.
- 2026-11-13: Recorded that first-seen long Codex journals need bounded recovery or an explicit unavailable-source state before real monitoring.
- 2026-11-13: Located older macOS reference captures; they remain candidates rather than proof of the later approved appearance.
- 2026-11-13: Started an isolated lock-probe experiment; it is not a production lock observer or evidence about the user's real files.
- 2026-11-13: Recorded the App Server instance-scope limitation and the distinction between `notLoaded` and task completion.
- 2026-11-13: Added the previously requested tester-facing feature description to the final handoff.
- 2026-11-13: Recorded disposable CI evidence for the invocation guard and lock experiment, and the missing Claude step-event contract in the native hook.
- 2026-11-13: Recorded primary-branch integration and independent review of the test guard, synthetic Codex source, and lock experiment, including their remaining limitations.
- 2026-11-13: Extended invocation protection to the reference capture and recorded candidate visual-reference evidence without claiming visual acceptance.
