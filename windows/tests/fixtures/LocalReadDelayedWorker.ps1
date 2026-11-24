param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
$ErrorActionPreference='Stop'
$gate=[Threading.EventWaitHandle]::OpenExisting('Local\AITaskMonitorSyntheticDelay-'+$ParentId)
try { if (-not $gate.WaitOne(10000)) { return } } finally { $gate.Dispose() }
& (Join-Path $PSScriptRoot 'LocalReadSyntheticWorker.ps1') -PipeName $PipeName -ParentId $ParentId
