param([string]$LoopTestPipe="",[string]$LogTestMutex="")
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$loopClientAvailable=$false
try{. (Join-Path $PSScriptRoot "ClaudeLoopClient.ps1");$loopClientAvailable=$true}catch{}
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
 if($maximumBytes -le 0){return}
 Assert-EventPathSafe $path
 if(-not (Test-Path -LiteralPath $path)){return}
 $file=Get-Item -LiteralPath $path
 if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing to rotate a linked event log.'}
 if($file.Length -le $maximumBytes){return}
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
}

try {
 $inputBuffer=New-Object char[] 4096
 $inputBuilder=New-Object Text.StringBuilder
 while(($inputCount=[Console]::In.Read($inputBuffer,0,$inputBuffer.Length)) -gt 0){
  if($inputBuilder.Length+$inputCount -gt 1048576){exit 0}
  [void]$inputBuilder.Append($inputBuffer,0,$inputCount)
 }
 $raw=$inputBuilder.ToString()
 if(-not $raw){exit 0}
 $inputEvent=$raw|ConvertFrom-Json
 $eventName=[string](Value $inputEvent "hook_event_name" "Unknown")
 $toolInput=Value $inputEvent "tool_input"
 $taskId=[string](Value $inputEvent "task_id" (Value $toolInput "taskId" (Value $toolInput "task_id" "")))
 $taskStatus=[string](Value $toolInput "status" "")
 $subject=Clip ([string](Value $inputEvent "task_subject" (Value $toolInput "subject" ""))) 240
 $toolName=Clip ([string](Value $inputEvent "tool_name" "")) 120
 $activity=switch($eventName){
  "UserPromptSubmit" {"New request"}
  "PreToolUse" {if($toolName){"Running: $toolName"}else{"Running tool"}}
  "PostToolUse" {if($toolName){"Completed: $toolName"}else{"Tool completed"}}
  "PostToolUseFailure" {if($toolName){"Failed: $toolName"}else{"Tool failed"}}
  "TaskCreated" {if($subject){"Added step: $subject"}else{"Added step"}}
  "TaskCompleted" {if($subject){"Completed step: $subject"}else{"Step completed"}}
  "SubagentStart" {"Subagent started"}
  "SubagentStop" {"Subagent stopped"}
  "Stop" {"Waiting for the next request"}
  "SessionEnd" {"Session ended"}
  default {$eventName}
 }
 $active=$eventName -notin @("Stop","SessionEnd","StopFailure")
 $record=[ordered]@{
  timestamp=[DateTime]::UtcNow.ToString("o")
  provider="claude"
  session_id=[string](Value $inputEvent "session_id" "")
  event=$eventName
  active=$active
  activity=$activity
  task_id=$taskId
  task_subject=$subject
  task_status=$taskStatus
  tool_name=$toolName
 }
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
   Rotate-EventLog $eventPath (Event-SizeLimit $dataDirectory)
   [IO.File]::AppendAllText($eventPath,$line,[Text.UTF8Encoding]::new($false));$written=$true
  }
 }finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
 if($written -and $loopClientAvailable){Send-ClaudeLoopEvent $inputEvent $LoopTestPipe}
}catch{
 if($env:AI_TASK_MONITOR_AUDIT -eq "1"){[Console]::Error.WriteLine($_.Exception.ToString());exit 1}
 exit 0
}

