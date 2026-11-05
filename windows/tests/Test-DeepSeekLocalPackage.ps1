$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-dsh-package-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app/integrations'))
try {
    [void][IO.Directory]::CreateDirectory($root)
    $plugin = Join-Path $root 'plugin'
    [void][IO.Directory]::CreateDirectory($plugin)
    foreach ($name in @('package.json', 'cordis.patch.yml', 'deepseek-plugin.js', 'provider-events.mjs', 'provider-observers.mjs', 'provider-transport.mjs')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $plugin $name)
    }
    [IO.File]::WriteAllText((Join-Path $plugin 'monitor-profile.json'), ('{"namespace":"' + ('a' * 32) + '"}'), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $root 'package.json'), '{"name":"aitm-synthetic-profile","version":"1.0.0","private":true}', [Text.UTF8Encoding]::new($false))
    & pnpm --dir $root --store-dir (Join-Path $root 'store') --cache-dir (Join-Path $root 'cache') add --offline --ignore-scripts $plugin
    if ($LASTEXITCODE -ne 0) { throw 'Offline local package installation failed.' }
    $manifest = [IO.File]::ReadAllText((Join-Path $root 'package.json')) | ConvertFrom-Json
    $spec = [string]$manifest.dependencies.'ai-task-monitor-dsh-observer'
    if (-not ($spec.StartsWith('file:') -or $spec.StartsWith('link:'))) {
        $prefixKind = (($spec -split ':', 2)[0] -replace '[^A-Za-z]', '')
        throw ('The package manager recorded a different dependency form: ' + $prefixKind)
    }
    $dependencyValue = $spec.Substring($spec.IndexOf(':') + 1)
    $dependencyPath = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($dependencyValue)) { $dependencyValue } else { Join-Path $root $dependencyValue }))
    if (-not [string]::Equals($dependencyPath, $plugin, [StringComparison]::OrdinalIgnoreCase)) { throw 'The local dependency points outside the fixture plugin.' }
    $installedManifest = Join-Path $root 'node_modules\ai-task-monitor-dsh-observer\package.json'
    if (-not (Test-Path -LiteralPath $installedManifest -PathType Leaf)) { throw 'The local plugin was not installed.' }
    $installed = [IO.File]::ReadAllText($installedManifest) | ConvertFrom-Json
    if ($installed.name -cne 'ai-task-monitor-dsh-observer' -or $installed.dsh.bundle.patch -cne './cordis.patch.yml') { throw 'The installed plugin metadata differs.' }
    $scopePath = Join-Path $root 'node_modules\ai-task-monitor-dsh-observer\monitor-profile.json'
    if (-not (Test-Path -LiteralPath $scopePath -PathType Leaf) -or ([IO.File]::ReadAllText($scopePath) | ConvertFrom-Json).namespace -cne ('a' * 32)) { throw 'The installed package lost its profile namespace.' }
    & pnpm --dir $root --store-dir (Join-Path $root 'store') --cache-dir (Join-Path $root 'cache') --config.offline=true --config.ignore-scripts=true remove 'ai-task-monitor-dsh-observer'
    if ($LASTEXITCODE -ne 0) { throw 'Offline local package removal failed.' }
    $after = [IO.File]::ReadAllText((Join-Path $root 'package.json')) | ConvertFrom-Json
    if ($null -ne $after.dependencies.'ai-task-monitor-dsh-observer') { throw 'The local dependency remained.' }
    Write-Output 'DeepSeek local package: offline add, metadata and removal verified in an isolated profile.'
} finally {
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
