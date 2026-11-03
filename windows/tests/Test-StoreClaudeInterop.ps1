$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-store-claude-'+[Guid]::NewGuid().ToString('N'))))
$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test directory.'}
[void][IO.Directory]::CreateDirectory($root)
$oldProfile=$env:USERPROFILE;$oldLocal=$env:LOCALAPPDATA;$oldInstall=$env:AITM_TEST_INSTALL_PATH;$oldPublisher=$env:AITM_TEST_PUBLISHER;$oldMissing=$env:AITM_TEST_MISSING
try{
 $app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
 $store=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\msix'))
 $layouts=@((Join-Path $root "package version 'one'"),(Join-Path $root 'package-version-two'))
 foreach($layout in $layouts){
  [void][IO.Directory]::CreateDirectory($layout)
  foreach($name in @('Configure-ClaudeIntegration.ps1','ClaudeTaskHook.ps1','ClaudeLoopClient.ps1','CodexProgress.ps1')){Copy-Item -LiteralPath (Join-Path $app $name) -Destination (Join-Path $layout $name)}
  Copy-Item -LiteralPath (Join-Path $store 'StoreClaudeHook.ps1') -Destination (Join-Path $layout 'StoreClaudeHook.ps1')
  [IO.File]::WriteAllText((Join-Path $layout 'store-channel.marker'),'store')
  [IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'),'<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="imatrue.AITaskMonitor" Publisher="CN=115CA8A1-932E-47B0-A1AB-4491DF2684C5" Version="1.0.0.0" ProcessorArchitecture="x64"/></Package>')
 }
 $env:USERPROFILE=Join-Path $root 'profile';$env:LOCALAPPDATA=Join-Path $root 'local';$env:AITM_TEST_PUBLISHER='CN=115CA8A1-932E-47B0-A1AB-4491DF2684C5';$env:AITM_TEST_MISSING='0'
 $claude=Join-Path $env:USERPROFILE '.claude';[void][IO.Directory]::CreateDirectory($claude)
 $settings=Join-Path $claude 'settings.json'
 [IO.File]::WriteAllText($settings,'{"unrelated":"keep","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo foreign"}]}]}}',[Text.UTF8Encoding]::new($false))
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $layouts[0] 'Configure-ClaudeIntegration.ps1') -Mode Install
 if($LASTEXITCODE -ne 0){throw 'Store hook installation failed.'}
 $parsed=Get-Content -Raw -Encoding UTF8 -LiteralPath $settings|ConvertFrom-Json
 $command=[string]$parsed.hooks.UserPromptSubmit[0].hooks[0].command
 $head='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '
 if(-not $command.StartsWith($head)){throw 'Unexpected Store hook command.'}
 . (Join-Path $layouts[0] 'StoreClaudeHook.ps1')
 if($command -cne (Get-StoreClaudeHookCommand $layouts[0]) -or $command -cne (Get-StoreClaudeHookCommand $layouts[1])){throw 'Store hook must stay identical across package paths.'}
 $decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($command.Substring($head.Length)))
 if($decoded.Contains($layouts[0]) -or $decoded.Contains($layouts[1])){throw 'Store hook contains a versioned package path.'}
 $mock=@'
function Get-AppxPackage {
 [CmdletBinding()]param([string]$Name)
 if($env:AITM_TEST_MISSING -ne '1') { [PSCustomObject]@{Name=$Name;Publisher=$env:AITM_TEST_PUBLISHER;InstallLocation=$env:AITM_TEST_INSTALL_PATH} }
}
'@
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($mock+"`n"+$decoded))
 $eventFile=Join-Path $env:USERPROFILE '.ai-task-monitor\claude-events-v2.jsonl'
 for($i=0;$i -lt $layouts.Count;$i++){
  $env:AITM_TEST_INSTALL_PATH=$layouts[$i]
  ('{"hook_event_name":"UserPromptSubmit","session_id":"synthetic-'+$i+'","prompt":"do not store me","cwd":"C:\\private"}') | & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
  if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $eventFile -PathType Leaf)){throw 'Store hook did not write its synthetic event.'}
 }
 $events=@(Get-Content -LiteralPath $eventFile -Encoding UTF8)
 if($events.Count -ne 2 -or ($events -join '') -match 'do not store me|C:\\\\private'){throw 'Store hook lost events or persisted private input.'}
 if(Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexTaskProgress\claude-events-v2.jsonl')){throw 'Store hook wrote to the standalone edition directory.'}
 $env:AITM_TEST_PUBLISHER='CN=Other Publisher'
 '{"hook_event_name":"UserPromptSubmit","session_id":"untrusted"}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
 if($LASTEXITCODE -ne 0 -or @(Get-Content -LiteralPath $eventFile).Count -ne 2){throw 'Store hook used an unexpected publisher.'}
 $env:AITM_TEST_PUBLISHER='CN=115CA8A1-932E-47B0-A1AB-4491DF2684C5';$env:AITM_TEST_MISSING='1'
 '{"hook_event_name":"UserPromptSubmit","session_id":"absent"}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
 if($LASTEXITCODE -ne 0 -or @(Get-Content -LiteralPath $eventFile).Count -ne 2){throw 'A removed Store package must fail silently.'}
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $layouts[1] 'Configure-ClaudeIntegration.ps1') -Mode Install
 if($LASTEXITCODE -ne 0){throw 'Store hook reconnection failed.'}
 $parsed=Get-Content -Raw -Encoding UTF8 -LiteralPath $settings|ConvertFrom-Json
 if(@($parsed.hooks.UserPromptSubmit).Count -ne 1 -or $parsed.unrelated -ne 'keep'){throw 'Store hook duplicated or altered unrelated settings.'}
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $layouts[1] 'Configure-ClaudeIntegration.ps1') -Mode Remove
 if($LASTEXITCODE -ne 0){throw 'Store hook removal failed.'}
 $parsed=Get-Content -Raw -Encoding UTF8 -LiteralPath $settings|ConvertFrom-Json
 if($null -ne $parsed.hooks.PSObject.Properties['UserPromptSubmit'] -or $parsed.unrelated -ne 'keep' -or $parsed.hooks.PreToolUse[0].hooks[0].command -ne 'echo foreign'){throw 'Store hook removal changed unrelated settings.'}
 Write-Output 'Store Claude hook: stable package identity, updates, publisher validation, privacy and safe removal verified.'
}finally{
 $env:USERPROFILE=$oldProfile;$env:LOCALAPPDATA=$oldLocal;$env:AITM_TEST_INSTALL_PATH=$oldInstall;$env:AITM_TEST_PUBLISHER=$oldPublisher;$env:AITM_TEST_MISSING=$oldMissing
 if(Test-Path -LiteralPath $root){$resolved=(Resolve-Path -LiteralPath $root).Path;if($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'};Remove-Item -LiteralPath $resolved -Recurse -Force}
}
