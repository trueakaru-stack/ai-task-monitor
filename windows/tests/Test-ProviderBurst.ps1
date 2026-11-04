$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path @((Join-Path $PSScriptRoot '../app/integrations/ProviderEventState.cs'),(Join-Path $PSScriptRoot '../app/integrations/ProviderEventChannel.cs')) -ReferencedAssemblies System.Web.Extensions
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
$name='AITaskMonitor.Test.Burst'+[Guid]::NewGuid().ToString('N')
$channel=[AITaskMonitor.ExternalProviders.EventChannel]::new($name)
try{
 $channel.SetAllowedProviders(@('opencode'))
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=(Get-Command node.exe -ErrorAction Stop).Source
 $start.Arguments='"'+(Join-Path $PSScriptRoot 'Invoke-ProviderBurstFixture.mjs')+'" "'+$name+'"'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $child=[Diagnostics.Process]::Start($start)
 try{
  if(-not $child.WaitForExit(30000)){$child.Kill();throw 'Burst fixture timed out.'}
  $output=$child.StandardOutput.ReadToEnd();$errorOutput=$child.StandardError.ReadToEnd()
  Assert ($child.ExitCode -eq 0) ('Burst sender failed: '+$errorOutput)
  $result=$output|ConvertFrom-Json
 }finally{$child.Dispose()}
 $batch=$channel.Drain()
 Assert ([int]$result.failures -eq [int]$result.reportedGaps) 'A failed delivery did not produce a gap report.'
 if(-not $batch.Gap){
  $received=@{};foreach($event in $batch.Events){if($event.Kind -eq 'active'){$received[$event.Session]=$true}}
  foreach($session in @($result.acknowledged)){Assert ($received.ContainsKey([string]$session)) 'An acknowledged event disappeared without a channel gap.'}
  Assert (@($batch.Events|Where-Object Kind -eq 'gap').Count -eq [int]$result.reportedGaps) 'A sender gap report was not received.'
 }
 Write-Output ('Burst: '+@($result.acknowledged).Count+' acknowledged, '+$result.failures+' detected failures, '+$result.reportedGaps+' reported gaps, channel gap='+$batch.Gap+'.')
}finally{$channel.Dispose()}
Assert ($channel.IsStopped) 'The burst fixture did not stop its receiver.'
