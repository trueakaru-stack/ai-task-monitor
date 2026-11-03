$ErrorActionPreference="Stop"
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai-monitor-uninstall-"+[Guid]::NewGuid().ToString("N"))))
$temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if(-not $root.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test directory."}
[void][IO.Directory]::CreateDirectory($root)
$previousLocal=$env:LOCALAPPDATA;$previousRoaming=$env:APPDATA
try{
 $env:LOCALAPPDATA=$root;$env:APPDATA=Join-Path $root "roaming"
 $install=Join-Path $root "AITaskMonitor";$data=Join-Path $root "CodexTaskProgress"
 $diagnostics=Join-Path $data "diagnostics";$programs=Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
 foreach($directory in @($install,$diagnostics,$programs)){[void][IO.Directory]::CreateDirectory($directory)}
 $uninstaller=Join-Path $install "Uninstall-CodexProgress.ps1"
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\app\Uninstall-CodexProgress.ps1") -Destination $uninstaller
 $files=@((Join-Path $data "settings.json"),(Join-Path $data "claude-events.jsonl"),(Join-Path $data "claude-events-v2.jsonl"),(Join-Path $diagnostics "diagnostic-events-v1.jsonl"))
 foreach($path in $files){[IO.File]::WriteAllText($path,"synthetic preserved data")}
 $shortcut=Join-Path $programs "AI task monitor.lnk";[IO.File]::WriteAllText($shortcut,"synthetic shortcut")
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller
 if($LASTEXITCODE -ne 0){throw "The isolated uninstaller failed."}
 foreach($path in $files){if(-not (Test-Path -LiteralPath $path) -or [IO.File]::ReadAllText($path) -ne "synthetic preserved data"){throw "Uninstall changed or removed application data."}}
 if(Test-Path -LiteralPath $shortcut){throw "Uninstall did not remove the application shortcut."}
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while((Test-Path -LiteralPath $install) -and $watch.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 100}
 if(Test-Path -LiteralPath $install){throw "The isolated installation directory was not removed."}
 Write-Output "Uninstall: settings, legacy and current event files, and diagnostic journal preserved."
}finally{
 $env:LOCALAPPDATA=$previousLocal;$env:APPDATA=$previousRoaming
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test cleanup path."}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
