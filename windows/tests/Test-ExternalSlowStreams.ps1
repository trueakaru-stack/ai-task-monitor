$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 . (Join-Path $PSScriptRoot '..\app\integrations\KimiRuntime.ps1')
 . (Join-Path $PSScriptRoot '..\app\integrations\DeepSeekRuntime.ps1')
 function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
 function Fake-Process {
  $process=[PSCustomObject]@{HasExited=$true;ExitCode=0;Disposed=$false}
  $process|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
  return $process
 }
 $scope='a'*32;$now=[DateTimeOffset]::UtcNow
 $pending=[Threading.Tasks.TaskCompletionSource[string]]::new();$empty=[Threading.Tasks.Task]::FromResult([string]'')
 $process=Fake-Process
 $kimi=New-KimiMonitorController -AppRoot 'synthetic';$kimi.SeenScope=$scope;$kimi.Scope=$scope;$kimi.State='connected';$kimi.Scanned=$true
 $kimi.Request=[PSCustomObject]@{Process=$process;Output=$pending.Task;Errors=$empty;Started=$now.AddSeconds(-35)}
 $clock=[Diagnostics.Stopwatch]::StartNew();Update-KimiMonitorController $kimi $now;$clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 500 -and $null -ne $kimi.Request -and -not $process.Disposed -and
  (Get-KimiMonitorConnectionState $kimi) -ceq 'error' -and @(Get-KimiUncertainScopes $kimi).Count -eq 1) 'A held Kimi output blocked or falsely confirmed its source.'
 $response=@{ok=$true;result=@{state='connected';scope=$scope}}|ConvertTo-Json -Compress -Depth 5
 [void]$pending.SetResult($response);Update-KimiMonitorController $kimi $now
 Require ($null -eq $kimi.Request -and $process.Disposed -and (Get-KimiMonitorConnectionState $kimi) -ceq 'connected') 'Kimi did not recover after its synthetic stream closed.'
 $pending=[Threading.Tasks.TaskCompletionSource[string]]::new();$process=Fake-Process
 $deep=New-DeepSeekMonitorController -AppRoot 'synthetic';$deep.Seen['default']=$scope;$deep.Scanned=$true
 $deep.Profiles=@([PSCustomObject]@{Name='default';State='connected';Scope=$scope;Error=''})
 $deep.Request=[PSCustomObject]@{Process=$process;Output=$pending.Task;Errors=$empty;Started=$now.AddSeconds(-35);Action='list';Profile='';ExpectedScope=''}
 $clock.Restart();Update-DeepSeekMonitorController $deep $now;$clock.Stop()
 Require ($clock.ElapsedMilliseconds -lt 500 -and $null -ne $deep.Request -and -not $process.Disposed -and
  (Get-DeepSeekMonitorConnectionState $deep) -ceq 'error' -and @(Get-DeepSeekUncertainScopes $deep).Count -eq 1) 'A held DeepSeek output blocked or falsely confirmed its source.'
 $response=@{ok=$true;result=@(@{name='default';state='connected';scope=$scope})}|ConvertTo-Json -Compress -Depth 5
 [void]$pending.SetResult($response);Update-DeepSeekMonitorController $deep $now
 Require ($null -eq $deep.Request -and $process.Disposed -and (Get-DeepSeekMonitorConnectionState $deep) -ceq 'connected') 'DeepSeek did not recover after its synthetic stream closed.'
 Write-Output 'External source checks: held synthetic streams remained nonblocking, became unconfirmed and recovered without another process.'
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
