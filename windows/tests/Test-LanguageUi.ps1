param([string]$EvidenceDirectory = '')
$ErrorActionPreference = 'Stop'
$app = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'))
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-language-ui-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory($root)
try {
    if ($EvidenceDirectory) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($EvidenceDirectory)) }
    foreach ($theme in @('dark','light')) {
        foreach ($language in @('ru','en')) {
            $stem = $theme + '-' + $language
            $snapshot = Join-Path $root ($stem + '-tasks.png')
            $settings = Join-Path $root ($stem + '-settings.png')
            $preferences = Join-Path $root ($stem + '-preferences.json')
            & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 1 -PreviewScenario planned -PreviewOffscreen -ThemeOverride $theme -LanguageOverride $language -PreferencesFile $preferences -PreviewLanguageUiTest -DiagnosticDirectory (Join-Path $root ($stem+'-diagnostics')) -SnapshotFile $snapshot -SettingsSnapshotFile $settings
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot) -or -not (Test-Path -LiteralPath $settings)) { throw "Language UI preview failed: $stem" }
            if ($EvidenceDirectory) {
                Copy-Item -LiteralPath $snapshot -Destination (Join-Path $EvidenceDirectory ($stem+'-tasks.png'))
                Copy-Item -LiteralPath $settings -Destination (Join-Path $EvidenceDirectory ($stem+'-settings.png'))
            }
        }
    }
    Write-Output 'Language UI: Russian and English in both themes rendered and verified.'
} finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
