# Windows host execution safety

- These rules apply to every command run on the user's Windows computer, including work on the macOS branch and commands delegated to other agents. The coordinator must pass them explicitly to each agent that can run Windows commands.
- Never invoke `python`, `python3`, `py`, `pip` or related Windows execution aliases by bare name. They can launch Python Install Manager and install or update software. Prefer `apply_patch` or PowerShell/.NET APIs; if Python is needed, first verify the full path to an existing interpreter and confirm it is not an execution alias or installer. An isolated hosted runner may use its verified Python toolchain.
- Never change the persistent user or machine `PATH` while running tests.
- Set `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` in every process that launches `dotnet`, including CI jobs and nested child environments rebuilt from an allowlist. A separate `DOTNET_CLI_HOME` alone does not prevent the SDK from changing the user's `PATH`.
- After test runs, check that persistent user and machine `PATH` are unchanged.
- Before reusing scripts from the adjacent `AI Task Monitor Audit` directory, inspect their complete process environment. Many historical copies do not include this protection, and inheriting the flag from a parent is insufficient when a script clears the child environment.
- Run `windows/tests/Test-DotnetPathSafety.py` when changing test launchers. Its static checks cover known patterns; they do not prove that every possible launcher is safe.

# Continuity and delivery for this project

- The agreed Windows objective is a standalone C# application and installer that preserve the approved interface and monitoring functionality. Component tests do not by themselves establish application or installer readiness.
- A question, diagnosis, or partial fix does not replace the agreed objective. Resume the remaining work unless the user stops it or a user-specified resource limit is reached.
- Windows source is maintained in `windows`, macOS source in `macos`; `main` holds project documentation. Use a temporary branch when needed for verification, then integrate verified and authorized source changes into the relevant platform branch while preserving unrelated local work.
- Report source integration, application behavior, installer readiness, and visual verification separately. Do not present an unconnected migration component as a completed application.

# Release screenshots

- For each release that adds functionality or changes the interface, update the relevant, verified screenshots of the affected platform and README links in `main` as part of the same release. Keep screenshots for the other platform current, identify example data, and do not present previews as verified native windows. Verify the published images and links; if a necessary capture or check is unavailable, report the specific limitation.
