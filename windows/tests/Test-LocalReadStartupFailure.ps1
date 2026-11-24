$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -Path (Join-Path $PSScriptRoot '..\app\LocalReadOwner.cs')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Wait-Failure($owner){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($clock.ElapsedMilliseconds -lt 15000){
  $result=$owner.TryReceive();if($null -ne $result){Require (-not $result.Success) 'The synthetic failure returned success.';return}
  Start-Sleep -Milliseconds 10
 }
 throw ('The synthetic startup failure did not arrive; stage='+$owner.Stage+'; failure='+$owner.FailureStage)
}
function Finish($owner){
 $owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require $owner.CanReplace 'The synthetic startup worker was not safely cleaned up.'
}
$owner=$null
try{
 $exitFixture=Join-Path $PSScriptRoot 'fixtures\LocalReadStartupExit.ps1'
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($exitFixture,[string[]]@('synthetic'))
 Require ($owner.Request([string[]]@('poll'))) 'The early exit request was rejected.'
 Wait-Failure $owner
 Require ($owner.FailureStage -ceq 'worker-exited-before-connection' -and $owner.HasStartupExitCode -and $owner.StartupExitCode -eq 117) 'The worker exit was not distinguished or its original exit code was lost.'
 Finish $owner;$owner=$null
 $holdFixture=Join-Path $PSScriptRoot 'fixtures\LocalReadStartupHold.ps1'
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($holdFixture,[string[]]@('synthetic'))
 Require ($owner.Request([string[]]@('poll'))) 'The connection timeout request was rejected.'
 Wait-Failure $owner
 Require ($owner.FailureStage -ceq 'connection-timeout' -and -not $owner.HasStartupExitCode) 'The live worker timeout was confused with an early exit.'
 Finish $owner;$owner=$null
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new($holdFixture,[string[]]@('synthetic'))
 Require ($owner.Request([string[]]@('poll'))) 'The startup close request was rejected.'
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while($owner.Stage -cne 'wait-connection' -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require ($owner.Stage -ceq 'wait-connection') 'The synthetic worker did not enter connection waiting.'
 $clock.Restart();$owner.Dispose();$clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 500) 'Closing the synthetic owner blocked on startup.'
 Finish $owner;$owner=$null
 Write-Output 'Synthetic worker startup: early exit and original exit code, live connection timeout, and nonblocking close verified.'
}finally{
 if($null -ne $owner){Finish $owner}
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
