param([string]$EvidenceDirectory="")
$ErrorActionPreference="Stop"
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\app"))
. (Join-Path $appRoot "DiagnosticPolicy.ps1")
. (Join-Path $appRoot "DiagnosticStore.ps1")
$fixture=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-journal-recovery-"+[Guid]::NewGuid().ToString("N"))))
$temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $fixture.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe fixture path."}
[void][IO.Directory]::CreateDirectory($fixture)
try{
 foreach($theme in @("dark","light")){
  $data=Join-Path $fixture ($theme+"-data")
  if($theme -eq "dark"){[void](Get-DiagnosticInstallationKey -Directory $data)}
  else{Ensure-DiagnosticDirectory $data}
  $journal=Join-Path $data "diagnostic-events-v1.jsonl"
  [IO.File]::WriteAllText($journal,($script:DiagnosticHeader+"`n"+'{"partial":'),[Text.UTF8Encoding]::new($false))
  $snapshot=Join-Path $fixture ($theme+".png")
  $recovery=Join-Path $fixture ($theme+"-recovery.png")
  & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $appRoot "CodexProgress.ps1") -PreviewActiveTasks 0 -SnapshotFile $snapshot -DiagnosticDirectory $data -ThemeOverride $theme -PreviewJournalRecoveryUiTest -JournalRecoverySnapshotFile $recovery
  if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $recovery)){throw "Journal recovery UI failed in $theme mode."}
  if(@(Read-DiagnosticEvents -Directory $data -Now ([DateTimeOffset]::UtcNow) -RetentionDays 7 -MaximumBytes 10000000).Count -ne 0){throw "The confirmed journal clear did not succeed."}
  if($EvidenceDirectory){
   if(-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)){[void][IO.Directory]::CreateDirectory($EvidenceDirectory)}
   Copy-Item -LiteralPath $recovery -Destination (Join-Path $EvidenceDirectory ($theme+".png"))
  }
 }
 Write-Output "Journal recovery UI: damaged journal retained until confirmation, then restored in both themes."
}finally{
 if(Test-Path -LiteralPath $fixture){
  $resolved=(Resolve-Path -LiteralPath $fixture).Path
  if($resolved -ne $fixture -or -not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe fixture cleanup path."}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
