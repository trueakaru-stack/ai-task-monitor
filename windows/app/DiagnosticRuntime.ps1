function Set-DiagnosticNextCleanup($Runtime,[object[]]$Events) {
 $next=[DateTimeOffset]::MaxValue
 # Retained events are normalized in chronological order by the store.
 if($Events.Count -gt 0){
  $time=Get-DiagnosticTimestamp (Get-DiagnosticProperty $Events[0] "time") $true
  if($null -ne $time){$next=$time.AddDays($Runtime.Settings.RetentionDays)}
 }
 $Runtime.NextCleanup=$next
}

function New-DiagnosticRuntime {
 param([Parameter(Mandatory=$true)][string]$Directory,[Parameter(Mandatory=$true)][DateTimeOffset]$Since,[Parameter(Mandatory=$true)][DateTimeOffset]$Now)
 $settings=Get-DiagnosticSettings -Directory $Directory
 $key=Get-DiagnosticInstallationKey -Directory $Directory
 $limit=[long]$settings.MaximumMB*1000000
 Remove-ExpiredDiagnosticEvents -Directory $Directory -Now $Now -RetentionDays $settings.RetentionDays -MaximumBytes $limit
 $existing=@(Read-DiagnosticEvents -Directory $Directory -Now $Now -RetentionDays $settings.RetentionDays -MaximumBytes $limit)
 $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
 $order=New-Object 'Collections.Generic.Queue[string]'
 foreach($event in $existing){if($seen.Add([string]$event.id)){$order.Enqueue([string]$event.id)}}
 $loopKey=New-Object byte[] 32
 $random=[Security.Cryptography.RandomNumberGenerator]::Create()
 try{$random.GetBytes($loopKey)}finally{$random.Dispose()}
 $runtime=[PSCustomObject]@{
  Directory=$Directory;Settings=$settings;Key=$key;Since=$Since.ToUniversalTime();RunId=[Guid]::NewGuid().ToString("N")
  Seen=$seen;SeenOrder=$order;TaskStates=@{};SourceStates=@{};Cursors=@{};NextCleanup=[DateTimeOffset]::MaxValue
  LoopKey=$loopKey;LoopStates=@{}
 }
 Set-DiagnosticNextCleanup $runtime $existing
 return $runtime
}

function New-DiagnosticRuntimeEvent($Runtime,[string]$Provider,[string]$TaskKey,[string]$Type,[DateTimeOffset]$Now) {
 $id=Get-DiagnosticEventKey -TaskKey $TaskKey -Type $Type -Reference $Runtime.RunId -Time $Now -Key $Runtime.Key
 $task=if($Type -like "source_*"){""}else{$TaskKey}
 return [PSCustomObject][ordered]@{version=1;time=$Now.ToUniversalTime().ToString("o");source=$Provider;task=$task;type=$Type;id=$id}
}

function Read-DiagnosticTaskBatch($Runtime,[string]$Path,[string]$TaskKey,[hashtable]$NextCursors,$LoopTracker=$null,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
 $cursorKey=$Path+"|"+$TaskKey
 if($NextCursors.ContainsKey($cursorKey)){
  $old=$NextCursors[$cursorKey]
  $cursor=[PSCustomObject]@{Offset=$old.Offset;Skipping=$old.Skipping;Anchor=$old.Anchor;CreationTicks=$old.CreationTicks;Calls=$old.Calls.Clone()}
 }else{$cursor=New-CodexDiagnosticCursor -Path $Path}
 $observer=$null;$reset=$null
 if($null -ne $LoopTracker){
  $updater=${function:Update-CodexLoopTracker};$resetter=${function:Reset-CodexLoopSequence}
  $observer={param($record) & $updater $LoopTracker $record $Now}.GetNewClosure()
  $reset={& $resetter $LoopTracker}.GetNewClosure()
 }
 $events=@(Read-CodexToolEventsIncremental -Path $Path -Cursor $cursor -TaskKey $TaskKey -Key $Runtime.Key -Since $Runtime.Since -OnRecord $observer -OnReset $reset)
 $NextCursors[$cursorKey]=$cursor
 return $events
}

function Update-DiagnosticRuntime {
 param(
  [Parameter(Mandatory=$true)]$Runtime,
  [AllowEmptyCollection()][object[]]$Tasks=@(),
  [AllowEmptyCollection()][string[]]$Unavailable=@(),
  [Parameter(Mandatory=$true)][DateTimeOffset]$Now,
  [Parameter(Mandatory=$true)][scriptblock]$SessionResolver,
  [Parameter(Mandatory=$true)][scriptblock]$StateResolver
 )
 $limit=[long]$Runtime.Settings.MaximumMB*1000000
 if($Now -ge $Runtime.NextCleanup){
  Remove-ExpiredDiagnosticEvents -Directory $Runtime.Directory -Now $Now -RetentionDays $Runtime.Settings.RetentionDays -MaximumBytes $limit
  $existing=@(Read-DiagnosticEvents -Directory $Runtime.Directory -Now $Now -RetentionDays $Runtime.Settings.RetentionDays -MaximumBytes $limit)
  Set-DiagnosticNextCleanup $Runtime $existing
 }
 $events=New-Object 'Collections.Generic.List[object]'
 $current=@{}
 $nextCursors=$Runtime.Cursors.Clone()
 $nextLoops=@{}
 foreach($task in $Tasks){
  $provider=[string](Get-DiagnosticProperty $task "Provider" "")
  $id=[string](Get-DiagnosticProperty $task "Id" "")
  $state=[string](Get-DiagnosticProperty $task "State" "")
  if($provider -cnotin @("codex","claude") -or $id -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or $state -cnotin @("active","unknown")){continue}
  $identity=$provider+":"+$id
  if($current.ContainsKey($identity)){continue}
  $taskKey=Get-DiagnosticTaskKey -Provider $provider -TaskId $id -Key $Runtime.Key
  $current[$identity]=[PSCustomObject]@{Provider=$provider;Id=$id;State=$state;TaskKey=$taskKey}
  $previous=if($Runtime.TaskStates.ContainsKey($identity)){$Runtime.TaskStates[$identity]}else{$null}
  if($null -eq $previous -or $previous.State -ne $state){
   $type=if($state -eq "active"){"task_observed"}else{"task_unconfirmed"}
   $events.Add((New-DiagnosticRuntimeEvent $Runtime $provider $taskKey $type $Now))
  }
  if($provider -eq "codex"){
   $loop=$null
   if($state -eq "active"){
    $loop=if($Runtime.LoopStates.ContainsKey($identity)){Copy-CodexLoopTracker $Runtime.LoopStates[$identity]}else{New-CodexLoopTracker -Key $Runtime.LoopKey -Since $Runtime.Since -Threshold $Runtime.Settings.LoopThreshold -WindowMinutes $Runtime.Settings.LoopWindowMinutes}
    if($loop.Threshold -ne $Runtime.Settings.LoopThreshold -or $loop.WindowMinutes -ne $Runtime.Settings.LoopWindowMinutes){
     Reset-CodexLoopSequence $loop;$loop.Threshold=$Runtime.Settings.LoopThreshold;$loop.WindowMinutes=$Runtime.Settings.LoopWindowMinutes
    }
    $nextLoops[$identity]=$loop
   }
   $path=& $SessionResolver $id
   if($path -and (Test-Path -LiteralPath $path)){
    foreach($event in @(Read-DiagnosticTaskBatch $Runtime $path $taskKey $nextCursors $loop $Now)){$events.Add($event)}
   }
   if($null -ne $loop){Refresh-CodexLoopTracker $loop $Now}
  }
 }
 foreach($identity in @($Runtime.TaskStates.Keys)){
  if($current.ContainsKey($identity)){continue}
  $previous=$Runtime.TaskStates[$identity]
  if($previous.Provider -ne "codex"){continue}
  if($Unavailable -notcontains "Codex"){
   $path=& $SessionResolver $previous.Id
   if($path -and (Test-Path -LiteralPath $path)){foreach($event in @(Read-DiagnosticTaskBatch $Runtime $path $previous.TaskKey $nextCursors)){$events.Add($event)}}
  }
  $state=if($Unavailable -contains "Codex"){"unknown"}else{[string]((& $StateResolver $previous.Id).State)}
  if($state -eq "completed"){$type="task_completed"}elseif($state -eq "interrupted"){$type="task_interrupted"}elseif($previous.State -eq "active"){$type="task_unconfirmed"}else{continue}
  $events.Add((New-DiagnosticRuntimeEvent $Runtime "codex" $previous.TaskKey $type $Now))
 }
 $newSources=@{}
 foreach($entry in @(@("codex","Codex"),@("claude","Claude Code"))){
  $provider=[string]$entry[0];$isUnavailable=$Unavailable -contains [string]$entry[1]
  $wasUnavailable=$Runtime.SourceStates.ContainsKey($provider) -and [bool]$Runtime.SourceStates[$provider]
  $newSources[$provider]=$isUnavailable
  if($isUnavailable -ne $wasUnavailable){
   $sourceKey=Get-DiagnosticTaskKey -Provider $provider -TaskId "source" -Key $Runtime.Key
   $type=if($isUnavailable){"source_unavailable"}else{"source_recovered"}
   $events.Add((New-DiagnosticRuntimeEvent $Runtime $provider $sourceKey $type $Now))
  }
 }
 $batch=New-Object 'Collections.Generic.List[object]'
 $batchIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
 foreach($event in $events){if(-not $Runtime.Seen.Contains([string]$event.id) -and $batchIds.Add([string]$event.id)){$batch.Add($event)}}
 if($batch.Count -gt 0){
  Write-DiagnosticEvents -Directory $Runtime.Directory -Events $batch.ToArray() -Now $Now -RetentionDays $Runtime.Settings.RetentionDays -MaximumBytes $limit
  foreach($event in $batch){
   if($Runtime.Seen.Add([string]$event.id)){$Runtime.SeenOrder.Enqueue([string]$event.id)}
   $time=Get-DiagnosticTimestamp (Get-DiagnosticProperty $event "time") $true
   if($null -ne $time -and $time.AddDays($Runtime.Settings.RetentionDays) -lt $Runtime.NextCleanup){$Runtime.NextCleanup=$time.AddDays($Runtime.Settings.RetentionDays)}
  }
  while($Runtime.SeenOrder.Count -gt 50000){[void]$Runtime.Seen.Remove($Runtime.SeenOrder.Dequeue())}
 }
 $Runtime.TaskStates=$current
 $Runtime.SourceStates=$newSources
 $Runtime.Cursors=$nextCursors
 $Runtime.LoopStates=$nextLoops
}
