param([string]$LoopTestPipe="",[string]$LogTestMutex="")
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$loopClientAvailable=$false
try{. (Join-Path $PSScriptRoot "ClaudeLoopClient.ps1");$loopClientAvailable=$true}catch{}
$stageHelperAvailable=$false
try{
 Add-Type -Path (Join-Path $PSScriptRoot 'ClaudeStageObservation.dll') -ErrorAction Stop
 $stageHelperAvailable=$true
}catch{}
$utf8InputAvailable=$false
try{[Console]::InputEncoding=[Text.UTF8Encoding]::new($false,$true);$utf8InputAvailable=$true}catch{}
if($LoopTestPipe -and $env:AI_TASK_MONITOR_AUDIT -ne "1"){exit 0}
if($LogTestMutex -and ($env:AI_TASK_MONITOR_AUDIT -ne "1" -or $LogTestMutex -cnotmatch '^AITM\.Test\.[A-Za-z0-9_.-]{1,100}$')){exit 0}

function Value($object,[string]$name,$fallback=$null) {
 if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name}
 return $fallback
}

function Clip([string]$value,[int]$limit) {
 if(-not $value){return ""}
 $clean=[regex]::Replace($value,'\s+',' ').Trim()
 if($clean.Length -le $limit){return $clean}
 return $clean.Substring(0,$limit-3)+"..."
}

function Event-SizeLimit([string]$directory) {
 $maximum=10
 try{
  $settingsPath=Join-Path $directory 'settings.json'
  if(Test-Path -LiteralPath $settingsPath -PathType Leaf){
   $settings=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
   if($null -eq $settings -or $settings -isnot [PSCustomObject]){return 0}
   if($null -ne $settings.PSObject.Properties['claudeMaximumMB'] -and (-not [int]::TryParse([string]$settings.claudeMaximumMB,[ref]$maximum) -or $maximum -lt 1 -or $maximum -gt 100)){return 0}
  }
  return [long]$maximum*1000000
 }catch{return 0}
}

function Assert-EventPathSafe([string]$path) {
 try{$attributes=[IO.File]::GetAttributes($path)}
 catch [IO.FileNotFoundException]{return}
 catch [IO.DirectoryNotFoundException]{return}
 if(($attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -ne 0){throw 'Refusing to use a linked or non-file event log.'}
}

function Rotate-EventLog([string]$path,[long]$maximumBytes) {
 if($maximumBytes -le 0){return $false}
 Assert-EventPathSafe $path
 if(-not (Test-Path -LiteralPath $path)){return $false}
 $file=Get-Item -LiteralPath $path
 if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing to rotate a linked event log.'}
 if($file.Length -le $maximumBytes){return $false}
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{
  $bytes=[Math]::Min([long]($maximumBytes*0.9),$stream.Length)
  [void]$stream.Seek(-$bytes,[IO.SeekOrigin]::End)
  $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true,4096,$true)
  try{$tail=$reader.ReadToEnd()}finally{$reader.Dispose()}
 }finally{$stream.Dispose()}
 $newline=$tail.IndexOf("`n")
 if($newline -ge 0){$tail=$tail.Substring($newline+1)}
 $temporaryPath=Join-Path (Split-Path -Parent $path) ('.aitm-hook-retention-'+[Guid]::NewGuid().ToString('N')+'.tmp')
 try{
  [IO.File]::WriteAllText($temporaryPath,$tail,[Text.UTF8Encoding]::new($false))
  [IO.File]::Replace($temporaryPath,$path,[System.Management.Automation.Language.NullString]::Value)
 }finally{if([IO.File]::Exists($temporaryPath)){[IO.File]::Delete($temporaryPath)}}
 return $true
}

try {
 $inputBuffer=New-Object char[] 4096
 $inputBuilder=New-Object Text.StringBuilder
 $tooLarge=$false;$invalidInput=$false
 while($true){
  try{$inputCount=[Console]::In.Read($inputBuffer,0,$inputBuffer.Length)}catch{$invalidInput=$true;break}
  if($inputCount -le 0){break}
  if($inputBuilder.Length+$inputCount -gt 1048576){$tooLarge=$true;break}
  [void]$inputBuilder.Append($inputBuffer,0,$inputCount)
 }
 $raw=$inputBuilder.ToString()
 $inputEvent=$null;$observation=$null
 if($stageHelperAvailable -and $utf8InputAvailable -and -not $tooLarge -and -not $invalidInput -and $raw){
  try{$observation=[AITaskMonitor.ClaudePhase.StageObservation]::Assess($raw)}catch{}
 }
 if($null -ne $observation -and $observation.ValidInput){
  $eventName=$observation.Event;$sessionId=$observation.Session
  $taskId=$observation.TaskId;$taskStatus=$observation.Status
  $subject=Clip $observation.Subject 240;$toolName=Clip $observation.Tool 120
  $stagePhase=$observation.Phase;$previousStatus=$observation.Previous
  if($loopClientAvailable){try{$inputEvent=$raw|ConvertFrom-Json -ErrorAction Stop}catch{$inputEvent=$null}}
 }else{
  $eventName='Unknown';$sessionId='';$taskId='';$taskStatus='';$subject='';$toolName=''
  $stagePhase='source_uncertain';$previousStatus=''
 }
 if($stagePhase -eq 'step_uncertain'){
  $stagePhase=if($eventName -ceq 'TaskCreated'){'created_notice'}else{'completed_notice'}
  $eventName='StageNotice'
 }
 $stageTaskId=''
 if($stagePhase -in @('created_notice','completed_notice','update_attempt','update_failure','update_unknown')){$stageTaskId=$taskId;$taskId=''}
 $requestedStatus=''
 if($stagePhase -in @('update_attempt','update_failure','update_unknown')){$requestedStatus=$taskStatus;$taskStatus=''}
 $activity=switch($eventName){
  "UserPromptSubmit" {"New request"}
  "PreToolUse" {if($toolName){"Running: $toolName"}else{"Running tool"}}
  "PostToolUse" {if($stagePhase -in @('create_unknown','update_unknown')){"Status unconfirmed"}elseif($toolName){"Completed: $toolName"}else{"Tool completed"}}
  "PostToolUseFailure" {if($toolName){"Failed: $toolName"}else{"Tool failed"}}
  "StageNotice" {"Running an action"}
  "SubagentStart" {"Subagent started"}
  "SubagentStop" {"Subagent stopped"}
  "Stop" {"Waiting for the next request"}
  "SessionEnd" {"Session ended"}
  default {$eventName}
 }
 $active=if($stagePhase -in @('source_uncertain','session_uncertain','stop_uncertain','stop_failure')){$null}else{$eventName -notin @("Stop","SessionEnd","StopFailure")}
 $record=[ordered]@{
  timestamp=[DateTime]::UtcNow.ToString("o")
  provider="claude"
  session_id=$sessionId
  event=$eventName
  active=$active
  activity=$activity
  task_id=$taskId
  task_subject=$subject
  task_status=$taskStatus
  tool_name=$toolName
 }
 if($stagePhase){$record.stage_phase=$stagePhase;$record.stage_version=1}
 if($previousStatus){$record.stage_previous_status=$previousStatus}
 if($requestedStatus){$record.stage_requested_status=$requestedStatus}
 if($stageTaskId){$record.stage_task_id=$stageTaskId}
 $dataDirectory=if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'store-channel.marker') -PathType Leaf){Join-Path $env:USERPROFILE '.ai-task-monitor'}else{Join-Path $env:LOCALAPPDATA "CodexTaskProgress"}
 [IO.Directory]::CreateDirectory($dataDirectory)|Out-Null
 $eventPath=Join-Path $dataDirectory "claude-events-v2.jsonl"
 $line=($record|ConvertTo-Json -Compress -Depth 8)+[Environment]::NewLine
 $mutexName=if($LogTestMutex){"Local\"+$LogTestMutex}else{"Local\CodexTasksClaudeEvents"}
 $mutex=New-Object Threading.Mutex($false,$mutexName)
 $written=$false
 try{
  if($mutex.WaitOne(2000)){
   Assert-EventPathSafe $eventPath
   $rotated=Rotate-EventLog $eventPath (Event-SizeLimit $dataDirectory)
   if($rotated){
    $marker=[ordered]@{timestamp=[DateTime]::UtcNow.ToString('o');provider='claude';session_id='';event='Unknown';active=$null;activity='';task_id='';task_subject='';task_status='';tool_name='';stage_phase='source_uncertain';stage_version=1}
    [IO.File]::AppendAllText($eventPath,(($marker|ConvertTo-Json -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
   }
   [IO.File]::AppendAllText($eventPath,$line,[Text.UTF8Encoding]::new($false));$written=$true
  }
 }finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
 if($written -and $loopClientAvailable -and $null -ne $inputEvent){Send-ClaudeLoopEvent $inputEvent $LoopTestPipe}
}catch{
 if($env:AI_TASK_MONITOR_AUDIT -eq "1"){[Console]::Error.WriteLine($_.Exception.ToString());exit 1}
 exit 0
}

