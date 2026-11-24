$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
. (Join-Path $app 'DiagnosticPolicy.ps1');. (Join-Path $app 'DiagnosticStore.ps1')
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-policy-race-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic diagnostic directory.'
[void][IO.Directory]::CreateDirectory($root)
$startName='Local\AITMPolicyStart-'+[Guid]::NewGuid().ToString('N');$releaseName='Local\AITMPolicyRelease-'+[Guid]::NewGuid().ToString('N')
$started=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startName)
$release=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$releaseName)
$child=$null
try{
 $now=[DateTimeOffset]::UtcNow;Save-DiagnosticSettings -Directory $root -RetentionDays 7 -MaximumMB 10
 [void](Get-DiagnosticInstallationKey -Directory $root)
 $old=[PSCustomObject]@{version=1;time=$now.AddDays(-2).ToString('o');source='codex';task=('a'*64);type='tool_started';id=('b'*64)}
 Write-DiagnosticEvent -Directory $root -Event $old -Now $now -RetentionDays 7
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $fixture=Join-Path $PSScriptRoot 'fixtures\DiagnosticPolicyGate.ps1'
 $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$fixture+'" -Directory "'+$root+'" -StartedName "'+$startName+'" -ReleaseName "'+$releaseName+'" -AppRoot "'+$app+'"'
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $child=[Diagnostics.Process]::Start($start)
 Require ($started.WaitOne(15000)) 'The synthetic diagnostic runtime did not pause with its old policy.'
 Save-DiagnosticSettings -Directory $root -RetentionDays 7 -MaximumMB 10
 [void]$release.Set()
 Require ($child.WaitForExit(15000) -and $child.ExitCode -eq 0) 'The synthetic diagnostic runtime failed after the policy update.'
 $events=@(Read-DiagnosticEvents -Directory $root -Now ([DateTimeOffset]::UtcNow) -UseStoredPolicy)
 Require (@($events|Where-Object {$_.id -ceq ('b'*64)}).Count -eq 1 -and $events.Count -ge 2) 'A stale one-day policy removed a two-day event after seven-day retention was saved.'
 Save-DiagnosticSettings -Directory $root -RetentionDays 1 -MaximumMB 10
 Remove-ExpiredDiagnosticEvents -Directory $root -Now ([DateTimeOffset]::UtcNow) -RetentionDays 7 -UseStoredPolicy
 Require (@(Read-DiagnosticEvents -Directory $root -Now ([DateTimeOffset]::UtcNow) -RetentionDays 7).Count -eq 1) 'The current shorter stored retention was not applied atomically.'
 Write-Output 'Diagnostic policy race: a blocked old-policy runtime preserved newer retention, and current shortening was applied.'
}finally{
 [void]$release.Set()
 if($null -ne $child){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)};$child.Dispose()}
 $started.Dispose();$release.Dispose()
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic policy cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
