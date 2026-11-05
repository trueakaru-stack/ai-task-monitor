param([Parameter(Mandatory=$true)][string]$Assembly,[Parameter(Mandatory=$true)][string]$Tests)
$ErrorActionPreference='Stop'
if([Environment]::Version.Major -ne 10){throw 'The native reader test requires PowerShell on .NET 10.'}
Add-Type -Path $Assembly
if(-not ('AITaskMonitor.Claude.Reader' -as [type])){throw 'The native reader did not load.'}
& $Tests
