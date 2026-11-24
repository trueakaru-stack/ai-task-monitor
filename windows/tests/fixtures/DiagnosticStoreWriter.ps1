param([string]$PolicyPath,[string]$StorePath,[string]$Directory,[int]$Number,[string]$Time,[string]$GateName,[string]$ReadyName)
$ErrorActionPreference='Stop'
. $PolicyPath
. $StorePath
$gate=[Threading.EventWaitHandle]::OpenExisting($GateName)
$ready=[Threading.EventWaitHandle]::OpenExisting($ReadyName)
try{[void]$ready.Set();if(-not $gate.WaitOne(30000)){throw 'The synthetic parallel writer gate did not open.'}}finally{$ready.Dispose();$gate.Dispose()}
$event=[PSCustomObject]@{version=1;time=$Time;source='codex';task=('a'*64);type='tool_started';id=('{0:x64}' -f $Number)}
Write-DiagnosticEvent -Directory $Directory -Event $event -Now ([DateTimeOffset]::Parse($Time)) -RetentionDays 7 -MaximumBytes 10000
