$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'The application source failed to parse.' }
$definitions = foreach ($name in @('Prop', 'Resolve-Language', 'Save-DisplayPreference', 'Load-ThemeMode', 'Save-ThemeMode', 'Load-LanguageMode', 'Save-LanguageMode', 'Load-ClaudeRetentionSettings', 'Save-ClaudeRetentionPreference')) {
    $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true)
    if ($null -eq $node) { throw "Missing function: $name" }
    $node.Extent.Text
}
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-language-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory($root)
$checks = @'
$script:settingsPath=Join-Path $args[0] 'settings.json'
if ((Resolve-Language 'system' 'ru-RU') -ne 'ru' -or (Resolve-Language 'system' 'en-US') -ne 'en' -or (Resolve-Language 'system' 'fr-FR') -ne 'en') { throw 'System language fallback is incorrect.' }
if ((Resolve-Language 'en' 'ru-RU') -ne 'en' -or (Resolve-Language 'ru' 'en-US') -ne 'ru' -or (Resolve-Language 'invalid' 'ru-RU') -ne 'ru') { throw 'Language override is incorrect.' }
[IO.File]::WriteAllText($script:settingsPath,'{"theme":"dark","other":"preserve"}',[Text.UTF8Encoding]::new($false))
if (-not (Save-LanguageMode 'en')) { throw 'Saving language failed.' }
$saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
if ($saved.theme -ne 'dark' -or $saved.language -ne 'en' -or $saved.other -ne 'preserve') { throw 'Saving language must preserve theme and unrelated settings.' }
if (-not (Save-ThemeMode 'light')) { throw 'Saving theme failed.' }
$saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
if ($saved.theme -ne 'light' -or $saved.language -ne 'en' -or $saved.other -ne 'preserve') { throw 'Saving theme must preserve language and unrelated settings.' }
if ((Load-ThemeMode) -ne 'light' -or (Load-LanguageMode) -ne 'en') { throw 'The chosen preferences did not reload.' }
if (-not (Save-ClaudeRetentionPreference 'claudeRetentionDays' 30) -or -not (Save-ClaudeRetentionPreference 'claudeMaximumMB' 100)) { throw 'Saving separate Claude retention failed.' }
$policy=Load-ClaudeRetentionSettings
if (-not $policy.Valid -or $policy.Days -ne 30 -or $policy.MaximumMB -ne 100 -or (Load-ThemeMode) -ne 'light' -or (Load-LanguageMode) -ne 'en') { throw 'Separate retention preferences did not persist safely.' }
if (Save-ClaudeRetentionPreference 'claudeRetentionDays' 31) { throw 'An out-of-range retention was accepted.' }
[IO.File]::WriteAllText($script:settingsPath,'not-valid-json',[Text.UTF8Encoding]::new($false))
if ((Save-LanguageMode 'ru') -or [IO.File]::ReadAllText($script:settingsPath) -cne 'not-valid-json') { throw 'Invalid settings must never be overwritten.' }
if ((Load-ClaudeRetentionSettings).Valid) { throw 'Cleanup must not use defaults when existing settings are corrupt.' }
Write-Output 'Language preferences: system fallback, overrides and safe persistence verified.'
'@
try { & ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks)) $root }
finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
