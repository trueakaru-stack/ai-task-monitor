[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$MakeAppxPath,
 [string]$SignToolPath='',
 [switch]$InstallInEphemeralCI
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$identity='imatrue.AITaskMonitor'
$publisher='CN=115CA8A1-932E-47B0-A1AB-4491DF2684C5'
$publisherDisplay='imatrue'
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-msix-test-'+[Guid]::NewGuid().ToString('N'))))
$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $root.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test directory.'}
[void][IO.Directory]::CreateDirectory($root)
$package=Join-Path $root 'AITaskMonitor-Store.msix'
$builder=Join-Path $PSScriptRoot '..\msix\Build-StorePackage.ps1'
& $builder -IdentityName $identity -Publisher $publisher -PublisherDisplayName $publisherDisplay -MakeAppxPath $MakeAppxPath -WorkingDirectory (Join-Path $root 'build') -OutputFile $package
if(-not (Test-Path -LiteralPath $package -PathType Leaf)){throw 'The MSIX package was not created.'}
$unpack=Join-Path $root 'unpacked'
& $MakeAppxPath unpack /p $package /d $unpack | Out-Null
if($LASTEXITCODE -ne 0){throw 'The MSIX package could not be unpacked.'}
[xml]$manifest=[IO.File]::ReadAllText((Join-Path $unpack 'AppxManifest.xml'))
if($manifest.Package.Identity.Name -cne $identity -or $manifest.Package.Identity.Publisher -cne $publisher -or
   $manifest.Package.Identity.Version -cne '1.0.0.0' -or $manifest.Package.Identity.ProcessorArchitecture -cne 'x64' -or
   $manifest.Package.Properties.PublisherDisplayName -cne $publisherDisplay){throw 'The MSIX package identity is incorrect.'}
foreach($name in @('CodexProgress.ps1','ClaudeTaskHook.ps1','ClaudeLoopClient.ps1','ClaudeLoopChannel.cs','Configure-ClaudeIntegration.ps1','Configure-OpenCodeIntegration.ps1','StoreClaudeHook.ps1','ReleaseUpdates.ps1','AI task monitor.exe','AITaskMonitor.Runtime.dll','store-channel.marker','LICENSE','assets\app-icon.ico','assets\StoreLogo.png','assets\Square44x44Logo.png','assets\Square150x150Logo.png')){
 if(-not (Test-Path -LiteralPath (Join-Path $unpack $name) -PathType Leaf)){throw ('Missing MSIX content: '+$name)}
}
$appRoot=Join-Path $PSScriptRoot '..\app'
foreach($name in @('CodexProgress.ps1','ClaudeTaskHook.ps1','ClaudeLoopClient.ps1','Configure-ClaudeIntegration.ps1','Configure-OpenCodeIntegration.ps1','ReleaseUpdates.ps1')){
 if((Get-FileHash -LiteralPath (Join-Path $unpack $name) -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath (Join-Path $appRoot $name) -Algorithm SHA256).Hash){throw ('Packaged source differs: '+$name)}
}
foreach($name in @('ProviderEventView.ps1','ProviderRuntime.ps1','ProviderEventState.cs','ProviderEventChannel.cs','provider-events.mjs','provider-observers.mjs','provider-transport.mjs','opencode-entry.js')){
 $relative=Join-Path 'integrations' $name
 if((Get-FileHash -LiteralPath (Join-Path $unpack $relative) -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath (Join-Path $appRoot $relative) -Algorithm SHA256).Hash){throw ('Packaged integration differs: '+$relative)}
}
Add-Type -AssemblyName System.Drawing
foreach($image in @(@('StoreLogo.png',50),@('Square44x44Logo.png',44),@('Square150x150Logo.png',150))){
 $bitmap=[Drawing.Image]::FromFile((Join-Path $unpack ('assets\'+$image[0])))
 try{if($bitmap.Width -ne [int]$image[1] -or $bitmap.Height -ne [int]$image[1]){throw ('Invalid Store asset size: '+$image[0])}}finally{$bitmap.Dispose()}
}
Write-Output 'MSIX structure: Store identity, runtime files, source hashes and asset sizes verified.'
$previewRoot=Join-Path $root "host's preview";[void][IO.Directory]::CreateDirectory($previewRoot)
$previewSnapshot=Join-Path $previewRoot 'about.png'
$previewDiagnostics=Join-Path $previewRoot 'diagnostics'
$previewReady=Join-Path $previewRoot 'ready.flag'
$previewStart=New-Object Diagnostics.ProcessStartInfo
$previewStart.FileName=Join-Path $unpack 'AI task monitor.exe'
$previewStart.Arguments='-PreviewActiveTasks 1 -PreviewAbout -PreviewAboutUiTest -ThemeOverride dark -SnapshotFile "'+$previewSnapshot+'" -DiagnosticDirectory "'+$previewDiagnostics+'" -PreviewStartupReadyFile "'+$previewReady+'" -PreviewStartupDelayMilliseconds 1'
$previewStart.WorkingDirectory=$unpack;$previewStart.UseShellExecute=$false;$previewStart.CreateNoWindow=$true;$previewStart.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$previewStart.EnvironmentVariables['LOCALAPPDATA']=$previewRoot;$previewStart.EnvironmentVariables['USERPROFILE']=$previewRoot;$previewStart.EnvironmentVariables['CODEX_HOME']=Join-Path $previewRoot 'codex'
$preview=[Diagnostics.Process]::Start($previewStart)
if(-not $preview.WaitForExit(45000)){throw 'The isolated Store host did not exit; it was not terminated.'}
if($preview.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $previewSnapshot -PathType Leaf)){throw ('The isolated Store host failed: '+$preview.ExitCode)}
$previewStatePath=$previewReady+'.result.json'
if(-not (Test-Path -LiteralPath $previewStatePath -PathType Leaf)){throw 'The isolated Store host did not write its startup probe.'}
$previewState=Get-Content -Raw -Encoding UTF8 -LiteralPath $previewStatePath|ConvertFrom-Json
$previewJournal=Join-Path $previewDiagnostics 'diagnostic-events-v1.jsonl'
if(-not $previewState.diagnosticModulesAvailable -or -not $previewState.diagnosticRuntimeAvailable -or -not $previewState.claudeReaderAvailable -or $previewState.diagnosticStatus -or -not (Test-Path -LiteralPath $previewJournal -PathType Leaf) -or [IO.File]::ReadAllText($previewJournal) -notmatch '"type":"task_observed"'){throw ('The isolated Store host did not initialize monitoring: '+$previewState.diagnosticFailure+' '+$previewState.diagnosticStatus+' '+$previewState.claudeReaderFailure)}
Write-Output 'MSIX host: in-process PowerShell initialized monitoring, rendered a synthetic view and exited normally.'
if(-not $InstallInEphemeralCI){Write-Output ('Unsigned package for structural review: '+$package);return}
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted'){throw 'MSIX installation test is restricted to a disposable GitHub-hosted runner.'}
if(-not $SignToolPath -or -not (Test-Path -LiteralPath $SignToolPath -PathType Leaf)){throw 'SignTool is required for the isolated install test.'}
$signtoolSignature=Get-AuthenticodeSignature -LiteralPath $SignToolPath
if($signtoolSignature.Status -ne 'Valid' -or $signtoolSignature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'){throw 'SignTool does not have a valid Microsoft signature.'}
if(@(Get-AppxPackage -Name $identity -ErrorAction SilentlyContinue).Count -ne 0){throw 'The test package identity is already installed; refusing to alter it.'}
$claudeHome=Join-Path $env:USERPROFILE '.claude'
$storeData=Join-Path $env:USERPROFILE '.ai-task-monitor'
$codexHome=Join-Path $env:USERPROFILE '.codex'
if((Test-Path -LiteralPath $claudeHome) -or (Test-Path -LiteralPath $storeData) -or (Test-Path -LiteralPath $codexHome)){throw 'The isolated runner already has provider or Store application data; refusing to alter it.'}

$certificate=New-SelfSignedCertificate -Type Custom -Subject $publisher -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter ([DateTime]::Now.AddHours(3)) -CertStoreLocation 'Cert:\CurrentUser\My' -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3','2.5.29.19={text}')
$publicCertificate=Join-Path $root 'test-only.cer'
Export-Certificate -Cert $certificate -FilePath $publicCertificate | Out-Null
Import-Certificate -FilePath $publicCertificate -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
$testPackage=Join-Path $root 'test-only-signed.msix'
Copy-Item -LiteralPath $package -Destination $testPackage
& $SignToolPath sign /fd SHA256 /sha1 $certificate.Thumbprint $testPackage
if($LASTEXITCODE -ne 0){throw 'Test-only signing failed.'}
Add-AppxPackage -Path $testPackage -ErrorAction Stop
$installed=@(Get-AppxPackage -Name $identity -ErrorAction Stop)
if($installed.Count -ne 1 -or $installed[0].Publisher -cne $publisher -or $installed[0].Version.ToString() -cne '1.0.0.0'){throw 'MSIX installation identity verification failed.'}

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
class ApplicationActivationManager { }
[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IApplicationActivationManager {
    [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out uint processId);
}
public static class MsixTestActivation {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern int GetPackageFullName(IntPtr process, ref uint length, StringBuilder name);
    public static int Activate(string id, string args, out uint pid) {
        return ((IApplicationActivationManager)new ApplicationActivationManager()).ActivateApplication(id, args, 0, out pid);
    }
    public static string PackageOf(int pid) {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) return "";
        try {
            uint length = 0; int result = GetPackageFullName(process, ref length, null);
            if (result != 122 || length == 0) return "";
            var name = new StringBuilder((int)length);
            return GetPackageFullName(process, ref length, name) == 0 ? name.ToString() : "";
        } finally { CloseHandle(process); }
    }
}
'@
$snapshotRoot=Join-Path $env:USERPROFILE ('aitm-msix-smoke-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $snapshotRoot){throw 'Unexpected existing MSIX test directory.'}
[void][IO.Directory]::CreateDirectory($snapshotRoot)
$evidence=Join-Path $env:RUNNER_TEMP 'aitm-msix-evidence'
if(Test-Path -LiteralPath $evidence){throw 'Unexpected existing MSIX evidence directory.'}
[void][IO.Directory]::CreateDirectory($evidence)
$snapshot=Join-Path $snapshotRoot 'about-dark.png'
$arguments='-PreviewActiveTasks 1 -PreviewAbout -PreviewAboutUiTest -ThemeOverride dark -SnapshotFile "'+$snapshot+'"'
$aumid=$installed[0].PackageFamilyName+'!App'
[uint32]$processId=0
$hr=[MsixTestActivation]::Activate($aumid,$arguments,[ref]$processId)
if($hr -ne 0 -or $processId -eq 0){throw ('Packaged app activation failed: 0x{0:X8}' -f $hr)}
$appProcess=[Diagnostics.Process]::GetProcessById([int]$processId)
[void]$appProcess.Handle
$watch=[Diagnostics.Stopwatch]::StartNew()
$packageName=[MsixTestActivation]::PackageOf([int]$processId)
if(-not $packageName.StartsWith($identity+'_',[StringComparison]::OrdinalIgnoreCase)){throw 'The monitor process did not retain MSIX package identity.'}
while(-not (Test-Path -LiteralPath $snapshot -PathType Leaf) -and $watch.Elapsed.TotalSeconds -lt 45){Start-Sleep -Milliseconds 200}
if(-not (Test-Path -LiteralPath $snapshot -PathType Leaf)){throw 'The installed MSIX did not render its synthetic About view.'}
Copy-Item -LiteralPath $snapshot -Destination (Join-Path $evidence 'about-dark.png')
if(-not $appProcess.WaitForExit(30000)){throw 'The packaged preview did not exit.'}
if($null -ne $appProcess.ExitCode -and $appProcess.ExitCode -ne 0){throw ('The packaged preview exited with code '+$appProcess.ExitCode)}
Write-Output 'MSIX install: test-signed package installed, packaged process identity and synthetic app rendering verified on the disposable runner.'

function Invoke-HiddenPowerShell([string]$Arguments,[string]$InputText='', [switch]$Audit){
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $start.Arguments=$Arguments;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 if($Audit){$start.EnvironmentVariables['AI_TASK_MONITOR_AUDIT']='1'}
 # Windows PowerShell 5.1 uses Console.InputEncoding for the redirected writer.
 # Its UTF-8 encoding may otherwise prepend a BOM before the JSON payload.
 $previousInputEncoding=[Console]::InputEncoding
 try{[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);$process=[Diagnostics.Process]::Start($start)}
 finally{[Console]::InputEncoding=$previousInputEncoding}
 try{
  if($process.StandardInput.Encoding.GetPreamble().Length -ne 0){throw 'The isolated hook input writer would prepend a byte-order mark.'}
  if($InputText){
   $bytes=[Text.UTF8Encoding]::new($false).GetBytes($InputText)
   $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
  }
  $process.StandardInput.Close()
  if(-not $process.WaitForExit(30000)){throw 'The isolated hook process did not exit.'}
  $stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd()
  if($process.ExitCode -ne 0){throw ('The isolated hook process failed: '+$process.ExitCode+' '+$stderr+' '+$stdout)}
  if($Audit -and ($stdout -or $stderr)){Write-Output ('Isolated hook diagnostic: '+$stderr+' '+$stdout)}
 }finally{$process.Dispose()}
}

[void][IO.Directory]::CreateDirectory($claudeHome)
$claudeSettings=Join-Path $claudeHome 'settings.json'
[IO.File]::WriteAllText($claudeSettings,'{"unrelated":"keep","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo foreign"}]}]}}',[Text.UTF8Encoding]::new($false))
$configure=Join-Path $installed[0].InstallLocation 'Configure-ClaudeIntegration.ps1'
Invoke-HiddenPowerShell ('-NoProfile -ExecutionPolicy Bypass -File "'+$configure+'" -Mode Install')
$settings=Get-Content -Raw -Encoding UTF8 -LiteralPath $claudeSettings|ConvertFrom-Json
if($settings.unrelated -cne 'keep' -or $settings.hooks.PreToolUse[0].hooks[0].command -cne 'echo foreign'){throw 'Claude integration changed another setting or hook.'}
$command=[string]$settings.hooks.UserPromptSubmit[0].hooks[0].command
$head='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '
if(-not $command.StartsWith($head,[StringComparison]::Ordinal)){throw 'The installed Claude hook has an unexpected command.'}
$encoded=$command.Substring($head.Length)
$decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
if($decoded.Contains($installed[0].InstallLocation)){throw 'The Claude hook contains a version-specific package path.'}

$now=Get-Date
$sessions=Join-Path (Join-Path (Join-Path (Join-Path $codexHome 'sessions') $now.ToString('yyyy')) $now.ToString('MM')) $now.ToString('dd')
$locks=Join-Path $codexHome 'thread-writer-locks'
[void][IO.Directory]::CreateDirectory($sessions);[void][IO.Directory]::CreateDirectory($locks)
$codexId='msix-codex-session'
$codexSession=Join-Path $sessions ('rollout-'+$codexId+'.jsonl')
$codexIndex=@{id=$codexId;thread_name='Synthetic Codex task';updated_at=$now.ToString('o')}|ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $codexHome 'session_index.jsonl'),($codexIndex+"`n"),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($codexSession,('{"type":"event_msg","payload":{"type":"task_started"}}'+"`n"),[Text.UTF8Encoding]::new($false))
$lockOwner=[IO.File]::Open((Join-Path $locks ($codexId+'.lock')),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)

$activeSnapshot=Join-Path $snapshotRoot 'claude-active.png'
$diagnostics=Join-Path $root 'active-diagnostics'
$ready=Join-Path $root 'active-ready.flag'
$arguments='-ThemeOverride dark -SnapshotFile "'+$activeSnapshot+'" -DiagnosticDirectory "'+$diagnostics+'" -PreviewStartupReadyFile "'+$ready+'" -PreviewStartupDelayMilliseconds 5000'
[uint32]$activeId=0
$hr=[MsixTestActivation]::Activate($aumid,$arguments,[ref]$activeId)
if($hr -ne 0 -or $activeId -eq 0){throw ('Packaged monitor activation failed: 0x{0:X8}' -f $hr)}
$activeProcess=[Diagnostics.Process]::GetProcessById([int]$activeId)
[void]$activeProcess.Handle
$watch=[Diagnostics.Stopwatch]::StartNew()
while(-not (Test-Path -LiteralPath $ready -PathType Leaf) -and $watch.Elapsed.TotalSeconds -lt 45 -and -not $activeProcess.HasExited){Start-Sleep -Milliseconds 100}
if(-not (Test-Path -LiteralPath $ready -PathType Leaf)){throw 'The packaged monitor did not reach the hook test.'}
$codexEvent=@{timestamp=[DateTime]::UtcNow.ToString('o');type='event_msg';payload=@{type='agent_reasoning';text='Synthetic activity'}}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($codexSession,($codexEvent+"`n"),[Text.UTF8Encoding]::new($false))
$hookArguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
Invoke-HiddenPowerShell $hookArguments '{"hook_event_name":"UserPromptSubmit","session_id":"msix-session-1","prompt":"private test","cwd":"C:\\private"}'
if(-not $activeProcess.WaitForExit(45000)){throw 'The packaged monitor hook preview did not exit.'}
if(($null -ne $activeProcess.ExitCode -and $activeProcess.ExitCode -ne 0) -or -not (Test-Path -LiteralPath $activeSnapshot -PathType Leaf)){throw 'The packaged monitor hook preview failed.'}
Copy-Item -LiteralPath $activeSnapshot -Destination (Join-Path $evidence 'monitor-dark.png')
$previewResult=$ready+'.result.json'
if(Test-Path -LiteralPath $previewResult -PathType Leaf){
 Copy-Item -LiteralPath $previewResult -Destination (Join-Path $evidence 'preview-result.json')
 Write-Output ('Packaged monitor probe: '+[IO.File]::ReadAllText($previewResult))
}else{Write-Output 'Packaged monitor probe: result file unavailable.'}
$lockOwner.Dispose()
$eventFile=Join-Path $storeData 'claude-events-v2.jsonl'
if(-not (Test-Path -LiteralPath $eventFile -PathType Leaf)){
 $probePackages=@(Get-AppxPackage -Name $identity -ErrorAction Stop|Where-Object{$_.Publisher -ceq $publisher})
 Write-Output ('Installed hook diagnostic: matching packages='+$probePackages.Count+'; hook readable='+(Test-Path -LiteralPath (Join-Path $installed[0].InstallLocation 'ClaudeTaskHook.ps1') -PathType Leaf))
 $inputProbe='[Console]::Out.Write(([Console]::In.ReadToEnd().ToCharArray() | ForEach-Object { [int]$_ }) -join ",")'
 $inputProbeEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inputProbe))
 Invoke-HiddenPowerShell ('-NoProfile -EncodedCommand '+$inputProbeEncoded) '{"a":1}' -Audit
 $probeHook=Join-Path $installed[0].InstallLocation 'ClaudeTaskHook.ps1'
 $probeScript="& '"+$probeHook.Replace("'","''")+"'"
 $probeEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeScript))
 Invoke-HiddenPowerShell ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$probeEncoded) '{"hook_event_name":"UserPromptSubmit","session_id":"msix-diagnostic"}' -Audit
 Write-Output ('Direct hook diagnostic: event file present='+(Test-Path -LiteralPath $eventFile -PathType Leaf))
 throw 'The installed Claude hook did not write a shared event.'
}
$rawEvents=Get-Content -Raw -Encoding UTF8 -LiteralPath $eventFile
if($rawEvents -notmatch 'msix-session-1' -or $rawEvents -match 'private test|C:\\\\private'){throw 'The installed Claude hook lost an event or stored private input.'}
$journal=Join-Path $diagnostics 'diagnostic-events-v1.jsonl'
if(-not (Test-Path -LiteralPath $journal -PathType Leaf)){throw 'The packaged monitor did not record its observed Claude task.'}
$observed=@(Get-Content -Encoding UTF8 -LiteralPath $journal|Select-Object -Skip 1|ForEach-Object{$_|ConvertFrom-Json}|Where-Object{$_.source -ceq 'claude' -and $_.type -ceq 'task_observed'})
if($observed.Count -ne 1){throw 'The packaged monitor did not observe the event written by the installed hook.'}
$observedCodex=@(Get-Content -Encoding UTF8 -LiteralPath $journal|Select-Object -Skip 1|ForEach-Object{$_|ConvertFrom-Json}|Where-Object{$_.source -ceq 'codex' -and $_.type -ceq 'task_observed'})
if($observedCodex.Count -ne 1){throw 'The packaged monitor did not observe the Codex session fixture.'}
Write-Output 'MSIX monitoring: Codex session and external Claude hook events were observed by the packaged monitor.'

$upgrade=Join-Path $root 'upgrade-test-only.msix'
& $builder -IdentityName $identity -Publisher $publisher -PublisherDisplayName $publisherDisplay -MakeAppxPath $MakeAppxPath -WorkingDirectory (Join-Path $root 'upgrade-build') -OutputFile $upgrade -PackageVersion '1.0.1.0'
& $SignToolPath sign /fd SHA256 /sha1 $certificate.Thumbprint $upgrade
if($LASTEXITCODE -ne 0){throw 'Test-only upgrade signing failed.'}
Add-AppxPackage -Path $upgrade -ErrorAction Stop
$upgraded=@(Get-AppxPackage -Name $identity -ErrorAction Stop)
if($upgraded.Count -ne 1 -or $upgraded[0].Publisher -cne $publisher -or $upgraded[0].Version.ToString() -cne '1.0.1.0' -or $upgraded[0].InstallLocation -ceq $installed[0].InstallLocation){throw 'MSIX upgrade identity or location verification failed.'}
Invoke-HiddenPowerShell $hookArguments '{"hook_event_name":"UserPromptSubmit","session_id":"msix-session-2","prompt":"private test"}'
$afterUpgrade=Get-Content -Raw -Encoding UTF8 -LiteralPath $eventFile
if($afterUpgrade -notmatch 'msix-session-1' -or $afterUpgrade -notmatch 'msix-session-2' -or $afterUpgrade -match 'private test'){throw 'The existing hook did not survive the package upgrade.'}
Remove-AppxPackage -Package $upgraded[0].PackageFullName -ErrorAction Stop
if(@(Get-AppxPackage -Name $identity -ErrorAction SilentlyContinue).Count -ne 0 -or -not (Test-Path -LiteralPath $eventFile -PathType Leaf)){throw 'MSIX removal did not preserve the shared application data.'}
Invoke-HiddenPowerShell $hookArguments '{"hook_event_name":"UserPromptSubmit","session_id":"msix-after-removal"}'
if((Get-Content -Raw -Encoding UTF8 -LiteralPath $eventFile) -match 'msix-after-removal'){throw 'The removed package hook did not safely stop.'}
Write-Output 'MSIX lifecycle: Claude hook survived an upgrade; shared data remained after removal and the absent-package hook exited safely.'
