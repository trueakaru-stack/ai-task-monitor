$ErrorActionPreference='Stop'
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
$setupSource=Join-Path $appRoot 'Configure-ClaudeIntegration.ps1'
$sourceText=[IO.File]::ReadAllText($setupSource)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($setupSource,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The Claude setup script did not parse.'}
$patches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '*namespace AITaskMonitor.LegacyClaude*'},$true))
Require ($patches.Count -eq 1) 'The existing Claude settings transformer was not identified uniquely.'
Add-Type -TypeDefinition $patches[0].Value -ReferencedAssemblies 'System.Core.dll'
. (Join-Path $appRoot 'ClaudeReaderCore.ps1')

$hookPath=Join-Path $appRoot 'ClaudeTaskHook.ps1'
$literal="'"+$hookPath.Replace("'","''")+"'"
$prefix='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '
$legacy=$prefix+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('& '+$literal))
$older='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$hookPath+'"'
$connectionId=[Guid]::NewGuid().ToString('N')
$current=$prefix+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(('& '+$literal+" -ConnectionId '"+$connectionId+"'")))
$events=[string[]]@('PreToolUse')
$fixture=@{unrelated=@{number=42};hooks=@{
 PreToolUse=@(@{matcher='Read';hooks=@(@{type='command';command='echo foreign'},@{type='command';command=$legacy},@{type='command';command=$older})})
 FutureHook=@(@{hooks=@(@{type='command';command='echo future'})})
}}|ConvertTo-Json -Depth 20 -Compress

# Applying two pure transforms before one write can migrate both old forms;
# foreign commands and an unknown event remain intact in this fixture.
$first=[AITaskMonitor.LegacyClaude.ClaudeConfigRawPatch]::Apply($fixture,$current,$legacy,$true,$events)
$second=[AITaskMonitor.LegacyClaude.ClaudeConfigRawPatch]::Apply($first.Json,$current,$older,$true,$events)
$installed=$second.Json|ConvertFrom-Json
$commands=@($installed.hooks.PreToolUse|ForEach-Object {$_.hooks}|ForEach-Object {[string]$_.command})
Require (@($commands|Where-Object {$_ -ceq $current}).Count -eq 1 -and
 @($commands|Where-Object {$_ -ceq $legacy -or $_ -ceq $older}).Count -eq 0 -and
 @($commands|Where-Object {$_ -ceq 'echo foreign'}).Count -eq 1 -and
 $installed.unrelated.number -eq 42 -and $installed.hooks.FutureHook[0].hooks[0].command -ceq 'echo future') 'The synthetic migration changed foreign settings or left an old command.'
$removed=[AITaskMonitor.LegacyClaude.ClaudeConfigRawPatch]::Apply($second.Json,$current,$legacy,$false,$events)
$afterRemove=$removed.Json|ConvertFrom-Json
$remaining=@($afterRemove.hooks.PreToolUse|ForEach-Object {$_.hooks}|ForEach-Object {[string]$_.command})
Require ($remaining.Count -eq 1 -and $remaining[0] -ceq 'echo foreign' -and $afterRemove.hooks.FutureHook[0].hooks[0].command -ceq 'echo future') 'The synthetic rollback changed a foreign hook.'

# An old monitor does not recognise the new command. Its install adds its own
# legacy command, while its remove leaves the new one behind.
$oldInstall=[AITaskMonitor.LegacyClaude.ClaudeConfigRawPatch]::Apply($second.Json,$legacy,$older,$true,$events)
$oldCommands=@(($oldInstall.Json|ConvertFrom-Json).hooks.PreToolUse|ForEach-Object {$_.hooks}|ForEach-Object {[string]$_.command})
Require (@($oldCommands|Where-Object {$_ -ceq $legacy}).Count -eq 1 -and @($oldCommands|Where-Object {$_ -ceq $current}).Count -eq 1) 'The old-version incompatibility was not reproduced.'
$oldRemove=[AITaskMonitor.LegacyClaude.ClaudeConfigRawPatch]::Apply($oldInstall.Json,$legacy,$older,$false,$events)
$oldRemaining=@(($oldRemove.Json|ConvertFrom-Json).hooks.PreToolUse|ForEach-Object {$_.hooks}|ForEach-Object {[string]$_.command})
Require (@($oldRemaining|Where-Object {$_ -ceq $legacy}).Count -eq 0 -and @($oldRemaining|Where-Object {$_ -ceq $current}).Count -eq 1) 'The old-version removal incompatibility was not reproduced.'

# The existing reader ignores the proposed extra field. A late stop from the
# old connection can therefore hide a task observed in the new connection.
$now=[DateTime]::UtcNow
function New-Record([string]$id,[string]$event,[DateTime]$time,[bool]$active,[string]$generation,[string]$phase=''){
 $item=@{timestamp=$time.ToString('o');session_id=$id;event=$event;active=$active;connection_id=$generation}
 if($phase){$item.stage_phase=$phase;$item.stage_version=1}
 return $item
}
$oldId=[Guid]::NewGuid().ToString('N')
$newStart=New-Record 'synthetic-session' 'UserPromptSubmit' $now.AddSeconds(-2) $true $connectionId
$lateOldStop=New-Record 'synthetic-session' 'Stop' $now.AddSeconds(-1) $false $oldId 'stop_clear'
$mixed=@($newStart,$lateOldStop)|ForEach-Object {$_|ConvertTo-Json -Compress}
$mixedResult=@([AITaskMonitor.Claude.Reader]::Read(($mixed -join "`n"),'',$now,$now.AddSeconds(-3)))
Require ($mixedResult.Count -eq 0) 'The old reader did not reproduce cross-generation event mixing.'
$onlyCurrent=($newStart|ConvertTo-Json -Compress)
$newResult=@([AITaskMonitor.Claude.Reader]::Read($onlyCurrent,'',$now,$now.AddSeconds(-3)))
Require ($newResult.Count -eq 1 -and -not $newResult[0].Unconfirmed) 'A synthetic event for the current generation was not observable.'

# Run an instrumented copy of the existing installer against fixture files.
# The hook is not invoked and no user profile or real settings are read.
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-claude-epoch-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture root.'
[void][IO.Directory]::CreateDirectory((Join-Path $root '.claude'))
$settings=Join-Path $root '.claude\settings.json'
$exe=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
$initial='{"unrelated":"original","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo foreign"}]}]}}'
$concurrent='{"unrelated":"original","concurrent":"keep","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo foreign"}]}]}}'
$waitCode=@'
[IO.File]::WriteAllText($env:AITM_SYNTHETIC_READY,'ready')
$probeClock=[Diagnostics.Stopwatch]::StartNew()
while(-not [IO.File]::Exists($env:AITM_SYNTHETIC_CONTINUE) -and $probeClock.ElapsedMilliseconds -lt 15000){Start-Sleep -Milliseconds 10}
if(-not [IO.File]::Exists($env:AITM_SYNTHETIC_CONTINUE)){throw 'Synthetic probe timed out.'}
if($env:AITM_SYNTHETIC_FAIL -eq '1'){throw 'Synthetic failure before replacement.'}
'@
$beforeCheck='  if(-not [string]::Equals($verifiedWritePath,$settingsWritePath,[StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $verifiedWritePath -Algorithm SHA256).Hash -cne $originalHash){throw "Claude Code settings changed during the update; no changes were made."}'
$beforeReplace='  [IO.File]::Replace($temporaryPath,$settingsWritePath,[System.Management.Automation.Language.NullString]::Value)'
Require ($sourceText.Contains($beforeCheck) -and $sourceText.Contains($beforeReplace)) 'The known settings replacement sequence changed.'
function Invoke-Fixture([string]$name,[string]$needle,[bool]$change,[bool]$fail,[int]$expectedExit){
 $ready=Join-Path $root ($name+'.ready');$continue=Join-Path $root ($name+'.continue')
 $scriptPath=Join-Path $root ($name+'.ps1')
 [IO.File]::WriteAllText($settings,$initial,[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText($scriptPath,($sourceText.Replace($needle,($waitCode+"`r`n"+$needle))),[Text.UTF8Encoding]::new($false))
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe
 $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$scriptPath+'" -Mode Install'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.EnvironmentVariables['USERPROFILE']=$root;$start.EnvironmentVariables['LOCALAPPDATA']=$root
 $start.EnvironmentVariables['AITM_SYNTHETIC_READY']=$ready;$start.EnvironmentVariables['AITM_SYNTHETIC_CONTINUE']=$continue
 $start.EnvironmentVariables['AITM_SYNTHETIC_FAIL']=if($fail){'1'}else{'0'}
 $child=[Diagnostics.Process]::Start($start)
 try {
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not [IO.File]::Exists($ready) -and -not $child.HasExited -and $clock.ElapsedMilliseconds -lt 15000){Start-Sleep -Milliseconds 10}
  Require ([IO.File]::Exists($ready)) 'The synthetic setup did not reach its synchronization point.'
  for($i=0;$i -lt 50;$i++){Require ([IO.File]::ReadAllText($settings) -ceq $initial) 'An unfinished synthetic update changed the target.'}
  if($change){[IO.File]::WriteAllText($settings,$concurrent,[Text.UTF8Encoding]::new($false))}
  [IO.File]::WriteAllText($continue,'continue')
  if(-not $child.WaitForExit(15000)){throw 'The synthetic setup did not exit.'}
  Require ($child.ExitCode -eq $expectedExit) 'The synthetic setup returned an unexpected result.'
  $result=[IO.File]::ReadAllText($settings)
  [void]($result|ConvertFrom-Json -ErrorAction Stop)
  Require (@(Get-ChildItem -LiteralPath (Join-Path $root '.claude') -Force -Filter '.ai-task-monitor-settings-*.tmp').Count -eq 0) 'A synthetic temporary file was left behind.'
  return $result
 } finally {
  if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)}
  $child.Dispose()
 }
}
function Invoke-SyntheticHook([string]$path,[string]$id,[string]$mutexName) {
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe
 $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$path+'" -LogTestMutex "'+$mutexName+'"'
 if($id){$start.Arguments+=' -ConnectionId '+$id}
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.EnvironmentVariables['USERPROFILE']=$root;$start.EnvironmentVariables['LOCALAPPDATA']=$root
 $start.EnvironmentVariables['AI_TASK_MONITOR_AUDIT']='1'
 $child=[Diagnostics.Process]::Start($start)
 try{
  $output=$child.StandardOutput.ReadToEndAsync();$errorOutput=$child.StandardError.ReadToEndAsync()
  $child.StandardInput.WriteLine('{"hook_event_name":"UserPromptSubmit","session_id":"synthetic-session"}')
  $child.StandardInput.Close()
  if(-not $child.WaitForExit(15000)){throw 'The synthetic hook did not exit.'}
  Require ($child.ExitCode -eq 0) 'The synthetic hook failed.'
 }finally{
  if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)}
  $child.Dispose()
 }
}
try{
 # Prototype only: instrument a copy of the actual hook and send it two
 # synthetic inputs. No installed script, profile or configuration is touched.
 $hookDirectory=Join-Path $root 'hook';[void][IO.Directory]::CreateDirectory($hookDirectory)
 $hookFixture=Join-Path $hookDirectory 'ClaudeTaskHook.ps1'
 $hookText=[IO.File]::ReadAllText($hookPath)
 $oldParameters='param([string]$LoopTestPipe="",[string]$LogTestMutex="")'
 $newParameters='param([string]$LoopTestPipe="",[string]$LogTestMutex="",[string]$ConnectionId="")'
 $recordPoint=' if($stagePhase){$record.stage_phase=$stagePhase;$record.stage_version=1}'
 Require ($hookText.Contains($oldParameters) -and $hookText.Contains($recordPoint)) 'The known hook fixture points changed.'
 $withParameter=$hookText.Replace($oldParameters,$newParameters)
 $recordGeneration=' if($ConnectionId -cmatch ''^[0-9a-f]{32}$''){$record.connection_id=$ConnectionId}'
 $withGeneration=$withParameter.Replace($recordPoint,($recordGeneration+[Environment]::NewLine+$recordPoint))
 [IO.File]::WriteAllText($hookFixture,$withGeneration,[Text.UTF8Encoding]::new($false))
 Add-Type -Path (Join-Path $appRoot 'ClaudeStageObservation.cs') -ReferencedAssemblies 'System.Web.Extensions' -OutputAssembly (Join-Path $hookDirectory 'ClaudeStageObservation.dll')
 $mutexName='AITM.Test.'+[Guid]::NewGuid().ToString('N')
 Invoke-SyntheticHook $hookFixture '' $mutexName
 Invoke-SyntheticHook $hookFixture $connectionId $mutexName
 $eventFile=Join-Path $root 'CodexTaskProgress\claude-events-v2.jsonl'
 $hookRecords=@([IO.File]::ReadAllLines($eventFile)|ForEach-Object {$_|ConvertFrom-Json})
 Require ($hookRecords.Count -eq 2 -and $null -eq $hookRecords[0].PSObject.Properties['connection_id'] -and
  $hookRecords[1].connection_id -ceq $connectionId -and $hookRecords[0].event -ceq 'UserPromptSubmit' -and
  $hookRecords[1].event -ceq 'UserPromptSubmit') 'The synthetic legacy and generation-tagged hook records were not separated.'

 $success=Invoke-Fixture 'successful' $beforeReplace $false $false 0
 Require (($success|ConvertFrom-Json).unrelated -ceq 'original') 'The synthetic atomic replacement lost unrelated settings.'
 $changedBeforeCheck=Invoke-Fixture 'before-check' $beforeCheck $true $false 1
 Require ($changedBeforeCheck -ceq $concurrent) 'An update made before verification was not preserved.'
 $changedAfterCheck=Invoke-Fixture 'after-check' $beforeReplace $true $false 0
 Require ($changedAfterCheck -cne $concurrent -and $null -eq ($changedAfterCheck|ConvertFrom-Json).PSObject.Properties['concurrent']) 'The post-check concurrency gap was not reproduced.'
 $failed=Invoke-Fixture 'failed' $beforeReplace $false $true 1
 Require ($failed -ceq $initial) 'A failure before replacement changed the synthetic settings.'
}finally{
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup target.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output 'Synthetic connection-ID feasibility: modified hook copy emits a generation tag and accepts legacy invocation; foreign hooks and rollback retained; old-version incompatibility and a post-verification concurrent-write race reproduced; pre-verification changes and failed replacement preserved.'
