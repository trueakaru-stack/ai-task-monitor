param([string]$EvidenceDirectory='')
$ErrorActionPreference='Stop'
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
$testRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-claude-loop-ui-'+[guid]::NewGuid().ToString('N'))))
$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $testRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test directory.'}
[void][IO.Directory]::CreateDirectory($testRoot)
$oldLocal=$env:LOCALAPPDATA;$oldProfile=$env:USERPROFILE
try{
 $env:LOCALAPPDATA=$testRoot;$env:USERPROFILE=$testRoot
 foreach($theme in @('dark','light')){
  foreach($mode in @('full','compact')){
   $snapshot=Join-Path $testRoot ($theme+'-'+$mode+'.png')
   $data=Join-Path $testRoot ($theme+'-'+$mode+'-data')
   $pipe='AITM.Test.ClaudeUi.'+[guid]::NewGuid().ToString('N')
   $parameters=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $appRoot 'CodexProgress.ps1'),
    '-PreviewActiveTasks','3','-PreviewProvider','claude','-ThemeOverride',$theme,'-DiagnosticDirectory',$data,
    '-PreviewClaudeLoopPipe',$pipe,'-PreviewClaudeLoopUiTest','-SnapshotFile',$snapshot)
   if($mode -eq 'compact'){$parameters+='-CompactMode'}
   & powershell.exe @parameters
   if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $snapshot)){throw "Claude loop UI failed for $theme $mode."}
   if(-not (Test-Path -LiteralPath (Join-Path $data 'CodexTaskProgress\claude-events-v2.jsonl') -PathType Leaf)){throw 'The real synthetic hook was not exercised.'}
   if($EvidenceDirectory){
    if(-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)){[void][IO.Directory]::CreateDirectory($EvidenceDirectory)}
    Copy-Item -LiteralPath $snapshot -Destination (Join-Path $EvidenceDirectory ($theme+'-'+$mode+'.png'))
   }
  }
 }
 foreach($file in @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.jsonl')){
  $text=[IO.File]::ReadAllText($file.FullName)
  if($text -match 'synthetic-private-command|synthetic-private-project|synthetic-private-output'){throw 'Sensitive synthetic content entered an application-owned journal.'}
 }
 Write-Output 'Claude loop UI: full and compact views, both themes, isolation and dismissal verified.'
}finally{
 $env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldProfile
 if(Test-Path -LiteralPath $testRoot){
  $resolved=(Resolve-Path -LiteralPath $testRoot).Path
  if($resolved -ne $testRoot -or -not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
