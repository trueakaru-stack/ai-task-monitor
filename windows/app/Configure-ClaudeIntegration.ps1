param([ValidateSet("Install","Remove")][string]$Mode="Install")

Set-StrictMode -Version 2.0
$ErrorActionPreference="Stop"
$claudeDirectory=Join-Path $env:USERPROFILE ".claude"
$settingsPath=Join-Path $claudeDirectory "settings.json"
$hookPath=Join-Path $PSScriptRoot "ClaudeTaskHook.ps1"
$hookCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$hookPath+'"'
$events=@("UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","TaskCreated","TaskCompleted","SubagentStart","SubagentStop","Stop","SessionEnd")

function Is-OurHook($hook) {
 if($null -eq $hook){return $false}
 return [string]::Equals(([string]$hook.command).Trim(),$hookCommand,[StringComparison]::OrdinalIgnoreCase)
}

if(-not (Test-Path -LiteralPath $claudeDirectory)){
 if($Mode -eq "Remove"){exit 0}
 [IO.Directory]::CreateDirectory($claudeDirectory)|Out-Null
}

if(Test-Path -LiteralPath $settingsPath){
 $raw=Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath
 $settings=if($raw.Trim()){$raw|ConvertFrom-Json}else{[PSCustomObject]@{}}
}else{$settings=[PSCustomObject]@{}}

if($null -eq $settings.PSObject.Properties["hooks"]){$settings|Add-Member NoteProperty hooks ([PSCustomObject]@{})}

if($Mode -eq "Install"){
 if(Test-Path -LiteralPath $settingsPath){
  $backup=$settingsPath+".codex-tasks-backup-"+(Get-Date -Format "yyyyMMdd-HHmmss")
  Copy-Item -LiteralPath $settingsPath -Destination $backup
 }
 foreach($eventName in $events){
  $property=$settings.hooks.PSObject.Properties[$eventName]
  [object[]]$entries=@()
  if($null -ne $property){$entries=@($property.Value)}
  $exists=$false
  foreach($entry in $entries){
   if($null -eq $entry){continue}
   $hooksProperty=$entry.PSObject.Properties["hooks"]
   if($null -eq $hooksProperty){continue}
   foreach($hook in @($hooksProperty.Value)){if(Is-OurHook $hook){$exists=$true}}
  }
  if(-not $exists){$entries=@($entries)+[PSCustomObject]@{hooks=@([PSCustomObject]@{type="command";command=$hookCommand;timeout=10})}}
  if($null -eq $property){$settings.hooks|Add-Member NoteProperty $eventName ([object[]]$entries)}else{$property.Value=[object[]]$entries}
 }
}else{
 foreach($eventName in @($settings.hooks.PSObject.Properties.Name)){
  $property=$settings.hooks.PSObject.Properties[$eventName]
  $kept=New-Object Collections.Generic.List[object]
  foreach($entry in @($property.Value)){
   $hooksProperty=$entry.PSObject.Properties["hooks"]
   if($null -eq $hooksProperty){$kept.Add($entry);continue}
   $remaining=New-Object Collections.Generic.List[object]
   foreach($hook in @($hooksProperty.Value)){
    if(-not (Is-OurHook $hook)){$remaining.Add($hook)}
   }
   if($remaining.Count -gt 0){$hooksProperty.Value=[object[]]$remaining;$kept.Add($entry)}
  }
  if($kept.Count -eq 0){$settings.hooks.PSObject.Properties.Remove($eventName)}else{$property.Value=[object[]]$kept}
 }
}

$json=$settings|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($settingsPath,$json+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
