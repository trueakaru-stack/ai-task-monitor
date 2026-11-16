$ErrorActionPreference='Stop'
if ($env:CI -ne 'true' -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:RUNNER_OS -ne 'Windows' -or $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -ne '0') {
 throw 'Disposable hosted Windows runner required.'
}
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
. (Join-Path $appRoot 'integrations/ProviderEventView.ps1')
. (Join-Path $appRoot 'integrations/ProviderRuntime.ps1')
. (Join-Path $appRoot 'integrations/DeepSeekRuntime.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $appRoot 'CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Application source could not be parsed.'}
$mapper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Unconfirmed-ExternalTasks'},$true)
if($null -eq $mapper){throw 'Application task mapper not found.'}
. ([scriptblock]::Create($mapper.Extent.Text))
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Receive-DeepSeekRuntimeRequest {param($Request) return $Request.Reply}
function Start-DeepSeekRuntimeRequest {param($Context,$Action,$Profile,$ExpectedScope) return [PSCustomObject]@{Action=$Action;Profile=$Profile;ExpectedScope=$ExpectedScope;Reply=$null}}
function Feed-DeepSeek($controller,[object[]]$items,[bool]$ok=$true){
 $reply=[PSCustomObject]@{Ok=$ok;Error=$(if($ok){''}else{'synthetic-error'});Action='list';Profile='';Result=$items}
 $controller.Request=[PSCustomObject]@{Action='list';Profile='';Reply=$reply}
 Update-DeepSeekMonitorController $controller
}
function Profile([string]$name,[string]$state,[string]$scope=''){
 return [PSCustomObject]@{name=$name;state=$state;scope=$scope;error=''}
}
function Send([string]$name,[string]$json){
 $stream=[IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut)
 try{
  $stream.Connect(2000);$bytes=[Text.Encoding]::UTF8.GetBytes($json);$header=[BitConverter]::GetBytes([int]$bytes.Length)
  $stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
  $ack=New-Object byte[] 1;$pending=$stream.BeginRead($ack,0,1,$null,$null)
  if(-not $pending.AsyncWaitHandle.WaitOne(2000) -or $stream.EndRead($pending) -ne 1 -or $ack[0] -ne 6){throw 'Acknowledgement missing.'}
 }finally{$stream.Dispose()}
}
function Send-Event([string]$provider,[string]$session,[string]$kind){
 Send $pipe ('{"version":1,"provider":"'+$provider+'","session":"'+$session+'","kind":"'+$kind+'"}')
}
function Poll-Group {
 $script:state=Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen `
  -PreviousTasks $state.Tasks -ProfileScopes $scopes -UncertainProfileScopes $uncertain -ConfirmedDisconnectedProfileScopes $confirmed
}
$a='a'*32;$b='b'*32;$c='c'*32
$deep=New-DeepSeekMonitorController -AppRoot $appRoot
Feed-DeepSeek $deep @((Profile 'A' 'connected' $a),(Profile 'B' 'connected' $b))
Assert (@(Get-DeepSeekAllowedScopes $deep).Count -eq 2) 'Valid profiles were not connected.'
$unlocked=New-DeepSeekMonitorController -AppRoot $appRoot
Feed-DeepSeek $unlocked @((Profile 'A' 'connected' $a),(Profile 'B' 'connected' $b))
Feed-DeepSeek $unlocked @((Profile 'A' 'disconnected'),(Profile 'B' 'connected' $b))
Assert (@(Get-DeepSeekConfirmedDisconnectedScopes $unlocked).Count -eq 0 -and @(Get-DeepSeekUncertainScopes $unlocked) -ccontains $a) 'An unlocked listing was treated as proof.'
$deep.Context=[PSCustomObject]@{}
$deep.FixtureContext=$deep.Context
Request-DeepSeekProfileConnection -Controller $deep -Profile 'A' -Connect $false
Assert (@(Get-DeepSeekConfirmedDisconnectedScopes $deep).Count -eq 0 -and @(Get-DeepSeekUncertainScopes $deep) -ccontains $a -and
        @(Get-DeepSeekAllowedScopes $deep) -ccontains $b) 'A disconnect request claimed a confirmed scope or degraded B.'
$deep.Request.Reply=[PSCustomObject]@{Ok=$true;Error='';Action='disconnect';Profile='A';Result=[PSCustomObject]@{state='disconnected';scope=$a}}
Update-DeepSeekMonitorController $deep
$deep.Request=$null
Assert (@(Get-DeepSeekConfirmedDisconnectedScopes $deep) -ccontains $a -and @(Get-DeepSeekAllowedScopes $deep) -ccontains $b) 'A matching locked proof did not isolate A.'
Feed-DeepSeek $deep @((Profile 'A' 'partial'),(Profile 'B' 'connected' $b))
Assert (@(Get-DeepSeekConfirmedDisconnectedScopes $deep).Count -eq 0 -and @(Get-DeepSeekUncertainScopes $deep) -ccontains $a -and
        (Get-DeepSeekMonitorConnectionState $deep) -eq 'connected-degraded') 'A stale disconnect was reused after the profile became partial.'
Feed-DeepSeek $deep @((Profile 'B' 'connected' $b))
Assert (@(Get-DeepSeekConfirmedDisconnectedScopes $deep).Count -eq 0 -and @(Get-DeepSeekUncertainScopes $deep) -ccontains $a) 'A stale disconnect was reused after the profile disappeared.'
Feed-DeepSeek $deep @((Profile 'A' 'disconnected'),(Profile 'B' 'connected' $b))
Assert (@(Get-DeepSeekConfirmedDisconnectedScopes $deep) -ccontains $a) 'A current listing did not retain the earlier locked proof.'
$race=New-DeepSeekMonitorController -AppRoot $appRoot
Feed-DeepSeek $race @((Profile 'A' 'connected' $a),(Profile 'B' 'connected' $b))
$race.Context=[PSCustomObject]@{};$race.FixtureContext=$race.Context
Request-DeepSeekProfileConnection -Controller $race -Profile 'A' -Connect $false
$race.Request.Reply=[PSCustomObject]@{Ok=$true;Error='';Action='disconnect';Profile='A';Result=[PSCustomObject]@{state='disconnected';scope=$c}}
Update-DeepSeekMonitorController $race
$race.Request=$null
Assert ($race.ActionError -eq 'scope-changed' -and @(Get-DeepSeekConfirmedDisconnectedScopes $race).Count -eq 0 -and
        @(Get-DeepSeekUncertainScopes $race) -ccontains $a -and @(Get-DeepSeekAllowedScopes $race) -ccontains $b) 'A mismatched reply confirmed or affected another profile.'
$reconnectedDeep=New-DeepSeekMonitorController -AppRoot $appRoot
Feed-DeepSeek $reconnectedDeep @((Profile 'A' 'connected' $a),(Profile 'B' 'connected' $b))
$reconnectedDeep.Context=[PSCustomObject]@{};$reconnectedDeep.FixtureContext=$reconnectedDeep.Context
Request-DeepSeekProfileConnection -Controller $reconnectedDeep -Profile 'A' -Connect $false
$reconnectedDeep.Request.Reply=[PSCustomObject]@{Ok=$true;Error='';Action='disconnect';Profile='A';Result=[PSCustomObject]@{state='disconnected';scope=$a}}
Update-DeepSeekMonitorController $reconnectedDeep
$reconnectedDeep.Request=$null
Feed-DeepSeek $reconnectedDeep @((Profile 'A' 'connected' $c),(Profile 'B' 'connected' $b))
Assert (@(Get-DeepSeekAllowedScopes $reconnectedDeep) -ccontains $c -and @(Get-DeepSeekAllowedScopes $reconnectedDeep) -ccontains $b -and
        @(Get-DeepSeekUncertainScopes $reconnectedDeep) -ccontains $c -and @(Get-DeepSeekUncertainScopes $reconnectedDeep) -cnotcontains $b) 'A new namespace after disconnect was falsely confirmed or affected B.'
$lostRoster=New-DeepSeekMonitorController -AppRoot $appRoot
Feed-DeepSeek $lostRoster @((Profile 'A' 'connected' $a))
Feed-DeepSeek $lostRoster @((Profile 'A' 'disconnected'))
Feed-DeepSeek $lostRoster @() $false
Assert ((Get-DeepSeekMonitorConnectionState $lostRoster) -eq 'error' -and @(Get-DeepSeekConfirmedDisconnectedScopes $lostRoster).Count -eq 0) 'A later roster error was treated as a confirmed disconnect.'
$collision=New-DeepSeekMonitorController -AppRoot $appRoot
Feed-DeepSeek $collision @((Profile 'A' 'connected' $a),(Profile 'B' 'connected' $b))
Feed-DeepSeek $collision @((Profile 'A' 'connected' $b),(Profile 'B' 'connected' $b))
Feed-DeepSeek $collision @((Profile 'A' 'disconnected'),(Profile 'B' 'connected' $b))
Assert (@(Get-DeepSeekConfirmedDisconnectedScopes $collision).Count -eq 0 -and @(Get-DeepSeekUncertainScopes $collision).Count -ge 1) 'An identity collision was accepted as a confirmed disconnect.'
$many=New-DeepSeekMonitorController -AppRoot $appRoot
$manyProfiles=@(for($i=0;$i -lt 256;$i++){Profile ('P'+$i) 'connected' ('{0:x32}' -f $i)})
Feed-DeepSeek $many $manyProfiles
Feed-DeepSeek $many @((Profile 'Overflow' 'connected' ('{0:x32}' -f 256)))
Assert ($many.Seen.Count -eq 256 -and $many.ScopeHistoryLost -and @(Get-DeepSeekConfirmedDisconnectedScopes $many).Count -eq 0) 'DeepSeek profile history grew without a safe bound.'

$pipe='AITaskMonitor.Test.'+[Guid]::NewGuid().ToString('N')
$controller=New-ExternalProviderController -PipeName $pipe
$seen=@{};$connections=@{deepseek='connected';opencode='connected';kimi='disconnected';hermes='disconnected'}
$scopes=@{deepseek=@($a,$b)};$uncertain=@{deepseek=@()};$confirmed=@{}
$state=[PSCustomObject]@{Tasks=@()}
try{
 Poll-Group
 $originalStore=$controller.Store
 Send-Event 'deepseek' ($a+'_one') 'active'
 Send-Event 'opencode' 'other' 'active'
 for($i=0;$i -lt 254;$i++){Send-Event 'deepseek' ($b+'_'+$i) 'active'}
 Poll-Group
 Assert ($state.Tasks.Count -eq 256 -and @($state.Tasks | Where-Object {$_.Active}).Count -eq 256) 'Normal V1 startup changed.'
 Send-Event 'deepseek' ($a+'_overflow') 'active'
 Poll-Group
 Assert ($state.Tasks.Count -eq 256 -and $state.Unavailable -contains 'DeepSeek Harness' -and $state.Unavailable -notcontains 'OpenCode') 'Capacity loss affected the wrong source or displaced a card.'
 Assert ($state.PartialData -contains 'DeepSeek Harness' -and $state.PartialData -notcontains 'OpenCode') 'Capacity loss was not identified as partial data loss.'
 Send-Event 'deepseek' ($a+'_one') 'completed'
 Send-Event 'deepseek' ($a+'_one') 'active'
 $connections.deepseek='connected-degraded';$scopes.deepseek=@($b);$uncertain.deepseek=@($a)
 Poll-Group
 Assert (@($state.Tasks | Where-Object {$_.Id -eq ('deepseek:'+$a+'_one') -and -not $_.Active -and -not $_.Paused}).Count -eq 1) 'Delayed A events changed an unconfirmed task.'
 Assert (@($state.Tasks | Where-Object {$_.Id -like ('deepseek:'+$b+'_*') -and $_.Active}).Count -eq 254 -and
         @($state.Tasks | Where-Object {$_.Id -eq 'opencode:other' -and $_.Active}).Count -eq 1) 'A partial A profile affected B or OpenCode.'
 Assert ($state.PartialConnection -contains 'DeepSeek Harness' -and $state.PartialData -contains 'DeepSeek Harness') 'Partial connection and known event loss were not distinguished.'
 $connections.deepseek='connected';$scopes.deepseek=@($a,$b);$uncertain.deepseek=@()
 Poll-Group
 Assert ($state.Unavailable -contains 'DeepSeek Harness' -and $state.Tasks.Count -eq 256) 'Recovery forgot the scoped loss.'
 $connections.deepseek=Get-DeepSeekMonitorConnectionState $unlocked
 $scopes.deepseek=@(Get-DeepSeekAllowedScopes $unlocked)
 $uncertain.deepseek=@(Get-DeepSeekUncertainScopes $unlocked)
 $confirmed.deepseek=@(Get-DeepSeekConfirmedDisconnectedScopes $unlocked)
 Poll-Group
 Assert (@($state.Tasks | Where-Object {$_.Id -eq ('deepseek:'+$a+'_one') -and -not $_.Active}).Count -eq 1 -and
         @($state.Tasks | Where-Object {$_.Id -like ('deepseek:'+$b+'_*') -and $_.Active}).Count -eq 254 -and
         $state.Unavailable -contains 'DeepSeek Harness') 'An unlocked profile listing removed A or affected healthy B in the real group flow.'
 $connections.deepseek='connected';$scopes.deepseek=@($b);$uncertain.deepseek=@();$confirmed.deepseek=@(Get-DeepSeekConfirmedDisconnectedScopes $deep)
 Poll-Group
 Assert (@($state.Tasks | Where-Object {$_.Id -eq ('deepseek:'+$a+'_one')}).Count -eq 0 -and
         @($state.Tasks | Where-Object {$_.Id -like ('deepseek:'+$b+'_*') -and $_.Active}).Count -eq 254 -and
         $state.Unavailable -notcontains 'DeepSeek Harness') 'Confirmed A disconnect did not clear only A and its warning.'
 $scopes.deepseek=@($a,$b);$confirmed=@{}
 Send-Event 'deepseek' ($a+'_reconnected') 'active'
 Poll-Group
 Assert (@($state.Tasks | Where-Object {$_.Id -eq ('deepseek:'+$a+'_reconnected') -and -not $_.Active -and -not $_.Paused}).Count -eq 1 -and
         @($state.Tasks | Where-Object {$_.Id -like ('deepseek:'+$b+'_*') -and $_.Active}).Count -eq 254) 'Reconnected A was confirmed or affected healthy B.'
 $scopes.deepseek=@($b);$confirmed.deepseek=@($a)
 Poll-Group
 $scopes.deepseek=@($b,$c);$confirmed=@{}
 Send-Event 'deepseek' ($c+'_one') 'active'
 Poll-Group
 Assert (@($state.Tasks | Where-Object {$_.Id -eq ('deepseek:'+$c+'_one')}).Count -eq 1) 'New fixture C was not observed.'
 $connections.deepseek='partial';$scopes.deepseek=@();$uncertain.deepseek=@($b);$confirmed.deepseek=@($c)
 Poll-Group
 Assert (@($state.Tasks | Where-Object {$_.Id -eq ('deepseek:'+$c+'_one')}).Count -eq 0 -and
         @($state.Tasks | Where-Object {$_.Id -like ('deepseek:'+$b+'_*')}).Count -eq 254) 'Confirmed disconnect was resurrected by fallback or removed B.'
 $connections.deepseek='connected';$scopes.deepseek=@($b);$uncertain.deepseek=@();$confirmed=@{}
 Poll-Group
 Assert ($state.Unavailable -contains 'DeepSeek Harness' -and $state.Unavailable -notcontains 'OpenCode') 'Source loss warning did not persist across recovery.'
 $broken=[IO.Pipes.NamedPipeClientStream]::new('.',$pipe,[IO.Pipes.PipeDirection]::InOut)
 try{$broken.Connect(2000);$broken.WriteByte(1);$broken.Flush()}finally{$broken.Dispose()}
 $deadline=[DateTime]::UtcNow.AddSeconds(3)
 do{if($controller.Channel.DiagnosticCounts -match 'invalid=[1-9]'){break};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
 Assert ($controller.Channel.DiagnosticCounts -match 'invalid=[1-9]') 'The channel did not observe the malformed frame.'
 Poll-Group
 Assert ($state.Unavailable -contains 'DeepSeek Harness' -and $state.Unavailable -contains 'OpenCode' -and
         @($state.Tasks | Where-Object {$_.Active -or $_.Paused}).Count -eq 0) 'An unidentifiable channel loss did not invalidate every affected source.'
 $controller.Channel.Dispose()
 Poll-Group
 Assert ([object]::ReferenceEquals($controller.Store,$originalStore) -and $state.Tasks.Count -eq 255 -and
         $state.Unavailable -contains 'DeepSeek Harness' -and $state.Unavailable -contains 'OpenCode') 'A stopped channel lost its store or hid the shared failure.'
 Poll-Group
 Assert ([object]::ReferenceEquals($controller.Store,$originalStore) -and $null -ne $controller.Channel -and $state.Tasks.Count -eq 255) 'Channel recovery discarded prior evidence.'
 $connections.deepseek='partial';$connections.opencode='partial';$uncertain.deepseek=@($b);$scopes.deepseek=@()
 Poll-Group
 Assert ($null -eq $controller.Channel -and [object]::ReferenceEquals($controller.Store,$originalStore) -and $state.Tasks.Count -eq 255) 'No-channel interval dropped unconfirmed cards.'
 $connections.deepseek='connected';$connections.opencode='connected';$scopes.deepseek=@($b);$uncertain.deepseek=@()
 Poll-Group
 Assert ($state.Tasks.Count -eq 255 -and $state.Unavailable -contains 'DeepSeek Harness' -and $state.Unavailable -contains 'OpenCode') 'Restarted channel hid prior transport uncertainty.'
}finally{Stop-ExternalProviderController $controller -KnownIdle}
'Provider V1 recovery: real group, scoped disconnect, loss and synthetic channel checks passed.'
