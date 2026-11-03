param([string]$EvidenceDirectory="")
$ErrorActionPreference="Stop"
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\app"))
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("aitm-store-channel-"+[Guid]::NewGuid().ToString("N"))))
$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test directory."}
if($EvidenceDirectory -and (Test-Path -LiteralPath $EvidenceDirectory)){throw "Evidence directory already exists."}
[void][IO.Directory]::CreateDirectory($root)
$oldLocal=$env:LOCALAPPDATA;$oldProfile=$env:USERPROFILE;$oldCodex=$env:CODEX_HOME
try{
 $copy=Join-Path $root "app";[void][IO.Directory]::CreateDirectory($copy)
 Get-ChildItem -LiteralPath $appRoot -File | Where-Object {$_.Extension -in @('.ps1','.cs')} | Copy-Item -Destination $copy
 Copy-Item -LiteralPath (Join-Path $appRoot "assets") -Destination $copy -Recurse
 [IO.File]::WriteAllText((Join-Path $copy "store-channel.marker"),"store")
 $env:LOCALAPPDATA=$root;$env:USERPROFILE=$root;$env:CODEX_HOME=Join-Path $root "codex"
 if($EvidenceDirectory){[void][IO.Directory]::CreateDirectory($EvidenceDirectory)}
 foreach($theme in @("dark","light")){
  $snapshot=Join-Path $root ($theme+".png")
  & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $copy "CodexProgress.ps1") -PreviewActiveTasks 2 -PreviewAbout -PreviewAboutUiTest -ThemeOverride $theme -DiagnosticDirectory (Join-Path $root "diagnostics") -SnapshotFile $snapshot
  if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot -PathType Leaf)){throw "Store channel test failed for $theme."}
  if($EvidenceDirectory){Copy-Item -LiteralPath $snapshot -Destination (Join-Path $EvidenceDirectory ($theme+".png"))}
 }
 Write-Output "Store channel: GitHub update request disabled; Store description and About navigation verified."
}finally{
 $env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldProfile;$env:CODEX_HOME=$oldCodex
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test cleanup path."}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
