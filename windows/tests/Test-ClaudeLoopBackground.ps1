$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 Add-Type -AssemblyName System.Web.Extensions
 $sources=@((Join-Path $PSScriptRoot '..\app\ClaudeLoopChannel.cs'),(Join-Path $PSScriptRoot '..\app\ClaudeLoopBackground.cs'),(Join-Path $PSScriptRoot 'fixtures\SyntheticClaudeLoopSource.cs'))
 Add-Type -Path $sources -ReferencedAssemblies System.Web.Extensions
 function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
 $controller=[SyntheticClaudeLoopController]::new()
 $factory=[Delegate]::CreateDelegate([Func[AITaskMonitor.ClaudeLoop.ILoopSource]],$controller,'Create')
 $owner=[AITaskMonitor.ClaudeLoop.BackgroundChannel]::new($factory,350)
 try{
  $owner.SetEnabled($true)
  Require ($controller.CreateEntered.Wait(10000)) 'The synthetic channel did not block during startup.'
  Start-Sleep -Milliseconds 450
  Require ($owner.HasError -and -not $owner.IsReady -and $controller.Created -eq 1) 'A stuck startup was reported as available or started another owner.'
  $clock=[Diagnostics.Stopwatch]::StartNew();$owner.SetEnabled($false);[void]$owner.Drain();$owner.SetEnabled($true);$clock.Stop()
  Require ($clock.ElapsedMilliseconds -lt 1000 -and $controller.Created -eq 1) 'The UI waited for startup or created a concurrent channel.'
  $controller.CreateRelease.Set();$deadline=[Diagnostics.Stopwatch]::StartNew();$seen=@()
  do{
   Start-Sleep -Milliseconds 10;$batch=$owner.Drain();$seen+=@($batch.Events)
  }while((-not $owner.IsReady -or $seen.Count -lt 1) -and $deadline.ElapsedMilliseconds -lt 10000)
  Require ($owner.IsReady -and $controller.Created -eq 2 -and @($seen|Where-Object {$_.SessionId -ceq 'synthetic-1'}).Count -eq 0 -and
   @($seen|Where-Object {$_.SessionId -ceq 'synthetic-2'}).Count -eq 1) 'A stale connection emitted an event after reconnection.'
  $controller.HoldNextDrain()
  Require ($controller.DrainEntered.Wait(10000)) 'The synthetic receiver did not block while draining.'
  Start-Sleep -Milliseconds 450
  Require ($owner.HasError -and $owner.IsReady -and $controller.Created -eq 2) 'A stuck Drain stayed available or created another channel.'
  $controller.DrainRelease.Set();$deadline.Restart()
  while($owner.HasError -and $deadline.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
  $afterDrain=$owner.Drain()
  Require (-not $owner.HasError -and $afterDrain.Gap -and @($afterDrain.Events|Where-Object {$_.SessionId -ceq 'stale'}).Count -eq 0) 'A late drained batch was applied instead of reporting a gap.'
  $controller.QueueOverflow();$deadline.Restart();$overflow=$null
  do{Start-Sleep -Milliseconds 10;$batch=$owner.Drain();if($batch.Gap){$overflow=$batch;break}}while($deadline.ElapsedMilliseconds -lt 10000)
  Require ($null -ne $overflow -and @($overflow.Events).Count -le 2048) 'Overflow did not report an event gap or exceeded its bound.'
  $controller.SetStopped($true);$deadline.Restart()
  while(-not $owner.HasError -and $deadline.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
  Require $owner.HasError 'A receiver that stopped without a Drain exception remained available.'
  $controller.SetStopped($false);$deadline.Restart()
  while(-not $owner.IsReady -and $deadline.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
  $afterStop=$owner.Drain()
  Require ($owner.IsReady -and $afterStop.Gap) 'Receiver recovery did not report the interrupted event sequence.'
  $controller.DisposeEntered.Reset();$controller.DisposeRelease.Reset()
  $clock.Restart();$owner.SetEnabled($false);$clock.Stop()
  Require ($clock.ElapsedMilliseconds -lt 1000 -and $controller.DisposeEntered.Wait(10000)) 'Disabling waited for channel shutdown.'
  $clock.Restart();$owner.Dispose();$clock.Stop()
  Require ($clock.ElapsedMilliseconds -lt 1000) 'Closing waited for the blocked channel.'
  Write-Output ('Claude loop background owner: blocked startup/shutdown, reconnection generation and bounded gap handling verified ('+$clock.ElapsedMilliseconds+' ms close).')
 }finally{$controller.CreateRelease.Set();$controller.DrainRelease.Set();$controller.DisposeRelease.Set();$owner.Dispose()}
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
