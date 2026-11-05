$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$app = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app/integrations'))
. (Join-Path $app 'CodexCloudRuntime.ps1')
Add-Type -Path (Join-Path $app 'CodexCloudProcess.cs')
foreach($packagingFile in @('../app/Build-Installer-v2.ps1','../app/CodexProgressInstaller.cs','../msix/Build-StorePackage.ps1')){
 $text=Get-Content -LiteralPath (Join-Path $PSScriptRoot $packagingFile) -Raw
 foreach($name in @('CodexCloudRuntime.ps1','CodexCloudProcess.cs')){if(-not $text.Contains($name)){throw "Cloud component missing from $packagingFile."}}
}

$json = '{"tasks":[{"id":"fixture-one","title":"Synthetic\n task","status":"pending","updated_at":"2026-11-05T09:01:00Z","summary":{"private":"SYNTHETIC_SECRET"},"url":"https://example.invalid/private"},{"id":"fixture-two","status":"ready"},{"id":"fixture-three","status":"error"},{"id":"fixture-four","status":"new-status"}],"cursor":"fixture-cursor"}'
$page = ConvertFrom-CodexCloudPage $json
if (($page.Tasks.State -join ',') -cne 'pending,terminal,terminal,unknown' -or $page.Tasks[0].Title -cne 'Synthetic task' -or $page.Cursor -cne 'fixture-cursor') { throw 'The cloud response was mapped incorrectly.' }
if ($page.Tasks[0].Id -cnotmatch '^codex-cloud:[a-f0-9]{32}$' -or ($page | ConvertTo-Json -Depth 8) -match 'SYNTHETIC_SECRET|example\.invalid') { throw 'The cloud response exposed unneeded fields.' }
foreach($bad in @('bad-json','{"tasks":[{"id":"same"},{"id":"same"}]}','{"tasks":null}')) {
 $failed=$false;try{[void](ConvertFrom-CodexCloudPage $bad)}catch{$failed=$true};if(-not $failed){throw 'Malformed cloud data was accepted.'}
}
$many=@{tasks=@(0..20|ForEach-Object{@{id="fixture-$_";status='pending'}})}|ConvertTo-Json -Depth 4 -Compress
try{[void](ConvertFrom-CodexCloudPage $many);throw 'Too many tasks were accepted.'}catch{if($_.Exception.Message -eq 'Too many tasks were accepted.'){throw}}

$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-cloud-process-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($root)
try {
 $fixture=Join-Path $root 'synthetic codex.exe'
 $program=@'
using System;
using System.IO;
using System.Threading;
public static class SyntheticCodex {
 public static int Main(string[] args) {
  if (args.Length < 5 || args[0] != "cloud" || args[1] != "list" || args[2] != "--json" || args[3] != "--limit" || args[4] != "20") return 2;
  string cursor = args.Length == 7 && args[5] == "--cursor" ? args[6] : "";
  if (cursor == "slow") { Thread.Sleep(5000); return 0; }
  if (cursor == "large") { for (int i=0;i<200;i++) Console.Write(new string('x',8192)); return 0; }
  string modePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "mode.txt");
  string mode = File.Exists(modePath) ? File.ReadAllText(modePath) : "";
  if (mode == "paging") {
   Console.Write(cursor == "" ? "{\"tasks\":[{\"id\":\"fixture-page-one\",\"status\":\"pending\"}],\"cursor\":\"fixture-next\"}" : "{\"tasks\":[{\"id\":\"fixture-page-two\",\"status\":\"ready\"}],\"cursor\":null}");
   return 0;
  }
  if (mode == "cycle") { Console.Write("{\"tasks\":[],\"cursor\":\"repeated\"}"); return 0; }
  if (mode == "partial") {
   int n = cursor == "" ? 1 : Int32.Parse(cursor);
   Console.Write("{\"tasks\":[{\"id\":\"other-" + n + "\",\"status\":\"pending\"}],\"cursor\":\"" + (n + 1) + "\"}");
   return 0;
  }
  if (mode == "terminal") { Console.Write("{\"tasks\":[{\"id\":\"fixture-page-one\",\"status\":\"error\"}],\"cursor\":null}"); return 0; }
  if (cursor != "" && cursor != "cursor with \"quotes\" \\ end") return 3;
  Console.OutputEncoding = new System.Text.UTF8Encoding(false);
  Console.Write("{\"tasks\":[{\"id\":\"fixture-process\",\"status\":\"pending\"}],\"cursor\":null}");
  return 0;
 }
}
'@
 Add-Type -TypeDefinition $program -OutputAssembly $fixture -OutputType ConsoleApplication
 $request=[AITaskMonitor.CodexCloud.Command]::new($fixture,'cursor with "quotes" \ end',5000)
 while(-not $request.Completed){Start-Sleep -Milliseconds 20}
 $result=$request.GetResult();$request.Dispose()
 if(-not $result.Ok -or (ConvertFrom-CodexCloudPage $result.Json).Tasks.Count -ne 1){throw 'The synthetic CLI process or cursor quoting failed.'}
 $request=[AITaskMonitor.CodexCloud.Command]::new($fixture,'large',5000)
 while(-not $request.Completed){Start-Sleep -Milliseconds 20}
 $result=$request.GetResult();$request.Dispose();if($result.Ok){throw 'Oversized output was accepted.'}
 $timer=[Diagnostics.Stopwatch]::StartNew()
 $request=[AITaskMonitor.CodexCloud.Command]::new($fixture,'slow',250)
 while(-not $request.Completed){Start-Sleep -Milliseconds 20}
 $result=$request.GetResult();$request.Dispose();$timer.Stop()
 if($result.Ok -or $timer.Elapsed.TotalSeconds -ge 3){throw 'The synthetic timeout was not enforced.'}
 $request=[AITaskMonitor.CodexCloud.Command]::new($fixture,'slow',5000)
 Start-Sleep -Milliseconds 150;$request.Cancel()
 $deadline=[DateTime]::UtcNow.AddSeconds(3)
 while(-not $request.Completed -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 20}
 if(-not $request.Completed -or $request.GetResult().Ok){throw 'Cancellation did not stop the synthetic request.'}
 $request.Dispose()
 [IO.File]::WriteAllText((Join-Path $root 'mode.txt'),'paging')
 $controller=New-CodexCloudController -Enabled $true -FixtureExecutable $fixture
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do {Update-CodexCloudController $controller;Start-Sleep -Milliseconds 20} while($controller.NextScan -eq [DateTimeOffset]::MinValue -and [DateTime]::UtcNow -lt $deadline)
 if($controller.LastError -or $controller.Partial -or @($controller.Tasks).Count -ne 1 -or $controller.Tasks[0].State -ne 'pending'){throw 'The paginated synthetic task was not retained as unconfirmed.'}
 $visible=@(ConvertTo-CodexCloudMonitorTasks $controller.Tasks 'Cloud: ' 'Synthetic task' 'unconfirmed-fixture')
 if($visible.Count -ne 1 -or $visible[0].Active -or $visible[0].Status -cne 'unconfirmed-fixture' -or $null -ne $visible[0].Progress -or $visible[0].Provider -cne 'codex'){throw 'Cloud tasks must remain unconfirmed and must not count as active.'}
 $parseErrors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $app '../CodexProgress.ps1'),[ref]$null,[ref]$parseErrors)
 if($parseErrors.Count){throw 'The application source failed to parse.'}
 $snapshotDefinition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Source-Snapshot'},$true)
 if($null -eq $snapshotDefinition){throw 'Source snapshot is missing.'}
 . ([scriptblock]::Create($snapshotDefinition.Extent.Text))
 function Tr([string]$value){return $value}
 function Codex-Tasks {return [PSCustomObject]@{Id='local-codex';Provider='codex';Active=$true}}
 function Claude-Tasks {return [PSCustomObject]@{Id='local-claude';Provider='claude';Active=$true}}
 $ClaudeEventFile='fixture';$script:lastCodexTasks=@();$script:lastClaudeTasks=@()
 $script:codexCloudController=$controller;$script:codexCloudModulesAvailable=$true
 $script:externalProviderModulesAvailable=$false;$script:showingSettings=$false
 $snapshot=Source-Snapshot
 if(@($snapshot.Tasks).Count -ne 3 -or @($snapshot.Tasks|Where-Object Active).Count -ne 2 -or @($snapshot.Unavailable).Count){throw 'Cloud and local sources did not coexist truthfully.'}
 $updateDefinition=${function:Update-CodexCloudController}
 function Update-CodexCloudController {throw 'Synthetic unexpected update failure.'}
 $snapshot=Source-Snapshot
 if(@($snapshot.Tasks).Count -ne 3 -or @($snapshot.Tasks|Where-Object Active).Count -ne 2 -or -not $controller.LastError){throw 'An unexpected cloud update failure must preserve prior unconfirmed tasks.'}
 Set-Item -Path Function:Update-CodexCloudController -Value $updateDefinition
 [IO.File]::WriteAllText((Join-Path $root 'mode.txt'),'cycle');$controller.NextScan=[DateTimeOffset]::MinValue
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do {Update-CodexCloudController $controller;Start-Sleep -Milliseconds 20} while($controller.NextScan -eq [DateTimeOffset]::MinValue -and [DateTime]::UtcNow -lt $deadline)
 if(-not $controller.LastError -or @($controller.Tasks).Count -ne 1){throw 'A failed page must preserve previous unconfirmed tasks.'}
 $snapshot=Source-Snapshot
 if(@($snapshot.Tasks).Count -ne 3 -or @($snapshot.Tasks|Where-Object Active).Count -ne 2 -or @($snapshot.Unavailable).Count){throw 'Cloud failure must not hide local sources.'}
 [IO.File]::WriteAllText((Join-Path $root 'mode.txt'),'partial');$controller.NextScan=[DateTimeOffset]::MinValue
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do {Update-CodexCloudController $controller;Start-Sleep -Milliseconds 20} while($controller.NextScan -eq [DateTimeOffset]::MinValue -and [DateTime]::UtcNow -lt $deadline)
 if(-not $controller.Partial -or $controller.LastError -or @($controller.Tasks).Count -ne 6){throw 'Partial cloud pages must retain previously seen tasks.'}
 [IO.File]::WriteAllText((Join-Path $root 'mode.txt'),'terminal');$controller.NextScan=[DateTimeOffset]::MinValue
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do {Update-CodexCloudController $controller;Start-Sleep -Milliseconds 20} while($controller.NextScan -eq [DateTimeOffset]::MinValue -and [DateTime]::UtcNow -lt $deadline)
 if($controller.Partial -or $controller.LastError -or @($controller.Tasks).Count){throw 'A complete terminal snapshot must remove cloud tasks without claiming success.'}
 Set-CodexCloudControllerEnabled $controller $false
 if($controller.Enabled -or @($controller.Tasks).Count -ne 0){throw 'Disconnect did not remove cloud tasks.'}
 $snapshot=Source-Snapshot
 if(@($snapshot.Tasks).Count -ne 2 -or @($snapshot.Tasks|Where-Object Active).Count -ne 2){throw 'Cloud disconnect must preserve local tasks.'}
 Write-Output 'Codex cloud: bounded synthetic output, cursor quoting, timeout, cancellation and privacy passed.'
} finally {
 if(Test-Path -LiteralPath $root){$resolved=(Resolve-Path -LiteralPath $root).Path;if($resolved -ne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'};Remove-Item -LiteralPath $resolved -Recurse -Force}
}
