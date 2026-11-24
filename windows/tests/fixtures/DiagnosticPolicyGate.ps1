param([string]$Directory,[string]$StartedName,[string]$ReleaseName,[string]$AppRoot)
$ErrorActionPreference='Stop'
foreach($module in @('DiagnosticPolicy.ps1','DiagnosticStore.ps1','LoopDetection.ps1','DiagnosticCollector.ps1','DiagnosticRuntime.ps1')){. (Join-Path $AppRoot $module)}
$now=[DateTimeOffset]::UtcNow
$runtime=New-DiagnosticRuntime -Directory $Directory -Since $now.AddMinutes(-1) -Now $now
Save-DiagnosticSettings -Directory $Directory -RetentionDays 1 -MaximumMB 10
$runtime.Settings=Get-DiagnosticSettings -Directory $Directory
$runtime.NextCleanup=[DateTimeOffset]::MaxValue
$started=[Threading.EventWaitHandle]::OpenExisting($StartedName);$release=[Threading.EventWaitHandle]::OpenExisting($ReleaseName)
try{
 $resolver={param($id)[void]$started.Set();if(-not $release.WaitOne(10000)){throw 'The synthetic policy gate did not open.'};return ''}
 $stateResolver={param($id)return [PSCustomObject]@{State='unknown'}}
 $task=[PSCustomObject]@{Provider='codex';Id='synthetic-task';State='active'}
 Update-DiagnosticRuntime -Runtime $runtime -Tasks @($task) -Unavailable @() -Now ([DateTimeOffset]::UtcNow) -SessionResolver $resolver -StateResolver $stateResolver
}finally{$started.Dispose();$release.Dispose()}
