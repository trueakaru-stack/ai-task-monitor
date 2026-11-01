Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

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

function Rotate-EventLog([string]$path) {
 if(-not (Test-Path -LiteralPath $path)){return}
 $file=Get-Item -LiteralPath $path
 if($file.Length -le 8388608){return}
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{
  $bytes=[Math]::Min([long]4194304,$stream.Length)
  [void]$stream.Seek(-$bytes,[IO.SeekOrigin]::End)
  $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true,4096,$true)
  try{$tail=$reader.ReadToEnd()}finally{$reader.Dispose()}
 }finally{$stream.Dispose()}
 $newline=$tail.IndexOf("`n")
 if($newline -ge 0){$tail=$tail.Substring($newline+1)}
 [IO.File]::WriteAllText($path,$tail,[Text.UTF8Encoding]::new($false))
}

try {
 $raw=[Console]::In.ReadToEnd()
 if(-not $raw){exit 0}
 if($raw.Length -gt 1048576){exit 0}
 $inputEvent=$raw|ConvertFrom-Json
 $eventName=[string](Value $inputEvent "hook_event_name" "Unknown")
 $toolInput=Value $inputEvent "tool_input"
 $taskId=[string](Value $inputEvent "task_id" (Value $toolInput "taskId" (Value $toolInput "task_id" "")))
 $taskStatus=[string](Value $toolInput "status" "")
 $subject=Clip ([string](Value $inputEvent "task_subject" (Value $toolInput "subject" ""))) 240
 $toolName=Clip ([string](Value $inputEvent "tool_name" "")) 120
 $prompt=Clip ([string](Value $inputEvent "prompt" "")) 240
 $activity=switch($eventName){
  "UserPromptSubmit" {if($prompt){$prompt}else{"New request"}}
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
  cwd=Clip ([string](Value $inputEvent "cwd" "")) 1024
  prompt=$prompt
  activity=$activity
  task_id=$taskId
  task_subject=$subject
  task_status=$taskStatus
  tool_name=$toolName
 }
 $dataDirectory=Join-Path $env:LOCALAPPDATA "CodexTaskProgress"
 [IO.Directory]::CreateDirectory($dataDirectory)|Out-Null
 $eventPath=Join-Path $dataDirectory "claude-events.jsonl"
 $line=($record|ConvertTo-Json -Compress -Depth 8)+[Environment]::NewLine
 $mutex=New-Object Threading.Mutex($false,"Local\CodexTasksClaudeEvents")
 try{
  if($mutex.WaitOne(5000)){Rotate-EventLog $eventPath;[IO.File]::AppendAllText($eventPath,$line,[Text.UTF8Encoding]::new($false))}
 }finally{try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
}catch{
 if($env:AI_TASK_MONITOR_AUDIT -eq "1"){[Console]::Error.WriteLine($_.Exception.ToString());exit 1}
 exit 0
}

