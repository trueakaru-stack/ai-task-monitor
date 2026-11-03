param([string]$EvidenceDirectory='')
$ErrorActionPreference='Stop'
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'))
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-update-test-'+[Guid]::NewGuid().ToString('N'))))
$temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $root.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test directory.'}
if($EvidenceDirectory -and (Test-Path -LiteralPath $EvidenceDirectory)){throw 'The evidence directory must not already exist.'}
[void][IO.Directory]::CreateDirectory($root)
$oldLocal=$env:LOCALAPPDATA;$oldProfile=$env:USERPROFILE;$oldCodex=$env:CODEX_HOME
try{
 $env:LOCALAPPDATA=$root;$env:USERPROFILE=$root;$env:CODEX_HOME=Join-Path $root 'codex'
 if($EvidenceDirectory){[void][IO.Directory]::CreateDirectory($EvidenceDirectory)}
 foreach($theme in @('dark','light')){
  $snapshot=Join-Path $root ($theme+'.png')
  & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 2 -PreviewUpdate -PreviewUpdateUiTest -ThemeOverride $theme -SnapshotFile $snapshot
  if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot -PathType Leaf)){throw "Update UI failed for $theme."}
  if($EvidenceDirectory){Copy-Item -LiteralPath $snapshot -Destination (Join-Path $EvidenceDirectory ($theme+'.png'))}
 }
 Write-Output 'Update UI: both themes and session behavior verified.'
}finally{
 $env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldProfile;$env:CODEX_HOME=$oldCodex
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
