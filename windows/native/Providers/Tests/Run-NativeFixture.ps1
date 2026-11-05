param(
    [Parameter(Mandatory=$true)][string]$AssemblyPath,
    [Parameter(Mandatory=$true)][string]$FixturePath
)
$ErrorActionPreference = 'Stop'
if ([Environment]::Version.Major -ne 10) { throw 'The native fixture runner requires PowerShell on .NET 10.' }
Add-Type -Path $AssemblyPath
$lines = [IO.File]::ReadAllLines($FixturePath)
if ($lines.Length -lt 4 -or $lines[0] -ne '$ErrorActionPreference = ''Stop''' -or
    $lines[1] -ne 'Add-Type -AssemblyName System.Web.Extensions' -or
    $lines[2] -ne 'Add-Type -Path (Join-Path $PSScriptRoot ''../app/integrations/ProviderEventState.cs'') -ReferencedAssemblies System.Web.Extensions') {
    throw 'The upstream fixture setup changed; review before running it against the native library.'
}
$body = $lines[3..($lines.Length - 1)] -join [Environment]::NewLine
& ([ScriptBlock]::Create($body))
