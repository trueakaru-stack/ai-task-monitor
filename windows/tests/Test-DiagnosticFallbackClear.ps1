$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'The synthetic clear handler requires STA.'}
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$priorProfile=[Environment]::GetEnvironmentVariable('USERPROFILE','Process');$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -AssemblyName PresentationFramework
Add-Type -Path (Join-Path $app 'LocalReadOwner.cs')
foreach($name in @('DiagnosticPolicy.ps1','DiagnosticStore.ps1','LoopDetection.ps1','DiagnosticCollector.ps1','DiagnosticRuntime.ps1','DiagnosticClient.ps1')){. (Join-Path $app $name)}
function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Update-JournalSettings {}
function Failure([string]$id,[DateTimeOffset]$time){return @{timestamp=$time.ToString('o');type='event_msg';payload=@{type='item_completed';item=@{type='CommandExecution';id=$id;status='failed';exit_code=1;command=@('synthetic-tool');cwd='synthetic'}}}|ConvertTo-Json -Depth 8 -Compress}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
Require ($errors.Count -eq 0) 'The production clear handler could not be parsed.'
$start=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Start-DiagnosticClient'},$true)
$actions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $node.Expression.VariablePath.UserPath -ceq 'journalConfirmClearButton' -and [string]$node.Member.Value -ceq 'Add_Click'},$true))
Require ($null -ne $start -and $actions.Count -eq 1 -and $actions[0].Arguments.Count -eq 1) 'The production fallback clear path could not be identified.'
$startText=$start.Extent.Text;$needle='Join-Path $PSScriptRoot ''DiagnosticWorker.ps1'''
Require ($startText.Contains($needle)) 'The synthetic diagnostic worker path could not be isolated.'
. ([scriptblock]::Create($startText.Replace($needle,'$script:syntheticDiagnosticWorker')))
$body=$actions[0].Arguments[0].ScriptBlock.Extent.Text.Trim();if($body.StartsWith('{') -and $body.EndsWith('}')){$body=$body.Substring(1,$body.Length-2)}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-clear-fallback-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic fallback directory.'
if([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)){throw 'The synthetic fallback directory already exists.'}
[void][IO.Directory]::CreateDirectory($root);$script:diagnosticClient=$null
try{
 $script:syntheticDiagnosticWorker=Join-Path $app 'DiagnosticWorker.ps1'
 foreach($mode in @('existing-runtime','missing-runtime')){
  $fixture=Join-Path $root $mode;$codexHome=Join-Path $fixture 'codex';$sessions=Join-Path $codexHome 'sessions';$profile=Join-Path $fixture 'profile';$dataDirectory=Join-Path $fixture 'data';$script:diagnosticDirectory=Join-Path $fixture 'journal'
  foreach($path in @($sessions,$profile,$dataDirectory,$script:diagnosticDirectory)){[void][IO.Directory]::CreateDirectory($path)}
  Require ([IO.Path]::GetFullPath($profile).StartsWith(($root.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic profile.'
  [Environment]::SetEnvironmentVariable('USERPROFILE',$profile,'Process')
  $now=[DateTimeOffset]::UtcNow;$script:monitorStartedUtc=$now.AddMinutes(-1).UtcDateTime;$utf8=[Text.UTF8Encoding]::new($false)
  $id='60000000-0000-0000-0000-000000000001';$rollout=Join-Path $sessions ('rollout-2026-11-24T12-00-00-'+$id+'.jsonl')
  [IO.File]::WriteAllText($rollout,((Failure 'before-clear' $now.AddSeconds(-10))+[Environment]::NewLine),$utf8)
  $script:diagnosticClient=$null;$script:diagnosticError='';$script:journalUiError='';$script:journalFingerprint=''
  if($mode -ceq 'existing-runtime'){
   $script:diagnosticRuntime=New-DiagnosticRuntime -Directory $script:diagnosticDirectory -Since $now.AddMinutes(-1) -Now $now
   $old=[PSCustomObject]@{version=1;time=$now.ToString('o');source='codex';task=('a'*64);type='tool_started';id=('b'*64)}
   Write-DiagnosticEvent -Directory $script:diagnosticDirectory -Event $old -Now $now
  }else{
   $script:diagnosticRuntime=$null
   [IO.File]::WriteAllText((Join-Path $script:diagnosticDirectory 'diagnostic-events-v1.jsonl'),($script:DiagnosticHeader+[Environment]::NewLine+'{"malformed":true}'+[Environment]::NewLine),$utf8)
  }
  $journalConfirmClearButton=[Windows.Controls.Button]::new();$journalClearConfirmation=[Windows.Controls.Border]::new()
  $journalConfirmClearButton.Add_Click([Windows.RoutedEventHandler]([scriptblock]::Create($body)))
  $before=[DateTimeOffset]::UtcNow
  $journalConfirmClearButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Require ($null -ne $script:diagnosticRuntime -and $null -ne $script:diagnosticClient -and
   $script:diagnosticRuntime.Since -ge $before -and -not $script:journalUiError) ('The synthetic fallback did not retain the clear boundary: '+$mode)
  $task=[PSCustomObject]@{Provider='codex';Id=$id;State='active'};$clock=[Diagnostics.Stopwatch]::StartNew()
  do{Get-DiagnosticClientUpdate $script:diagnosticClient @($task) @();if($script:diagnosticClient.Fresh){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
  Require ($script:diagnosticClient.Fresh -and -not $script:diagnosticClient.Error) ('The synthetic fallback worker did not start: '+$mode)
  $events=@(Read-DiagnosticEvents -Directory $script:diagnosticDirectory -Now ([DateTimeOffset]::UtcNow))
  Require (@($events|Where-Object {$_.type -ceq 'tool_failed'}).Count -eq 0) ('A pre-clear event returned through the synthetic fallback: '+$mode)
  [IO.File]::AppendAllText($rollout,((Failure 'after-clear' ([DateTimeOffset]::UtcNow))+[Environment]::NewLine),$utf8)
  $clock.Restart();do{Get-DiagnosticClientUpdate $script:diagnosticClient @($task) @();Start-Sleep -Milliseconds 10;$events=@(Read-DiagnosticEvents -Directory $script:diagnosticDirectory -Now ([DateTimeOffset]::UtcNow))}while(@($events|Where-Object {$_.type -ceq 'tool_failed'}).Count -eq 0 -and $clock.ElapsedMilliseconds -lt 15000)
  Require (@($events|Where-Object {$_.type -ceq 'tool_failed'}).Count -eq 1) ('A new event was lost after the synthetic fallback: '+$mode)
  $owner=$script:diagnosticClient.Owner;$owner.Dispose();$clock.Restart();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
  Require $owner.CanReplace 'The synthetic fallback owner did not stop.';$script:diagnosticClient=$null
 }
 Write-Output 'Production fallback clear: existing and recovered runtime pass the clear boundary to a new worker.'
}finally{
 try{
  if($null -ne $script:diagnosticClient -and $null -ne $script:diagnosticClient.Owner){$owner=$script:diagnosticClient.Owner;$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic fallback owner did not stop.'}}
  $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
  if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic fallback cleanup.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }finally{
  [Environment]::SetEnvironmentVariable('USERPROFILE',$priorProfile,'Process')
  if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
 }
}
