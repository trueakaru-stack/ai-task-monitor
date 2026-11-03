$ErrorActionPreference="Stop"
$app=Join-Path $PSScriptRoot "..\app\CodexProgress.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-loop-ui-"+[Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fixture|Out-Null
foreach($mode in @("full","compact")){
 $arguments=@("-NoProfile","-STA","-ExecutionPolicy","Bypass","-File",$app,"-PreviewActiveTasks","1","-PreviewLoopWarning","-PreviewLoopUiTest","-SnapshotFile",(Join-Path $fixture ($mode+".png")),"-DiagnosticDirectory",(Join-Path $fixture ($mode+"-data")))
 if($mode -eq "compact"){$arguments+="-CompactMode";$arguments+=@("-ThemeOverride","light")}else{$arguments+=@("-ThemeOverride","dark")}
 & powershell.exe @arguments
 if($LASTEXITCODE -ne 0){throw "Loop UI $mode fixture failed."}
}
Write-Output "Loop UI: expanded and compact dismissal and settings controls verified."
