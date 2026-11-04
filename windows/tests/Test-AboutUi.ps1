param([string]$EvidenceDirectory="")
$ErrorActionPreference="Stop"
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\app\CodexProgress.ps1"))
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("aitm-about-test-"+[Guid]::NewGuid().ToString("N"))))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $root.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test directory."}
if($EvidenceDirectory -and (Test-Path -LiteralPath $EvidenceDirectory)){throw "The evidence directory must not already exist."}
[void][IO.Directory]::CreateDirectory($root)
$oldLocal=$env:LOCALAPPDATA;$oldProfile=$env:USERPROFILE;$oldCodex=$env:CODEX_HOME
try{
 $env:LOCALAPPDATA=$root;$env:USERPROFILE=$root;$env:CODEX_HOME=Join-Path $root "codex"
 if($EvidenceDirectory){[void][IO.Directory]::CreateDirectory($EvidenceDirectory)}
 foreach($theme in @("dark","light")){
  foreach($language in @('ru','en')){
   $stem=$theme+'-'+$language
   $snapshot=Join-Path $root ($stem+".png")
   $settingsSnapshot=Join-Path $root ("settings-"+$stem+".png")
   & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 2 -PreviewAbout -PreviewAboutUiTest -PreviewSettingsEnd -ThemeOverride $theme -LanguageOverride $language -DiagnosticDirectory (Join-Path $root "diagnostics") -SnapshotFile $snapshot -SettingsSnapshotFile $settingsSnapshot
   if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot -PathType Leaf)){throw "About UI failed for $stem."}
   if(-not (Test-Path -LiteralPath $settingsSnapshot -PathType Leaf)){throw "Settings snapshot failed for $stem."}
   if($EvidenceDirectory){Copy-Item -LiteralPath $snapshot -Destination (Join-Path $EvidenceDirectory ($stem+".png"));Copy-Item -LiteralPath $settingsSnapshot -Destination (Join-Path $EvidenceDirectory ("settings-"+$stem+".png"))}
  }
 }
 Write-Output "About UI: both themes and languages, back navigation, email and small-window scrolling verified."
}finally{
 $env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldProfile;$env:CODEX_HOME=$oldCodex
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test cleanup path."}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
