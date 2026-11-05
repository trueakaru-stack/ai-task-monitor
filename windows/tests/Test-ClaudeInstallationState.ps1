$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'The application source failed to parse.' }
$node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Claude-InstallationState' }, $true)
if ($null -eq $node) { throw 'Missing Claude installation discovery function.' }
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-install-state-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory($root)
$checks = @'
$profile=Join-Path $args[0] 'profile';$appData=Join-Path $args[0] 'roaming';$localData=Join-Path $args[0] 'local';$bin=Join-Path $args[0] 'custom-bin'
if ((Claude-InstallationState $profile $appData $localData '') -ne 'not-found') { throw 'A missing profile and command should be reported as not found.' }
$desktop=Join-Path $localData 'Programs\Claude'
[void][IO.Directory]::CreateDirectory($desktop)
[IO.File]::WriteAllText((Join-Path $desktop 'Claude.exe'),'synthetic desktop')
if ((Claude-InstallationState $profile $appData $localData $desktop) -ne 'unconfirmed') { throw 'Claude Desktop must permit a connection without claiming a CLI installation.' }
[void][IO.Directory]::CreateDirectory((Join-Path $profile '.claude'))
if ((Claude-InstallationState $profile $appData $localData '') -ne 'unconfirmed') { throw 'A profile directory alone must not prove installation.' }
[void][IO.Directory]::CreateDirectory($bin)
[IO.File]::WriteAllText((Join-Path $bin 'claude.cmd'),'synthetic')
if ((Claude-InstallationState $profile $appData $localData $bin) -ne 'available') { throw 'An existing command on PATH was not detected.' }
Write-Output 'Claude discovery: command, stale profile and missing installation distinguished.'
'@
try { & ([scriptblock]::Create($node.Extent.Text+"`n"+$checks)) $root }
finally {
    if (Test-Path -LiteralPath $root) {
        $resolved=(Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
