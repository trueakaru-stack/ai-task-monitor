param([string]$EvidenceDirectory = '',[switch]$CopyOnly,[switch]$SelectionOnly,[switch]$CopySmoke,[switch]$LongSelection)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($LongSelection -and -not $SelectionOnly){throw 'Long selection evidence requires selection-only mode.'}
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'))
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-hermes-ui-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture directory.'}
[void][IO.Directory]::CreateDirectory($root)
$environmentNames=@('USERPROFILE','HOME','APPDATA','LOCALAPPDATA','CODEX_HOME','KIMI_CODE_HOME','HERMES_HOME','PATH')
$old=@{}
foreach($name in $environmentNames){$old[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
 $env:USERPROFILE=Join-Path $root 'profile';$env:HOME=$env:USERPROFILE
 $env:APPDATA=Join-Path $root 'roaming';$env:LOCALAPPDATA=Join-Path $root 'local'
 $env:CODEX_HOME=Join-Path $root 'codex';$env:KIMI_CODE_HOME=Join-Path $root 'kimi';$env:HERMES_HOME=Join-Path $root 'hermes'
 $env:PATH=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')+';'+(Join-Path $env:SystemRoot 'System32')+';'+$env:SystemRoot
 foreach($directory in @($env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:CODEX_HOME,$env:KIMI_CODE_HOME,$env:HERMES_HOME)){[void][IO.Directory]::CreateDirectory($directory)}
 if($EvidenceDirectory){[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($EvidenceDirectory))}
 foreach($theme in @('dark','light')){
  foreach($language in @('ru','en')){
   $states=if($SelectionOnly){@()}elseif($CopySmoke){@('prepared')}elseif($CopyOnly){@('prepared','enabled','long')}else{@('unselected','absent','prepared','enabled','long','error')}
   foreach($state in $states){
    $stem=$theme+'-'+$language+'-'+$state
    $snapshot=Join-Path $root ($stem+'-tasks.png');$settings=Join-Path $root ($stem+'-settings.png')
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 1 -PreviewOffscreen -PreviewSources -PreviewHermesUiTest -PreviewHermesState $state -ThemeOverride $theme -LanguageOverride $language -PreferencesFile (Join-Path $root ($stem+'-preferences.json')) -DiagnosticDirectory (Join-Path $root ($stem+'-diagnostics')) -SnapshotFile $snapshot -SettingsSnapshotFile $settings
    if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($snapshot) -or -not [IO.File]::Exists($settings)){throw ('Hermes source preview failed: '+$stem)}
    if($EvidenceDirectory){Copy-Item -LiteralPath $settings -Destination (Join-Path $EvidenceDirectory ($stem+'.png'))}
   }
   $selectionState=if($LongSelection){'long'}else{'prepared'}
   $stem=$theme+'-'+$language+$(if($LongSelection){'-long-selection'}elseif($SelectionOnly){'-selection'}else{'-focus'})
   $snapshot=Join-Path $root ($stem+'-tasks.png');$settings=Join-Path $root ($stem+'-settings.png')
   if($SelectionOnly){
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 1 -PreviewOffscreen -PreviewSources -PreviewHermesState $selectionState -PreviewHermesFocus -PreviewHermesSelection -ThemeOverride $theme -LanguageOverride $language -PreferencesFile (Join-Path $root ($stem+'-preferences.json')) -DiagnosticDirectory (Join-Path $root ($stem+'-diagnostics')) -SnapshotFile $snapshot -SettingsSnapshotFile $settings
   }else{
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 1 -PreviewOffscreen -PreviewSources -PreviewHermesState prepared -PreviewHermesFocus -ThemeOverride $theme -LanguageOverride $language -PreferencesFile (Join-Path $root ($stem+'-preferences.json')) -DiagnosticDirectory (Join-Path $root ($stem+'-diagnostics')) -SnapshotFile $snapshot -SettingsSnapshotFile $settings
   }
   if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($snapshot) -or -not [IO.File]::Exists($settings)){throw ('Hermes focus preview failed: '+$stem)}
   if($EvidenceDirectory){Copy-Item -LiteralPath $settings -Destination (Join-Path $EvidenceDirectory ($stem+'.png'))}
   if($SelectionOnly){
    $stem=$theme+'-'+$language+$(if($LongSelection){'-long-disable-selection'}else{'-disable-selection'})
    $snapshot=Join-Path $root ($stem+'-tasks.png');$settings=Join-Path $root ($stem+'-settings.png')
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 1 -PreviewOffscreen -PreviewSources -PreviewHermesState $selectionState -PreviewHermesFocus -PreviewHermesSelection -PreviewHermesDisableSelection -ThemeOverride $theme -LanguageOverride $language -PreferencesFile (Join-Path $root ($stem+'-preferences.json')) -DiagnosticDirectory (Join-Path $root ($stem+'-diagnostics')) -SnapshotFile $snapshot -SettingsSnapshotFile $settings
    if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($snapshot) -or -not [IO.File]::Exists($settings)){throw ('Hermes disable selection preview failed: '+$stem)}
    if($EvidenceDirectory){Copy-Item -LiteralPath $settings -Destination (Join-Path $EvidenceDirectory ($stem+'.png'))}
   }
  }
 }
 'Hermes source UI: isolated states, profile selection, command safety, languages and themes verified.'
}finally{
 foreach($name in $environmentNames){[Environment]::SetEnvironmentVariable($name,$old[$name],'Process')}
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
