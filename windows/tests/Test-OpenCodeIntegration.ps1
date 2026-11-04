$ErrorActionPreference = 'Stop'
$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app/Configure-OpenCodeIntegration.ps1'))
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-opencode-test-' + [Guid]::NewGuid().ToString('N'))))
$prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
[void][IO.Directory]::CreateDirectory($root)
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Invoke-Fixture([string]$mode,[string]$fixtureHome=$root,[string]$fixtureVersion='') {
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
 $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$scriptPath+'" -Mode '+$mode+' -FixtureHome "'+$fixtureHome+'"'
 if($fixtureVersion){$start.Arguments+=' -FixtureVersion "'+$fixtureVersion+'"'}
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $process=[Diagnostics.Process]::Start($start)
 try{
  if(-not $process.WaitForExit(5000)){$process.Kill();throw 'Fixture timed out.'}
  return [PSCustomObject]@{Code=$process.ExitCode;Output=$process.StandardOutput.ReadToEnd().Trim();Error=$process.StandardError.ReadToEnd()}
 }finally{$process.Dispose()}
}
function Get-StateInScope([string]$fixtureHome=$root) {
 return (& { param($path,$homePath) . $path -Mode State -FixtureHome $homePath -ReturnStateToCaller } $scriptPath $fixtureHome)
}
try {
 foreach($version in @('1.18.28','3.0.0','unknown','2.0.0-beta')){
  $refused=Invoke-Fixture 'Install' $root $version
  Assert ($refused.Code -ne 0 -and -not [IO.Directory]::Exists((Join-Path $root '.config'))) ('Unsupported version changed the fixture profile: '+$version)
 }
 $other=Join-Path $root '.config\opencode\plugins\another-plugin.js'
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $other))
 [IO.File]::WriteAllText($other,'UNRELATED')
 $state=Invoke-Fixture 'State'
 Assert ($state.Code -eq 0 -and $state.Output -eq 'disconnected') 'Initial state must be disconnected.'
 Assert ((Get-StateInScope) -eq 'disconnected') 'Read-only in-process state must detect disconnection.'
 $install=Invoke-Fixture 'Install'
 Assert ($install.Code -eq 0 -and $install.Output -eq 'connected') ('Install failed: '+$install.Error)
 $again=Invoke-Fixture 'Install'
 Assert ($again.Code -eq 0 -and $again.Output -eq 'connected') 'Install is not idempotent.'
 $connected=Invoke-Fixture 'State'
 Assert ($connected.Code -eq 0 -and $connected.Output -eq 'connected') 'Connection was not detected.'
 Assert ((Get-StateInScope) -eq 'connected') 'Read-only in-process state must detect connection.'
 Assert ([IO.File]::ReadAllText($other) -ceq 'UNRELATED') 'Another plugin was modified.'
 $shim=Join-Path $root '.config\opencode\plugins\ai-task-monitor.js'
 $oldProfile=$env:USERPROFILE
 try{
  $env:USERPROFILE=$root
  & node (Join-Path $PSScriptRoot 'Test-OpenCodePluginLoad.mjs') $shim
  Assert ($LASTEXITCODE -eq 0) 'The installed OpenCode plugin did not load.'
 }finally{$env:USERPROFILE=$oldProfile}
 $module=Join-Path $root '.config\opencode\ai-task-monitor-data\provider-events.mjs'
 $old=[IO.File]::ReadAllText($module)
 [IO.File]::WriteAllText($module, $old+'// user change')
 $refused=Invoke-Fixture 'Remove'
 Assert ($refused.Code -ne 0 -and [IO.File]::Exists($module)) 'A modified plugin must not be removed.'
 $stateRefused=$false
 try{[void](Get-StateInScope)}catch{$stateRefused=$true}
 Assert $stateRefused 'Read-only in-process state must reject a modified plugin.'
 [IO.File]::WriteAllText($module,$old,[Text.UTF8Encoding]::new($false))
 $extra=Join-Path $root '.config\opencode\ai-task-monitor-data\user-file.txt'
 [IO.File]::WriteAllText($extra,'KEEP')
 $refusedExtra=Invoke-Fixture 'Remove'
 Assert ($refusedExtra.Code -ne 0 -and [IO.File]::Exists($extra)) 'An unknown file must not be removed.'
 [IO.File]::Delete($extra)
 $remove=Invoke-Fixture 'Remove'
 Assert ($remove.Code -eq 0 -and $remove.Output -eq 'disconnected') ('Remove failed: '+$remove.Error)
 Assert ([IO.File]::Exists($other) -and [IO.File]::ReadAllText($other) -ceq 'UNRELATED') 'Unrelated plugin was not preserved.'
 $removed=Invoke-Fixture 'State'
 Assert ($removed.Code -eq 0 -and $removed.Output -eq 'disconnected') 'Removed connection is still shown as connected.'
 $version2=Invoke-Fixture 'Install' $root '2.0.0'
 Assert ($version2.Code -eq 0 -and $version2.Output -eq 'connected') 'A supported OpenCode 2 fixture was refused.'
 $remove2=Invoke-Fixture 'Remove'
 Assert ($remove2.Code -eq 0 -and $remove2.Output -eq 'disconnected') 'OpenCode 2 fixture removal failed.'
 $linkedHome=Join-Path $root 'linked-home'
 $linkTarget=Join-Path $root 'link-target'
 [void][IO.Directory]::CreateDirectory($linkedHome)
 [void][IO.Directory]::CreateDirectory($linkTarget)
 $sentinel=Join-Path $linkTarget 'sentinel.txt'
 [IO.File]::WriteAllText($sentinel,'KEEP')
 New-Item -ItemType SymbolicLink -Path (Join-Path $linkedHome '.config') -Target $linkTarget -ErrorAction Stop | Out-Null
 $linked=Invoke-Fixture 'Install' $linkedHome
 Assert ($linked.Code -ne 0 -and [IO.File]::ReadAllText($sentinel) -ceq 'KEEP') 'Symbolic link target was not protected.'
 Write-Output 'OpenCode integration fixtures passed.'
} finally {
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
