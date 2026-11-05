param([Parameter(Mandatory=$true)][string]$CliPath)
$ErrorActionPreference = 'Stop'
$cli = [IO.Path]::GetFullPath($CliPath)
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'The isolated DeepSeek CLI fixture is missing.' }
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-real-dsh-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
[void][IO.Directory]::CreateDirectory($root)
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app/integrations'))
$old = @{}
foreach ($name in @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'DSH_HOME', 'NPM_CONFIG_CACHE', 'NPM_CONFIG_USERCONFIG', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'PNPM_HOME', 'PNPM_CONFIG_IGNORE_SCRIPTS', 'PNPM_CONFIG_IGNORE_PNPMFILE', 'PNPM_CONFIG_OFFLINE', 'AITM_SCRIPT_MARKER')) {
    $old[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    foreach ($name in @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA')) { [Environment]::SetEnvironmentVariable($name, $root, 'Process') }
    [Environment]::SetEnvironmentVariable('DSH_HOME', (Join-Path $root 'dsh-home'), 'Process')
    [Environment]::SetEnvironmentVariable('NPM_CONFIG_CACHE', (Join-Path $root 'cache'), 'Process')
    [Environment]::SetEnvironmentVariable('NPM_CONFIG_USERCONFIG', (Join-Path $root 'empty-npmrc'), 'Process')
    [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', (Join-Path $root 'xdg-config'), 'Process')
    [Environment]::SetEnvironmentVariable('XDG_CACHE_HOME', (Join-Path $root 'xdg-cache'), 'Process')
    [Environment]::SetEnvironmentVariable('PNPM_HOME', (Join-Path $root 'pnpm-home'), 'Process')
    [Environment]::SetEnvironmentVariable('PNPM_CONFIG_IGNORE_SCRIPTS', 'true', 'Process')
    [Environment]::SetEnvironmentVariable('PNPM_CONFIG_IGNORE_PNPMFILE', 'true', 'Process')
    [Environment]::SetEnvironmentVariable('PNPM_CONFIG_OFFLINE', 'true', 'Process')
    [Environment]::SetEnvironmentVariable('AITM_SCRIPT_MARKER', (Join-Path $root 'script-ran'), 'Process')
    [IO.File]::WriteAllText((Join-Path $root 'empty-npmrc'), '')
    $foreign = Join-Path $root 'foreign-plugin'
    $monitor = Join-Path $root 'monitor-plugin'
    [void][IO.Directory]::CreateDirectory($foreign)
    [void][IO.Directory]::CreateDirectory($monitor)
    [IO.File]::WriteAllText((Join-Path $foreign 'package.json'), '{"name":"aitm-foreign-fixture","version":"1.0.0","type":"module","main":"index.js","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $foreign 'index.js'), 'export const name = "aitm-foreign-fixture"; export function apply() {}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $foreign 'cordis.patch.yml'), "- insert:`n    - id: foreign-fixture`n      name: aitm-foreign-fixture`n", [Text.UTF8Encoding]::new($false))
    foreach ($name in @('package.json', 'cordis.patch.yml', 'deepseek-plugin.js', 'provider-events.mjs', 'provider-observers.mjs', 'provider-transport.mjs')) {
        [IO.File]::Copy((Join-Path $source $name), (Join-Path $monitor $name))
    }
    [IO.File]::WriteAllText((Join-Path $monitor 'monitor-profile.json'), ('{"namespace":"' + ('a' * 32) + '"}'), [Text.UTF8Encoding]::new($false))
    & $cli plugin --profile aitm-fixture add --offline --ignore-scripts $foreign
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated foreign bundle fixture.' }
    $manifestPath = Join-Path $env:DSH_HOME 'profiles\aitm-fixture\package.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The fixture profile was not initialized.' }
    & $cli plugin --profile aitm-fixture add --offline --ignore-scripts $monitor
    if ($LASTEXITCODE -ne 0) { throw 'The official CLI could not add the monitor bundle offline.' }
    $installed = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($null -eq $installed.dependencies.'aitm-foreign-fixture' -or $null -eq $installed.dependencies.'ai-task-monitor-dsh-observer') { throw 'A dependency was lost during installation.' }
    if (@($installed.dsh.profile.bundles | Where-Object { $_ -ceq 'aitm-foreign-fixture' }).Count -ne 1 -or @($installed.dsh.profile.bundles | Where-Object { $_ -ceq 'ai-task-monitor-dsh-observer' }).Count -ne 1) { throw 'The expected bundle selection was not preserved.' }
    $composed = @(& $cli --profile aitm-fixture --dump-config)
    if ($LASTEXITCODE -ne 0 -or -not (($composed -join "`n").Contains('ai-task-monitor-dsh-observer'))) { throw 'The upstream CLI did not compose the monitor bundle.' }
    $installed | Add-Member -NotePropertyName scripts -NotePropertyValue ([pscustomobject]@{ preinstall = 'node -e "require(''fs'').writeFileSync(process.env.AITM_SCRIPT_MARKER,''executed'')"'; postinstall = 'node -e "require(''fs'').writeFileSync(process.env.AITM_SCRIPT_MARKER,''executed'')"' }) -Force
    [IO.File]::WriteAllText($manifestPath, ($installed | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    $profileRoot = Split-Path -Parent $manifestPath
    [IO.File]::WriteAllText((Join-Path $profileRoot '.pnpmfile.mjs'), 'import { writeFileSync } from "node:fs"; writeFileSync(process.env.AITM_SCRIPT_MARKER,"executed"); export function readPackage(pkg) { return pkg; }', [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('PNPM_CONFIG_IGNORE_PNPMFILE', 'false', 'Process')
    Push-Location -LiteralPath $profileRoot
    try { & pnpm install --offline --ignore-scripts --lockfile-only } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $env:AITM_SCRIPT_MARKER)) { throw 'The pnpmfile control fixture did not execute.' }
    [IO.File]::Delete($env:AITM_SCRIPT_MARKER)
    [Environment]::SetEnvironmentVariable('PNPM_CONFIG_IGNORE_PNPMFILE', 'true', 'Process')
    & $cli plugin --profile aitm-fixture remove 'ai-task-monitor-dsh-observer'
    if ($LASTEXITCODE -ne 0) { throw 'The official CLI could not remove the monitor bundle offline.' }
    if (Test-Path -LiteralPath $env:AITM_SCRIPT_MARKER) { throw 'Removing the observer ran a profile lifecycle script or pnpmfile.' }
    $after = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($null -eq $after.dependencies.'aitm-foreign-fixture' -or $null -ne $after.dependencies.'ai-task-monitor-dsh-observer') { throw 'Disconnect affected the wrong dependency.' }
    if (@($after.dsh.profile.bundles | Where-Object { $_ -ceq 'aitm-foreign-fixture' }).Count -ne 1 -or @($after.dsh.profile.bundles | Where-Object { $_ -ceq 'ai-task-monitor-dsh-observer' }).Count -ne 0) { throw 'Disconnect affected the wrong bundle selection.' }
    Write-Output 'DeepSeek upstream CLI: isolated offline add/remove preserved an unrelated bundle and profile.'
} finally {
    foreach ($name in $old.Keys) { [Environment]::SetEnvironmentVariable($name, $old[$name], 'Process') }
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
