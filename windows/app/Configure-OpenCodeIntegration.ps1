param(
 [ValidateSet('Install','Remove','State')][string]$Mode = 'State',
 [string]$FixtureHome = '',
 [string]$FixtureVersion = '',
 [switch]$ReturnStateToCaller
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if($ReturnStateToCaller -and $Mode -ne 'State'){throw 'The library entry is read-only.'}
if($FixtureVersion -and -not $FixtureHome){throw 'A fixture version requires an isolated test profile.'}
$profileHome = if($FixtureHome){
 $full=[IO.Path]::GetFullPath($FixtureHome)
 $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture home must be inside the temporary directory.'}
 $full
}else{[IO.Path]::GetFullPath($env:USERPROFILE)}
$source = Join-Path $profileHome '.config\opencode'
$plugins = Join-Path $source 'plugins'
$folder = Join-Path $source 'ai-task-monitor-data'
$shim = Join-Path $plugins 'ai-task-monitor.js'
$manifestPath = Join-Path $folder 'manifest.json'
$assets = Join-Path $PSScriptRoot 'integrations'
$names = @('provider-events.mjs','provider-observers.mjs','provider-transport.mjs')
$shimAsset = Join-Path $assets 'opencode-entry.js'

function Test-SupportedVersion([string]$value) {
 $match=[regex]::Match($value.Trim(),'^(?:opencode\s+)?v?(\d{1,5})\.(\d{1,5})\.(\d{1,5})$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
 if(-not $match.Success){return $false}
 $major=[int]$match.Groups[1].Value;$minor=[int]$match.Groups[2].Value;$patch=[int]$match.Groups[3].Value
 return ($major -eq 2) -or ($major -eq 1 -and ($minor -gt 18 -or ($minor -eq 18 -and $patch -ge 29)))
}
function Get-InstalledVersions {
 $candidates=@(Get-Command -Name 'opencode.exe' -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
 $defaultExecutable=Join-Path $profileHome '.opencode\bin\opencode.exe'
 if([IO.File]::Exists($defaultExecutable)){$candidates=@($candidates+@($defaultExecutable)|Select-Object -Unique)}
 if($candidates.Count -eq 0){return @()}
 $versions=New-Object Collections.Generic.List[string]
 foreach($candidate in $candidates){
  $info=[Diagnostics.ProcessStartInfo]::new()
  $info.FileName=$candidate;$info.Arguments='--version';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $process=[Diagnostics.Process]::Start($info)
  try{
   $output=$process.StandardOutput.ReadToEndAsync();$errorOutput=$process.StandardError.ReadToEndAsync()
   if(-not $process.WaitForExit(3000)){try{$process.Kill()}catch{};throw 'OpenCode version check timed out.'}
   if($process.ExitCode -ne 0){throw 'OpenCode version check failed.'}
   $version=$output.GetAwaiter().GetResult().Trim()
   if($version.Length -gt 80 -or -not (Test-SupportedVersion $version)){throw 'OpenCode version is unsupported.'}
   $versions.Add($version)
  }finally{$process.Dispose()}
 }
 return $versions.ToArray()
}
if($Mode -eq 'Install'){
 if($FixtureHome){$versions=@($(if($FixtureVersion){$FixtureVersion}else{'1.18.29'}))}
 else{$versions=@(Get-InstalledVersions)}
 if($versions.Count -eq 0 -or @($versions|Where-Object {-not (Test-SupportedVersion $_)}).Count -gt 0){throw 'OpenCode version compatibility has not been verified; no changes were made.'}
}

function Check-NotLink([string]$path) {
 $item=Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
 if($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A source directory or file is a link; no changes were made.'}
}
function Check-Directories {
 foreach($path in @($profileHome,(Join-Path $profileHome '.config'),$source,$plugins,$folder,$shim,$manifestPath)){Check-NotLink $path}
}
function Digest([string]$path) {
 $stream=[IO.File]::OpenRead($path)
 $hasher=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','')}
 finally{$hasher.Dispose();$stream.Dispose()}
}
function Read-OwnedManifest {
 Check-Directories
 if(-not [IO.Directory]::Exists($folder) -or -not [IO.File]::Exists($manifestPath)){return $null}
 $items=@(Get-ChildItem -LiteralPath $folder -Force)
 if($items.Count -ne ($names.Count+1) -or @($items|Where-Object {$_.PSIsContainer -or $_.Name -notin ($names+@('manifest.json'))}).Count -gt 0){throw 'OpenCode monitor files were modified; no changes were made.'}
 foreach($item in $items){Check-NotLink $item.FullName}
 $text=[IO.File]::ReadAllText($manifestPath)
 if($text.Length -gt 8192){throw 'OpenCode monitor manifest is invalid; no changes were made.'}
 $manifest=$text|ConvertFrom-Json
 if($null -eq $manifest -or [string]$manifest.owner -cne 'AI Task Monitor OpenCode v1' -or $null -eq $manifest.files -or $null -eq $manifest.shim){throw 'OpenCode monitor manifest is invalid; no changes were made.'}
 $properties=@($manifest.files.PSObject.Properties.Name)
 if($properties.Count -ne $names.Count -or @($properties|Where-Object {$_ -notin $names}).Count -gt 0){throw 'OpenCode monitor manifest is invalid; no changes were made.'}
 foreach($name in $names){
  $expected=[string]$manifest.files.$name
  if($expected -cnotmatch '^[A-F0-9]{64}$' -or (Digest (Join-Path $folder $name)) -cne $expected){throw 'OpenCode monitor files were modified; no changes were made.'}
 }
 if([string]$manifest.shim -cnotmatch '^[A-F0-9]{64}$'){throw 'OpenCode monitor manifest is invalid; no changes were made.'}
 if([IO.File]::Exists($shim) -and (Digest $shim) -cne [string]$manifest.shim){throw 'OpenCode monitor entry was modified; no changes were made.'}
 return $manifest
}

Check-Directories
$hasFolder=[IO.Directory]::Exists($folder)
$hasShim=[IO.File]::Exists($shim)
$owned=if($hasFolder){Read-OwnedManifest}else{$null}
if($hasFolder -and $null -eq $owned){throw 'The OpenCode plugin name is already in use; no changes were made.'}
if($hasShim -and $null -eq $owned -and (Digest $shim) -cne (Digest $shimAsset)){throw 'The OpenCode entry name is already in use; no changes were made.'}

if($Mode -eq 'State') {
 if($hasFolder -and $hasShim -and $null -ne $owned){Write-Output 'connected'}
 elseif($hasFolder -or $hasShim){Write-Output 'partial'}
 else{Write-Output 'disconnected'}
 if($ReturnStateToCaller){return}
 exit 0
}

if($Mode -eq 'Remove') {
 if($hasShim -and $null -eq $owned){throw 'The OpenCode entry has no ownership manifest; no changes were made.'}
 if($hasShim){[IO.File]::Delete($shim)}
 if($hasFolder){
  foreach($name in $names){[IO.File]::Delete((Join-Path $folder $name))}
  [IO.File]::Delete($manifestPath)
  [IO.Directory]::Delete($folder,$false)
 }
 Write-Output 'disconnected'
 exit 0
}

foreach($name in $names){if(-not [IO.File]::Exists((Join-Path $assets $name))){throw 'Monitor plugin resources are missing.'}}
if(-not [IO.File]::Exists($shimAsset)){throw 'Monitor plugin resources are missing.'}
if($hasFolder -and $hasShim){
 foreach($name in $names){if((Digest (Join-Path $assets $name)) -cne [string]$owned.files.$name){throw 'Reconnect OpenCode to update the monitor plugin.'}}
 if((Digest $shimAsset) -cne [string]$owned.shim){throw 'Reconnect OpenCode to update the monitor plugin.'}
 Write-Output 'connected'
 exit 0
}
if($hasFolder -or $hasShim){throw 'OpenCode connection is incomplete; disconnect before reconnecting.'}
[IO.Directory]::CreateDirectory($plugins)|Out-Null
Check-Directories
$stage=Join-Path $source ('.aitm-stage-'+[Guid]::NewGuid().ToString('N'))
$temporaryShim=Join-Path $plugins ('.aitm-entry-'+[Guid]::NewGuid().ToString('N')+'.tmp')
$created=New-Object Collections.Generic.List[string]
$moved=$false
$shimCreated=$false
try {
 New-Item -ItemType Directory -Path $stage -ErrorAction Stop|Out-Null
 $hashes=[ordered]@{}
 foreach($name in $names){
  $target=Join-Path $stage $name
  [IO.File]::Copy((Join-Path $assets $name),$target,$false)
  $created.Add($target)
  $hashes[$name]=Digest $target
 }
 $marker=[ordered]@{owner='AI Task Monitor OpenCode v1';files=$hashes;shim=(Digest $shimAsset)}|ConvertTo-Json -Depth 4
 $stageManifest=Join-Path $stage 'manifest.json'
 $manifestStream=[IO.File]::Open($stageManifest,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$writer=[IO.StreamWriter]::new($manifestStream,[Text.UTF8Encoding]::new($false));try{$writer.Write($marker)}finally{$writer.Dispose()}}finally{$manifestStream.Dispose()}
 $created.Add($stageManifest)
 [IO.File]::Copy($shimAsset,$temporaryShim,$false)
 $shimCreated=$true
 Check-Directories
 [IO.Directory]::Move($stage,$folder)
 $moved=$true
 [IO.File]::Move($temporaryShim,$shim)
 $shimCreated=$false
 Write-Output 'connected'
} catch {
 if($moved -and -not [IO.File]::Exists($shim)){
  try{[void](Read-OwnedManifest);foreach($name in $names){[IO.File]::Delete((Join-Path $folder $name))};[IO.File]::Delete($manifestPath);[IO.Directory]::Delete($folder,$false)}catch{}
 }
 throw
} finally {
 if($shimCreated -and [IO.File]::Exists($temporaryShim)){[IO.File]::Delete($temporaryShim)}
 if([IO.Directory]::Exists($stage)){
  Check-NotLink $stage
  foreach($path in $created){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
  [IO.Directory]::Delete($stage,$false)
 }
}
