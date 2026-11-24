# Local source functions staged for a shared production module. Do not load alongside divergent copies.
. (Join-Path $PSScriptRoot 'CodexAgentRetention.ps1')
. (Join-Path $PSScriptRoot 'CodexAgentRetentionAdapter.ps1')
function Initialize-LocalSourceReader {
 param(
  [Parameter(Mandatory=$true)][string]$CodexHome,
  [Parameter(Mandatory=$true)][string]$ProfileRoot,
  [Parameter(Mandatory=$true)][string]$DataDirectory,
  [Parameter(Mandatory=$true)][DateTime]$MonitorStartedUtc,
  [string]$ProgressFile='',
  [string]$ClaudeEventFile=''
 )
 if($null -ne (Get-Variable -Scope Script -Name localSourceInitialized -ErrorAction SilentlyContinue) -and $script:localSourceInitialized){throw 'The local source reader is already initialized.'}
 foreach($value in @($CodexHome,$ProfileRoot,$DataDirectory)){if(-not [IO.Path]::IsPathRooted($value)){throw 'The local source path is not absolute.'}}
 if($ProgressFile -and -not [IO.Path]::IsPathRooted($ProgressFile)){throw 'The progress path is not absolute.'}
 if($ClaudeEventFile -and -not [IO.Path]::IsPathRooted($ClaudeEventFile)){throw 'The Claude event path is not absolute.'}
 $script:codexHome=[IO.Path]::GetFullPath($CodexHome)
 $script:localSourceProfileRoot=[IO.Path]::GetFullPath($ProfileRoot)
 $script:dataDirectory=[IO.Path]::GetFullPath($DataDirectory)
 $script:sessionIndex=Join-Path $script:codexHome 'session_index.jsonl'
 $script:sessionsDirectory=Join-Path $script:codexHome 'sessions'
 $script:lockDirectory=Join-Path $script:codexHome 'thread-writer-locks'
 $script:ProgressFile=$ProgressFile;$script:ClaudeEventFile=$ClaudeEventFile
 $script:claudeEventPath=if($ClaudeEventFile){$ClaudeEventFile}else{Join-Path $script:dataDirectory 'claude-events-v2.jsonl'}
 $script:claudeLegacyEventPath=if($ClaudeEventFile){''}else{Join-Path $script:dataDirectory 'claude-events.jsonl'}
 $script:sessionFiles=@{};$script:sessionDates=[hashtable]::Synchronized(@{})
 $script:sessionDiscovery=[PSCustomObject]@{Gate=[object]::new();Files=$script:sessionFiles;Rollouts=$null;LastScanTicks=[long]0;Attempted=$false;ScanFailed=$false;RetrySeconds=5;HotUntilTicks=[long]0;IndexVersions=@{};DatedMisses=@{};RolloutMisses=@{}}
 $script:sessionIndexLookup=@{};$script:planCache=@{};$script:planConfirmations=@{}
 $script:lifecycleState=@{};$script:observedCodex=@{};$script:monitorStartedUtc=$MonitorStartedUtc.ToUniversalTime()
 $script:lastCodexTasks=@();$script:lastClaudeTasks=@();$script:codexSourcePartial=$false
 $script:codexRolloutPaths=@{};$script:codexRolloutSnapshot=$null;$script:codexObservedStarts=@{};$script:codexTerminalChecks=@{}
 if(-not ('AITaskMonitor.CodexTitles.Reader' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'CodexTitlesCore.cs') -ErrorAction Stop}
 if(-not ('AITaskMonitor.CodexObservation.CodexRecentEventObserver' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'CodexRecentEventObserver.cs') -ErrorAction Stop}
 . (Join-Path $PSScriptRoot 'ClaudeReaderCore.ps1')
 $script:codexAgentRetention=New-CodexAgentRetention
 $script:codexTitleReader=[AITaskMonitor.CodexTitles.Reader]::new()
 $script:codexRolloutReader=[AITaskMonitor.CodexTitles.RolloutReader]::new()
 $script:codexRecentEventObserver=[AITaskMonitor.CodexObservation.CodexRecentEventObserver]::new($script:sessionsDirectory)
 $script:codexRootEvidenceReader=[AITaskMonitor.CodexObservation.CodexRootEvidenceReader]::new($script:codexHome)
 $script:localSourceInitialized=$true
}

function Prop($object, [string]$name, $fallback = $null) {
 if ($null -ne $object -and $null -ne $object.PSObject.Properties[$name]) { return $object.$name }
 return $fallback
}

function Claude-ConnectionState {
 $profileVariable=Get-Variable -Scope Script -Name localSourceProfileRoot -ErrorAction SilentlyContinue
 $profileRoot=if($null -ne $profileVariable -and [string]$profileVariable.Value){[string]$profileVariable.Value}else{$env:USERPROFILE}
 $path=Join-Path (Join-Path $profileRoot ".claude") "settings.json"
 try{$attributes=[IO.File]::GetAttributes($path)}
 catch [IO.FileNotFoundException]{return "disconnected"}
 catch [IO.DirectoryNotFoundException]{return "disconnected"}
 if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){throw "Claude Code settings are not a file."}
 $hookPath=Join-Path $PSScriptRoot "ClaudeTaskHook.ps1"
 $legacy='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$hookPath+'"'
 $hookScript="& '"+$hookPath.Replace("'","''")+"'"
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hookScript))
 $expected='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
 if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'store-channel.marker') -PathType Leaf){
  . (Join-Path $PSScriptRoot 'StoreClaudeHook.ps1')
  $expected=Get-StoreClaudeHookCommand $PSScriptRoot
 }
 $raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
 if(-not $raw.Trim()){return "disconnected"}
 $settings=$raw|ConvertFrom-Json -ErrorAction Stop
 if($null -eq $settings -or $settings -is [array] -or $settings -is [string] -or $settings -is [ValueType]){throw "Claude Code settings are not a JSON object."}
 $hooksProperty=$settings.PSObject.Properties["hooks"]
 if($null -eq $hooksProperty){return "disconnected"}
 if($hooksProperty.Value -isnot [PSCustomObject]){throw "Claude Code hooks are not a JSON object."}
 $knownEvents=@("UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","TaskCreated","TaskCompleted","SubagentStart","SubagentStop","Stop","StopFailure","SessionEnd")
 $connectedEvents=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($eventProperty in $hooksProperty.Value.PSObject.Properties){
  if($eventProperty.Name -notin $knownEvents){continue}
  if($eventProperty.Value -isnot [array]){throw "Claude Code hook groups are not an array."}
  foreach($entry in $eventProperty.Value){
   if($entry -isnot [PSCustomObject]){throw "A Claude Code hook group is not an object."}
   $entryHooks=$entry.PSObject.Properties["hooks"]
   if($null -eq $entryHooks){continue}
   if($entryHooks.Value -isnot [array]){throw "Claude Code commands are not an array."}
   foreach($hook in $entryHooks.Value){
    if($hook -isnot [PSCustomObject]){throw "A Claude Code hook is not an object."}
    if($null -eq $hook.PSObject.Properties["type"] -or [string]$hook.type -ne "command" -or $null -eq $hook.PSObject.Properties["command"] -or $null -ne $hook.PSObject.Properties["args"]){continue}
    $hasExtraProperties=$false
    foreach($propertyName in $hook.PSObject.Properties.Name){if($propertyName -notin @("type","command","timeout")){$hasExtraProperties=$true;break}}
    if($hasExtraProperties){continue}
    $command=([string]$hook.command).Trim()
    if([string]::Equals($command,$expected,[StringComparison]::Ordinal) -or [string]::Equals($command,$legacy,[StringComparison]::OrdinalIgnoreCase)){[void]$connectedEvents.Add($eventProperty.Name)}
   }
  }
 }
 if($connectedEvents.Count -eq $knownEvents.Count){return "connected"}
 if($connectedEvents.Count -gt 0){return "partial"}
 return "disconnected"
}

function Lock-State([string]$path) {
 try {
  # Only inspect the directory entry. Opening this file without write sharing
  # can prevent Codex from acquiring its writer lock.
  $attributes=[IO.File]::GetAttributes($path)
  if(($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0){return "unavailable"}
  return "present"
 } catch {
  $exception=$_.Exception
  while($null -ne $exception.InnerException){$exception=$exception.InnerException}
  if($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException]){return "missing"}
  return "unavailable"
 }
}

function Find-PriorLifecycle([string]$path) {
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try {
  $position=$stream.Length;$buffer=New-Object byte[] 262144;$carry='';$discardPartial=$false
  $minimum=[Math]::Max([long]0,$position-[long]8388608)
  $terminals=New-Object 'Collections.Generic.List[object]'
  while($position -gt $minimum){
   $count=[int][Math]::Min([long]$buffer.Length,$position-$minimum);$position-=$count
   [void]$stream.Seek($position,[IO.SeekOrigin]::Begin)
   $read=0
   while($read -lt $count){$n=$stream.Read($buffer,$read,$count-$read);if($n -le 0){throw 'Unable to read Codex session history.'};$read+=$n}
   $text=[Text.Encoding]::UTF8.GetString($buffer,0,$read)
   if(-not $discardPartial){$text+=$carry}
   $lines=$text.Split([char]10)
   if($lines.Length -eq 1 -and $position -gt 0){
    if($discardPartial){$carry=''}elseif($text.Length -gt 1048576){$carry='';$discardPartial=$true}else{$carry=$text}
    continue
   }
   $last=$lines.Length-1
   if($discardPartial){$last--;$discardPartial=$false}
   $first=if($position -eq 0){0}else{1}
   for($i=$last;$i -ge $first;$i--){
    $line=$lines[$i]
    if($line.Length -gt 1048576 -or $line -notmatch '"event_msg"' -or $line -notmatch '"(task_started|turn_started|task_complete|turn_complete|turn_aborted)"'){continue}
    try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
    if($null -eq $record.PSObject.Properties['type'] -or [string]$record.type -ne 'event_msg' -or $null -eq $record.PSObject.Properties['payload']){continue}
    $payload=$record.payload
    if($null -eq $payload -or $null -eq $payload.PSObject.Properties['type']){continue}
    $type=[string]$payload.type
    if($type -notin @('task_started','turn_started','task_complete','turn_complete','turn_aborted')){continue}
    $turn=if($null -ne $payload.PSObject.Properties['turn_id']){[string]$payload.turn_id}else{''}
    if($type -in @('task_started','turn_started')){
     $raw=if($null -ne $record.PSObject.Properties['timestamp']){[string]$record.timestamp}else{''}
     $timestamp=[DateTime]::MinValue
     if($null -ne $record.PSObject.Properties['timestamp']){
      $value=$record.timestamp
      if($value -is [DateTime]){$timestamp=$value.ToUniversalTime()}
      elseif($value -is [DateTimeOffset]){$timestamp=$value.UtcDateTime}
      elseif($null -ne $value -and [DateTime]::TryParse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp)){$timestamp=$timestamp.ToUniversalTime()}
     }
     $lifecycle='task_started'
     foreach($terminal in $terminals){
      if(-not $turn -or -not $terminal.TurnId){return $null}
      if($turn -eq $terminal.TurnId){$lifecycle=$terminal.Lifecycle;break}
     }
     $key=if($turn){'turn:'+$turn}elseif($raw){'time:'+$raw}else{''}
     return [PSCustomObject]@{Lifecycle=$lifecycle;TurnId=$turn;LastEventUtc=$timestamp;StartKey=$key;StartedUtc=$timestamp}
    }
    if($terminals.Count -ge 1024){return $null}
    $terminals.Add([PSCustomObject]@{Lifecycle=$(if($type -eq 'turn_aborted'){'turn_aborted'}else{'task_complete'});TurnId=$turn})
   }
   if($position -gt 0){
    $carry=$lines[0]
    if($carry.Length -gt 1048576){$carry='';$discardPartial=$true}
   }
  }
  # A terminal without its matching start cannot establish the current turn.
  return $null
 } finally {$stream.Dispose()}
}

function Thread-State([string]$id,[bool]$AllowPriorWithoutLock=$false) {
 if($id -notmatch '^[A-Za-z0-9_-]{1,128}$'){return [PSCustomObject]@{State="unknown";HasStartMarker=$false;UpdatedUtc=[DateTime]::MinValue;StartKey="";StartedUtc=[DateTime]::MinValue}}
 $path = Session-File $id
 if (-not $path -or -not (Test-Path -LiteralPath $path)) { return [PSCustomObject]@{State="unknown";HasStartMarker=$false;UpdatedUtc=[DateTime]::MinValue;StartKey="";StartedUtc=[DateTime]::MinValue} }
 $file=Get-Item -LiteralPath $path
 $cached=if($script:lifecycleState.ContainsKey($path)){$script:lifecycleState[$path]}else{$null}
 if($null -ne $cached -and [long]$cached.Length -eq [long]$file.Length -and [long]$cached.Stamp -eq $file.LastWriteTimeUtc.Ticks){
  $lifecycle=[string]$cached.Lifecycle
  $lastEventUtc=[DateTime]$cached.LastEventUtc
  $startKey=if($null -ne $cached.PSObject.Properties["StartKey"]){[string]$cached.StartKey}else{""}
  $startedUtc=if($null -ne $cached.PSObject.Properties["StartedUtc"]){[DateTime]$cached.StartedUtc}else{[DateTime]::MinValue}
 }else{
  $tailLimit=2097152
  $tail=Read-TailText $path $tailLimit $true
  $seed=$null
  if($null -ne $cached -and $cached.Lifecycle -in @('task_started','task_complete','turn_aborted') -and
     $null -ne $cached.PSObject.Properties['TurnId'] -and [long]$file.Length -ge [long]$cached.Length -and
     ([long]$file.Length-[long]$cached.Length) -le $tailLimit -and $file.LastWriteTimeUtc.Ticks -ge [long]$cached.Stamp){$seed=$cached}
  $scannedPrior=($null -ne $cached -and $null -ne $cached.PSObject.Properties['PriorScanComplete'] -and $cached.PriorScanComplete -and
   [long]$file.Length -ge [long]$cached.Length -and ([long]$file.Length-[long]$cached.Length) -le $tailLimit -and
   $file.LastWriteTimeUtc.Ticks -ge [long]$cached.Stamp)
  $parseTail={param($text,$initial)
   $lifecycle=if($initial){[string]$initial.Lifecycle}else{''}
   $turnId=if($initial){[string]$initial.TurnId}else{''}
   $startKey=if($initial){[string]$initial.StartKey}else{''}
   $startedUtc=if($initial){[DateTime]$initial.StartedUtc}else{[DateTime]::MinValue}
   $lastEventUtc=if($initial){[DateTime]$initial.LastEventUtc}else{[DateTime]::MinValue}
   $latestTailEventUtc=[DateTime]::MinValue;$sawStart=$false
   foreach($line in ($text -split "`r?`n")){
   if($line.Length -gt 1048576 -or $line -notmatch '"event_msg"'){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   if($null -eq $record.PSObject.Properties["type"] -or [string]$record.type -ne "event_msg" -or $null -eq $record.PSObject.Properties["payload"]){continue}
   $payload=$record.payload
   if($null -eq $payload -or $null -eq $payload.PSObject.Properties["type"]){continue}
   $eventType=[string]$payload.type
   $eventTurn=if($null -ne $payload.PSObject.Properties["turn_id"]){[string]$payload.turn_id}else{""}
   $timestampValue=if($null -ne $record.PSObject.Properties["timestamp"]){$record.timestamp}else{$null}
   $timestamp=[DateTime]::MinValue
   if($timestampValue -is [DateTime]){$timestamp=$timestampValue.ToUniversalTime()}
   elseif($timestampValue -is [DateTimeOffset]){$timestamp=$timestampValue.UtcDateTime}
   elseif($null -ne $timestampValue -and [DateTime]::TryParse([string]$timestampValue,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp)){$timestamp=$timestamp.ToUniversalTime()}
   if($timestamp -gt $latestTailEventUtc){$latestTailEventUtc=$timestamp}
   if($eventType -in @("task_started","turn_started")){
    $sawStart=$true
    $lifecycle="task_started";$turnId=$eventTurn;$lastEventUtc=[DateTime]::MinValue
    $rawStart=if($null -ne $record.PSObject.Properties["timestamp"]){[string]$record.timestamp}else{""}
    $startKey=if($eventTurn){"turn:"+$eventTurn}elseif($rawStart){"time:"+$rawStart}else{""}
   }
   elseif($eventType -notin @("task_complete","turn_complete","turn_aborted") -and $lifecycle -ne "task_started"){continue}
   if($turnId -and $eventTurn -and $eventTurn -ne $turnId){continue}
   if($eventType -in @("task_complete","turn_complete","turn_aborted")){
    # A terminal without a matching turn ID cannot close an observed turn.
    if(-not $turnId -or -not $eventTurn){$lifecycle="uncertain_terminal";continue}
    if($lifecycle -eq "task_started"){$lifecycle=if($eventType -eq "turn_aborted"){"turn_aborted"}else{"task_complete"}}
    continue
   }
   if($eventType -in @("task_started","turn_started")){$startedUtc=$timestamp}
   if($timestamp -gt $lastEventUtc){$lastEventUtc=$timestamp}
   }
   return [PSCustomObject]@{Lifecycle=$lifecycle;TurnId=$turnId;LastEventUtc=$lastEventUtc;StartKey=$startKey;StartedUtc=$startedUtc;LatestTailEventUtc=$latestTailEventUtc;SawStart=$sawStart}
  }
  $parsed=& $parseTail $tail $seed
  if($null -eq $seed -and -not $scannedPrior -and -not $parsed.SawStart -and [long]$file.Length -gt $tailLimit){
   $priorLock=Lock-State (Join-Path $lockDirectory "$id.lock")
   if($priorLock -eq 'unavailable'){throw 'Codex session lock cannot be checked.'}
   if($priorLock -eq 'present' -or $AllowPriorWithoutLock){
    $prior=Find-PriorLifecycle $path
    $scannedPrior=$true
    if($null -ne $prior){$parsed=& $parseTail $tail $prior}
   }
  }
  $lifecycle=[string]$parsed.Lifecycle;$turnId=[string]$parsed.TurnId;$lastEventUtc=[DateTime]$parsed.LastEventUtc
  $startKey=[string]$parsed.StartKey;$startedUtc=[DateTime]$parsed.StartedUtc
  $script:lifecycleState[$path]=[PSCustomObject]@{Length=[long]$file.Length;Stamp=$file.LastWriteTimeUtc.Ticks;Lifecycle=$lifecycle;TurnId=$turnId;LastEventUtc=$lastEventUtc;StartKey=$startKey;StartedUtc=$startedUtc;PriorScanComplete=$scannedPrior}
 }
 $hasStart=$lifecycle -eq "task_started"
 $lock=if($hasStart){Lock-State (Join-Path $lockDirectory "$id.lock")}else{"missing"}
 if($lock -eq "unavailable"){throw "Codex session lock cannot be checked."}
 $state=if($lifecycle -eq "task_complete"){"completed"}elseif($lifecycle -eq "turn_aborted"){"interrupted"}else{"unknown"}
 return [PSCustomObject]@{State=$state;HasStartMarker=$hasStart;AmbiguousTerminal=($lifecycle -eq 'uncertain_terminal');UpdatedUtc=$file.LastWriteTimeUtc;StartKey=$startKey;StartedUtc=$startedUtc;LockState=$lock}
}

function Codex-Uncertain([string]$id,$threadState) {
 if($threadState.State -eq "active"){$script:observedCodex[$id]=$true}
 elseif($threadState.State -in @("completed","interrupted")){[void]$script:observedCodex.Remove($id)}
 elseif($threadState.State -eq "unknown" -and $threadState.HasStartMarker -and
   (($null -ne $threadState.PSObject.Properties['LockState'] -and $threadState.LockState -eq 'present') -or $threadState.UpdatedUtc -ge $script:monitorStartedUtc)){$script:observedCodex[$id]=$true}
 return ($threadState.State -eq "unknown" -and $script:observedCodex.ContainsKey($id))
}

function Update-CodexRolloutPaths($snapshot,$sessions) {
 $next=@{};$paths=Prop $snapshot 'Paths'
 if($null -ne $paths){foreach($session in $sessions){
  $id=[string](Prop $session 'id' '')
  if($id -and $paths.ContainsKey($id)){$next[$id]=[string]$paths[$id]}
 }}
 foreach($id in @($next.Keys)){
  $new=[string]$next[$id];$old=if($script:codexRolloutPaths.ContainsKey($id)){[string]$script:codexRolloutPaths[$id]}else{''}
  if([string]::Equals($old,$new,[StringComparison]::OrdinalIgnoreCase)){continue}
  $cache=$script:sessionDiscovery
  [Threading.Monitor]::Enter($cache.Gate)
  try{
   $cached=if($cache.Files.ContainsKey($id)){[string]$cache.Files[$id]}else{''}
   if($cached -and -not [string]::Equals($cached,$new,[StringComparison]::OrdinalIgnoreCase)){
    [void]$cache.Files.Remove($id);[void]$cache.DatedMisses.Remove($id);[void]$cache.RolloutMisses.Remove($id)
    [void]$script:lifecycleState.Remove($cached);[void]$script:planCache.Remove($cached)
   }
  }finally{[Threading.Monitor]::Exit($cache.Gate)}
  if($script:unindexedPaths.ContainsKey($id) -and -not [string]::Equals([string]$script:unindexedPaths[$id],$new,[StringComparison]::OrdinalIgnoreCase)){
   $prior=[string]$script:unindexedPaths[$id];[void]$script:unindexedPaths.Remove($id)
   [void]$script:lifecycleState.Remove($prior);[void]$script:planCache.Remove($prior)
  }
  if($old -and -not [string]::Equals($old,$new,[StringComparison]::OrdinalIgnoreCase)){
   [void]$script:lifecycleState.Remove($old);[void]$script:planCache.Remove($old)
  }
  if($script:codexObservedStarts.ContainsKey($id) -and
     -not [string]::Equals([string]$script:codexObservedStarts[$id].Path,$new,[StringComparison]::OrdinalIgnoreCase)){
   [void]$script:codexObservedStarts.Remove($id);[void]$script:codexTerminalChecks.Remove($id)
   [void]$script:observedCodex.Remove($id);[void]$script:planConfirmations.Remove($id)
  }
 }
 $script:codexRolloutPaths=$next;$script:codexRolloutSnapshot=$snapshot
}

function Confirm-CodexTerminal([string]$id,$state,[string]$path) {
 $reader=Get-Variable -Scope Script -Name codexRolloutReader -ErrorAction SilentlyContinue
 if($null -eq $reader){return $true}
 if($null -eq $reader.Value -or -not $script:codexRolloutPaths.ContainsKey($id) -or
    -not [string]::Equals([string]$script:codexRolloutPaths[$id],$path,[StringComparison]::OrdinalIgnoreCase) -or
    -not $script:codexObservedStarts.ContainsKey($id)){return $false}
 $start=$script:codexObservedStarts[$id]
 if(-not [string]::Equals([string]$start.Path,$path,[StringComparison]::OrdinalIgnoreCase) -or
    -not $state.StartKey -or [string]$start.StartKey -cne [string]$state.StartKey){return $false}
 $check=if($script:codexTerminalChecks.ContainsKey($id)){$script:codexTerminalChecks[$id]}else{$null}
 if($null -eq $check -or -not [string]::Equals([string]$check.Path,$path,[StringComparison]::OrdinalIgnoreCase) -or
    [string]$check.StartKey -cne [string]$state.StartKey){
  $check=[PSCustomObject]@{Path=$path;StartKey=[string]$state.StartKey;After=[Diagnostics.Stopwatch]::GetTimestamp()}
  $script:codexTerminalChecks[$id]=$check
 }
 $checked=Prop $script:codexRolloutSnapshot 'CheckedTicks'
 if($null -ne $checked -and $checked.ContainsKey($id) -and [long]$checked[$id] -gt [long]$check.After){return $true}
 $reader.Value.RefreshSoon($id)
 return $false
}

function Session-File([string]$id) {
 $rollouts=Get-Variable -Scope Script -Name codexRolloutPaths -ErrorAction SilentlyContinue
 if($null -ne $rollouts -and $null -ne $rollouts.Value -and $rollouts.Value.ContainsKey($id)){
  return [string]$rollouts.Value[$id]
 }
 $cache=$script:sessionDiscovery
 [Threading.Monitor]::Enter($cache.Gate)
 try {
  $markActivity={
   $cache.RetrySeconds=5
   $cache.HotUntilTicks=[Diagnostics.Stopwatch]::GetTimestamp()+([long][Diagnostics.Stopwatch]::Frequency * 30)
  }
  $fileAvailable={param([string]$candidate)
   try {
    $attributes=[IO.File]::GetAttributes($candidate)
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { throw 'Not a session file.' }
    return $true
   } catch {
    $exception=$_.Exception
    while($null -ne $exception.InnerException){$exception=$exception.InnerException}
    if($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException]){return $false}
    throw 'Codex session file cannot be read.'
   }
  }
  $unindexed=Get-Variable -Scope Script -Name 'unindexedPaths' -ErrorAction SilentlyContinue
  if($null -ne $unindexed -and $null -ne $unindexed.Value -and $unindexed.Value.ContainsKey($id)){
   $candidate=[string]$unindexed.Value[$id]
   try{
    $attributes=[IO.File]::GetAttributes($candidate)
    if(($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0){throw 'Invalid unindexed session file.'}
    return $candidate
   }catch{
    $exception=$_.Exception
    while($null -ne $exception.InnerException){$exception=$exception.InnerException}
    if($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException]){return ''}
    throw 'Codex session file cannot be read.'
   }
  }
  if ($cache.Files.ContainsKey($id)) {
   $cached=[string]$cache.Files[$id]
   if ($cached -and (& $fileAvailable $cached)) { return $cached }
   [void]$cache.Files.Remove($id)
   [void]$cache.DatedMisses.Remove($id)
   & $markActivity
  }
  if ($script:sessionDates.ContainsKey($id)) {
   $folder = $script:sessionDates[$id]
   $skipDated=$false
   if ($cache.DatedMisses.ContainsKey($id)) {
    $miss=$cache.DatedMisses[$id]
    $age=[Diagnostics.Stopwatch]::GetTimestamp()-[long]$miss.Tick
    if ([string]::Equals([string]$miss.Folder,[string]$folder,[StringComparison]::OrdinalIgnoreCase) -and
        $age -ge 0 -and $age -lt [Diagnostics.Stopwatch]::Frequency) { $skipDated=$true }
    else { [void]$cache.DatedMisses.Remove($id) }
   }
   if (-not $skipDated) {
    try {
     if (Test-Path -LiteralPath $folder -PathType Container -ErrorAction Stop) {
      $datedFile = Get-ChildItem -LiteralPath $folder -File -Filter ("*" + $id + ".jsonl") -ErrorAction Stop | Select-Object -First 1
      if ($null -ne $datedFile) {
       [void]$cache.DatedMisses.Remove($id)
       $cache.Files[$id] = $datedFile.FullName
       & $markActivity
       return $datedFile.FullName
      }
     }
     $cache.DatedMisses[$id]=[PSCustomObject]@{Folder=$folder;Tick=[Diagnostics.Stopwatch]::GetTimestamp()}
    } catch {
     [void]$cache.DatedMisses.Remove($id)
     throw 'Codex session files cannot be read.'
    }
   }
  }
  try {
   $rootAttributes=[IO.File]::GetAttributes($sessionsDirectory)
   if (($rootAttributes -band [IO.FileAttributes]::Directory) -eq 0) { throw 'Not a session directory.' }
  } catch {
   throw 'Codex session files cannot be read.'
  }
  $now=[Diagnostics.Stopwatch]::GetTimestamp()
  if ($cache.Attempted -and $now -lt $cache.LastScanTicks) { $cache.LastScanTicks=$now; $cache.RetrySeconds=5 }
  $interval=[long][Diagnostics.Stopwatch]::Frequency * [Math]::Max(5,[int]$cache.RetrySeconds)
  if (-not $cache.Attempted -or ($now - $cache.LastScanTicks) -ge $interval) {
   $previousAttempt=[bool]$cache.Attempted
   $previousFailure=[bool]$cache.ScanFailed
   $cache.RolloutMisses.Clear()
   try {
    $cache.Rollouts = @([IO.Directory]::EnumerateFiles($sessionsDirectory, "*.jsonl", [IO.SearchOption]::AllDirectories))
    $cache.ScanFailed = $false
    if ($previousFailure) { & $markActivity }
   } catch {
    $cache.Rollouts = $null
    $cache.ScanFailed = $true
   } finally {
    $cache.LastScanTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    $cache.Attempted = $true
    if ($previousAttempt -and $cache.LastScanTicks -ge $cache.HotUntilTicks) {
     $cache.RetrySeconds = [Math]::Min(60,[int]$cache.RetrySeconds * 2)
    }
   }
  }
  if ($cache.ScanFailed) { throw 'Codex session files cannot be read.' }
  if ($cache.RolloutMisses.ContainsKey($id)) { return "" }
  $matched=$false
  foreach ($file in $cache.Rollouts) {
   if ($file.EndsWith($id + ".jsonl", [StringComparison]::OrdinalIgnoreCase)) {
    $matched=$true
    if (& $fileAvailable $file) {
     $path = [string]$file
     $cache.Files[$id] = $path
     & $markActivity
     return $path
    }
   }
  }
  if (-not $matched) { $cache.RolloutMisses[$id]=$true }
  return ""
 } finally {
  [Threading.Monitor]::Exit($cache.Gate)
 }
}

function Session-Workspace([string]$id) {
 $path = Session-File $id
 if (-not $path) { return "" }
 try {
  $sharing=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
  try{
   # Codex normally writes session_meta as the first complete line. Avoid
   # copying the first MiB of every candidate on the UI thread in that case.
   $headCount=[int][Math]::Min([long]65536,[long]$stream.Length)
   $head=[byte[]]::new($headCount);$headRead=0
   while($headRead -lt $headCount){$read=$stream.Read($head,$headRead,$headCount-$headRead);if($read -le 0){throw 'The session changed while reading.'};$headRead+=$read}
   $lfEnd=[Array]::IndexOf($head,[byte]10);$crEnd=[Array]::IndexOf($head,[byte]13)
   $lineEnd=if($lfEnd -lt 0){$crEnd}elseif($crEnd -lt 0){$lfEnd}else{[Math]::Min($lfEnd,$crEnd)}
   if($lineEnd -ge 0){
    $line=[Text.Encoding]::UTF8.GetString($head,0,$lineEnd).TrimStart([char]0xFEFF)
    if($line -match '"type":"session_meta"'){
     $record=$line|ConvertFrom-Json -ErrorAction Stop
     return [string](Prop $record.payload 'cwd' '')
    }
   }
   [void]$stream.Seek(0,[IO.SeekOrigin]::Begin)
   $count=[int][Math]::Min([long]1048576,[long]$stream.Length);$bytes=[byte[]]::new($count);$offset=0
   while($offset -lt $count){$read=$stream.Read($bytes,$offset,$count-$offset);if($read -le 0){throw 'The session changed while reading.'};$offset+=$read}
  }finally{$stream.Dispose()}
  $memory=[IO.MemoryStream]::new($bytes,$false)
  try{
   $reader=[IO.StreamReader]::new($memory,[Text.Encoding]::UTF8,$true,4096,$true)
   try{
    for($i=0;$i -lt 12 -and $null -ne ($line=$reader.ReadLine());$i++){
     if($line -notmatch '"type":"session_meta"'){continue}
     $record=$line|ConvertFrom-Json -ErrorAction Stop
     return [string](Prop $record.payload 'cwd' '')
    }
   }finally{$reader.Dispose()}
  }finally{$memory.Dispose()}
 } catch {}
 return ""
}

function Progress-Files($sessions) {
 $paths = New-Object Collections.Generic.List[string]
 if ($ProgressFile -and (Test-Path -LiteralPath $ProgressFile)) { $paths.Add((Resolve-Path -LiteralPath $ProgressFile).Path) }
 foreach ($session in $sessions) {
  $workspace = Session-Workspace ([string]$session.id)
  if (-not $workspace) { continue }
  foreach ($name in @("task-progress.json", "task-progress-v2.json")) {
   $candidate = Join-Path $workspace $name
   if ((Test-Path -LiteralPath $candidate) -and -not $paths.Contains($candidate)) { $paths.Add($candidate) }
  }
 }
 return @($paths)
}

function Manual-Tasks($sessions) {
 $map = @{}
 foreach ($path in @(Progress-Files $sessions)) {
  try {
   $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
   $all = if ($null -ne $data.PSObject.Properties["tasks"]) { @($data.tasks) } else { @($data) }
   foreach ($item in $all) {
    if ($null -eq $item) { continue }
    $id = [string](Prop $item "threadId" ""); $title = [string](Prop $item "title" "")
    if ($id) { $map[$id] = $item } elseif ($title) { $map["title:$title"] = $item }
   }
  } catch {}
 }
 return $map
}

function Read-TailText([string]$path,[long]$maxBytes,[bool]$allowDelete=$false) {
 $sharing=[IO.FileShare]::ReadWrite
 if($allowDelete){$sharing=$sharing -bor [IO.FileShare]::Delete}
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
 try {
  if($maxBytes -lt 0 -or $maxBytes -gt [int]::MaxValue){throw 'Invalid bounded tail size.'}
  $length=[long]$stream.Length;$count=[int][Math]::Min($maxBytes,$length)
  $bytes=[byte[]]::new($count);[void]$stream.Seek($length-$count,[IO.SeekOrigin]::Begin)
  $offset=0
  while($offset -lt $count){$read=$stream.Read($bytes,$offset,$count-$offset);if($read -le 0){throw 'The session changed while reading.'};$offset+=$read}
 }finally{$stream.Dispose()}
 $memory=[IO.MemoryStream]::new($bytes,$false)
 try{
  $reader=[IO.StreamReader]::new($memory,[Text.Encoding]::UTF8,$true,4096,$true)
  try{return $reader.ReadToEnd()}finally{$reader.Dispose()}
 }finally{$memory.Dispose()}
}

function Codex-Plan([string]$id) {
 $path = Session-File $id
 if (-not $path) { return @() }
 if($null -eq (Get-Variable -Scope Script -Name planConfirmations -ErrorAction SilentlyContinue)){$script:planConfirmations=@{}}
 $file=Get-Item -LiteralPath $path -ErrorAction Stop
 $stamp=$file.LastWriteTimeUtc.Ticks
 $cached=if($script:planCache.ContainsKey($path)){$script:planCache[$path]}else{$null}
 if($null -ne $cached -and $cached.Stamp -eq $stamp -and $cached.Length -eq $file.Length){
  $script:planConfirmations[$id]=[bool]$cached.Confirmed
  return @($cached.Steps)
 }
 $latest=@();$confirmed=$false;$currentTurn='';$offset=[long]0
 $sharing=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
 try{
  $length=[long]$stream.Length
  $readAnchor={param([IO.Stream]$inputStream,[long]$position)
   $count=[int][Math]::Min([long]128,$position)
   if($count -eq 0){return ''}
   $data=New-Object byte[] $count
   [void]$inputStream.Seek($position-$count,[IO.SeekOrigin]::Begin)
   $read=0
   while($read -lt $count){$n=$inputStream.Read($data,$read,$count-$read);if($n -le 0){throw 'Unable to verify Codex plan history.'};$read+=$n}
   return [Convert]::ToBase64String($data)
  }
  $safeEnd=[long]0;$position=$length;$buffer=New-Object byte[] 65536
  $minimumEnd=[Math]::Max([long]0,$length-[long]8388608)
  while($position -gt $minimumEnd -and $safeEnd -eq 0){
   $count=[int][Math]::Min([long]$buffer.Length,$position-$minimumEnd);$position-=$count
   [void]$stream.Seek($position,[IO.SeekOrigin]::Begin)
   $read=0
   while($read -lt $count){$n=$stream.Read($buffer,$read,$count-$read);if($n -le 0){throw 'Unable to read Codex plan history.'};$read+=$n}
   for($i=$read-1;$i -ge 0;$i--){if($buffer[$i] -eq 10){$safeEnd=$position+$i+1;break}}
  }
  if($null -ne $cached -and $length -gt [long]$cached.Length -and $safeEnd -ge [long]$cached.Offset){
   $anchor=& $readAnchor $stream ([long]$cached.Offset)
   if($anchor -ceq [string]$cached.Anchor){$offset=[long]$cached.Offset;$latest=@($cached.Steps);$confirmed=[bool]$cached.Confirmed;$currentTurn=[string]$cached.CurrentTurn}
  }
  if($safeEnd -gt $offset){
   $partialPlan=($safeEnd-$offset) -gt 8388608
   if($partialPlan){$offset=$safeEnd-8388608;$latest=@();$confirmed=$false;$currentTurn=''}
   [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin)
   $count=[int]($safeEnd-$offset);$data=[byte[]]::new($count);$read=0
   while($read -lt $count){$n=$stream.Read($data,$read,$count-$read);if($n -le 0){throw 'Unable to read Codex plan history.'};$read+=$n}
   $memory=[IO.MemoryStream]::new($data,$false)
   $reader=[IO.StreamReader]::new($memory,[Text.Encoding]::UTF8,($offset -eq 0),4096,$true)
   try{
    if($partialPlan){[void]$reader.ReadLine()}
    while($null -ne ($line=$reader.ReadLine())){
     if($line -notmatch 'update_plan|task_started|turn_started'){continue}
     try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
     $payload=Prop $record "payload"
     if($null -eq $payload){continue}
     $eventType=[string](Prop $payload "type" "")
     if([string](Prop $record "type" "") -eq 'event_msg' -and $eventType -in @('task_started','turn_started')){
      $eventTurn=[string](Prop $payload 'turn_id' '')
      if(-not $eventTurn -or -not $currentTurn -or $eventTurn -cne $currentTurn){if($latest.Count -gt 0){$confirmed=$false}}
      $currentTurn=$eventTurn
      continue
     }
     if($eventType -notin @('custom_tool_call','function_call')){continue}
     $eventTurn=[string](Prop $payload 'turn_id' '')
     if($currentTurn -and $eventTurn -and $eventTurn -cne $currentTurn){continue}
     $name=[string](Prop $payload 'name' '')
     $inputText=[string](Prop $payload 'input' (Prop $payload 'arguments' ''))
     if(-not $inputText){continue}
     $isDirectPlan=$name -eq 'update_plan'
     if(-not $isDirectPlan -and $inputText -notmatch 'update_plan\s*\('){continue}
     $candidate=New-Object Collections.Generic.List[object]
     if($isDirectPlan){
      try{$parsed=$inputText|ConvertFrom-Json -ErrorAction Stop}catch{$parsed=$null}
      if($null -ne $parsed -and $null -ne $parsed.PSObject.Properties['plan'] -and $parsed.plan -is [array]){
       foreach($step in $parsed.plan){
        $label=[string](Prop $step 'step' '');$status=[string](Prop $step 'status' '')
        if(-not $label -or $status -notin @('completed','in_progress','pending')){continue}
        $state=switch($status){'completed'{'done'} 'in_progress'{'active'} default{'pending'}}
        $candidate.Add([PSCustomObject]@{title=$label;status=$state})
       }
       if($parsed.plan.Count -eq 0 -or $candidate.Count -gt 0){$latest=$candidate.ToArray();$confirmed=$true}
       continue
      }
     }
     $matches=[regex]::Matches($inputText, 'step\s*:\s*"(?<step>(?:\\.|[^"\\])*)"\s*,\s*status\s*:\s*"(?<status>completed|in_progress|pending)"')
     if($matches.Count -eq 0){continue}
     foreach($match in $matches){
      $state=switch($match.Groups['status'].Value){'completed'{'done'} 'in_progress'{'active'} default{'pending'}}
      $candidate.Add([PSCustomObject]@{title=[regex]::Unescape($match.Groups['step'].Value);status=$state})
     }
     $latest=$candidate.ToArray();$confirmed=$true
    }
   }finally{$reader.Dispose();$memory.Dispose()}
   if($partialPlan){$confirmed=$false}
  }
  $anchor=& $readAnchor $stream $safeEnd
 }finally{$stream.Dispose()}
 if($script:planCache.Count -ge 100){$script:planCache.Clear()}
 $script:planCache[$path]=[PSCustomObject]@{Length=$length;Stamp=$stamp;Offset=$safeEnd;Anchor=$anchor;Steps=@($latest);Confirmed=$confirmed;CurrentTurn=$currentTurn}
 $script:planConfirmations[$id]=[bool]$confirmed
 return @($latest)
}

function Codex-TurnStartIndex([string[]]$lines,[string]$turnId) {
 if(-not $turnId){return -1}
 for($index=$lines.Count-1;$index -ge 0;$index--){
  $line=$lines[$index]
  if($line -notmatch '"(task_started|turn_started)"' -or [Text.Encoding]::UTF8.GetByteCount($line) -gt 1048576){continue}
  try{$boundary=ConvertFrom-Json -InputObject $line -ErrorAction Stop}catch{continue}
  $boundaryPayload=Prop $boundary 'payload'
  if([string](Prop $boundary 'type' '') -ceq 'event_msg' -and [string](Prop $boundaryPayload 'type' '') -in @('task_started','turn_started')){
   if([string](Prop $boundaryPayload 'turn_id' '') -ceq $turnId){return $index}
   return -1
  }
 }
 return -1
}

function Codex-ContainsIdentifier([string]$line,[string]$id) {
 if($line.Contains($id)){return $true}
 if(-not $line.Contains('\u')){return $false}
 $decoded=[regex]::Replace($line,'\\u([0-9a-fA-F]{4})',{
  param($match) return [string][char][Convert]::ToInt32($match.Groups[1].Value,16)
 })
 return $decoded.Contains($id)
}

function Codex-CurrentToolActivity([string[]]$lines,[string]$turnId) {
 if(-not $turnId){return ''}
 $startIndex=Codex-TurnStartIndex $lines $turnId
 if($startIndex -lt 0){return ''}
 # Keep this UI-thread check bounded even for a very long current turn.
 # A call that started outside this window falls back to the observed summary.
 $windowStart=[Math]::Max($startIndex,$lines.Count-512)
 $currentLines=@($lines[$windowStart..($lines.Count-1)])
 if(-not ($currentLines -match '"mcp__cua_repl"')){return ''}
 $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
 $active=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
 $order=0;$insideTurn=($windowStart -gt $startIndex);$reliable=$true
 foreach($line in $currentLines){
  if([string]::IsNullOrWhiteSpace($line)){continue}
  if([Text.Encoding]::UTF8.GetByteCount($line) -gt 1048576){if($insideTurn){$active.Clear();$reliable=$false};continue}
  $relevant=$line -match '"(function_call|function_call_output|task_started|turn_started|task_complete|turn_complete|turn_aborted)"'
  if(-not $relevant -and (-not $insideTurn -or -not $reliable)){continue}
  try{$record=ConvertFrom-Json -InputObject $line -ErrorAction Stop}catch{
   if($insideTurn){$active.Clear();$reliable=$false}
   continue
  }
  $payload=Prop $record 'payload'
  if($insideTurn -and ($null -eq $payload -or $payload -isnot [PSCustomObject])){$active.Clear();$reliable=$false;continue}
  $recordType=[string](Prop $record 'type' '');$kind=[string](Prop $payload 'type' '')
  $eventTurn=[string](Prop $payload 'turn_id' '')
  if($recordType -eq 'event_msg' -and $kind -in @('task_started','turn_started')){
   $insideTurn=$eventTurn -ceq $turnId;$active.Clear();$seen.Clear();$order=0;$reliable=$true
   continue
  }
  if(-not $insideTurn -or ($eventTurn -and $eventTurn -cne $turnId)){continue}
  if($recordType -eq 'event_msg' -and $kind -in @('task_complete','turn_complete','turn_aborted')){
   $insideTurn=$false;$active.Clear();$seen.Clear()
   continue
  }
  if(-not $reliable -or $recordType -ne 'response_item'){continue}
  $callId=[string](Prop $payload 'call_id' '')
  if($kind -eq 'function_call_output'){
   if(-not $callId -or [Text.Encoding]::UTF8.GetByteCount($callId) -gt 256){$active.Clear();$reliable=$false;continue}
   [void]$active.Remove($callId);[void]$seen.Add($callId)
   if($seen.Count -gt 4096){$active.Clear();$reliable=$false}
   continue
  }
  if($kind -ne 'function_call' -or $callId -cnotmatch '^[A-Za-z0-9_-]{1,256}$' -or $seen.Contains($callId) -or
     [string](Prop $payload 'namespace' '') -cne 'mcp__cua_repl' -or [string](Prop $payload 'name' '') -cne 'js'){continue}
  [void]$seen.Add($callId)
  if($seen.Count -gt 4096){$active.Clear();$reliable=$false;continue}
  $arguments=Prop $payload 'arguments'
  if($arguments -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($arguments) -gt 1048576){continue}
  try{$inputObject=$arguments|ConvertFrom-Json -ErrorAction Stop}catch{continue}
  $title=Prop $inputObject 'title'
  if($title -is [string] -and $title.Length -le 4096 -and -not [string]::IsNullOrWhiteSpace($title)){
   $order++;$active[$callId]=[PSCustomObject]@{Title=[regex]::Replace($title.Trim(),'\s+',' ');Order=$order}
  }
 }
 if($insideTurn -and $reliable -and $active.Count -gt 16){return ''}
 if($insideTurn -and $reliable -and $windowStart -gt $startIndex -and $active.Count){
  foreach($id in @($active.Keys)){
   for($index=$startIndex+1;$index -lt $windowStart;$index++){
    if(Codex-ContainsIdentifier $lines[$index] $id){[void]$active.Remove($id);break}
   }
  }
 }
 if($insideTurn -and $reliable -and $active.Count){
  $current=@($active.Values|Sort-Object Order -Descending|Select-Object -First 1)
  if($current.Count){return [string]$current[0].Title}
 }
 return ''
}

function Codex-FigmaCompleted($payload,[string]$id,[string]$turnId) {
 if(-not $turnId -or [string](Prop $payload 'type' '') -cne 'item_completed' -or
    [string](Prop $payload 'thread_id' '') -cne $id -or [string](Prop $payload 'turn_id' '') -cne $turnId){return $null}
 $item=Prop $payload 'item'
 $itemId=[string](Prop $item 'id' '')
 if([string](Prop $item 'type' '') -cne 'McpToolCall' -or [string](Prop $item 'server' '') -cne 'codex_apps' -or
    [string](Prop $item 'tool' '') -cne 'figma.use_figma' -or [string](Prop $item 'status' '') -cne 'completed' -or
    $itemId -cnotmatch '^[A-Za-z0-9_-]{1,256}$' -or $null -ne (Prop $item 'error') -or
    [bool](Prop (Prop $item 'result') 'isError' $false)){return $null}
 $arguments=Prop $item 'arguments';$description=Prop $arguments 'description'
 if($arguments -isnot [PSCustomObject] -or $description -isnot [string] -or
    $description.Length -gt 4096 -or [string]::IsNullOrWhiteSpace($description)){return $null}
 return [PSCustomObject]@{Id=$itemId;Description=[regex]::Replace($description.Trim(),'\s+',' ')}
}

function Codex-FirstFigmaCompletion([string[]]$lines,[int]$startIndex,[int]$candidateIndex,$candidate) {
 if($startIndex -lt 0 -or $null -eq $candidate -or $candidateIndex -le $startIndex -or $candidateIndex -ge $lines.Count){return $false}
 if(($lines.Count-1-$candidateIndex) -gt 512){return $false}
 for($index=$startIndex+1;$index -lt $candidateIndex;$index++){
  if(Codex-ContainsIdentifier $lines[$index] ([string]$candidate.Id)){return $false}
 }
 for($index=$candidateIndex+1;$index -lt $lines.Count;$index++){
  $line=$lines[$index]
  if([string]::IsNullOrWhiteSpace($line)){continue}
  if([Text.Encoding]::UTF8.GetByteCount($line) -gt 1048576){return $false}
  try{$record=ConvertFrom-Json -InputObject $line -ErrorAction Stop}catch{return $false}
  if($record -isnot [PSCustomObject] -or (Prop $record 'payload') -isnot [PSCustomObject]){return $false}
 }
 return $true
}

function Codex-Activity([string]$id) {
 $path = Session-File $id
 if (-not $path) { return "" }
 try {
  $tail=Read-TailText $path 2097152 $true
  $lines=$tail -split "`r?`n"; $startIndex=-1; $turnId=""; $latestCommentary=""
  for($index=$lines.Count-1;$index -ge 0;$index--){
   $line=$lines[$index]
   if($line.Length -gt 1048576 -or $line -notmatch '"(task_started|turn_started)"'){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   $payload=Prop $record "payload"
   if([string](Prop $record "type" "") -eq "event_msg" -and [string](Prop $payload "type" "") -in @("task_started","turn_started")){
    $startIndex=$index;$turnId=[string](Prop $payload "turn_id" "");break
   }
  }
  $currentTool=Codex-CurrentToolActivity $lines $turnId;$laterAction=$false;$figmaSuppressed=$false
  if($currentTool){return $currentTool}
  for($index=$lines.Count-1;$index -gt $startIndex;$index--){
   $line=$lines[$index]
   if($figmaSuppressed -and $line -notmatch '"(agent_reasoning|reasoning|Reasoning|commentary|AgentMessage)"'){continue}
   if($line.Length -gt 1048576 -or $line -notmatch '"(agent_reasoning|reasoning|Reasoning|commentary|item_completed)"'){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   $payload=Prop $record "payload"
   $recordType=[string](Prop $record "type" ""); $kind=[string](Prop $payload "type" "")
   $eventTurn=[string](Prop $payload "turn_id" "")
   if($turnId -and $eventTurn -and $turnId -cne $eventTurn){continue}
   $eventThread=[string](Prop $payload 'thread_id' '')
   if($eventThread -and $eventThread -cne $id){continue}
   $eventRole=[string](Prop $payload 'role' '')
   if($eventRole -and $eventRole -cne 'assistant'){continue}
   if($recordType -eq 'event_msg' -and $kind -eq 'item_completed' -and
      (-not $eventThread -or $eventThread -ceq $id) -and (-not $eventTurn -or $eventTurn -ceq $turnId)){
    $completedItem=Prop $payload 'item';$completedType=[string](Prop $completedItem 'type' '')
    if($completedType -notin @('Reasoning','AgentMessage')){
     $figma=Codex-FigmaCompleted $payload $id $turnId
     if($null -ne $figma){
      if(-not $laterAction -and -not $latestCommentary -and (Codex-FirstFigmaCompletion $lines $startIndex $index $figma)){$prefix=if($script:resolvedLanguage -eq 'en'){'Last Figma action: '}else{'Последнее действие в Figma: '};return $prefix+$figma.Description}
      $figmaSuppressed=$true;$laterAction=$true;continue
     }
     $laterAction=$true
    }
   }
   $summary=""
   if($recordType -eq "event_msg" -and $kind -eq "agent_reasoning"){
    $summary=[string](Prop $payload "text" "")
   }elseif(-not $latestCommentary -and $recordType -eq 'event_msg' -and $kind -eq 'agent_message' -and [string](Prop $payload 'phase' '') -eq 'commentary'){
    $text=[string](Prop $payload 'message' '');if($text.Trim()){$latestCommentary=$text}
   }elseif($recordType -eq "response_item" -and $kind -eq "reasoning"){
    foreach($part in @(Prop $payload "summary" @())){
     if([string](Prop $part "type" "") -eq "summary_text" -and [string](Prop $part "text" "")){$summary=[string](Prop $part "text" "")}
    }
   }elseif($recordType -ceq 'event_msg' -and $kind -ceq 'item_completed' -and $turnId -and $eventTurn -ceq $turnId -and $eventThread -ceq $id){
    $item=Prop $payload "item"
    if([string](Prop $item "type" "") -eq "Reasoning"){
     foreach($part in @(Prop $item "summary_text" @())){if($part -is [string] -and $part.Trim()){$summary=[string]$part}}
    }elseif(-not $latestCommentary -and [string](Prop $item "type" "") -eq "AgentMessage" -and [string](Prop $item "phase" "") -eq "commentary"){
     $itemRole=[string](Prop $item 'role' '')
     if(-not $itemRole -or $itemRole -ceq 'assistant'){foreach($part in @(Prop $item "content" @())){if([string](Prop $part "type" "") -eq "Text"){$text=[string](Prop $part "text" "");if($text.Trim()){$latestCommentary=$text}}}}
    }
   }elseif(-not $latestCommentary -and $recordType -eq 'response_item' -and $kind -eq "message" -and [string](Prop $payload "phase" "") -eq "commentary" -and [string](Prop $payload 'role' '') -ceq 'assistant'){
    foreach($part in @(Prop $payload "content" @())){if([string](Prop $part "type" "") -eq "output_text"){$text=[string](Prop $part "text" "");if($text.Trim()){$latestCommentary=$text}}}
   }
   if($latestCommentary){return [regex]::Replace($latestCommentary.Trim(),'\s+',' ')}
   if($summary){
    $firstLine=@($summary -split "`r?`n" | Where-Object {$_.Trim()} | Select-Object -First 1)
    if($firstLine.Count -gt 0){
     $value=$firstLine[0].Trim()
     if($value -match '^\*\*(?<heading>.+?)\*\*'){$value=$Matches.heading}
     return [regex]::Replace($value,'\s+',' ')
    }
   }
  }
  if($latestCommentary){return [regex]::Replace($latestCommentary.Trim(),'\s+',' ')}
 } catch {}
 return ""
}

function Read-ObservedCodexTail([string]$path,[string]$id) {
 $sharing=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
 try{
  $length=[long]$stream.Length
  $headCount=[int][Math]::Min([long]65536,$length)
  $offset=[Math]::Max([long]0,$length-[long]2097152)
  $tailStart=if($offset -gt 0){$offset-1}else{[long]0}
  $tailCount=[int]($length-$tailStart)
  $readRange={param([long]$position,[int]$count)
   $data=[byte[]]::new($count);[void]$stream.Seek($position,[IO.SeekOrigin]::Begin);$read=0
   while($read -lt $count){$n=$stream.Read($data,$read,$count-$read);if($n -le 0){throw 'Codex journal changed while reading.'};$read+=$n}
   return ,$data
  }
  $head=& $readRange 0 $headCount;$tail=& $readRange $tailStart $tailCount
  $headAgain=& $readRange 0 $headCount;$tailAgain=& $readRange $tailStart $tailCount
  if($stream.Length -lt $length){throw 'Codex journal was truncated.'}
  $hash=[Security.Cryptography.SHA256]::Create()
  try{
   if([Convert]::ToBase64String($hash.ComputeHash($head)) -cne [Convert]::ToBase64String($hash.ComputeHash($headAgain)) -or
      [Convert]::ToBase64String($hash.ComputeHash($tail)) -cne [Convert]::ToBase64String($hash.ComputeHash($tailAgain))){throw 'Codex journal changed while reading.'}
  }finally{$hash.Dispose()}
 }finally{$stream.Dispose()}
 $lineEnd=0;while($lineEnd -lt $head.Length -and $head[$lineEnd] -ne 10){$lineEnd++}
 if($lineEnd -ge $head.Length){return ''}
 $encoding=[Text.UTF8Encoding]::new($false,$true)
 $first=$encoding.GetString($head,0,$lineEnd).TrimStart([char]0xFEFF).TrimEnd([char]13)
 try{$meta=$first|ConvertFrom-Json -ErrorAction Stop}catch{return ''}
 if([string](Prop $meta 'type' '') -ne 'session_meta' -or [string](Prop (Prop $meta 'payload') 'id' '') -ne $id){return ''}
 $start=0
 if($offset -gt 0){
  $start=1
  if($tail[0] -ne 10){while($start -lt $tail.Length -and $tail[$start] -ne 10){$start++};if($start -lt $tail.Length){$start++}}
 }
 $end=$tail.Length
 if($end -gt $start -and $tail[$end-1] -ne 10){while($end -gt $start -and $tail[$end-1] -ne 10){$end--}}
 if($end -le $start){return ''}
 return $encoding.GetString($tail,$start,$end-$start)
}

function Codex-ObservedActivity([string]$id,[string]$startKey) {
 $path=Session-File $id
 if(-not $path){return ''}
 try{
  $tail=Read-ObservedCodexTail $path $id
  $lines=$tail -split "`r?`n"
  $turn=if($startKey.StartsWith('turn:',[StringComparison]::Ordinal)){$startKey.Substring(5)}else{''}
  $currentTool=Codex-CurrentToolActivity $lines $turn
  if($currentTool){return $currentTool}
  $startIndex=Codex-TurnStartIndex $lines $turn;$laterAction=$false;$figmaSuppressed=$false
  for($index=$lines.Count-1;$index -gt $startIndex;$index--){
   $line=$lines[$index]
   if($figmaSuppressed -and $line -notmatch '"(Reasoning|AgentMessage|agent_message|commentary)"'){continue}
   if($line.Length -gt 1048576 -or $line -notmatch '"(item_completed|agent_message|commentary)"'){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   $payload=Prop $record 'payload';$recordType=[string](Prop $record 'type' '');$kind=[string](Prop $payload 'type' '')
   $message=''
   $eventThread=[string](Prop $payload 'thread_id' '');$eventTurn=[string](Prop $payload 'turn_id' '')
   if(($eventThread -and $eventThread -cne $id) -or ($turn -and $eventTurn -and $eventTurn -cne $turn)){continue}
   $eventRole=[string](Prop $payload 'role' '')
   if($eventRole -and $eventRole -cne 'assistant'){continue}
   if($recordType -eq 'event_msg' -and $kind -eq 'item_completed' -and
      (-not $eventThread -or $eventThread -ceq $id) -and (-not $eventTurn -or $eventTurn -ceq $turn)){
    $actionItem=Prop $payload 'item';$actionType=[string](Prop $actionItem 'type' '')
    if($actionType -notin @('Reasoning','AgentMessage')){
     $figma=Codex-FigmaCompleted $payload $id $turn
     if($null -ne $figma){
      if(-not $laterAction -and (Codex-FirstFigmaCompletion $lines $startIndex $index $figma)){$prefix=if($script:resolvedLanguage -eq 'en'){'Last Figma action: '}else{'Последнее действие в Figma: '};return $prefix+$figma.Description}
      $figmaSuppressed=$true;$laterAction=$true;continue
     }
     $laterAction=$true
    }
   }
   if($recordType -eq 'event_msg' -and $kind -eq 'item_completed' -and $turn -and
      [string](Prop $payload 'thread_id' '') -eq $id -and [string](Prop $payload 'turn_id' '') -ceq $turn){
    $item=Prop $payload 'item';$itemType=[string](Prop $item 'type' '')
    if($itemType -eq 'Reasoning'){
     foreach($part in @(Prop $item 'summary_text' @())){if($part -is [string] -and $part.Trim()){$message=[string]$part}}
    }elseif($itemType -eq 'AgentMessage' -and [string](Prop $item 'phase' '') -eq 'commentary'){
     $itemRole=[string](Prop $item 'role' '')
     if(-not $itemRole -or $itemRole -ceq 'assistant'){foreach($part in @(Prop $item 'content' @())){if([string](Prop $part 'type' '') -eq 'Text'){$message=[string](Prop $part 'text' '')}}}
    }
   }elseif($recordType -eq 'event_msg' -and $kind -eq 'agent_message' -and [string](Prop $payload 'phase' '') -eq 'commentary'){
    $message=[string](Prop $payload 'message' '')
   }elseif($recordType -eq 'response_item' -and $kind -eq 'message' -and [string](Prop $payload 'role' '') -ceq 'assistant' -and [string](Prop $payload 'phase' '') -eq 'commentary'){
    foreach($part in @(Prop $payload 'content' @())){if([string](Prop $part 'type' '') -eq 'output_text'){$message=[string](Prop $part 'text' '')}}
   }
   if($message){
    $first=@($message -split "`r?`n"|Where-Object {$_.Trim()}|Select-Object -First 1)
    if($first.Count){$value=$first[0].Trim();if($value -match '^\*\*(?<heading>.+?)\*\*'){$value=$Matches.heading};return [regex]::Replace($value,'\s+',' ')}
   }
  }
 }catch{}
 return ''
}

function Plan-Progress($steps, [int]$fallback) {
 $all = @($steps)
 if ($all.Count -eq 0) { return $fallback }
 $done = @($all | Where-Object { [string](Prop $_ "status" "pending") -eq "done" }).Count
 return [int][Math]::Round(($done / $all.Count) * 100)
}

function Codex-IndexCandidates {
 $sessionMap=@{}
 $needed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($id in @($script:observedCodex.Keys)){
  if([string]$id -match '^[A-Za-z0-9_-]{1,128}$'){[void]$needed.Add([string]$id)}
 }
 if(Test-Path -LiteralPath $lockDirectory -PathType Container -ErrorAction Stop){
  foreach($lock in Get-ChildItem -LiteralPath $lockDirectory -File -Filter '*.lock' -ErrorAction Stop){
   $id=[IO.Path]::GetFileNameWithoutExtension($lock.Name)
   if($id -notmatch '^[A-Za-z0-9_-]{1,128}$'){continue}
   $lockState=Lock-State $lock.FullName
   if($lockState -eq 'unavailable'){throw 'Codex session lock metadata is unavailable.'}
   if($lockState -eq 'present'){[void]$needed.Add($id)}
   if($needed.Count -gt 256){throw 'Too many Codex session lock entries to inspect safely.'}
  }
 }
 if($needed.Count -gt 256){throw 'Too many observed Codex sessions to inspect safely.'}
 # Read one bounded snapshot. Do not read a growing index to EOF or expose a
 # partial snapshot as a complete list when the file changes during the read.
 $sharing=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
 $stream=[IO.File]::Open($sessionIndex,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
 try{
  $length=[long]$stream.Length
  if($length -gt 16777216){throw 'Codex session index exceeds the safe read budget.'}
  $bytes=[byte[]]::new([int]$length)
  $offset=0
  while($offset -lt $bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read -le 0){throw 'Codex session index changed during reading.'};$offset+=$read}
  if($stream.Length -ne $length){throw 'Codex session index changed during reading.'}
 }finally{$stream.Dispose()}
 $memory=[IO.MemoryStream]::new($bytes,$false)
 try{
  $reader=[IO.StreamReader]::new($memory,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
  try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
 }finally{$memory.Dispose()}
 if($text.Length -gt 0 -and -not $text.EndsWith("`n",[StringComparison]::Ordinal)){throw 'Codex session index has an incomplete final record.'}
 $recent=New-Object 'Collections.Generic.Queue[string]'
 $filter=if($needed.Count){'"(?:'+((@($needed)|ForEach-Object {[regex]::Escape($_)}) -join '|')+')"'}else{''}
 foreach($line in ($text -split "`r?`n")){
  if(-not $line){continue}
  if($line.Length -gt 1048576){throw 'Codex session index contains an oversized line.'}
  if($recent.Count -eq 50){[void]$recent.Dequeue()};$recent.Enqueue($line)
  if($filter -and $line -match $filter){
   try{$session=$line|ConvertFrom-Json -ErrorAction Stop;$id=[string](Prop $session 'id' '');if($needed.Contains($id)){$sessionMap[$id]=$session}}catch{}
  }
 }
 foreach($line in $recent){
  try{$session=$line|ConvertFrom-Json -ErrorAction Stop;$id=[string](Prop $session 'id' '');if($id -match '^[A-Za-z0-9_-]{1,128}$'){$sessionMap[$id]=$session}}catch{}
 }
 foreach($session in $sessionMap.Values){
  try{
   $id=[string](Prop $session "id" "")
   $updated=[DateTime]$session.updated_at
   $yearFolder=Join-Path $sessionsDirectory ([string]$updated.Year)
   $monthFolder=Join-Path $yearFolder $updated.Month.ToString("00")
   $script:sessionDates[$id]=Join-Path $monthFolder $updated.Day.ToString("00")
  }catch{}
 }
 return @($sessionMap.Values)
}

function Codex-SubagentMetadata($payload) {
 $spawn=Prop (Prop (Prop $payload 'source') 'subagent') 'thread_spawn'
 if($null -eq $spawn){return $null}
 $parent=[string](Prop $payload 'parent_thread_id' '')
 $name=[string](Prop $payload 'agent_nickname' '')
 $path=[string](Prop $payload 'agent_path' '')
 $uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 if($parent -notmatch $uuid -or [string](Prop $payload 'id' '') -notmatch $uuid -or
    $parent -cne [string](Prop $spawn 'parent_thread_id' '') -or
    [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 256 -or $name -match '[\x00-\x1f\x7f]' -or
    $name -cne [string](Prop $spawn 'agent_nickname' '') -or
    $path -cnotmatch '^/root/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$' -or [Text.Encoding]::UTF8.GetByteCount($path) -gt 1024 -or
    $path -cne [string](Prop $spawn 'agent_path' '') -or
    [string]::Equals($parent,[string](Prop $payload 'id' ''),[StringComparison]::OrdinalIgnoreCase)){return $null}
 return [PSCustomObject]@{ParentThreadId=$parent;AgentNickname=$name.Trim()}
}

function Codex-ReadSubagentMetadata([string]$id) {
 try{
  $path=Session-File $id
  if(-not $path){return $null}
  $attributes=[IO.File]::GetAttributes($path)
  if(($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0){return $null}
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try{
   $count=[int][Math]::Min([long]65536,[long]$stream.Length);$bytes=[byte[]]::new($count);$offset=0
   while($offset -lt $count){$read=$stream.Read($bytes,$offset,$count-$offset);if($read -le 0){return $null};$offset+=$read}
  }finally{$stream.Dispose()}
  $end=[Array]::IndexOf($bytes,[byte]10);if($end -lt 0){return $null}
  $line=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,0,$end).TrimStart([char]0xFEFF).TrimEnd([char]13)
  $record=$line|ConvertFrom-Json -ErrorAction Stop;$payload=Prop $record 'payload'
  if([string](Prop $record 'type' '') -cne 'session_meta' -or
     -not [string]::Equals([string](Prop $payload 'id' ''),$id,[StringComparison]::OrdinalIgnoreCase)){return $null}
  $checker='AITaskMonitor.CodexObservation.CodexRecentEventObserver' -as [type]
  if($null -eq $checker -or -not $checker::HeaderHasUniqueKeys($line)){return $null}
  return Codex-SubagentMetadata $payload
 }catch{return $null}
}

function Codex-UnindexedCandidates([bool]$HasIndexedHistory=$false) {
 # A rollout is evidence of a session, never evidence that its writer is live.
 # Keep a resumable directory cursor so a full page cannot hide later files.
 $now=[Diagnostics.Stopwatch]::GetTimestamp()
 $cached=Get-Variable -Scope Script -Name unindexedScan -ErrorAction SilentlyContinue
 $cachedRootSafe=$false
 try{
  $cachedAttributes=[IO.File]::GetAttributes($sessionsDirectory)
  $cachedRootSafe=(($cachedAttributes -band [IO.FileAttributes]::Directory) -ne 0 -and ($cachedAttributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
 }catch{}
 if($cachedRootSafe -and $null -ne $cached -and $null -ne $cached.Value -and
    [string]::Equals([string]$cached.Value.Root,[string]$sessionsDirectory,[StringComparison]::OrdinalIgnoreCase) -and -not [bool]$cached.Value.RootMissing -and
    ($now-[long]$cached.Value.Tick) -ge 0 -and ($now-[long]$cached.Value.Tick) -lt ([long][Diagnostics.Stopwatch]::Frequency*5)){
  $script:codexDiscoveryFailed=[bool]$cached.Value.Failed
  return @($cached.Value.Items)
 }
 $found=@{};$ambiguous=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 $count=0;$bytesRead=[long]0;$failed=$false;$completedRound=$false;$rootMissing=$false
 $uuid='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
 $cursorVariable=Get-Variable -Scope Script -Name unindexedCursor -ErrorAction SilentlyContinue
 $cursor=if($null -ne $cursorVariable){$cursorVariable.Value}else{$null}
 $today=[DateTime]::UtcNow.Date
 $localToday=[DateTime]::Now.Date
 if($null -ne $cursor -and (-not [string]::Equals([string]$cursor.Root,[string]$sessionsDirectory,[StringComparison]::OrdinalIgnoreCase) -or $cursor.Day -ne $today -or $cursor.LocalDay -ne $localToday)){
  if($null -ne $cursor.Enumerator){try{$cursor.Enumerator.Dispose()}catch{}}
  $cursor=$null
 }
 try{
  $rootAttributes=[IO.File]::GetAttributes($sessionsDirectory)
  if(($rootAttributes -band [IO.FileAttributes]::Directory) -eq 0 -or ($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Unavailable sessions directory.'}
  if($null -eq $cursor){
   $visited=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
   $days=New-Object 'Collections.Generic.List[object]'
   for($offset=0;$offset -lt 7;$offset++){
    foreach($date in @($today.AddDays(-$offset),$localToday.AddDays(-$offset))){
     $year=Join-Path $sessionsDirectory $date.ToString('yyyy',[Globalization.CultureInfo]::InvariantCulture)
     $month=Join-Path $year $date.ToString('MM',[Globalization.CultureInfo]::InvariantCulture)
     $day=Join-Path $month $date.ToString('dd',[Globalization.CultureInfo]::InvariantCulture)
     if($visited.Add($day)){$days.Add([PSCustomObject]@{Year=$year;Month=$month;Day=$day})}
    }
   }
   $cursor=[PSCustomObject]@{Root=$sessionsDirectory;Day=$today;LocalDay=$localToday;Days=$days.ToArray();Index=0;Enumerator=$null;Pending='';PassFailed=$false;ReportFailed=$false}
   $script:unindexedCursor=$cursor
  }
  while($count -lt 256 -and $bytesRead -lt 4194304){
   if($null -eq $cursor.Enumerator){
    if($cursor.Index -ge $cursor.Days.Count){$cursor.Index=0;$completedRound=$true;break}
    $entry=$cursor.Days[$cursor.Index]
    try{
     foreach($directory in @($entry.Year,$entry.Month,$entry.Day)){
      $attributes=[IO.File]::GetAttributes($directory)
      if(($attributes -band [IO.FileAttributes]::Directory) -eq 0 -or ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Unavailable dated directory.'}
     }
     $cursor.Enumerator=([IO.Directory]::EnumerateFiles($entry.Day,'rollout-*.jsonl',[IO.SearchOption]::TopDirectoryOnly)).GetEnumerator()
    }catch{
     $exception=$_.Exception
     while($null -ne $exception.InnerException){$exception=$exception.InnerException}
     if($exception -isnot [IO.FileNotFoundException] -and $exception -isnot [IO.DirectoryNotFoundException]){$failed=$true}
     $cursor.Index++;continue
    }
   }
   if($cursor.Pending){$path=[string]$cursor.Pending;$cursor.Pending=''}
   else{
    try{$hasNext=$cursor.Enumerator.MoveNext()}
    catch{$failed=$true;try{$cursor.Enumerator.Dispose()}catch{};$cursor.Enumerator=$null;$cursor.Index++;continue}
    if(-not $hasNext){try{$cursor.Enumerator.Dispose()}catch{};$cursor.Enumerator=$null;$cursor.Index++;continue}
    $path=[string]$cursor.Enumerator.Current
   }
   $count++
   $name=[IO.Path]::GetFileName($path)
   if($name -notmatch ('^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?<thread>'+ $uuid +')(?:_'+$uuid+')?\.jsonl$')){continue}
   $id=[string]$Matches.thread
   if($ambiguous.Contains($id)){continue}
   try{
    $attributes=[IO.File]::GetAttributes($path)
    if(($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0){$failed=$true;continue}
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{
     $length=[int][Math]::Min([long]65536,[long]$stream.Length)
     if(($bytesRead+$length) -gt 4194304){$cursor.Pending=$path;break}
     $bytes=[byte[]]::new($length);$offset=0
     while($offset -lt $length){$read=$stream.Read($bytes,$offset,$length-$offset);if($read -le 0){throw 'Rollout changed.'};$offset+=$read;$bytesRead+=$read}
    }finally{$stream.Dispose()}
    $end=[Array]::IndexOf($bytes,[byte]10)
    if($end -lt 0){continue}
    $first=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,0,$end).TrimStart([char]0xFEFF).TrimEnd([char]13)
    $record=$first|ConvertFrom-Json -ErrorAction Stop
    if([string](Prop $record 'type' '') -ne 'session_meta' -or
       -not [string]::Equals([string](Prop (Prop $record 'payload') 'id' ''),$id,[StringComparison]::OrdinalIgnoreCase)){continue}
    if($found.ContainsKey($id)){$found.Remove($id);[void]$ambiguous.Add($id);continue}
    $subagent=Codex-SubagentMetadata (Prop $record 'payload')
    if($null -ne $subagent){
     $checker='AITaskMonitor.CodexObservation.CodexRecentEventObserver' -as [type]
     if($null -eq $checker -or -not $checker::HeaderHasUniqueKeys($first)){$subagent=$null}
    }
    $found[$id]=[PSCustomObject]@{id=$id;thread_name='Задача Codex';titleGenerated=$true;unindexed=$true;path=$path;updated_at=[IO.File]::GetLastWriteTimeUtc($path).ToString('o');parentThreadId=[string](Prop $subagent 'ParentThreadId' '');agentNickname=[string](Prop $subagent 'AgentNickname' '')}
   }catch{
    $exception=$_.Exception
    while($null -ne $exception.InnerException){$exception=$exception.InnerException}
    if($exception -isnot [IO.FileNotFoundException] -and $exception -isnot [IO.DirectoryNotFoundException]){$failed=$true}
   }
  }
 }catch{
  $exception=$_.Exception
  while($null -ne $exception.InnerException){$exception=$exception.InnerException}
  $rootMissing=($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException])
  if($rootMissing){
   $previous=Get-Variable -Scope Script -Name lastCodexTasks -ErrorAction SilentlyContinue
   $failed=$HasIndexedHistory -or ($null -ne $previous -and @($previous.Value|Where-Object {$null -ne $_}).Count -gt 0)
  }else{$failed=$true}
  if($null -ne $cursor -and $null -ne $cursor.Enumerator){try{$cursor.Enumerator.Dispose()}catch{};$cursor.Enumerator=$null}
  if($rootMissing){$cursor=$null;$script:unindexedCursor=$null}
 }
 if($null -ne $cursor){
  $cursor.PassFailed=[bool]$cursor.PassFailed -or $failed
  if($completedRound){$cursor.ReportFailed=[bool]$cursor.PassFailed;$cursor.PassFailed=$false}
  $failed=$failed -or [bool]$cursor.PassFailed -or [bool]$cursor.ReportFailed
 }
 $items=@($found.Values)
 $script:codexDiscoveryFailed=$failed
 $script:unindexedScan=[PSCustomObject]@{Root=$sessionsDirectory;Tick=$now;Items=$items;CheckedFiles=$count;BytesRead=$bytesRead;Failed=$failed;RootMissing=$rootMissing}
 return $items
}

function Group-CodexTasks($tasks,$links,$titles) {
 $uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 $local=@{};$other=New-Object 'Collections.Generic.List[object]'
 foreach($task in @($tasks)){
  $id=[string](Prop $task 'Id' '')
  if([string](Prop $task 'Provider' '') -cne 'codex' -or [string](Prop $task 'Source' '') -ceq 'Codex Cloud' -or $id -notmatch $uuid){$other.Add($task);continue}
  if([bool](Prop $task 'TerminalConfirmed' $false)){continue}
  if(-not $local.ContainsKey($id)){$local[$id]=$task}
 }
 $groups=@{};$members=@{};$resolvedRoots=@{};$invalidChains=@{}
 foreach($id in @($local.Keys)){
  if(-not $links.ContainsKey($id) -or [bool](Prop $links[$id] 'IsRoot' $false)){continue}
  $cursor=$id;$seen=@{};$trail=New-Object 'Collections.Generic.List[string]';$valid=$true
  while($links.ContainsKey($cursor)){
   if([bool](Prop $links[$cursor] 'IsRoot' $false)){break}
   if($invalidChains.ContainsKey($cursor)){$valid=$false;break}
   if($resolvedRoots.ContainsKey($cursor)){$cursor=[string]$resolvedRoots[$cursor];break}
   if($seen.ContainsKey($cursor)){$valid=$false;break}
   $seen[$cursor]=$true;$trail.Add($cursor);$reference=$links[$cursor]
   $parent=[string](Prop $reference 'ParentThreadId' '')
   if([bool](Prop $reference 'Conflict' $false) -or $parent -notmatch $uuid -or [string]::Equals($parent,$cursor,[StringComparison]::OrdinalIgnoreCase)){$valid=$false;break}
   $cursor=$parent
  }
  if(-not $links.ContainsKey($cursor)){$valid=$false}
  if($valid){foreach($item in $trail){$resolvedRoots[$item]=$cursor}}
  else{foreach($item in $trail){$invalidChains[$item]=$true}}
  if(-not $valid -or [string]::Equals($cursor,$id,[StringComparison]::OrdinalIgnoreCase)){continue}
  if(-not $groups.ContainsKey($cursor)){$groups[$cursor]=@{}}
  $groups[$cursor][$id]=$true;$members[$id]=$cursor
 }
 $result=New-Object 'Collections.Generic.List[object]'
 foreach($id in @($local.Keys)){
  if($members.ContainsKey($id)){continue}
  $task=$local[$id]
  if($groups.ContainsKey($id)){
   $task=$task.PSObject.Copy();$unknown=$false
   $agentIds=[string[]]@($groups[$id].Keys);[Array]::Sort($agentIds,[StringComparer]::OrdinalIgnoreCase)
   $agents=New-Object 'Collections.Generic.List[object]'
   foreach($member in $agentIds){$agents.Add($local[$member]);if(-not [bool](Prop $local[$member] 'Active' $false) -and -not [bool](Prop $local[$member] 'Paused' $false)){$unknown=$true}}
   $task|Add-Member -NotePropertyMembers @{RelatedAgentCount=$agentIds.Length;RelatedAgentsUnconfirmed=$unknown;RelatedAgentIds=$agentIds;RelatedAgents=$agents.ToArray()} -Force
  }
  $result.Add($task)
 }
 foreach($parent in @($groups.Keys)){
  if($local.ContainsKey($parent)){continue}
  $title=if($titles.ContainsKey($parent)){[string]$titles[$parent]}else{''};$generated=([string]::IsNullOrWhiteSpace($title) -or $title -ceq 'Guardian review')
  if($generated){$title='Задача Codex'}
  $agentIds=[string[]]@($groups[$parent].Keys);[Array]::Sort($agentIds,[StringComparer]::OrdinalIgnoreCase)
  $agents=New-Object 'Collections.Generic.List[object]';$unknown=$false
  foreach($member in $agentIds){$agents.Add($local[$member]);if(-not [bool](Prop $local[$member] 'Active' $false) -and -not [bool](Prop $local[$member] 'Paused' $false)){$unknown=$true}}
  $result.Add([PSCustomObject]@{Id=$parent;Title=$title;TitleGenerated=$generated;Activity='Статус не подтверждён';ActivityGenerated=$true;ActivityObserved=$false;Active=$false;Paused=$false;Progress=$null;ProgressKind='none';ProgressBasis='task';Provider='codex';ProviderName='Codex';Status='Статус не подтверждён';Updated=[DateTime]::MinValue;Started=[DateTime]::MinValue;StartKey='';Steps=@();Source='Оценка активности';PlanConfirmed=$false;RelatedAgentCount=$agentIds.Length;RelatedAgentsUnconfirmed=$unknown;RelatedAgentIds=$agentIds;RelatedAgents=$agents.ToArray()})
 }
 foreach($task in $other){$result.Add($task)}
 return @($result.ToArray())
}

function Codex-Tasks {
 $script:codexSourcePartial=$false
 $script:codexDiscoveryFailed=$false
 $script:codexTerminated=@{}
 $script:codexUnconfirmedEndings=@{}
 $script:codexGroupLinks=@{};$script:codexGroupTitles=@{}
 $indexAvailable=Test-Path -LiteralPath $sessionIndex -PathType Leaf -ErrorAction Stop
 if (-not $indexAvailable -and -not (Test-Path -LiteralPath $codexHome -PathType Container -ErrorAction Stop)) {
  $cursorVariable=Get-Variable -Scope Script -Name unindexedCursor -ErrorAction SilentlyContinue
  if($null -ne $cursorVariable -and $null -ne $cursorVariable.Value -and $null -ne $cursorVariable.Value.Enumerator){try{$cursorVariable.Value.Enumerator.Dispose()}catch{}}
  $script:unindexedCursor=$null;$script:unindexedScan=$null
  if(@($script:lastCodexTasks).Count -gt 0){throw 'Codex source is unavailable.'}
  return @()
 }
 # Local journals and lock-file presence do not establish a complete set of
 # current tasks, even when all of the readable events are well formed.
 $script:codexSourcePartial=$true
 $sessions=@()
 if($indexAvailable){$sessions=@(Codex-IndexCandidates)}
 $indexed=@{}
 if($null -eq (Get-Variable -Scope Script -Name unindexedPaths -ErrorAction SilentlyContinue)){$script:unindexedPaths=@{}}
 foreach($session in $sessions){
  $id=[string](Prop $session 'id' '')
  $indexed[$id]=$true
  if($id){[void]$script:unindexedPaths.Remove($id)}
 }
 foreach($candidate in @(Codex-UnindexedCandidates -HasIndexedHistory ($sessions.Count -gt 0))){
  $id=[string]$candidate.id
  if($indexed.ContainsKey($id)){continue}
  if($script:unindexedPaths.ContainsKey($id) -and
     -not [string]::Equals([string]$script:unindexedPaths[$id],[string]$candidate.path,[StringComparison]::OrdinalIgnoreCase)){continue}
  if(-not $script:unindexedPaths.ContainsKey($id) -and $script:unindexedPaths.Count -ge 256){continue}
  $indexed[$id]=$true
  $sessions+=@($candidate)
  $script:unindexedPaths[$id]=[string]$candidate.path
 }
 $rolloutReader=Get-Variable -Scope Script -Name codexRolloutReader -ErrorAction SilentlyContinue
 $snapshot=$null
 if($null -ne $rolloutReader){
  if($null -ne $rolloutReader.Value -and $sessions.Count -gt 0){
   try{
    $ids=[string[]]@($sessions|ForEach-Object {[string](Prop $_ 'id' '')})
    $revisions=[string[]]@($sessions|ForEach-Object {[string](Prop $_ 'updated_at' '')})
    $snapshot=$rolloutReader.Value.Snapshot($codexHome,$ids,$revisions)
   }catch{}
  }
  Update-CodexRolloutPaths $snapshot $sessions
 }
 $codexTitles=$null
 $parentTitles=@{};$subagentRefs=@{};$groupLinks=@{};$activityIdentities=@{}
 $verifiedReferences=Prop $snapshot 'ParentReferences'
 $identityObserver=Get-Variable -Scope Script -Name codexRecentEventObserver -ErrorAction SilentlyContinue
 $verifiedPaths=Prop $snapshot 'Paths'
 foreach($session in $sessions){
  $parentId=[string](Prop $session 'id' '');$parentTitle=[string](Prop $session 'thread_name' '')
  if($parentId -and -not [string]::IsNullOrWhiteSpace($parentTitle) -and $parentTitle -cne 'Guardian review' -and -not [bool](Prop $session 'titleGenerated' $false)){$parentTitles[$parentId]=$parentTitle}
  # A paged discovery result can contain competing rollouts for the same ID.
  # Use its parent and nickname only after the reader and observer agree on
  # the selected file identity; otherwise the separate title stays neutral.
  $check=$null
  if($null -ne $identityObserver -and $null -ne $identityObserver.Value -and $null -ne $verifiedPaths -and $verifiedPaths.ContainsKey($parentId)){
   try{
    $check=$identityObserver.Value.Snapshot($parentId,[string]$verifiedPaths[$parentId])
    if([bool]$check.BaselineReady -and [string]$check.IdentityToken){$activityIdentities[$parentId]=[string]$check.IdentityToken}
   }catch{}
  }
  if($null -ne $verifiedReferences -and $verifiedReferences.ContainsKey($parentId)){
   $verified=$verifiedReferences[$parentId];$identityMatches=$false
   if(-not [bool](Prop $verified 'Conflict' $false) -and $null -ne $check -and $activityIdentities.ContainsKey($parentId) -and [string](Prop $verified 'IdentityToken' '')){
    $identityMatches=$activityIdentities[$parentId] -ceq [string]$verified.IdentityToken
   }
   if($identityMatches){$groupLinks[$parentId]=$verified;if(-not [bool](Prop $verified 'IsRoot' $false)){$subagentRefs[$parentId]=$verified}}
   else{$groupLinks[$parentId]=[PSCustomObject]@{Conflict=$true};[void]$subagentRefs.Remove($parentId)}
  }
 }
 # Before using a root, verify all matching local rollouts in the background.
 # An incomplete scan, unavailable reader or contradictory root keeps every
 # affected task separate until the evidence becomes available.
 $referencedParents=@{}
 foreach($reference in @($groupLinks.Values)){
  if(-not [bool](Prop $reference 'Conflict' $false) -and -not [bool](Prop $reference 'IsRoot' $false)){
   $candidate=[string](Prop $reference 'ParentThreadId' '');if($candidate){$referencedParents[$candidate]=$true}
  }
 }
 $rootReader=Get-Variable -Scope Script -Name codexRootEvidenceReader -ErrorAction SilentlyContinue
 foreach($candidate in @($referencedParents.Keys)){
  if(-not $groupLinks.ContainsKey($candidate) -or -not [bool](Prop $groupLinks[$candidate] 'IsRoot' $false)){continue}
  $agreed=$false
  if($null -ne $rootReader -and $null -ne $rootReader.Value -and $null -ne $verifiedPaths -and
     $verifiedPaths.ContainsKey($candidate) -and $activityIdentities.ContainsKey($candidate)){
   try{$proof=$rootReader.Value.Snapshot($candidate,[string]$verifiedPaths[$candidate],[string]$activityIdentities[$candidate]);$agreed=[bool]$proof.Complete -and [bool]$proof.RootsAgree}catch{}
  }
  if(-not $agreed){$groupLinks[$candidate]=[PSCustomObject]@{Conflict=$true}}
 }
 $titleReader=Get-Variable -Scope Script -Name codexTitleReader -ErrorAction SilentlyContinue
 if($null -ne $titleReader -and $null -ne $titleReader.Value -and $sessions.Count -gt 0){
  try{
   $parentIds=@($subagentRefs.Values | ForEach-Object {[string]$_.ParentThreadId} | Where-Object {$_})
   $sessionIds=@($sessions | Sort-Object -Property @{Expression={[string](Prop $_ 'updated_at' '')};Descending=$true} |
    ForEach-Object {[string](Prop $_ 'id' '')})
   $titleIds=[string[]]@(($parentIds+$sessionIds) | Select-Object -Unique -First 256)
   $codexTitles=$titleReader.Value.Snapshot($codexHome,$titleIds)
  }catch{}
 }
 $discoveryVariable=Get-Variable -Scope Script -Name 'sessionDiscovery' -ErrorAction SilentlyContinue
 if ($null -ne $discoveryVariable -and $null -ne $discoveryVariable.Value) {
  $cache=$discoveryVariable.Value
  [Threading.Monitor]::Enter($cache.Gate)
  try {
   $cache.DatedMisses.Clear()
   $versions=@{}
   $newActivity=$false
   foreach ($session in $sessions) {
    $id=[string](Prop $session 'id' '')
    if ($id -notmatch '^[A-Za-z0-9_-]{1,128}$') { continue }
    $updated=[string](Prop $session 'updated_at' '')
    $versions[$id]=$updated
    if (-not $cache.Files.ContainsKey($id) -and
        (-not $cache.IndexVersions.ContainsKey($id) -or $cache.IndexVersions[$id] -cne $updated)) { $newActivity=$true }
   }
   $cache.IndexVersions=$versions
   if ($newActivity) {
    $cache.RetrySeconds=5
    $cache.HotUntilTicks=[Diagnostics.Stopwatch]::GetTimestamp()+([long][Diagnostics.Stopwatch]::Frequency * 30)
   }
  } finally {
   [Threading.Monitor]::Exit($cache.Gate)
  }
 }
 $manual = Manual-Tasks $sessions
 $items = New-Object Collections.Generic.List[object]
 foreach ($session in $sessions) {
  $id = [string]$session.id; $title = [string]$session.thread_name
  if($title -eq "Guardian review"){continue}
  $titleGenerated=[bool](Prop $session 'titleGenerated' $false)
  if(($titleGenerated -or [string]::IsNullOrWhiteSpace($title)) -and $null -ne $codexTitles -and $codexTitles.ContainsKey($id)){$title=[string]$codexTitles[$id];$titleGenerated=$false}
  if(($titleGenerated -or [string]::IsNullOrWhiteSpace($title)) -and $subagentRefs.ContainsKey($id)){
   $parentId=[string]$subagentRefs[$id].ParentThreadId;$agentName=[string]$subagentRefs[$id].AgentNickname
   $parentTitle=if($parentTitles.ContainsKey($parentId)){$parentTitles[$parentId]}elseif($null -ne $codexTitles -and $codexTitles.ContainsKey($parentId)){$codexTitles[$parentId]}else{''}
   if(-not [string]::IsNullOrWhiteSpace($parentTitle) -and $parentTitle -cne 'Guardian review' -and $agentName){$agentWord=if($script:resolvedLanguage -eq 'en'){'agent'}else{'агент'};$title="$parentTitle ($agentWord $agentName)";$titleGenerated=$false}
  }
  if([string]::IsNullOrWhiteSpace($title)){$title='Задача Codex';$titleGenerated=$true}
  $unindexed=[bool](Prop $session 'unindexed' $false)
  if($title -eq "Guardian review"){continue}
  $threadState = Thread-State $id $unindexed
  $recentObserved=$false;$currentPath=''
  if($null -ne $rolloutReader){
   $currentPath=Session-File $id
   $observer=Get-Variable -Scope Script -Name codexRecentEventObserver -ErrorAction SilentlyContinue
   if($threadState.State -eq 'unknown' -and -not $threadState.HasStartMarker -and
      $null -ne $observer -and $null -ne $observer.Value -and
      $script:codexRolloutPaths.ContainsKey($id) -and
      [string]::Equals([string]$script:codexRolloutPaths[$id],$currentPath,[StringComparison]::OrdinalIgnoreCase)){
    try{$recentObserved=[bool]$observer.Value.Snapshot($id,$currentPath).HasEvent}catch{}
   }
   if($script:codexObservedStarts.ContainsKey($id) -and
      -not [string]::Equals([string]$script:codexObservedStarts[$id].Path,$currentPath,[StringComparison]::OrdinalIgnoreCase)){
    # A fallback path is not evidence that the observed rollout was replaced.
    # Preserve its start and let Source-Snapshot retain the prior card until
    # a newly verified path is available.
    if(-not $script:codexRolloutPaths.ContainsKey($id)){
     if($threadState.State -in @('completed','interrupted') -or [bool](Prop $threadState 'AmbiguousTerminal' $false)){$script:codexUnconfirmedEndings[$id]=$true}
     continue
    }
    [void]$script:codexObservedStarts.Remove($id);[void]$script:codexTerminalChecks.Remove($id)
   }
   if($threadState.State -in @('completed','interrupted') -or [bool](Prop $threadState 'AmbiguousTerminal' $false)){
    # A database path and a matching historical turn do not establish that a
    # newer rollout has not taken over. Keep any previously seen card unknown.
    if(-not ($recentObserved -and $threadState.State -eq 'unknown' -and [bool](Prop $threadState 'AmbiguousTerminal' $false))){
     $script:codexUnconfirmedEndings[$id]=$true
     continue
    }
   }elseif($currentPath -and $threadState.State -eq 'unknown' -and $threadState.HasStartMarker -and $threadState.StartKey){
    $script:codexObservedStarts[$id]=[PSCustomObject]@{Path=$currentPath;StartKey=[string]$threadState.StartKey}
    [void]$script:codexTerminalChecks.Remove($id)
   }
  }
  if($threadState.State -in @('completed','interrupted')){$script:codexTerminated[$id]=$true}
  if($recentObserved){$script:observedCodex[$id]=$true}
  $eventActive = $threadState.State -eq "active"
  $uncertain = Codex-Uncertain $id $threadState
  if($threadState.State -in @("interrupted","unobserved")){
   if($unindexed){
    $oldPath=[string]$script:unindexedPaths[$id];[void]$script:unindexedPaths.Remove($id)
    foreach($cacheName in @('lifecycleState','planCache')){$item=Get-Variable -Scope Script -Name $cacheName -ErrorAction SilentlyContinue;if($null -ne $item -and $null -ne $item.Value -and $oldPath){[void]$item.Value.Remove($oldPath)}}
   }
   continue
  }
  $observationOnly=$uncertain -and -not $threadState.HasStartMarker
  $override = if($observationOnly){$null}elseif ($manual.ContainsKey($id)) { $manual[$id] } elseif ($manual.ContainsKey("title:$title")) { $manual["title:$title"] } else { $null }
  $paused = $false; $steps = @(); $source = "Оценка активности"; $planConfirmed=$true
  if ($null -ne $override) {
   $title = [string](Prop $override "title" $title)
   if($null -ne $override.PSObject.Properties['title']){$titleGenerated=$false}
   $paused = [bool](Prop $override "paused" $false)
   $steps = @(Prop $override "steps" @())
   if ($steps.Count -gt 0) { $source = "План задачи" }
  }
  $uncertain=$uncertain -and -not $paused
  if ($steps.Count -eq 0 -and ($eventActive -or ($uncertain -and -not $observationOnly))) {
   $steps = @(Codex-Plan $id)
   if ($steps.Count -gt 0) {
    $source = "План Codex"
    if($null -ne (Get-Variable -Scope Script -Name planConfirmations -ErrorAction SilentlyContinue) -and $script:planConfirmations.ContainsKey($id)){$planConfirmed=[bool]$script:planConfirmations[$id]}
   }
  }
  $running = $eventActive -and -not $paused
  $status = if ($paused) { "На паузе" } elseif ($running) { "В работе" } elseif ($uncertain) { "Статус не подтверждён" } else { "Ожидает" }
  $progress=$null; $progressKind="none"; $progressBasis="task"
  if($steps.Count -gt 0){$progress=Plan-Progress $steps 0;$progressKind="exact";$progressBasis="steps"}
  if ($null -ne $override) {
   $value = Prop $override "progress"
   if ($null -ne $value) {
    $progress = [Math]::Max(0, [Math]::Min(100, [int]$value))
    $progressKind=[string](Prop $override "progressKind" "approximate")
    $progressBasis="task"
    if($progressKind -notin @("exact","approximate")){$progressKind="approximate"}
   }
   if(-not $uncertain){$status = [string](Prop $override "status" $status)}
  }
  if ($steps.Count -gt 0) {
   $doneCount = @($steps | Where-Object { [string](Prop $_ "status" "pending") -eq "done" }).Count
   if ($doneCount -eq $steps.Count) { $progress = 100; $progressKind="exact"; $progressBasis="steps" }
   elseif ($null -ne $progress -and $progress -ge 100) { $progress = 99 }
  }
  if($uncertain){$planConfirmed=$false;$progress=$null;$progressKind='none'}
  $updated = if($threadState.UpdatedUtc -ne [DateTime]::MinValue){$threadState.UpdatedUtc.ToLocalTime()}else{[DateTime]::MinValue}
  $startKey=[string](Prop $threadState "StartKey" "")
  $started=[DateTime](Prop $threadState "StartedUtc" ([DateTime]::MinValue))
  $activityGenerated=$uncertain;$activityObserved=$false
  $activity = if($uncertain){
   $observed=if($observationOnly){''}else{Codex-ObservedActivity $id $startKey}
   if($observed){$activityObserved=$true;$activityGenerated=$false;$observed}else{"Статус не подтверждён"}
  }elseif($running){$currentActivity=Codex-Activity $id;if($currentActivity){$currentActivity}else{$activityGenerated=$true;"Выполняется"}}else{""}
  if($unindexed -and -not $running -and -not $paused -and $status -notin @('Статус не подтверждён','Ожидает подтверждения')){
   $oldPath=[string]$script:unindexedPaths[$id];[void]$script:unindexedPaths.Remove($id)
   foreach($cacheName in @('lifecycleState','planCache')){$item=Get-Variable -Scope Script -Name $cacheName -ErrorAction SilentlyContinue;if($null -ne $item -and $null -ne $item.Value -and $oldPath){[void]$item.Value.Remove($oldPath)}}
  }
  $agentNickname=if($groupLinks.ContainsKey($id) -and -not [bool](Prop $groupLinks[$id] 'Conflict' $false)){[string](Prop $groupLinks[$id] 'AgentNickname' '')}else{''}
  $activityPath=if($currentPath -and $script:codexRolloutPaths.ContainsKey($id) -and [string]::Equals([string]$script:codexRolloutPaths[$id],$currentPath,[StringComparison]::OrdinalIgnoreCase)){$currentPath}else{''}
  $activityIdentity=if($activityPath -and $activityIdentities.ContainsKey($id)){$activityIdentities[$id]}else{''}
  $items.Add([PSCustomObject]@{ Id=$id; Title=$title; TitleGenerated=$titleGenerated; Activity=$activity; ActivityGenerated=$activityGenerated; ActivityObserved=$activityObserved; ActivityPath=$activityPath; ActivityIdentity=$activityIdentity; Active=$running; Paused=$paused; Progress=$progress; ProgressKind=$progressKind; ProgressBasis=$progressBasis; Provider="codex"; ProviderName="Codex"; Status=$status; Updated=$updated; Started=$started; StartKey=$startKey; Steps=$steps; Source=$source; PlanConfirmed=$planConfirmed; AgentNickname=$agentNickname })
 }
 if($null -ne $codexTitles){foreach($parentId in @($codexTitles.Keys)){$parentTitle=[string]$codexTitles[$parentId];if(-not $parentTitles.ContainsKey($parentId) -and $parentTitle -cne 'Guardian review'){$parentTitles[$parentId]=$parentTitle}}}
 $script:codexGroupLinks=$groupLinks;$script:codexGroupTitles=$parentTitles
 $visible=@($items.ToArray())
 $runningItems = @($visible | Where-Object Active | Sort-Object Updated -Descending)
 $trackedItems = @($visible | Where-Object { -not $_.Active -and ($_.Status -in @("Статус не подтверждён","Ожидает подтверждения") -or $_.Paused) } | Sort-Object Updated -Descending)
 return @($runningItems + $trackedItems)
}

function Claude-Tasks {
 $script:claudeSourceTransientPartial=$false
 # A bounded digest records continuity, not task content. It is held in memory only.
 $readSource={
  param([string]$path,$prior)
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try{
   $digest={
    param([IO.Stream]$inputStream,[long]$end)
    $count=[int][Math]::Min([long]4194304,$end);$data=[byte[]]::new($count)
    [void]$inputStream.Seek($end-$count,[IO.SeekOrigin]::Begin);$read=0
    while($read -lt $count){$n=$inputStream.Read($data,$read,$count-$read);if($n -le 0){throw 'Unable to verify Claude journal continuity.'};$read+=$n}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [Convert]::ToBase64String($sha.ComputeHash($data))}finally{$sha.Dispose()}
   }
   $length=[long]$stream.Length;$discontinuity=$false
   if($null -ne $prior){
    if($length -lt [long]$prior.Length){$discontinuity=$true}
    elseif((& $digest $stream ([long]$prior.Length)) -cne [string]$prior.EndDigest){$discontinuity=$true}
   }
   $endDigest=& $digest $stream $length
   $count=[int][Math]::Min([long]4194304,$length);$data=[byte[]]::new($count)
   $offset=$length-$count;$startsAtBoundary=$true
   if($offset -gt 0){[void]$stream.Seek($offset-1,[IO.SeekOrigin]::Begin);$startsAtBoundary=$stream.ReadByte() -eq 10}
   [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin);$read=0
   while($read -lt $count){$n=$stream.Read($data,$read,$count-$read);if($n -le 0){throw 'Unable to read Claude journal.'};$read+=$n}
   if($stream.Length -lt $length -or (& $digest $stream $length) -cne $endDigest){throw 'Claude journal changed during reading.'}
   # Only completed records are parsed. A writer can be interrupted mid-record.
   $start=0
   if($length -gt 4194304){
    $discontinuity=$true
    if(-not $startsAtBoundary){
     while($start -lt $count -and $data[$start] -ne 10){$start++}
     if($start -lt $count){$start++}
    }
   }
   $end=$count;$pending=$count -gt 0 -and $data[$count-1] -ne 10
   if($pending){while($end -gt $start -and $data[$end-1] -ne 10){$end--}}
   $value=''
   if($end -gt $start){
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    $value=$encoding.GetString($data,$start,$end-$start)
    if($length -le 4194304){$value=$value.TrimStart([char]0xFEFF)}
   }
   return [PSCustomObject]@{Text=$value;HasPartialLine=$pending;Discontinuity=$discontinuity;Cursor=[PSCustomObject]@{Length=$length;EndDigest=$endDigest}}
  }finally{$stream.Dispose()}
 }
 if(-not ("AITaskMonitor.Claude.Reader" -as [type])){throw "Claude event reader is unavailable."}
 if($null -eq (Get-Variable -Scope Script -Name claudeReaderSession -ErrorAction SilentlyContinue) -or $null -eq $script:claudeReaderSession){$script:claudeReaderSession=[AITaskMonitor.Claude.SessionReader]::new()}
 if($null -eq (Get-Variable -Scope Script -Name claudeLegacySourceSeen -ErrorAction SilentlyContinue)){$script:claudeLegacySourceSeen=$false}
 if($null -eq (Get-Variable -Scope Script -Name claudeCurrentSourceSeen -ErrorAction SilentlyContinue)){$script:claudeCurrentSourceSeen=$false}
 if($null -eq (Get-Variable -Scope Script -Name claudeCurrentSourceCursor -ErrorAction SilentlyContinue)){$script:claudeCurrentSourceCursor=$null}
 if($null -eq (Get-Variable -Scope Script -Name claudeLegacySourceCursor -ErrorAction SilentlyContinue)){$script:claudeLegacySourceCursor=$null}
 try{$attributes=[IO.File]::GetAttributes($claudeEventPath)}
 catch [IO.FileNotFoundException]{if($script:claudeCurrentSourceSeen -or $script:lastClaudeTasks.Count -gt 0){throw};return @()}
 catch [IO.DirectoryNotFoundException]{if($script:claudeCurrentSourceSeen -or $script:lastClaudeTasks.Count -gt 0){throw};return @()}
 if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){throw "Claude event source is not a file."}
 $currentRead=& $readSource $claudeEventPath $script:claudeCurrentSourceCursor
 if($currentRead.Discontinuity){$script:claudeReaderSession.MarkSourceLoss()}
 $script:claudeCurrentSourceCursor=$currentRead.Cursor
 $tail=$currentRead.Text
 $transientUncertain=[bool]$currentRead.HasPartialLine
 $script:claudeCurrentSourceSeen=$true
 $legacyTail=""
 if($claudeLegacyEventPath){
  $legacyAttributes=$null
  try{$legacyAttributes=[IO.File]::GetAttributes($claudeLegacyEventPath)}
  catch [IO.FileNotFoundException]{if($script:claudeLegacySourceSeen){$script:claudeReaderSession.MarkSourceLoss();throw}}
  catch [IO.DirectoryNotFoundException]{if($script:claudeLegacySourceSeen){$script:claudeReaderSession.MarkSourceLoss();throw}}
  catch{$script:claudeReaderSession.MarkSourceLoss();throw}
  if($null -ne $legacyAttributes){
   if(($legacyAttributes -band [IO.FileAttributes]::Directory) -ne 0){$script:claudeReaderSession.MarkSourceLoss();throw "Claude legacy event source is not a file."}
   $script:claudeLegacySourceSeen=$true
   try{
    $legacyRead=& $readSource $claudeLegacyEventPath $script:claudeLegacySourceCursor
    if($legacyRead.Discontinuity){$script:claudeReaderSession.MarkSourceLoss()}
    $script:claudeLegacySourceCursor=$legacyRead.Cursor
    $legacyTail=$legacyRead.Text
    $transientUncertain=$transientUncertain -or [bool]$legacyRead.HasPartialLine
   }catch{$script:claudeReaderSession.MarkSourceLoss();throw}
  }
 }
 $script:claudeSourceTransientPartial=$transientUncertain
 $sessions=@($script:claudeReaderSession.Read($tail,$legacyTail,[DateTime]::UtcNow,$script:monitorStartedUtc))
 $items=New-Object Collections.Generic.List[object]
 foreach($state in $sessions){
  $steps=@($state.Steps)
  $progress=$null;$kind="none"
  $planConfirmed=[bool]$state.PlanConfirmed -and -not $transientUncertain -and -not [bool]$state.RetainedPlanIncomplete
  if($steps.Count -gt 0 -and $planConfirmed){$progress=Plan-Progress $steps 0;$kind="exact"}
  $title="Задача Claude Code"
  $unconfirmed=[bool]$state.Unconfirmed -or $transientUncertain
  $activity=if($unconfirmed){"Статус не подтверждён"}else{$state.Activity}
  $status=if($unconfirmed){"Статус не подтверждён"}else{"В работе"}
  $items.Add([PSCustomObject]@{Id="claude:"+$state.Id;Title=$title;Activity=$activity;Active=(-not $unconfirmed);Paused=$false;Progress=$progress;ProgressKind=$kind;ProgressBasis=$(if($steps.Count -gt 0){"steps"}else{"task"});Provider="claude";ProviderName="Claude Code";Status=$status;Updated=$state.Updated.ToLocalTime();Started=$state.Started;StartKey=$state.StartKey;Steps=$steps;Source="Claude Code";PlanConfirmed=$planConfirmed;KnownStepCount=$(if($planConfirmed){[int]$state.KnownStepCount}else{0});KnownDoneCount=$(if($planConfirmed){[int]$state.KnownDoneCount}else{0});UnknownStepCount=$(if($planConfirmed){[int]$state.UnknownStepCount}else{$steps.Count});RetainedPlanIncomplete=[bool]$state.RetainedPlanIncomplete})
 }
 return @($items|Sort-Object Updated -Descending)
}

function Test-ClaudePartialData([string]$connectionState) {
 if($connectionState -notin @('connected','partial')){return $false}
 $transientVariable=Get-Variable -Scope Script -Name claudeSourceTransientPartial -ErrorAction SilentlyContinue
 $readerVariable=Get-Variable -Scope Script -Name claudeReaderSession -ErrorAction SilentlyContinue
 $reader=if($null -ne $readerVariable){$readerVariable.Value}else{$null}
 return ([bool](Prop $reader 'RetentionOverflow' $false) -or [bool](Prop $reader 'SourceUncertain' $false) -or ($null -ne $transientVariable -and [bool]$transientVariable.Value))
}

function Unconfirmed-Tasks($tasks) {
 foreach($task in $tasks){
  if($null -eq $task){continue}
  $copy=$task.PSObject.Copy()
  $copy.Active=$false; $copy.Status="Статус не подтверждён"
  if($null -ne $copy.PSObject.Properties['Paused']){$copy.Paused=$false}
  $keepLast=[string](Prop $copy 'Provider' '') -eq 'codex' -and -not [bool](Prop $copy 'ActivityGenerated' $false) -and
   -not [string]::IsNullOrWhiteSpace([string](Prop $copy 'Activity' '')) -and
   ([bool](Prop $task 'Active' $false) -or [bool](Prop $copy 'ActivityObserved' $false) -or [bool](Prop $copy 'ActivityIsLast' $false))
  if(-not $keepLast){$copy.Activity="Статус не подтверждён"}
  if($null -eq $copy.PSObject.Properties['ActivityIsLast']){$copy|Add-Member NoteProperty ActivityIsLast ([bool]$keepLast)}else{$copy.ActivityIsLast=[bool]$keepLast}
  if([string](Prop $copy 'Provider' '') -in @('claude','codex')){
   if($null -ne $copy.PSObject.Properties['PlanConfirmed']){$copy.PlanConfirmed=$false}
   if($null -ne $copy.PSObject.Properties['Progress']){$copy.Progress=$null}
   if($null -ne $copy.PSObject.Properties['ProgressKind']){$copy.ProgressKind='none'}
   if($null -ne $copy.PSObject.Properties['KnownStepCount']){$copy.KnownStepCount=0}
   if($null -ne $copy.PSObject.Properties['KnownDoneCount']){$copy.KnownDoneCount=0}
   if($null -ne $copy.PSObject.Properties['UnknownStepCount']){$copy.UnknownStepCount=@($copy.Steps).Count}
  }
  if($null -eq $copy.PSObject.Properties['ActivityGenerated']){$copy|Add-Member -MemberType NoteProperty -Name ActivityGenerated -Value (-not $keepLast)}else{$copy.ActivityGenerated=-not $keepLast}
  $copy
 }
}

function Local-SourceSnapshot([bool]$ClaudeEnabled=$true,[string]$ClaudeConnectionOverride='') {
 $codex=@(); $claude=@(); $unavailable=New-Object Collections.Generic.List[string]
 $partialConnection=New-Object Collections.Generic.List[string];$partialData=New-Object Collections.Generic.List[string]
 $codexIncomplete=$false;$codexReadFailed=$false
 try{
  $previousCodex=@($script:lastCodexTasks)
  $codex=@(Codex-Tasks)
  $previousById=@{};foreach($task in $previousCodex){$previousById[[string]$task.Id]=$task}
  foreach($task in $codex){
   $id=[string]$task.Id;$turn=[string](Prop $task 'StartKey' '')
   if([string](Prop $task 'Status' '') -ne 'Статус не подтверждён' -or [bool](Prop $task 'ActivityObserved' $false) -or
      -not $turn -or -not $previousById.ContainsKey($id)){continue}
   $prior=$previousById[$id]
   $origin=[string](Prop $task 'ActivityPath' '');$identity=[string](Prop $task 'ActivityIdentity' '')
   if(-not $origin -or -not $identity -or -not [string]::Equals([string](Prop $prior 'ActivityPath' ''),$origin,[StringComparison]::OrdinalIgnoreCase) -or
      [string](Prop $prior 'ActivityIdentity' '') -cne $identity -or
      [string](Prop $prior 'StartKey' '') -cne $turn -or [bool](Prop $prior 'ActivityGenerated' $false) -or
      -not ([bool](Prop $prior 'Active' $false) -or [bool](Prop $prior 'ActivityObserved' $false) -or [bool](Prop $prior 'ActivityIsLast' $false)) -or
      [string]::IsNullOrWhiteSpace([string](Prop $prior 'Activity' ''))){continue}
   $task.Activity=[string]$prior.Activity;$task.ActivityGenerated=$false
   if($null -eq $task.PSObject.Properties['ActivityIsLast']){$task|Add-Member NoteProperty ActivityIsLast $true}else{$task.ActivityIsLast=$true}
  }
  $codexPartial=Get-Variable -Scope Script -Name codexSourcePartial -ErrorAction SilentlyContinue
  if($null -ne $codexPartial -and $codexPartial.Value){
   [void]$unavailable.Add('Codex')
   $discoveryFailed=Get-Variable -Scope Script -Name codexDiscoveryFailed -ErrorAction SilentlyContinue
   if($null -ne $discoveryFailed -and [bool]$discoveryFailed.Value){[void]$partialData.Add('Codex')}else{$codexIncomplete=$true}
   $seenCodex=@{};foreach($task in $codex){$seenCodex[[string]$task.Id]=$true}
   $terminated=Get-Variable -Scope Script -Name codexTerminated -ErrorAction SilentlyContinue
   foreach($task in $previousCodex){
    $id=[string]$task.Id
    if($id -and -not $seenCodex.ContainsKey($id) -and ($null -eq $terminated -or $null -eq $terminated.Value -or -not $terminated.Value.ContainsKey($id))){
     $retained=@(Unconfirmed-Tasks @($task))
     $endings=Get-Variable -Scope Script -Name codexUnconfirmedEndings -ErrorAction SilentlyContinue
     if($retained.Count -gt 0 -and $null -ne $endings -and $null -ne $endings.Value -and $endings.Value.ContainsKey($id)){
      # A past operation is not current activity after an ambiguous ending.
      $retained[0].Activity='Статус не подтверждён'
      if($null -ne $retained[0].PSObject.Properties['ActivityObserved']){$retained[0].ActivityObserved=$false}
      if($null -ne $retained[0].PSObject.Properties['ActivityIsLast']){$retained[0].ActivityIsLast=$false}
     }
     $codex+=$retained;$seenCodex[$id]=$true
    }
   }
  }
  $script:lastCodexTasks=$codex
 }catch{$codexReadFailed=$true;[void]$unavailable.Add("Codex");$codex=@(Unconfirmed-Tasks $script:lastCodexTasks)}
 $links=Get-Variable -Scope Script -Name codexGroupLinks -ErrorAction SilentlyContinue
 $titles=Get-Variable -Scope Script -Name codexGroupTitles -ErrorAction SilentlyContinue
 try{
  $rawCodex=@($codex)
  $linkValues=if($null -ne $links){$links.Value}else{$null}
  $retention=Update-CodexAgentRetention -State $script:codexAgentRetention -Tasks $rawCodex -Links $linkValues -SourcePartial ([bool]$script:codexSourcePartial) -SourceUnavailable $codexReadFailed
  if($retention.CapacityExceeded){throw 'Codex relationship retention capacity reached.'}
  $effectiveLinks=Select-CodexRetentionLinks $linkValues $retention
  $hasRelation=$false
  foreach($reference in $effectiveLinks.Values){if(-not [bool](Prop $reference 'Conflict' $false) -and -not [bool](Prop $reference 'IsRoot' $false)){$hasRelation=$true;break}}
  if($hasRelation -and $null -ne $titles -and $null -ne $titles.Value){$codex=@(Group-CodexTasks $rawCodex $effectiveLinks $titles.Value)}
  $codex=@(Apply-CodexAgentRetention $codex $rawCodex $retention)
 }catch{
  if(-not $unavailable.Contains('Codex')){[void]$unavailable.Add('Codex')}
  $codex=@(Unconfirmed-Tasks $codex);$codexIncomplete=$true
 }
 $connectionState='unknown'
 try{
  $connectionState=if(-not $ClaudeEnabled){"disconnected"}elseif($ClaudeConnectionOverride){$ClaudeConnectionOverride}elseif($ClaudeEventFile){"connected"}else{Claude-ConnectionState}
  if($connectionState -notin @('connected','disconnected','partial')){throw 'Claude connection is unavailable.'}
  $previousClaude=@($script:lastClaudeTasks)
  if($connectionState -in @('connected','partial')){
   $claude=@(Claude-Tasks);$claudePartial=Test-ClaudePartialData $connectionState
   if($connectionState -eq 'partial'){$claude=@(Unconfirmed-Tasks $claude);[void]$unavailable.Add('Claude Code')}
   if($claudePartial -or $connectionState -eq 'partial'){
    $seenClaude=@{};foreach($task in $claude){$seenClaude[[string]$task.Id]=$true}
    foreach($task in $previousClaude){$id=[string]$task.Id;if($id -and -not $seenClaude.ContainsKey($id)){$claude+=@(Unconfirmed-Tasks @($task));$seenClaude[$id]=$true}}
   }
   $script:lastClaudeTasks=$claude
  }else{$script:lastClaudeTasks=@();$claudePartial=$false}
  if($ClaudeEnabled -and $claudePartial){
   if(-not $unavailable.Contains('Claude Code')){[void]$unavailable.Add('Claude Code')}
   if(-not $partialData.Contains('Claude Code')){[void]$partialData.Add('Claude Code')}
  }
 }catch{
  if($null -ne (Get-Variable -Scope Script -Name claudeReaderSession -ErrorAction SilentlyContinue) -and $null -ne $script:claudeReaderSession){$script:claudeReaderSession.MarkSourceLoss()}
  [void]$unavailable.Add("Claude Code");$claude=@(Unconfirmed-Tasks $script:lastClaudeTasks)
 }
 return [PSCustomObject]@{Codex=@($codex);Claude=@($claude);Unavailable=$unavailable.ToArray();PartialConnection=$partialConnection.ToArray();PartialData=$partialData.ToArray();CodexIncomplete=$codexIncomplete;ClaudeConnection=$connectionState}
}
