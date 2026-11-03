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
  $snapshot=Join-Path $root ($theme+".png")
  $settingsSnapshot=Join-Path $root ("settings-"+$theme+".png")
  & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 2 -PreviewAbout -PreviewAboutUiTest -PreviewSettingsEnd -ThemeOverride $theme -DiagnosticDirectory (Join-Path $root "diagnostics") -SnapshotFile $snapshot -SettingsSnapshotFile $settingsSnapshot
  if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot -PathType Leaf)){throw "About UI failed for $theme."}
  if(-not (Test-Path -LiteralPath $settingsSnapshot -PathType Leaf)){throw "Settings snapshot failed for $theme."}
  if($EvidenceDirectory){Copy-Item -LiteralPath $snapshot -Destination (Join-Path $EvidenceDirectory ($theme+".png"));Copy-Item -LiteralPath $settingsSnapshot -Destination (Join-Path $EvidenceDirectory ("settings-"+$theme+".png"))}
 }
 Write-Output "About UI: both themes, back navigation and small-window scrolling verified."
}finally{
 $env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldProfile;$env:CODEX_HOME=$oldCodex
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test cleanup path."}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
