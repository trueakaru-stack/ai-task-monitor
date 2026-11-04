param([string]$EvidenceDirectory = '')
$ErrorActionPreference = 'Stop'
$app = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'))
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-plan-ui-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory($root)
$oldLocal=$env:LOCALAPPDATA; $oldProfile=$env:USERPROFILE; $oldCodex=$env:CODEX_HOME
try {
    $env:LOCALAPPDATA=$root; $env:USERPROFILE=$root; $env:CODEX_HOME=Join-Path $root 'codex'
    if ($EvidenceDirectory) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($EvidenceDirectory)) }
    foreach ($theme in @('dark','light')) {
        foreach ($language in @('ru','en')) {
            foreach ($mode in @('expanded','compact')) {
                foreach ($state in @('confirmed','unconfirmed')) {
                    $stem="$theme-$language-$mode-$state"
                    $snapshot=Join-Path $root ($stem+'.png')
                    $parameters=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$app,'-PreviewActiveTasks','1','-PreviewScenario','planned','-PreviewOffscreen','-PreviewPlanUiTest','-ThemeOverride',$theme,'-LanguageOverride',$language,'-SnapshotFile',$snapshot)
                    if ($mode -eq 'compact') { $parameters += '-CompactMode' }
                    if ($state -eq 'unconfirmed') { $parameters += '-PreviewPlanUnconfirmed' }
                    & powershell.exe @parameters
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot -PathType Leaf)) { throw "Plan UI failed: $stem" }
                    if ($EvidenceDirectory) { Copy-Item -LiteralPath $snapshot -Destination (Join-Path $EvidenceDirectory ($stem+'.png')) }
                }
            }
        }
    }
    Write-Output 'Plan UI: both themes, languages, window modes and confirmation states rendered.'
} finally {
    $env:LOCALAPPDATA=$oldLocal; $env:USERPROFILE=$oldProfile; $env:CODEX_HOME=$oldCodex
    if (Test-Path -LiteralPath $root) {
        $resolved=(Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
