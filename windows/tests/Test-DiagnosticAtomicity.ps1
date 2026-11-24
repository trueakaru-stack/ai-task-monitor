param([switch]$Writer,[string]$FixtureRoot='',[string]$GateName='')
$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
. (Join-Path $app 'DiagnosticPolicy.ps1')
. (Join-Path $app 'DiagnosticStore.ps1')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Synthetic-Event([string]$id,[DateTimeOffset]$now){return [PSCustomObject]@{version=1;time=$now.ToString('o');source='codex';task=('a'*64);type='tool_started';id=($id*64)}}
if($Writer){
 $root=[IO.Path]::GetFullPath($FixtureRoot)
 Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($root).StartsWith('aitm-diagnostic-atomic-', [StringComparison]::Ordinal) -and
  [IO.File]::Exists((Join-Path $root '.synthetic-fixture')) -and $GateName -match '^Local\\AITMDiagnosticAtomic-[a-f0-9]{32}$') 'The atomicity writer requires a synthetic fixture.'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'DiagnosticStore.ps1'),[ref]$tokens,[ref]$errors)
 $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Write-DiagnosticFile'},$true)
 Require ($errors.Count -eq 0 -and $null -ne $node) 'The diagnostic writer could not be inspected.'
 $needle='  if(Test-Path -LiteralPath $path){[IO.File]::Replace'
 Require ($node.Extent.Text.IndexOf($needle,[StringComparison]::Ordinal) -ge 0) 'The atomic commit point was not found.'
 # Only the disposable test process pauses at the real commit point. The
 # production file has no injected wait or process-control hook.
 $pause='  $signal=[Threading.EventWaitHandle]::OpenExisting($script:fixtureGate);[void]$signal.Set();[Threading.Thread]::Sleep([Threading.Timeout]::Infinite)'+"`n"
 . ([scriptblock]::Create($node.Extent.Text.Replace($needle,$pause+$needle)))
 $script:fixtureGate=$GateName
 Write-DiagnosticEvent -Directory $root -Event (Synthetic-Event 'b' ([DateTimeOffset]::UtcNow)) -Now ([DateTimeOffset]::UtcNow)
 throw 'The synthetic atomic writer unexpectedly passed its gate.'
}
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-diagnostic-atomic-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic fixture.'
[void][IO.Directory]::CreateDirectory($root);[IO.File]::WriteAllText((Join-Path $root '.synthetic-fixture'),'synthetic')
$gateName='Local\AITMDiagnosticAtomic-'+[Guid]::NewGuid().ToString('N')
$gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$gateName)
$child=$null
try{
 $now=[DateTimeOffset]::UtcNow
 Write-DiagnosticEvent -Directory $root -Event (Synthetic-Event 'a' $now) -Now $now
 $path=Join-Path $root 'diagnostic-events-v1.jsonl';$before=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
 $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Writer -FixtureRoot "'+$root+'" -GateName "'+$gateName+'"'
 $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $child=[Diagnostics.Process]::Start($info)
 Require ($gate.WaitOne(10000)) 'The synthetic diagnostic writer did not reach the commit point.'
 $child.Kill();Require ($child.WaitForExit(10000)) 'The synthetic diagnostic writer did not terminate.'
 Require ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $before) 'An interrupted diagnostic write changed the existing journal.'
 $existing=@(Read-DiagnosticEvents -Directory $root -Now ([DateTimeOffset]::UtcNow))
 Require ($existing.Count -eq 1 -and $existing[0].id -ceq ('a'*64)) 'An interrupted diagnostic write corrupted the old journal.'
 Write-DiagnosticEvent -Directory $root -Event (Synthetic-Event 'c' ([DateTimeOffset]::UtcNow)) -Now ([DateTimeOffset]::UtcNow)
 Require (@(Read-DiagnosticEvents -Directory $root -Now ([DateTimeOffset]::UtcNow)).Count -eq 2) 'The journal did not recover after the interrupted writer.'
 Write-Output 'Diagnostic atomicity: killing a synthetic writer before replacement preserved a readable journal and later writes.'
}finally{
 if($null -ne $child){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(5000)};$child.Dispose()}
 $gate.Dispose()
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic cleanup target.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
