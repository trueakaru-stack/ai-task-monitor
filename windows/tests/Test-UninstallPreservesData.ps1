$ErrorActionPreference = 'Stop'
if ($env:CI -cne 'true' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows') {
    throw 'This uninstaller test requires a disposable hosted Windows runner.'
}
& (Join-Path $PSScriptRoot '..\..\.github\legacy-uninstall-ci\Test-InstallerAndRemoval.ps1')
