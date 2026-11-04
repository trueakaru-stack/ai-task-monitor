param([switch]$RequireSymbolicLink,[string]$ApplicationDirectory='')
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-integration-" + [Guid]::NewGuid().ToString("N"))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture path." }
[void][IO.Directory]::CreateDirectory($root)
$previousProfile = $env:USERPROFILE
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $env:USERPROFILE = $root
    $env:LOCALAPPDATA = $root
    $sourceRoot = if ($ApplicationDirectory) { [IO.Path]::GetFullPath($ApplicationDirectory) } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\app")) }
    $setup = Join-Path $sourceRoot "Configure-ClaudeIntegration.ps1"
    $hook = Join-Path $sourceRoot "ClaudeTaskHook.ps1"
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot "CodexProgress.ps1"), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "The application source failed to parse." }
    $definitions = foreach ($name in @('Claude-ConnectionState', 'Claude-HookConnected')) {
        $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
        if ($null -eq $definition) { throw "The integration connection check is missing: $name." }
        $definition.Extent.Text
    }
    $rootLiteral = "'" + $sourceRoot.Replace("'", "''") + "'"
    $connectionDefinition = ($definitions -join "`n").Replace('$PSScriptRoot', $rootLiteral)
    $assertConnected = [scriptblock]::Create($connectionDefinition + "`n" + 'if (-not (Claude-HookConnected)) { throw "The installed hook was not recognized." }')
    $assertDisconnected = [scriptblock]::Create($connectionDefinition + "`n" + 'if (Claude-HookConnected) { throw "An unrelated hook was recognized as the app hook." }')
    $legacy = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $hook + '"'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& '" + $hook.Replace("'", "''") + "'"))
    $owned = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $directory = Join-Path $root ".claude"
    [void][IO.Directory]::CreateDirectory($directory)
    $settingsPath = Join-Path $directory "settings.json"

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode Remove
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $settingsPath)) { throw "Removing an absent hook must not create settings." }

    $deep = [ordered]@{ value = "preserve" }
    for ($i = 0; $i -lt 25; $i++) { $deep = [ordered]@{ nested = $deep } }
    $fixture = [ordered]@{
        hooks = [ordered]@{
            PreToolUse = @(
                [ordered]@{ matcher = "Read"; hooks = @(
                    [ordered]@{ type = "command"; command = "echo synthetic" },
                    [ordered]@{ type = "prompt"; prompt = "synthetic" },
                    [ordered]@{ type = "command"; command = $owned + " --other-hook" },
                    [ordered]@{ type = "command"; command = $owned; shell = "powershell" }
                ) },
                [ordered]@{ matcher = "Other"; hooks = @() }
            )
        }
        unrelated = "keep"
        nestedConfiguration = $deep
    }
    $original = $fixture | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($settingsPath, $original, [Text.UTF8Encoding]::new($false))
    $originalHash = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode Remove
    if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -ne $originalHash) { throw "Removing an absent hook must not rewrite unrelated settings." }
    & $assertDisconnected

    $withLegacy = $original | ConvertFrom-Json
    $withLegacy.hooks.PreToolUse[0].hooks = @($withLegacy.hooks.PreToolUse[0].hooks) + [PSCustomObject]@{type="command";command=$legacy}
    [IO.File]::WriteAllText($settingsPath, ($withLegacy | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    & $assertConnected
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode Install
    if ($LASTEXITCODE -ne 0) { throw "Installing the hook failed." }
    $connected = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
    $groups = @($connected.hooks.PreToolUse)
    if ($groups.Count -ne 3 -or @($groups[0].hooks).Count -ne 4 -or @($groups[1].hooks).Count -ne 0) { throw "Existing hook groups were changed." }
    if ($groups[2].hooks[0].command -ne $owned) { throw "The app hook was not installed exactly." }
    & $assertConnected
    if (@(Get-ChildItem -LiteralPath $directory -Filter 'settings.json.codex-tasks-backup-*').Count -ne 1) { throw "A settings backup was not retained." }
    if (@(Get-ChildItem -LiteralPath $directory -Filter '.ai-task-monitor-settings-*.tmp' -Force).Count -ne 0) { throw "A temporary settings file was left behind." }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode Remove
    if ($LASTEXITCODE -ne 0) { throw "Removing the app hook failed." }
    $after = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
    $expectedNormalized = ($original | ConvertFrom-Json | ConvertTo-Json -Depth 100)
    $afterNormalized = $after | ConvertTo-Json -Depth 100
    if ($afterNormalized -cne $expectedNormalized) { throw "Unrelated settings or hook entries changed after removal." }
    & $assertDisconnected

    $specialDirectory = Join-Path $root "path with ' and `$(literal)"
    [void][IO.Directory]::CreateDirectory($specialDirectory)
    Copy-Item -LiteralPath $setup -Destination (Join-Path $specialDirectory "Configure-ClaudeIntegration.ps1")
    Copy-Item -LiteralPath $hook -Destination (Join-Path $specialDirectory "ClaudeTaskHook.ps1")
    [IO.File]::WriteAllText($settingsPath, '{}', [Text.UTF8Encoding]::new($false))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $specialDirectory "Configure-ClaudeIntegration.ps1") -Mode Install
    if ($LASTEXITCODE -ne 0) { throw "Installing a hook from a special-character path failed." }
    $special = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
    $registered = [string]$special.hooks.UserPromptSubmit[0].hooks[0].command
    $prefixCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '
    if (-not $registered.StartsWith($prefixCommand) -or $registered.Contains('$') -or $registered.Contains("'")) { throw "The hook command exposes shell-sensitive path characters." }
    $encodedSpecial = $registered.Substring($prefixCommand.Length)
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedSpecial))
    $expectedScript = "& '" + (Join-Path $specialDirectory "ClaudeTaskHook.ps1").Replace("'", "''") + "'"
    if ($decoded -cne $expectedScript) { throw "The encoded hook did not preserve the exact script path." }
    '{"hook_event_name":"UserPromptSubmit","session_id":"synthetic-special"}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedSpecial
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $root 'CodexTaskProgress\claude-events-v2.jsonl'))) { throw "The encoded hook did not receive input and write its synthetic event." }

    $invalid = '[1, 2, 3]'
    [IO.File]::WriteAllText($settingsPath, $invalid, [Text.UTF8Encoding]::new($false))
    $assertUnknown = [scriptblock]::Create($connectionDefinition + "`n" + '$failed = $false; try { [void](Claude-ConnectionState) } catch { $failed = $true }; if (-not $failed) { throw "Malformed settings must report an unavailable source." }')
    & $assertUnknown
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode Install 2>$null
    } finally { $ErrorActionPreference = $previousErrorPreference }
    if ($LASTEXITCODE -eq 0 -or [IO.File]::ReadAllText($settingsPath) -ne $invalid) { throw "Unsupported settings must be left untouched." }

    $invalidHooks = @(
        '{"hooks":{"PreToolUse":"unexpected"}}',
        '{"hooks":{"PreToolUse":[{"hooks":"unexpected"}]}}',
        '{"hooks":{"PreToolUse":[{"hooks":["unexpected"]}]}}'
    )
    $backupsBefore = @(Get-ChildItem -LiteralPath $directory -Filter 'settings.json.codex-tasks-backup-*').Count
    foreach ($invalid in $invalidHooks) {
        [IO.File]::WriteAllText($settingsPath, $invalid, [Text.UTF8Encoding]::new($false))
        & $assertUnknown
        foreach ($mode in @('Install', 'Remove')) {
            $previousErrorPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode $mode 2>$null
            } finally { $ErrorActionPreference = $previousErrorPreference }
            if ($LASTEXITCODE -eq 0 -or [IO.File]::ReadAllText($settingsPath) -cne $invalid) { throw "Unsupported hook structures must not be rewritten in mode $mode." }
        }
    }
    if (@(Get-ChildItem -LiteralPath $directory -Filter 'settings.json.codex-tasks-backup-*').Count -ne $backupsBefore) { throw "Invalid settings should not create a backup." }

    $linkProfile = Join-Path $root 'symlink-profile'
    $linkDirectory = Join-Path $linkProfile '.claude'
    [void][IO.Directory]::CreateDirectory($linkDirectory)
    $linkTarget = Join-Path $root 'linked-settings.json'
    $linkPath = Join-Path $linkDirectory 'settings.json'
    $linkOriginal = '{"unrelated":"keep"}'
    [IO.File]::WriteAllText($linkTarget, $linkOriginal, [Text.UTF8Encoding]::new($false))
    $linkSupported = $false
    try {
        [void](New-Item -ItemType SymbolicLink -Path $linkPath -Target $linkTarget -ErrorAction Stop)
        $linkSupported = $true
    } catch {
        $linkError = $_.Exception.Message
        if ($RequireSymbolicLink) { throw "The symbolic-link fixture could not be created: $linkError" }
        Write-Output "Claude integration symbolic-link fixture skipped: $linkError"
    }
    if ($linkSupported) {
        $env:USERPROFILE = $linkProfile
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode Install
            if ($LASTEXITCODE -ne 0) { throw 'Installing with linked settings failed.' }
            if (([IO.File]::GetAttributes($linkPath) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'Installing the hook replaced the existing settings symbolic link.' }
            $linked = [IO.File]::ReadAllText($linkTarget) | ConvertFrom-Json
            if ($linked.unrelated -ne 'keep' -or $null -eq $linked.hooks) { throw 'Installing the hook did not update the linked settings target safely.' }
            $linkBackups = @(Get-ChildItem -LiteralPath $linkDirectory -Filter 'settings.json.codex-tasks-backup-*')
            if ($linkBackups.Count -ne 1 -or [IO.File]::ReadAllText($linkBackups[0].FullName) -cne $linkOriginal) { throw 'A backup of the original linked settings was not retained.' }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode Remove
            if ($LASTEXITCODE -ne 0 -or ([IO.File]::GetAttributes($linkPath) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'Removing the hook did not preserve the settings symbolic link.' }
            $unlinked = [IO.File]::ReadAllText($linkTarget) | ConvertFrom-Json
            if ($unlinked.unrelated -ne 'keep' -or @($unlinked.hooks.PSObject.Properties).Count -ne 0) { throw 'Removing the hook changed unrelated linked settings.' }
        } finally { $env:USERPROFILE = $root }
        foreach ($case in @('relative', 'chain')) {
            $caseProfile = Join-Path $root ('symlink-' + $case)
            $caseDirectory = Join-Path $caseProfile '.claude'
            [void][IO.Directory]::CreateDirectory($caseDirectory)
            $caseTarget = Join-Path $root ('linked-' + $case + '.json')
            [IO.File]::WriteAllText($caseTarget, $linkOriginal, [Text.UTF8Encoding]::new($false))
            $casePath = Join-Path $caseDirectory 'settings.json'
            $targetSpec = '..\..\linked-' + $case + '.json'
            $intermediate = $null
            if ($case -eq 'chain') {
                $intermediate = Join-Path $caseDirectory 'settings-target.json'
                [void](New-Item -ItemType SymbolicLink -Path $intermediate -Target $targetSpec -ErrorAction Stop)
                $targetSpec = 'settings-target.json'
            }
            [void](New-Item -ItemType SymbolicLink -Path $casePath -Target $targetSpec -ErrorAction Stop)
            $env:USERPROFILE = $caseProfile
            try {
                foreach ($mode in @('Install', 'Remove')) {
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode $mode
                    if ($LASTEXITCODE -ne 0) { throw "The $case symbolic link failed in mode $mode." }
                    if (([IO.File]::GetAttributes($casePath) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw "The $case settings link was replaced in mode $mode." }
                    if ($intermediate -and ([IO.File]::GetAttributes($intermediate) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw "The intermediate settings link was replaced in mode $mode." }
                    $caseSettings = [IO.File]::ReadAllText($caseTarget) | ConvertFrom-Json
                    if ($caseSettings.unrelated -ne 'keep') { throw "Unrelated $case settings changed in mode $mode." }
                    if ($mode -eq 'Install' -and $null -eq $caseSettings.hooks) { throw "The $case link target was not updated." }
                    if ($mode -eq 'Remove' -and @($caseSettings.hooks.PSObject.Properties).Count -ne 0) { throw "The $case hook was not removed." }
                }
                $caseBackups = @(Get-ChildItem -LiteralPath $caseDirectory -Filter 'settings.json.codex-tasks-backup-*')
                if ($caseBackups.Count -ne 1 -or [IO.File]::ReadAllText($caseBackups[0].FullName) -cne $linkOriginal) { throw "The $case settings backup was not retained." }
            } finally { $env:USERPROFILE = $root }
        }
        foreach ($case in @('dangling', 'cycle')) {
            $caseProfile = Join-Path $root ('symlink-' + $case)
            $caseDirectory = Join-Path $caseProfile '.claude'
            [void][IO.Directory]::CreateDirectory($caseDirectory)
            $casePath = Join-Path $caseDirectory 'settings.json'
            $second = Join-Path $caseDirectory 'second.json'
            if ($case -eq 'cycle') { [void](New-Item -ItemType SymbolicLink -Path $second -Target 'settings.json' -ErrorAction Stop) }
            $targetSpec = if ($case -eq 'cycle') { 'second.json' } else { 'missing.json' }
            [void](New-Item -ItemType SymbolicLink -Path $casePath -Target $targetSpec -ErrorAction Stop)
            $env:USERPROFILE = $caseProfile
            try {
                $previousErrorPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Mode Install 2>$null
                } finally { $ErrorActionPreference = $previousErrorPreference }
                if ($LASTEXITCODE -eq 0) { throw "The $case symbolic link must not be updated." }
                if (([IO.File]::GetAttributes($casePath) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw "The $case symbolic link was replaced." }
                if (@(Get-ChildItem -LiteralPath $caseDirectory -Filter '.ai-task-monitor-settings-*.tmp' -Force).Count -ne 0) { throw "A temporary file remained after the $case link failed." }
            } finally { $env:USERPROFILE = $root }
        }
        Write-Output 'Claude integration: absolute, relative and chained settings symbolic links and backups verified.'
        Write-Output 'Claude integration: dangling and cyclic symbolic links are left unchanged.'
    }
    Write-Output "Claude integration: exact hook ownership, unrelated settings, unsupported structures, backups and safe replacement verified."
} finally {
    $env:USERPROFILE = $previousProfile
    $env:LOCALAPPDATA = $previousLocalAppData
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
