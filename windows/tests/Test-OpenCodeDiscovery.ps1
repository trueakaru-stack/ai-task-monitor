$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../app/integrations/ProviderRuntime.ps1')
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-opencode-discovery-' + [Guid]::NewGuid().ToString('N'))))
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
$oldPath = $env:PATH
$oldProfile = $env:USERPROFILE
try {
    [void][IO.Directory]::CreateDirectory($root)
    $env:PATH = ''
    $env:USERPROFILE = $root
    if (Test-OpenCodePotentialInstallation) { throw 'An empty profile must not appear installed.' }
    $bin = Join-Path $root '.opencode\bin'
    [void][IO.Directory]::CreateDirectory($bin)
    [IO.File]::WriteAllBytes((Join-Path $bin 'opencode.exe'), [byte[]]@())
    if (-not (Test-OpenCodePotentialInstallation)) { throw 'The standard OpenCode location was not found.' }
    Write-Output 'OpenCode discovery: isolated standard location and missing installation verified.'
} finally {
    $env:PATH = $oldPath
    $env:USERPROFILE = $oldProfile
    if (Test-Path -LiteralPath $root) {
        $resolved = (Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
