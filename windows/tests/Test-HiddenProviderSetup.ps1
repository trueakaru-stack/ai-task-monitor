$ErrorActionPreference = "Stop"
$app = Join-Path (Join-Path $PSScriptRoot "..\app") "CodexProgress.ps1"
$tokens=$null
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($app,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) { throw "The application does not parse." }
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-HiddenProviderSetup"},$true)
if ($null -eq $definition) { throw "The hidden provider setup helper is missing." }
foreach ($expected in @('$start.UseShellExecute=$false','$start.CreateNoWindow=$true','$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden','$process.WaitForExit()')) {
    if (-not $definition.Extent.Text.Contains($expected)) { throw "The hidden provider setup is missing: $expected" }
}
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai task monitor setup test-"+[Guid]::NewGuid().ToString("N"))))
$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($root)
try {
    $fixture=Join-Path $root "provider setup.ps1"
    $fixtureSource=@'
param([string]$Mode)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "child-pid.txt"),[string]$PID)
if ($Mode -eq "Install") { exit 7 }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "result.txt"),$Mode)
'@
    [IO.File]::WriteAllText($fixture,$fixtureSource,[Text.UTF8Encoding]::new($false))
    $checks=@'
$fixture=$args[0]
Invoke-HiddenProviderSetup $fixture "Remove"
$result=Join-Path (Split-Path -Parent $fixture) "result.txt"
if ([IO.File]::ReadAllText($result) -ne "Remove") { throw "The background setup did not finish normally." }
$childPid=[int][IO.File]::ReadAllText((Join-Path (Split-Path -Parent $fixture) "child-pid.txt"))
if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) { throw "The background setup process is still running." }
$failed=$false
try { Invoke-HiddenProviderSetup $fixture "Install" } catch { $failed=$true }
if (-not $failed) { throw "A failed background setup must be reported." }
'@
    & ([scriptblock]::Create($definition.Extent.Text+"`n"+$checks)) $fixture
    Write-Output "Provider setup: hidden process, completion, and failure propagation verified."
} finally {
    if (Test-Path -LiteralPath $root) {
        $resolved=(Resolve-Path -LiteralPath $root).Path
        if ($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
