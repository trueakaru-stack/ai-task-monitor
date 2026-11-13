# Claude hook translation slice

This is an isolated .NET 10 library. It does not install or run a hook, open
files, start a process, read settings or connect to the application. Its phase
classifier uses the same checked-in `windows/app/ClaudeStageObservation.cs`
source as the current PowerShell hook, with a bounded .NET JSON adapter. The
adapter deliberately treats any `/Date(...)/`-shaped string conservatively
because the Framework JSON parser converts some such strings to dates; unusual
valid text of that shape may therefore remain unconfirmed.

The output retains the ten existing event properties and, only when applicable,
`stage_phase`, `stage_version`, `stage_previous_status`,
`stage_requested_status` and `stage_task_id`. `active` may be null when activity
or a stop is unconfirmed. Blockable `TaskCreated` and `TaskCompleted` notices
do not prove a successful step; create and update phases require the validated
evidence used by the shared classifier. An observed step does not establish
that Claude has sent the entire plan. The monitor must continue to label any
progress as based on known steps and hide confirmed markers when the plan is
unconfirmed.

The bounded `ClaudeHookInputReader` accepts strict UTF-8, strips one initial
BOM and rejects malformed or oversized input. `TryTranslate` returns false for
unsupported or invalid input; false does not mean no event occurred. A future
hook process must preserve this uncertainty by attempting to publish
`SourceUncertain` on input, decoding or translation loss, and handle I/O failures
without blocking the agent. The marker itself can fail to be written. Input is
never logged by this library, but allowed fields such as a task subject can
still contain sensitive text. No secure memory erasure is claimed.

This phase-aware format must not be fed to an older reader that interprets
phase events as confirmed steps. Migration needs a separate journal and an
explicit compatibility and recovery policy. The unconnected native writer uses
`claude-events-v2.jsonl`, the current PowerShell hook's journal filename; it
must not be installed or pointed at user data merely because these tests pass.

For synthetic verification on a disposable GitHub-hosted Windows runner, call
`Test-ClaudeHook.ps1 -NativeOnly` with a .NET 10 SDK and a work directory outside
the repository and all user profiles. This mode does not copy or launch the
PowerShell hook. It tests bounded input, translation and the native reader.
Without `-NativeOnly`, the runner additionally copies and hash-checks the
PowerShell hook, compiles its phase helper and compares synthetic records.
Neither mode launches Claude. Child processes receive a cleared environment:
synthetic `USERPROFILE`, `DOTNET_CLI_HOME`, app-data and temporary paths,
`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0`, and no `HOME` or `CODEX_HOME` variables.
The CI environment checks and path checks are not a security boundary against
forged environment variables, path replacement, or hostile runners.

The native-only checks passed in [Windows CI run 43460428875](https://github.com/trueakaru-stack/ai-task-monitor/actions/runs/43460428875): 102 input-reader assertions and 66 translation/reader assertions. The PowerShell comparison was not run.
Real hook installation, live Claude behavior, concurrent
settings changes, production integration and installer remain unverified in
this change. No `.NET` or GUI was run locally for this work.
