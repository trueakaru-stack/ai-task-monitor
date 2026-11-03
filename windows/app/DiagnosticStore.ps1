function Assert-DiagnosticNotReparsePoint([string]$Path) {
 $current=[IO.Path]::GetFullPath($Path)
 while($current){
  if((Test-Path -LiteralPath $current -ErrorAction Stop) -and (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw "Diagnostic data cannot use a reparse point."}
  $parent=[IO.Path]::GetDirectoryName($current)
  if(-not $parent -or [string]::Equals($parent,$current,[StringComparison]::OrdinalIgnoreCase)){break}
  $current=$parent
 }
}

function Ensure-DiagnosticDirectory([string]$Directory) {
 Assert-DiagnosticNotReparsePoint $Directory
 if(-not [IO.Directory]::Exists($Directory)){
  $security=New-Object Security.AccessControl.DirectorySecurity
  $security.SetAccessRuleProtection($true,$false)
  $inherit=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
  $user=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $system=[Security.Principal.SecurityIdentifier]::new("S-1-5-18")
  foreach($identity in @($user,$system)){
   $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
   $security.AddAccessRule($rule)
  }
  [void][IO.Directory]::CreateDirectory($Directory,$security)
 }
 Assert-DiagnosticNotReparsePoint $Directory
}

function Invoke-DiagnosticStoreLock([string]$Directory,[scriptblock]$Action) {
 $directoryPath=[IO.Path]::GetFullPath($Directory)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$digest=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($directoryPath.ToUpperInvariant()))}finally{$sha.Dispose()}
 $suffix=[BitConverter]::ToString($digest).Replace("-","").Substring(0,24)
 $mutex=[Threading.Mutex]::new($false,"Local\AITaskMonitorDiagnostics-"+$suffix)
 $locked=$false
 try{
  try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true}
  if(-not $locked){throw "Timed out waiting for the diagnostic journal."}
  & $Action $directoryPath
 }finally{
  if($locked){$mutex.ReleaseMutex()}
  $mutex.Dispose()
 }
}

function Get-DiagnosticInstallationKey([Parameter(Mandatory=$true)][string]$Directory) {
 $emptyJournalContent=$script:DiagnosticHeader+"`n"
 $action={
  param($root)
  Add-Type -AssemblyName System.Security -ErrorAction Stop
  Ensure-DiagnosticDirectory $root
  $path=Join-Path $root "diagnostic-key-v1.bin"
  $marker=[Text.Encoding]::ASCII.GetBytes("AI-TASK-MONITOR-DIAGNOSTIC-KEY-1`n")
  if(Test-Path -LiteralPath $path){
   Assert-DiagnosticNotReparsePoint $path
   $stored=[IO.File]::ReadAllBytes($path)
   if($stored.Length -le $marker.Length -or $stored.Length -gt 4096){throw "Unrecognized diagnostic key; refusing to replace it."}
   for($index=0;$index -lt $marker.Length;$index++){if($stored[$index] -ne $marker[$index]){throw "Unrecognized diagnostic key; refusing to replace it."}}
   $protected=New-Object byte[] ($stored.Length-$marker.Length)
   [Array]::Copy($stored,$marker.Length,$protected,0,$protected.Length)
   $plain=[Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
   if($plain.Length -ne 32){throw "Invalid diagnostic key; refusing to replace it."}
   return ,$plain
  }
  $existingJournal=Join-Path $root "diagnostic-events-v1.jsonl"
  if(Test-Path -LiteralPath $existingJournal){
   Assert-DiagnosticNotReparsePoint $existingJournal
   $journalFile=Get-Item -LiteralPath $existingJournal -ErrorAction Stop
   if($journalFile.PSIsContainer -or $journalFile.Length -gt 1024 -or [IO.File]::ReadAllText($existingJournal,[Text.Encoding]::UTF8) -cne $emptyJournalContent){
    throw "Diagnostic key is missing; existing journal was preserved."
   }
  }
  $plain=New-Object byte[] 32
  $random=[Security.Cryptography.RandomNumberGenerator]::Create()
  try{$random.GetBytes($plain)}finally{$random.Dispose()}
  $protected=[Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $temporary=Join-Path $root ("diagnostic-key-"+[Guid]::NewGuid().ToString("N")+".tmp")
  try{
   $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
   try{$stream.Write($marker,0,$marker.Length);$stream.Write($protected,0,$protected.Length);$stream.Flush($true)}finally{$stream.Dispose()}
   [IO.File]::Move($temporary,$path)
  }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
  return ,$plain
 }.GetNewClosure()
 $key=Invoke-DiagnosticStoreLock $Directory $action
 return ,([byte[]]$key)
}

function Read-DiagnosticSettingsRaw([string]$Directory) {
 Assert-DiagnosticNotReparsePoint $Directory
 $path=Join-Path $Directory "diagnostic-settings-v1.json"
 if(-not (Test-Path -LiteralPath $path)){return [PSCustomObject]@{RetentionDays=7;MaximumMB=10;LoopThreshold=5;LoopWindowMinutes=10}}
 Assert-DiagnosticNotReparsePoint $path
 $file=Get-Item -LiteralPath $path -ErrorAction Stop
 if($file.PSIsContainer -or $file.Length -gt 4096){throw "Unrecognized diagnostic settings; refusing to replace them."}
 try{$settings=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop}catch{throw "Unrecognized diagnostic settings; refusing to replace them."}
 $days=0;$maximum=0
 if([string](Get-DiagnosticProperty $settings "format" "") -cne "ai-task-monitor-diagnostic-settings" -or
    [string](Get-DiagnosticProperty $settings "version" "") -ne "1" -or
    -not [int]::TryParse([string](Get-DiagnosticProperty $settings "retentionDays" ""),[ref]$days) -or
    -not [int]::TryParse([string](Get-DiagnosticProperty $settings "maximumMB" ""),[ref]$maximum) -or
    $days -lt 1 -or $days -gt 7 -or $maximum -lt 1 -or $maximum -gt 10){throw "Unrecognized diagnostic settings; refusing to replace them."}
 $threshold=5;$window=10
 if($null -ne $settings.PSObject.Properties["loopThreshold"] -and (-not [int]::TryParse([string]$settings.loopThreshold,[ref]$threshold) -or $threshold -lt 3 -or $threshold -gt 10)){throw "Unrecognized diagnostic settings; refusing to replace them."}
 if($null -ne $settings.PSObject.Properties["loopWindowMinutes"] -and (-not [int]::TryParse([string]$settings.loopWindowMinutes,[ref]$window) -or $window -lt 1 -or $window -gt 30)){throw "Unrecognized diagnostic settings; refusing to replace them."}
 return [PSCustomObject]@{RetentionDays=$days;MaximumMB=$maximum;LoopThreshold=$threshold;LoopWindowMinutes=$window}
}

function Get-DiagnosticSettings([Parameter(Mandatory=$true)][string]$Directory) {
 $action={param($root) Read-DiagnosticSettingsRaw $root}.GetNewClosure()
 return Invoke-DiagnosticStoreLock $Directory $action
}

function Save-DiagnosticSettings {
 param([Parameter(Mandatory=$true)][string]$Directory,[ValidateRange(1,7)][int]$RetentionDays=7,[ValidateRange(1,10)][int]$MaximumMB=10,[ValidateRange(3,10)][int]$LoopThreshold=5,[ValidateRange(1,30)][int]$LoopWindowMinutes=10)
 $hasDays=$PSBoundParameters.ContainsKey("RetentionDays");$hasMaximum=$PSBoundParameters.ContainsKey("MaximumMB")
 $hasThreshold=$PSBoundParameters.ContainsKey("LoopThreshold");$hasWindow=$PSBoundParameters.ContainsKey("LoopWindowMinutes")
 $action={
  param($root)
  Ensure-DiagnosticDirectory $root
  $existing=Read-DiagnosticSettingsRaw $root
  $days=if($hasDays){$RetentionDays}else{$existing.RetentionDays}
  $maximum=if($hasMaximum){$MaximumMB}else{$existing.MaximumMB}
  $threshold=if($hasThreshold){$LoopThreshold}else{$existing.LoopThreshold}
  $window=if($hasWindow){$LoopWindowMinutes}else{$existing.LoopWindowMinutes}
  $path=Join-Path $root "diagnostic-settings-v1.json"
  $temporary=Join-Path $root ("diagnostic-settings-"+[Guid]::NewGuid().ToString("N")+".tmp")
  $value=[PSCustomObject][ordered]@{format="ai-task-monitor-diagnostic-settings";version=1;retentionDays=$days;maximumMB=$maximum;loopThreshold=$threshold;loopWindowMinutes=$window}
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($value|ConvertTo-Json -Compress)+"`n")
  try{
   $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
   try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
   Assert-DiagnosticNotReparsePoint $path
   if(Test-Path -LiteralPath $path){
    [void](Read-DiagnosticSettingsRaw $root)
    [IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)
   }else{[IO.File]::Move($temporary,$path)}
  }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
 }.GetNewClosure()
 [void](Invoke-DiagnosticStoreLock $Directory $action)
}

function Read-DiagnosticRaw([string]$Directory,[switch]$AllowMalformed) {
 Assert-DiagnosticNotReparsePoint $Directory
 $path=Join-Path $Directory "diagnostic-events-v1.jsonl"
 if(-not (Test-Path -LiteralPath $path)){return [PSCustomObject]@{Exists=$false;Events=@();Content=$null;FileBytes=0}}
 Assert-DiagnosticNotReparsePoint $path
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{
  $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,4096,$true)
  try{
   if($reader.ReadLine() -cne $script:DiagnosticHeader){throw "Unrecognized diagnostic journal; refusing to modify it."}
   $fileBytes=$stream.Length
   $content=if($fileBytes -le 10000000){New-Object Text.StringBuilder}else{$null}
   if($null -ne $content){[void]$content.Append($script:DiagnosticHeader).Append("`n")}
   if($fileBytes -gt 10000000){
    $reader.DiscardBufferedData()
    [void]$stream.Seek(-10000000,[IO.SeekOrigin]::End)
    [void]$reader.ReadLine()
   }
   $events=New-Object 'Collections.Generic.List[object]'
   while($null -ne ($line=$reader.ReadLine())){
    if($null -ne $content){[void]$content.Append($line).Append("`n")}
    $event=if($line -and $line.Length -le 4096){[AITaskMonitor.Diagnostics.Policy]::ParseCanonical($line)}else{$null}
    if(-not [AITaskMonitor.Diagnostics.Policy]::IsRecognized($event)){
     if($AllowMalformed){continue}
     throw "The diagnostic journal contains an unsupported or incomplete record; it was not modified."
    }
    $events.Add($event)
   }
   $original=if($null -ne $content){$content.ToString()}else{$null}
   return [PSCustomObject]@{Exists=$true;Events=$events.ToArray();Content=$original;FileBytes=$fileBytes}
  }finally{$reader.Dispose()}
 }finally{$stream.Dispose()}
}

function ConvertTo-DiagnosticFileText([object[]]$Events) {
 return [AITaskMonitor.Diagnostics.Policy]::Serialize($Events,$script:DiagnosticHeader)
}

function Write-DiagnosticFile([string]$Directory,[object[]]$Events) {
 $path=Join-Path $Directory "diagnostic-events-v1.jsonl"
 Assert-DiagnosticNotReparsePoint $Directory
 Assert-DiagnosticNotReparsePoint $path
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-DiagnosticFileText $Events))
 if(Test-Path -LiteralPath $path){
  $existing=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{
   $reader=[IO.StreamReader]::new($existing,[Text.Encoding]::UTF8,$true,4096,$true)
   try{if($reader.ReadLine() -cne $script:DiagnosticHeader){throw "Unrecognized diagnostic journal; refusing to modify it."}}finally{$reader.Dispose()}
   if($existing.Length -eq $bytes.Length){
    $existing.Position=0
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$oldHash=[Convert]::ToBase64String($sha.ComputeHash($existing));$newHash=[Convert]::ToBase64String($sha.ComputeHash($bytes))}finally{$sha.Dispose()}
    if($oldHash -ceq $newHash){return}
   }
  }finally{$existing.Dispose()}
 }
 $temporary=Join-Path $Directory ("diagnostic-"+[Guid]::NewGuid().ToString("N")+".tmp")
 try{
  $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{
   $stream.Write($bytes,0,$bytes.Length)
   $stream.Flush($true)
  }finally{$stream.Dispose()}
  Assert-DiagnosticNotReparsePoint $path
  if(Test-Path -LiteralPath $path){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
 }finally{
  if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}
 }
}

function Append-DiagnosticFile([string]$Directory,[string]$Original,[string]$Suffix,[long]$ExpectedBytes) {
 if(-not $Suffix){return}
 $path=Join-Path $Directory "diagnostic-events-v1.jsonl"
 Assert-DiagnosticNotReparsePoint $Directory
 Assert-DiagnosticNotReparsePoint $path
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
 try{
  if($stream.Length -ne $ExpectedBytes){throw "The diagnostic journal changed during an update."}
  $sha=[Security.Cryptography.SHA256]::Create()
  try{
   $actual=[Convert]::ToBase64String($sha.ComputeHash($stream))
   $expected=[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Original)))
  }finally{$sha.Dispose()}
  if($actual -cne $expected){throw "The diagnostic journal changed during an update."}
  [void]$stream.Seek(0,[IO.SeekOrigin]::End)
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Suffix)
  $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
 }finally{$stream.Dispose()}
}

function Read-DiagnosticEvents {
 param([Parameter(Mandatory=$true)][string]$Directory,[Parameter(Mandatory=$true)][DateTimeOffset]$Now,[ValidateRange(1,7)][int]$RetentionDays=7,[ValidateRange(1,10000000)][long]$MaximumBytes=10000000)
 $action={
  param($root)
  $raw=Read-DiagnosticRaw $root
  $result=Limit-DiagnosticEvents -Events $raw.Events -Now $Now -RetentionDays $RetentionDays -MaximumBytes $MaximumBytes
  return $result.Events
 }.GetNewClosure()
 return @(Invoke-DiagnosticStoreLock $Directory $action)
}

function Write-DiagnosticEvent {
 param([Parameter(Mandatory=$true)][string]$Directory,[Parameter(Mandatory=$true)]$Event,[Parameter(Mandatory=$true)][DateTimeOffset]$Now,[ValidateRange(1,7)][int]$RetentionDays=7,[ValidateRange(1,10000000)][long]$MaximumBytes=10000000)
 $candidate=Limit-DiagnosticEvents -Events @($Event) -Now $Now -RetentionDays $RetentionDays -MaximumBytes $MaximumBytes
 if($candidate.Events.Count -ne 1){throw "Invalid diagnostic event."}
 Write-DiagnosticEvents -Directory $Directory -Events $candidate.Events -Now $Now -RetentionDays $RetentionDays -MaximumBytes $MaximumBytes
}

function Write-DiagnosticEvents {
 param([Parameter(Mandatory=$true)][string]$Directory,[AllowEmptyCollection()][object[]]$Events=@(),[Parameter(Mandatory=$true)][DateTimeOffset]$Now,[ValidateRange(1,7)][int]$RetentionDays=7,[ValidateRange(1,10000000)][long]$MaximumBytes=10000000)
 $candidate=Limit-DiagnosticEvents -Events $Events -Now $Now -RetentionDays $RetentionDays -MaximumBytes $MaximumBytes
 if($candidate.Events.Count -eq 0){return}
 $action={
  param($root)
  Ensure-DiagnosticDirectory $root
  $raw=Read-DiagnosticRaw $root
  $result=Limit-DiagnosticEvents -Events @($raw.Events+$candidate.Events) -Now $Now -RetentionDays $RetentionDays -MaximumBytes $MaximumBytes
  $desired=ConvertTo-DiagnosticFileText $result.Events
  if($raw.Exists -and $null -ne $raw.Content -and [Text.Encoding]::UTF8.GetByteCount($raw.Content) -eq $raw.FileBytes -and $desired.StartsWith($raw.Content,[StringComparison]::Ordinal)){
   Append-DiagnosticFile $root $raw.Content $desired.Substring($raw.Content.Length) $raw.FileBytes
  }else{Write-DiagnosticFile $root $result.Events}
 }.GetNewClosure()
 [void](Invoke-DiagnosticStoreLock $Directory $action)
}

function Remove-ExpiredDiagnosticEvents {
 param([Parameter(Mandatory=$true)][string]$Directory,[Parameter(Mandatory=$true)][DateTimeOffset]$Now,[ValidateRange(1,7)][int]$RetentionDays=7,[ValidateRange(1,10000000)][long]$MaximumBytes=10000000)
 $action={
  param($root)
  $raw=Read-DiagnosticRaw $root
  if(-not $raw.Exists){return}
  $result=Limit-DiagnosticEvents -Events $raw.Events -Now $Now -RetentionDays $RetentionDays -MaximumBytes $MaximumBytes
  Write-DiagnosticFile $root $result.Events
 }.GetNewClosure()
 [void](Invoke-DiagnosticStoreLock $Directory $action)
}

function Clear-DiagnosticEvents([string]$Directory) {
 $action={
  param($root)
  $raw=Read-DiagnosticRaw $root -AllowMalformed
  if($raw.Exists){Write-DiagnosticFile $root @()}
 }.GetNewClosure()
 [void](Invoke-DiagnosticStoreLock $Directory $action)
}
