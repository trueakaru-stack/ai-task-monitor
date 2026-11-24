param([Parameter(Mandatory=$true)][string]$PipeName,[Parameter(Mandatory=$true)][int]$ParentId)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
$writer=$null;$phase='connect'
try{
 $pipe.Connect(5000);$phase='identity'
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class DiagnosticWorkerServerIdentity {
 [DllImport("kernel32.dll", SetLastError=true)]
 public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
 $server=[uint32]0
 if(-not [DiagnosticWorkerServerIdentity]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$server) -or $server -ne [uint32]$ParentId){throw 'Unexpected owner.'}
 $reader=[IO.BinaryReader]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false,$true),$true)
 $initialized=$false;$runtime=$null;$warningTokens=@{}
 $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
 $seenOrder=New-Object 'Collections.Generic.Queue[string]'
 while($true){
  try{$length=$reader.ReadInt32()}catch [IO.EndOfStreamException]{break}
  if($length -le 0 -or $length -gt 16777216){throw 'Invalid request frame.'}
  $bytes=$reader.ReadBytes($length);if($bytes.Length -ne $length){throw 'Incomplete request frame.'}
  $message=[Management.Automation.PSSerializer]::Deserialize([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
  if(-not $initialized){
   $phase='configure'
   $configuration=@($message.Configuration)
   if($configuration.Count -ne 6 -or [string]$configuration[0] -cne 'AITM-DIAGNOSTIC-1'){throw 'Unsupported diagnostic configuration.'}
   $started=[DateTimeOffset]::MinValue
   if(-not [DateTimeOffset]::TryParseExact([string]$configuration[5],'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$started)){throw 'Invalid diagnostic start time.'}
   $diagnosticDirectory=[IO.Path]::GetFullPath([string]$configuration[4])
   $phase='load-source';. (Join-Path $PSScriptRoot 'LocalSourceCore.ps1')
   Initialize-LocalSourceReader -CodexHome ([string]$configuration[1]) -ProfileRoot ([string]$configuration[2]) -DataDirectory ([string]$configuration[3]) -MonitorStartedUtc $started.UtcDateTime
   $phase='load-diagnostics'
   foreach($module in @('DiagnosticPolicy.ps1','DiagnosticStore.ps1','LoopDetection.ps1','DiagnosticCollector.ps1','DiagnosticRuntime.ps1')){. (Join-Path $PSScriptRoot $module)}
   try{$runtime=New-DiagnosticRuntime -Directory $diagnosticDirectory -Since $started -Now ([DateTimeOffset]::UtcNow)}catch{$runtime=$null}
   $initialized=$true
  }
  $phase='parse-request'
  $request=@($message.Request)
  if($request.Count -lt 1 -or $request.Count -gt 32 -or [string]$request[0] -cne 'poll'){throw 'Unsupported diagnostic request.'}
  $tasks=New-Object 'Collections.Generic.List[object]';$unavailable=New-Object 'Collections.Generic.List[string]'
  $dismiss=New-Object 'Collections.Generic.List[object]';$clearId='';$observationTime=[DateTimeOffset]::UtcNow;$observedProvided=$false
  for($index=1;$index -lt $request.Count;$index++){
   $part=[string]$request[$index]
   if($part.StartsWith('observed:',[StringComparison]::Ordinal)){
    if($observedProvided -or -not [DateTimeOffset]::TryParseExact($part.Substring(9),'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$observationTime)){throw 'Invalid observation time.'}
    $observedProvided=$true
   }elseif($part.StartsWith('clear:',[StringComparison]::Ordinal)){
    $clearId=$part.Substring(6)
    if($clearId -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid clear operation.'}
   }elseif($part.StartsWith('unavailable:',[StringComparison]::Ordinal)){
    foreach($code in $part.Substring(12).Split(',')){if($code -ceq 'codex'){$unavailable.Add('Codex')}elseif($code -ceq 'claude'){$unavailable.Add('Claude Code')}elseif($code){throw 'Invalid source state.'}}
   }elseif($part.StartsWith('tasks:',[StringComparison]::Ordinal)){
    foreach($item in $part.Substring(6).Split(';')){
     if(-not $item){continue};$fields=$item.Split(',')
     if($fields.Length -ne 3 -or $fields[0] -cnotin @('codex','claude') -or $fields[1] -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $fields[2] -cnotin @('active','unknown')){throw 'Invalid diagnostic task.'}
     $tasks.Add([PSCustomObject]@{Provider=$fields[0];Id=$fields[1];State=$fields[2]})
    }
   }elseif($part.StartsWith('dismiss:',[StringComparison]::Ordinal)){
    foreach($item in $part.Substring(8).Split(';')){
     if(-not $item){continue};$fields=$item.Split(',')
     if($fields.Length -ne 3 -or $fields[0] -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $fields[1] -cnotmatch '^[a-f0-9]{32}$' -or $fields[2] -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid dismissal.'}
     $dismiss.Add([PSCustomObject]@{Id=$fields[0];Token=$fields[1];Operation=$fields[2]})
    }
   }else{throw 'Invalid diagnostic request field.'}
  }
  $clearAck='';$dismissed=New-Object 'Collections.Generic.List[string]';$failed=$false;$clearedAt=$null
  $failureStage='';$failureKind=''
  try{
   $phase='clear'
   if($clearId){
    $key='clear:'+ $clearId
    if(-not $seen.Contains($key)){
     Clear-DiagnosticEvents -Directory $diagnosticDirectory
     $clearedAt=[DateTimeOffset]::UtcNow
     if($null -ne $runtime){$runtime.NextCleanup=[DateTimeOffset]::MaxValue;$runtime.Since=$clearedAt}
     if($seen.Add($key)){$seenOrder.Enqueue($key)}
    }
    $clearAck=$clearId
   }
   $phase='runtime'
   if($null -eq $runtime){$runtime=New-DiagnosticRuntime -Directory $diagnosticDirectory -Since $(if($null -ne $clearedAt){$clearedAt}else{$started}) -Now ([DateTimeOffset]::UtcNow)}
   $settings=Get-DiagnosticSettings -Directory $diagnosticDirectory
   if($settings.RetentionDays -ne $runtime.Settings.RetentionDays -or $settings.MaximumMB -ne $runtime.Settings.MaximumMB){$runtime.NextCleanup=[DateTimeOffset]::MinValue}
   $runtime.Settings=$settings
   if($observationTime -lt $runtime.Since){$observationTime=$runtime.Since}
   foreach($entry in $dismiss){
    $key='dismiss:'+ [string]$entry.Operation
    if(-not $seen.Contains($key)){
     $taskKey='codex:'+ [string]$entry.Id
     if($warningTokens.ContainsKey($taskKey) -and $warningTokens[$taskKey].Token -ceq [string]$entry.Token -and $runtime.LoopStates.ContainsKey($taskKey)){$runtime.LoopStates[$taskKey].Dismissed=$true}
     if($seen.Add($key)){$seenOrder.Enqueue($key)}
    }
    $dismissed.Add([string]$entry.Operation)
   }
   while($seenOrder.Count -gt 1024){[void]$seen.Remove($seenOrder.Dequeue())}
   $phase='update'
   $resolver={param($id) return (Session-File $id)}
   $stateResolver={param($id) return (Thread-State $id)}
   Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks.ToArray() -Unavailable $unavailable.ToArray() -Now ([DateTimeOffset]::UtcNow) -ObservationTime $observationTime -SessionResolver $resolver -StateResolver $stateResolver
  }catch{$failed=$true;$failureStage=$phase;$failureKind=$_.Exception.GetBaseException().GetType().Name}
  $warnings=New-Object 'Collections.Generic.List[object]';$present=@{}
  if(-not $failed){
   foreach($key in @($runtime.LoopStates.Keys)){
    $state=$runtime.LoopStates[$key]
    if(-not [bool]$state.Warning){continue}
    $times=@($state.Times|ForEach-Object {$_.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)}) -join ','
    $signature=[string]$state.Fingerprint+'|'+$times+'|'+[string]$state.Threshold+'|'+[string]$state.WindowMinutes
    if(-not $warningTokens.ContainsKey($key) -or $warningTokens[$key].Signature -cne $signature){$warningTokens[$key]=[PSCustomObject]@{Signature=$signature;Token=[Guid]::NewGuid().ToString('N')}}
    $present[$key]=$true
    $warnings.Add([PSCustomObject]@{Key=[string]$key;Warning=$true;Dismissed=[bool]$state.Dismissed;Threshold=[int]$state.Threshold;WindowMinutes=[int]$state.WindowMinutes;Token=[string]$warningTokens[$key].Token})
   }
   foreach($key in @($warningTokens.Keys)){if(-not $present.ContainsKey($key)){[void]$warningTokens.Remove($key)}}
  }
  $result=[PSCustomObject]@{Failed=$failed;FailureStage=$failureStage;FailureKind=$failureKind;Warnings=$warnings.ToArray();ClearAck=$clearAck;DismissAck=$dismissed.ToArray()}
  $phase='respond'
  $response=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($result,24))
  if($response.Length -le 0 -or $response.Length -gt 16777216){throw 'Invalid result frame.'}
  $writer.Write([int]$response.Length);$writer.Write($response);$writer.Flush()
 }
}catch{
 # Send only a phase and exception type; never emit paths or source content.
 try{
  if($null -ne $writer){
   $safe=[PSCustomObject]@{Failed=$true;Fatal=$true;FailureStage=$phase;FailureKind=$_.Exception.GetBaseException().GetType().Name;Warnings=@();ClearAck='';DismissAck=@()}
   $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes([Management.Automation.PSSerializer]::Serialize($safe,8))
   $writer.Write([int]$bytes.Length);$writer.Write($bytes);$writer.Flush()
  }
 }catch{}
 exit 1
}finally{
 foreach($name in @('codexTitleReader','codexRolloutReader','codexRecentEventObserver','codexRootEvidenceReader')){
  $variable=Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
  if($null -ne $variable -and $null -ne $variable.Value){try{$variable.Value.Dispose()}catch{}}
 }
 $pipe.Dispose()
}
