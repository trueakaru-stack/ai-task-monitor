Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$embeddedManifest = 'BUILD_MANIFEST_REQUIRED'
$embeddedSelfHash = '0000000000000000000000000000000000000000000000000000000000000000'
Add-Type -AssemblyName System.Windows.Forms
function Resolve-RemovalLanguage {
 $fallback=if([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru'){'ru'}else{'en'}
 try{
  $local=[string]$env:LOCALAPPDATA
  if(-not $local -or -not [IO.Path]::IsPathRooted($local)){return $fallback}
  $local=[IO.Path]::GetFullPath($local)
  $folder=Join-Path $local 'CodexTaskProgress'
  $path=Join-Path $folder 'settings.json'
  foreach($part in @($local,$folder,$path)){
   $attributes=[IO.File]::GetAttributes($part)
   if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $fallback}
  }
  if(([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::Directory) -ne 0){return $fallback}
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{
   $buffer=[byte[]]::new(65537);$count=0
   while($count -lt $buffer.Length){
    $read=$stream.Read($buffer,$count,$buffer.Length-$count)
    if($read -le 0){break}
    $count+=$read
   }
   if($count -gt 65536){return $fallback}
   $text=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$count).TrimStart([char]0xFEFF)
   $settings=$text|ConvertFrom-Json -ErrorAction Stop
   if($settings -isnot [PSCustomObject]){return $fallback}
   $language=$settings.PSObject.Properties['language']
   if($null -eq $language -or $language.Value -isnot [string]){return $fallback}
   if($language.Value -ceq 'ru'){return 'ru'}
   if($language.Value -ceq 'en'){return 'en'}
  }finally{$stream.Dispose()}
 }catch{}
 return $fallback
}
$isRussian=(Resolve-RemovalLanguage) -ceq 'ru'
function Show-RemovalMessage([string]$ru,[string]$en,[System.Windows.Forms.MessageBoxIcon]$icon){
 [void][System.Windows.Forms.MessageBox]::Show($(if($isRussian){$ru}else{$en}),'AI task monitor',[System.Windows.Forms.MessageBoxButtons]::OK,$icon)
}
function Hash-Bytes([byte[]]$bytes){
 $algorithm=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-','')}finally{$algorithm.Dispose()}
}
function Get-ClaudeSettingsLocation {
 $profile=[string]$env:USERPROFILE
 if(-not $profile){throw 'Claude profile is unavailable.'}
 $profile=[IO.Path]::GetFullPath($profile)
 $drive=[IO.Path]::GetPathRoot($profile)
 if(-not $drive -or $drive.Length -ne 3 -or $drive[1] -ne ':'){throw 'Claude profile is not local.'}
 $current=$drive
 foreach($part in $profile.Substring($drive.Length).Split([char]'\')){
  if(-not $part){continue}
  $current=Join-Path $current $part
  $attributes=[IO.File]::GetAttributes($current)
  if(($attributes -band [IO.FileAttributes]::Directory) -eq 0 -or ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Claude profile is redirected or unavailable.'}
 }
 $directory=Join-Path $profile '.claude'
 try{$attributes=[IO.File]::GetAttributes($directory)}
 catch [IO.FileNotFoundException]{return $null}
 catch [IO.DirectoryNotFoundException]{return $null}
 if(($attributes -band [IO.FileAttributes]::Directory) -eq 0 -or ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Claude settings directory is redirected or unavailable.'}
 $path=Join-Path $directory 'settings.json'
 try{$attributes=[IO.File]::GetAttributes($path)}
 catch [IO.FileNotFoundException]{return $null}
 catch [IO.DirectoryNotFoundException]{return $null}
 if(($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0){throw 'Claude settings use a redirected file.'}
 return $path
}
function Open-ConfirmedClaudeSettings {
 $path=Get-ClaudeSettingsLocation
 if(-not $path){return $null}
 $file=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{
  if($file.Length -gt 4194304){throw 'Claude settings are too large to verify.'}
  $reader=[IO.StreamReader]::new($file,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
  try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
  $config=$text|ConvertFrom-Json -ErrorAction Stop
  if($config -isnot [PSCustomObject]){throw 'Claude settings are not an object.'}
  $hooks=$config.PSObject.Properties['hooks']
  if($null -ne $hooks){
   if($hooks.Value -isnot [PSCustomObject]){throw 'Claude hooks are not an object.'}
   foreach($event in $hooks.Value.PSObject.Properties){
    if($event.Value -isnot [array]){throw 'Claude hook groups are not an array.'}
    foreach($group in $event.Value){
     if($group -isnot [PSCustomObject]){throw 'Claude hook group is invalid.'}
     $commands=$group.PSObject.Properties['hooks']
     if($null -eq $commands){continue}
     if($commands.Value -isnot [array]){throw 'Claude hook commands are not an array.'}
     foreach($hook in $commands.Value){
      if($hook -isnot [PSCustomObject]){throw 'Claude hook is invalid.'}
      $command=$hook.PSObject.Properties['command']
      if($null -eq $command){continue}
      if($command.Value -isnot [string]){throw 'Claude hook command is invalid.'}
      $value=[string]$command.Value
      if($value.IndexOf('ClaudeTaskHook.ps1',[StringComparison]::OrdinalIgnoreCase) -ge 0){throw 'Claude hook remains connected.'}
      if($value -match '(?i)-(?:encodedcommand|enc)\b'){
       if($value -notmatch '(?i)-(?:encodedcommand|enc)\s+["'']?([A-Za-z0-9+/=]+)'){throw 'An encoded Claude hook cannot be verified.'}
       try{$decoded=[Text.UnicodeEncoding]::new($false,$true,$true).GetString([Convert]::FromBase64String($Matches[1]))}
       catch{throw 'An encoded Claude hook cannot be verified.'}
       if($decoded.IndexOf('ClaudeTaskHook.ps1',[StringComparison]::OrdinalIgnoreCase) -ge 0){throw 'Claude hook remains connected.'}
      }
     }
    }
   }
  }
  return $file
 }catch{$file.Dispose();throw}
}

$guard=$null
$settingsLock=$null
try{
 if($embeddedManifest -eq 'BUILD_MANIFEST_REQUIRED' -or $embeddedSelfHash -notmatch '^[A-F0-9]{64}$' -or $embeddedSelfHash -eq ('0'*64)){
  throw 'This installation has no verified removal inventory.'
 }
 $encoding=[Text.UTF8Encoding]::new($false,$true)
 $self=[IO.File]::Open($PSCommandPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{
  if($self.Length -gt 2097152){throw 'The removal script is too large.'}
  $memory=New-Object IO.MemoryStream
  try{$self.CopyTo($memory);$selfBytes=$memory.ToArray()}finally{$memory.Dispose()}
 }finally{$self.Dispose()}
 $selfText=$encoding.GetString($selfBytes)
 $selfLine='$embeddedSelfHash = '+"'"+$embeddedSelfHash+"'"
 $zeroLine='$embeddedSelfHash = '+"'"+('0'*64)+"'"
 if($selfText.IndexOf($selfLine,[StringComparison]::Ordinal) -lt 0 -or
    $selfText.IndexOf($selfLine,[StringComparison]::Ordinal) -ne $selfText.LastIndexOf($selfLine,[StringComparison]::Ordinal) -or
    (Hash-Bytes ($encoding.GetBytes($selfText.Replace($selfLine,$zeroLine)))) -cne $embeddedSelfHash){throw 'The removal script has changed.'}
 $expectedRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'AITaskMonitor')).TrimEnd('\')
 $root=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
 if(-not [string]::Equals($root,$expectedRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'The installation path cannot be verified.'}
 $manifestText=$encoding.GetString([Convert]::FromBase64String($embeddedManifest))
 if($manifestText.Length -gt 65536){throw 'The removal inventory is too large.'}
 $manifest=$manifestText|ConvertFrom-Json -ErrorAction Stop
 if($null -eq $manifest -or $manifest.version -ne 1 -or $manifest.files -isnot [PSCustomObject]){throw 'The removal inventory is invalid.'}
 $entries=@($manifest.files.PSObject.Properties)
 if($entries.Count -lt 1 -or $entries.Count -gt 128){throw 'The removal inventory is invalid.'}
 $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $entries){
  if($entry.Name -notmatch '^[A-Za-z0-9_. -]+(?:/[A-Za-z0-9_. -]+)*$' -or
     @($entry.Name.Split('/')|Where-Object {$_ -in @('.','..') -or $_.EndsWith('.') -or $_.EndsWith(' ')}).Count -gt 0 -or
     [string]$entry.Value -cnotmatch '^[A-F0-9]{64}$' -or -not $names.Add($entry.Name)){throw 'The removal inventory is invalid.'}
 }
 foreach($required in @('SafeUninstall.cs','Configure-ClaudeIntegration.ps1','ClaudeTaskHook.ps1','ClaudeLoopClient.ps1','ClaudeStageObservation.dll','Uninstall-CodexProgress.cmd')){
  if(-not $names.Contains($required)){throw 'The removal inventory is incomplete.'}
 }
 $helperPath=Join-Path $root 'SafeUninstall.cs'
 $helper=[IO.File]::Open($helperPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{
  if($helper.Length -gt 1048576){throw 'The removal helper is too large.'}
  $memory=New-Object IO.MemoryStream
  try{$helper.CopyTo($memory);$helperBytes=$memory.ToArray()}finally{$memory.Dispose()}
  if((Hash-Bytes $helperBytes) -cne [string]$manifest.files.'SafeUninstall.cs'){throw 'The removal helper has changed.'}
  Add-Type -TypeDefinition ($encoding.GetString($helperBytes)) -ErrorAction Stop
 }finally{$helper.Dispose()}
 $guard=[AITaskMonitor.SafeRemoval.Guard]::new($root)
 $nl=[Environment]::NewLine
 $question=if($isRussian){
  "Закройте AI task monitor, Claude Code, Claude Desktop и другие программы, которые могут менять настройки Claude, включая фоновые процессы. Во время одновременной записи настроек остаётся небольшой риск потери изменений.$nl$nl Если подключали Hermes, Kimi, OpenCode или DeepSeek, отключите их штатными средствами. Их файлы пока будут сохранены.$nl$nl Отключить Claude Code и удалить проверенные файлы AI task monitor?"
 }else{
  "Quit AI task monitor, Claude Code, Claude Desktop and other programs that can change Claude settings, including background processes. Simultaneous settings changes carry a small risk of data loss.$nl$nl If you connected Hermes, Kimi, OpenCode or DeepSeek, disconnect them using their own controls. Their files will be preserved.$nl$nl Disconnect Claude Code and remove the verified AI task monitor files?"
 }
 $answer=[System.Windows.Forms.MessageBox]::Show($question,'AI task monitor',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
 if($answer -ne [System.Windows.Forms.DialogResult]::Yes){exit 0}
 $null=Get-ClaudeSettingsLocation
 $configure=$guard.HoldVerified('Configure-ClaudeIntegration.ps1',[string]$manifest.files.'Configure-ClaudeIntegration.ps1')
 try{
  $ps=[IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::System),'WindowsPowerShell\v1.0\powershell.exe')
  $start=New-Object Diagnostics.ProcessStartInfo
  $start.FileName=$ps;$start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Configure-ClaudeIntegration.ps1')+'" -Mode Remove'
  $start.WorkingDirectory=$root;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $process=[Diagnostics.Process]::Start($start)
  try{
   $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
   if(-not $process.WaitForExit(20000)){$process.Kill();[void]$process.WaitForExit(5000);throw 'Claude disconnection timed out.'}
   if($process.ExitCode -ne 0){throw 'Claude disconnection failed.'}
  }finally{$process.Dispose()}
 }finally{$configure.Dispose()}
 $settingsLock=Open-ConfirmedClaudeSettings
 $retained=New-Object 'Collections.Generic.List[string]'
 $removed=0
 foreach($entry in $entries){
  $name=[string]$entry.Name
  if($name.StartsWith('integrations/',[StringComparison]::OrdinalIgnoreCase) -or
     $name -in @('Uninstall-CodexProgress.cmd','SafeUninstall.cs','Configure-OpenCodeIntegration.ps1')){
   $retained.Add($name);continue
  }
  $outcome=$guard.RemoveVerified($name,[string]$entry.Value)
  if($outcome -eq 'removed'){$removed++}
  elseif($outcome -ne 'missing'){$retained.Add($name)}
 }
 $programs=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
 $shortcut1=Join-Path $programs 'AI task monitor.lnk'
 $shortcut2=Join-Path $programs 'AI task monitor (new).lnk'
 $message=if($isRussian){
  "Отключение Claude Code проверено. Удалено файлов: $removed.$nl$nl Часть файлов и установочная папка сохранены: если подключали Hermes, Kimi, OpenCode или DeepSeek, отключите их штатными средствами. Изменённые, чужие и недоступные файлы также сохранены. Папка: $root.$nl$nl Проверьте ярлыки: $shortcut1 и $shortcut2."
 }else{
  "Claude Code disconnection was checked. Files removed: $removed.$nl$nl Some files and the installation folder were preserved. If you connected Hermes, Kimi, OpenCode or DeepSeek, disconnect them using their own controls. Modified, unrelated and unavailable files were also preserved. Folder: $root.$nl$nl Check shortcuts: $shortcut1 and $shortcut2."
 }
 if($null -ne $settingsLock){$settingsLock.Dispose();$settingsLock=$null}
 if($null -ne $guard){$guard.Dispose();$guard=$null}
 [void][System.Windows.Forms.MessageBox]::Show($message,'AI task monitor',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
 exit 0
}catch{
 Show-RemovalMessage 'Автоматическое удаление остановлено. Некоторые проверенные файлы уже могли быть удалены, а Claude Code — отключён. Проверьте папку приложения и подключения перед повтором.' 'Automatic removal stopped. Some verified files may already have been removed, and Claude Code may have been disconnected. Review the installation folder and connections before retrying.' ([System.Windows.Forms.MessageBoxIcon]::Warning)
 exit 1
}finally{
 if($null -ne $settingsLock){$settingsLock.Dispose()}
 if($null -ne $guard){$guard.Dispose()}
}
