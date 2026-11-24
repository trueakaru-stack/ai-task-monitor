param([string]$PolicyPath,[string]$StorePath,[string]$Directory,[int]$Number,[string]$Time,[string]$GateName,[string]$ReadyName,[string]$StartedName,[string]$PolicyReadyName)
$ErrorActionPreference='Stop'
$started=$null;$policyReady=$null;$gate=$null;$ready=$null;$phase=10
try{
 $started=[Threading.EventWaitHandle]::OpenExisting($StartedName)
 $policyReady=[Threading.EventWaitHandle]::OpenExisting($PolicyReadyName)
 [void]$started.Set()
 $phase=11;. $PolicyPath
 [void]$policyReady.Set()
 $phase=12;. $StorePath
 $phase=13;$gate=[Threading.EventWaitHandle]::OpenExisting($GateName)
 $ready=[Threading.EventWaitHandle]::OpenExisting($ReadyName)
 [void]$ready.Set()
 $phase=14;if(-not $gate.WaitOne(30000)){throw 'The synthetic parallel writer gate did not open.'}
 $phase=15
 $event=[PSCustomObject]@{version=1;time=$Time;source='codex';task=('a'*64);type='tool_started';id=('{0:x64}' -f $Number)}
 Write-DiagnosticEvent -Directory $Directory -Event $event -Now ([DateTimeOffset]::Parse($Time)) -RetentionDays 7 -MaximumBytes 10000
}catch{exit $phase}
finally{foreach($handle in @($started,$policyReady,$gate,$ready)){if($null -ne $handle){$handle.Dispose()}}}
