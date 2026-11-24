$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
Add-Type -Path (Join-Path $app 'LocalReadOwner.cs')
. (Join-Path $app 'DiagnosticPolicy.ps1');. (Join-Path $app 'DiagnosticStore.ps1');. (Join-Path $app 'DiagnosticClient.ps1')
function Prop($object,[string]$name,$fallback=$null){if($null -ne $object -and $null -ne $object.PSObject.Properties[$name]){return $object.$name};return $fallback}
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-temp-copy-guard-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic temporary-copy directory.'
if([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)){throw 'The synthetic temporary-copy directory already exists.'}
[void][IO.Directory]::CreateDirectory($root);$owner=$null
try{
 $journal=Join-Path $root 'journal'
 Clear-DiagnosticEvents -Directory $journal
 $now=[DateTimeOffset]::UtcNow
 $event=[PSCustomObject]@{version=1;time=$now.ToString('o');source='codex';task=('a'*64);type='tool_started';id=('b'*64)}
 Write-DiagnosticEvent -Directory $journal -Event $event -Now $now
 $path=Join-Path $journal 'diagnostic-events-v1.jsonl'
 $candidate=Join-Path $journal ('diagnostic-'+('a'*32)+'.tmp');$unrelated=Join-Path $journal 'diagnostic-foreign.tmp'
 [IO.File]::WriteAllText($candidate,'synthetic unknown file');[IO.File]::WriteAllText($unrelated,'synthetic unrelated file')
 $journalHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;$candidateHash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
 $failed=$false;try{Clear-DiagnosticEvents -Directory $journal}catch{$failed=$true}
 Require ($failed -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $journalHash -and
  (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ceq $candidateHash -and [IO.File]::ReadAllText($unrelated) -ceq 'synthetic unrelated file') 'A possible temporary copy was removed or the clear was falsely confirmed.'
 $codex=Join-Path $root 'codex';$profile=Join-Path $root 'profile';$data=Join-Path $root 'data'
 foreach($directory in @($codex,$profile,$data)){[void][IO.Directory]::CreateDirectory($directory)}
 $configuration=[string[]]@('AITM-DIAGNOSTIC-1',$codex,$profile,$data,$journal,$now.AddMinutes(-1).ToString('o'))
 $owner=[AITaskMonitor.LocalReadOwner.Owner]::new((Join-Path $app 'DiagnosticWorker.ps1'),$configuration)
 $client=New-DiagnosticClient $owner;[void](Queue-DiagnosticClear $client);$clock=[Diagnostics.Stopwatch]::StartNew();$completed=$false
 do{Get-DiagnosticClientUpdate $client @() @();if($client.LastClearCompleted){$completed=$true};if($client.LastClearUncertain){break};Start-Sleep -Milliseconds 10}while($clock.ElapsedMilliseconds -lt 15000)
 Require ($client.LastClearUncertain -and -not $completed -and -not $client.PendingClear -and
  (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $journalHash -and (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ceq $candidateHash) 'The production diagnostic client confirmed or changed a blocked clear.'
 $owner.Dispose();$clock.Restart();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10}
 Require $owner.CanReplace 'The synthetic temporary-copy owner did not stop.';$owner=$null
 [IO.File]::Delete($candidate)
 Clear-DiagnosticEvents -Directory $journal
 Require (@(Read-DiagnosticEvents -Directory $journal -Now $now).Count -eq 0 -and [IO.File]::ReadAllText($unrelated) -ceq 'synthetic unrelated file') 'The clear failed after the synthetic obstruction was removed or touched an unrelated entry.'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $app 'DiagnosticStore.ps1'),[ref]$tokens,[ref]$errors)
 $writer=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Write-DiagnosticFile'},$true)
 $needle='$temporary=Join-Path $Directory ("diagnostic-"+[Guid]::NewGuid().ToString("N")+".tmp")'
 Require ($errors.Count -eq 0 -and $null -ne $writer -and $writer.Extent.Text.Contains($needle)) 'The synthetic collision path could not be isolated.'
 . ([scriptblock]::Create($writer.Extent.Text.Replace($needle,'$temporary=$script:syntheticTemporary')))
 $script:syntheticTemporary=Join-Path $journal ('diagnostic-'+('c'*32)+'.tmp')
 [IO.File]::WriteAllText($script:syntheticTemporary,'synthetic pre-existing file')
 $oldHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;$collisionHash=(Get-FileHash -LiteralPath $script:syntheticTemporary -Algorithm SHA256).Hash
 $failed=$false;try{Write-DiagnosticEvent -Directory $journal -Event $event -Now $now}catch{$failed=$true}
 Require ($failed -and [IO.File]::Exists($script:syntheticTemporary) -and
  (Get-FileHash -LiteralPath $script:syntheticTemporary -Algorithm SHA256).Hash -ceq $collisionHash -and
  (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $oldHash) 'A CreateNew collision changed or deleted an unknown file.'
 $script:syntheticTemporary=Join-Path $journal ('diagnostic-'+('d'*32)+'.tmp')
 $hold=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{$failed=$false;try{Write-DiagnosticEvent -Directory $journal -Event $event -Now $now}catch{$failed=$true}}finally{$hold.Dispose()}
 Require ($failed -and [IO.File]::Exists($script:syntheticTemporary) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $oldHash) 'A failed replacement lost the old journal or deleted an unverified temporary entry.'
 $closeNeedle='}finally{$stream.Dispose()}'
 Require ($writer.Extent.Text.Contains($closeNeedle)) 'The synthetic substitution point could not be identified.'
 $substitute='[IO.File]::Delete($script:syntheticTemporary);[IO.File]::WriteAllText($script:syntheticTemporary,"synthetic substituted file");throw "Synthetic substitution"'
 $writerText=$writer.Extent.Text.Replace($needle,'$temporary=$script:syntheticTemporary').Replace($closeNeedle,($closeNeedle+[Environment]::NewLine+' '+$substitute))
 . ([scriptblock]::Create($writerText))
 $script:syntheticTemporary=Join-Path $journal ('diagnostic-'+('e'*32)+'.tmp')
 $failed=$false;try{Write-DiagnosticEvent -Directory $journal -Event $event -Now $now}catch{$failed=$true}
 Require ($failed -and [IO.File]::ReadAllText($script:syntheticTemporary) -ceq 'synthetic substituted file' -and
  (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $oldHash) 'A substituted temporary entry was deleted or the old journal changed.'
 Write-Output 'Diagnostic clear guard: possible copies block acknowledgement without deleting or changing unknown files.'
}finally{
 if($null -ne $owner){$owner.Dispose();$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $owner.HasExited -and $clock.ElapsedMilliseconds -lt 10000){Start-Sleep -Milliseconds 10};if(-not $owner.CanReplace){throw 'The synthetic temporary-copy owner did not stop.'}}
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic temporary-copy cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
