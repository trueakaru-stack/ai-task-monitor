# Release screenshots

- For each release that adds functionality or changes the interface, update the relevant, verified screenshots of the affected platform and README links in `main` as part of the same release. Keep screenshots for the other platform current, identify example data, and do not present previews as verified native windows. Verify the published images and links; if a necessary capture or check is unavailable, report the specific limitation.

# Windows host execution safety

- These rules apply to every command run on the user's Windows computer, including work on the macOS branch and commands delegated to other agents. The coordinator must pass them explicitly to each agent that can run Windows commands.
- Never invoke `python`, `python3`, `py`, `pip` or related Windows execution aliases by bare name. They can launch Python Install Manager and install or update software. Prefer `apply_patch` or PowerShell/.NET APIs; if Python is needed, first verify the full path to an existing interpreter and confirm it is not an execution alias or installer.
- Never change persistent user or machine `PATH` for tests. Set `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` in every process that launches `dotnet`, including nested child environments. After test runs, check that persistent user and machine `PATH` are unchanged. Hosted runners may use their own verified toolchains.
