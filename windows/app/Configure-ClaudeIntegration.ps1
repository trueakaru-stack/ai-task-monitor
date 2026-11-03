param([ValidateSet("Install","Remove")][string]$Mode="Install")

Set-StrictMode -Version 2.0
$ErrorActionPreference="Stop"
$claudeDirectory=Join-Path $env:USERPROFILE ".claude"
$settingsPath=Join-Path $claudeDirectory "settings.json"
$hookPath=Join-Path $PSScriptRoot "ClaudeTaskHook.ps1"
$legacyHookCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$hookPath+'"'
$hookScript="& '"+$hookPath.Replace("'","''")+"'"
$encodedHook=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hookScript))
$hookCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encodedHook
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'store-channel.marker') -PathType Leaf){
 . (Join-Path $PSScriptRoot 'StoreClaudeHook.ps1')
 $hookCommand=Get-StoreClaudeHookCommand $PSScriptRoot
}
$events=@("UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","TaskCreated","TaskCompleted","SubagentStart","SubagentStop","Stop","SessionEnd")

function Is-OurHook($hook) {
 if($null -eq $hook){return $false}
 foreach($propertyName in $hook.PSObject.Properties.Name){if($propertyName -notin @("type","command","timeout")){return $false}}
 if($null -eq $hook.PSObject.Properties["type"] -or [string]$hook.type -ne "command"){return $false}
 if($null -eq $hook.PSObject.Properties["command"]){return $false}
 if($null -ne $hook.PSObject.Properties["args"]){return $false}
 $command=([string]$hook.command).Trim()
 return [string]::Equals($command,$hookCommand,[StringComparison]::Ordinal) -or [string]::Equals($command,$legacyHookCommand,[StringComparison]::OrdinalIgnoreCase)
}

function Is-CurrentHook($hook) {
 return (Is-OurHook $hook) -and [string]::Equals(([string]$hook.command).Trim(),$hookCommand,[StringComparison]::Ordinal)
}

if(-not (Test-Path -LiteralPath $claudeDirectory)){
 if($Mode -eq "Remove"){exit 0}
 [IO.Directory]::CreateDirectory($claudeDirectory)|Out-Null
}

$hasSettings=Test-Path -LiteralPath $settingsPath -PathType Leaf
if($Mode -eq "Remove" -and -not $hasSettings){exit 0}
if($hasSettings){
 $originalBytes=[IO.File]::ReadAllBytes($settingsPath)
 $hasher=[Security.Cryptography.SHA256]::Create()
 try{$originalHash=[BitConverter]::ToString($hasher.ComputeHash($originalBytes)).Replace("-","")}finally{$hasher.Dispose()}
 $raw=[Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xFEFF)
 $settings=if($raw.Trim()){$raw|ConvertFrom-Json}else{[PSCustomObject]@{}}
}else{$settings=[PSCustomObject]@{}}

if($settings -isnot [PSCustomObject]){throw "Claude Code settings are not a JSON object; no changes were made."}
if($null -eq $settings.PSObject.Properties["hooks"]){$settings|Add-Member NoteProperty hooks ([PSCustomObject]@{})}
if($settings.hooks -isnot [PSCustomObject]){throw "Claude Code hooks are not a JSON object; no changes were made."}

$eventsToCheck=if($Mode -eq "Install"){$events}else{@($settings.hooks.PSObject.Properties.Name)}
foreach($eventName in $eventsToCheck){
 $property=$settings.hooks.PSObject.Properties[$eventName]
 if($null -eq $property){continue}
 if($property.Value -isnot [array]){throw "Claude Code hook groups are not an array; no changes were made."}
 foreach($entry in $property.Value){
  if($entry -isnot [PSCustomObject]){throw "A Claude Code hook group is not an object; no changes were made."}
  $entryHooks=$entry.PSObject.Properties["hooks"]
  if($null -eq $entryHooks){continue}
  if($entryHooks.Value -isnot [array]){throw "Claude Code commands are not an array; no changes were made."}
  foreach($hook in $entryHooks.Value){if($hook -isnot [PSCustomObject]){throw "A Claude Code hook is not an object; no changes were made."}}
 }
}

if($Mode -eq "Install"){
 if($hasSettings){
  $backup=$settingsPath+".codex-tasks-backup-"+(Get-Date -Format "yyyyMMdd-HHmmss-fffffff")
  Copy-Item -LiteralPath $settingsPath -Destination $backup
 }
 foreach($eventName in $events){
  $property=$settings.hooks.PSObject.Properties[$eventName]
  [object[]]$entries=@()
  if($null -ne $property){$entries=@($property.Value)}
  $exists=$false
  $kept=New-Object Collections.Generic.List[object]
  foreach($entry in $entries){
   if($null -eq $entry){$kept.Add($entry);continue}
   $hooksProperty=$entry.PSObject.Properties["hooks"]
   if($null -eq $hooksProperty){$kept.Add($entry);continue}
   $remaining=New-Object Collections.Generic.List[object]
   $migrated=$false
   foreach($hook in @($hooksProperty.Value)){
    if((Is-OurHook $hook) -and -not (Is-CurrentHook $hook)){$migrated=$true;continue}
    if(Is-CurrentHook $hook){$exists=$true}
    $remaining.Add($hook)
   }
   if(-not $migrated){$kept.Add($entry)}
   elseif($remaining.Count -gt 0){$hooksProperty.Value=[object[]]$remaining;$kept.Add($entry)}
  }
  $entries=$kept.ToArray()
  if(-not $exists){$entries=@($entries)+[PSCustomObject]@{hooks=@([PSCustomObject]@{type="command";command=$hookCommand;timeout=10})}}
  if($null -eq $property){$settings.hooks|Add-Member NoteProperty $eventName ([object[]]$entries)}else{$property.Value=[object[]]$entries}
 }
}else{
 $changed=$false
 foreach($eventName in @($settings.hooks.PSObject.Properties.Name)){
  $property=$settings.hooks.PSObject.Properties[$eventName]
  $kept=New-Object Collections.Generic.List[object]
  foreach($entry in @($property.Value)){
   if($null -eq $entry){$kept.Add($entry);continue}
   $hooksProperty=$entry.PSObject.Properties["hooks"]
   if($null -eq $hooksProperty){$kept.Add($entry);continue}
   $remaining=New-Object Collections.Generic.List[object]
   $entryChanged=$false
   foreach($hook in @($hooksProperty.Value)){
    if(Is-OurHook $hook){$entryChanged=$true;$changed=$true}else{$remaining.Add($hook)}
   }
   if(-not $entryChanged){$kept.Add($entry)}
   elseif($remaining.Count -gt 0){$hooksProperty.Value=[object[]]$remaining;$kept.Add($entry)}
  }
  if($kept.Count -eq 0){$settings.hooks.PSObject.Properties.Remove($eventName)}else{$property.Value=[object[]]$kept}
 }
 if(-not $changed){exit 0}
}

$json=$settings|ConvertTo-Json -Depth 100
$temporaryPath=Join-Path $claudeDirectory (".ai-task-monitor-settings-"+[Guid]::NewGuid().ToString("N")+".tmp")
try{
 $stream=[IO.File]::Open($temporaryPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{
  $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
  try{$writer.Write($json+[Environment]::NewLine)}finally{$writer.Dispose()}
 }finally{$stream.Dispose()}
 if($hasSettings){
  if(-not (Test-Path -LiteralPath $settingsPath -PathType Leaf) -or (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -cne $originalHash){throw "Claude Code settings changed during the update; no changes were made."}
  [IO.File]::Replace($temporaryPath,$settingsPath,[System.Management.Automation.Language.NullString]::Value)
 }else{[IO.File]::Move($temporaryPath,$settingsPath)}
}finally{if([IO.File]::Exists($temporaryPath)){[IO.File]::Delete($temporaryPath)}}
