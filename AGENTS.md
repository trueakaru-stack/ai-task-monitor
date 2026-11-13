# Windows .NET test safety

- Never change the persistent user or machine `PATH` while running tests.
- Set `DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0` in every process that launches `dotnet`, including CI jobs and nested child environments rebuilt from an allowlist. A separate `DOTNET_CLI_HOME` alone does not prevent the SDK from changing the user's `PATH`.
- Before reusing scripts from the adjacent `AI Task Monitor Audit` directory, inspect their complete process environment. Many historical copies do not include this protection, and inheriting the flag from a parent is insufficient when a script clears the child environment.
- Run `windows/tests/Test-DotnetPathSafety.py` when changing test launchers. Its static checks cover known patterns; they do not prove that every possible launcher is safe.
