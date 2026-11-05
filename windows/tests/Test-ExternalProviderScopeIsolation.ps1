$ErrorActionPreference='Stop'
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
. (Join-Path $appRoot 'integrations/ProviderEventView.ps1')
. (Join-Path $appRoot 'integrations/ProviderRuntime.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $appRoot 'CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Application source could not be parsed.'}
$mapper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Unconfirmed-ExternalTasks'},$true)
. ([scriptblock]::Create($mapper.Extent.Text))
function Assert($value,[string]$message){if(-not $value){throw $message}}
function Send([string]$name,[string]$json){
 $stream=[IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut)
 try{
  $stream.Connect(2000);$bytes=[Text.Encoding]::UTF8.GetBytes($json);$header=[BitConverter]::GetBytes([int]$bytes.Length)
  $stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
  $ack=New-Object byte[] 1;$pending=$stream.BeginRead($ack,0,1,$null,$null)
  if(-not $pending.AsyncWaitHandle.WaitOne(2000) -or $stream.EndRead($pending) -ne 1 -or $ack[0] -ne 6){throw 'Acknowledgement missing.'}
 }finally{$stream.Dispose()}
}
$pipe='AITaskMonitor.Test.'+[Guid]::NewGuid().ToString('N')
$controller=New-ExternalProviderController -PipeName $pipe
$seen=@{};$scopeOne='a'*32;$scopeTwo='b'*32
$connections=@{deepseek='connected';opencode='connected'}
$scopes=@{deepseek=@($scopeOne,$scopeTwo)};$uncertain=@{deepseek=@()}
try{
 $state=Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -ProfileScopes $scopes -UncertainProfileScopes $uncertain
 Send $pipe ('{"version":1,"provider":"deepseek","session":"'+$scopeOne+'_one","kind":"started"}')
 Send $pipe ('{"version":1,"provider":"deepseek","session":"'+$scopeTwo+'_two","kind":"started"}')
 Send $pipe '{"version":1,"provider":"opencode","session":"other","kind":"started"}'
 $state=Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks -ProfileScopes $scopes -UncertainProfileScopes $uncertain
 Assert (@($state.Tasks|Where-Object {$_.Active}).Count -eq 3) 'Both profiles and the other source must be active.'
 $connections.deepseek='connected-degraded';$scopes.deepseek=@($scopeOne);$uncertain.deepseek=@($scopeTwo)
 Send $pipe ('{"version":1,"provider":"deepseek","session":"'+$scopeTwo+'_two","kind":"active"}')
 $state=Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks -ProfileScopes $scopes -UncertainProfileScopes $uncertain
 Assert (@($state.Tasks|Where-Object {$_.Id -eq ('deepseek:'+$scopeOne+'_one') -and $_.Active}).Count -eq 1) 'A healthy profile must remain active.'
 Assert (@($state.Tasks|Where-Object {$_.Id -eq ('deepseek:'+$scopeTwo+'_two') -and -not $_.Active}).Count -eq 1) 'The unavailable profile must become unconfirmed.'
 Assert (@($state.Tasks|Where-Object {$_.Provider -eq 'opencode' -and $_.Active}).Count -eq 1) 'Another provider must remain active.'
 $connections.deepseek='connected';$uncertain.deepseek=@()
 Send $pipe ('{"version":1,"provider":"deepseek","session":"'+$scopeTwo+'_two","kind":"active"}')
 Send $pipe ('{"version":1,"provider":"deepseek","session":"'+$scopeTwo+'_two","kind":"gap"}')
 $state=Read-ExternalProviderGroupSnapshot -Controller $controller -Connections $connections -Seen $seen -PreviousTasks $state.Tasks -ProfileScopes $scopes -UncertainProfileScopes $uncertain
 Assert (@($state.Tasks|Where-Object {$_.Id -eq ('deepseek:'+$scopeTwo+'_two')}).Count -eq 0) 'A disconnected profile must be removed and its late events ignored.'
 Assert (@($state.Tasks|Where-Object {$_.Id -eq ('deepseek:'+$scopeOne+'_one') -and $_.Active}).Count -eq 1) 'A disconnected profile must not invalidate a healthy one.'
 'External profile scopes: failures, disconnects and late events remained isolated.'
}finally{Stop-ExternalProviderController $controller}
