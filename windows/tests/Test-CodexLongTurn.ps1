param([string]$ApplicationDirectory='')
$ErrorActionPreference='Stop'
$appRoot=if($ApplicationDirectory){[IO.Path]::GetFullPath($ApplicationDirectory)}else{[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))}
$source=Join-Path $appRoot 'CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Unable to parse the application.'}
$definitions=foreach($name in @('Read-TailText','Lock-State','Find-PriorLifecycle','Thread-State','Codex-Uncertain')){
 $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if($null -eq $definition){throw "Missing lifecycle function: $name"}
 $definition.Extent.Text
}
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('aitm-long-turn-'+[guid]::NewGuid().ToString('N'))))
$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test directory.'}
[void][IO.Directory]::CreateDirectory($root)
$checks=@'
$root=$args[0]
$lockDirectory=Join-Path $root 'locks'
[void][IO.Directory]::CreateDirectory($lockDirectory)
$script:lifecycleState=@{};$script:observedCodex=@{};$script:sessionPaths=@{}
$now=[DateTime]::UtcNow;$script:monitorStartedUtc=$now.AddSeconds(-2)
$old=$now.AddHours(-1).ToString('o');$recent=$now.AddSeconds(1).ToString('o')
function Session-File([string]$id){return $script:sessionPaths[$id]}
function Write-Fixture([string]$id,[string[]]$markers,[bool]$fresh,[bool]$largeLine){
 $path=Join-Path $root ($id+'.jsonl');$script:sessionPaths[$id]=$path
 $writer=[IO.StreamWriter]::new($path,$false,[Text.UTF8Encoding]::new($false))
 try{
  foreach($marker in $markers){$writer.WriteLine($marker)}
  if($largeLine){$writer.WriteLine('{"type":"response_item","payload":{"text":"'+('x'*3145728)+'"}}')}
  else{for($i=0;$i -lt 48;$i++){$writer.WriteLine('{"type":"response_item","payload":{"text":"'+('x'*65536)+'"}}')}}
  $stamp=if($fresh){$recent}else{$old}
  $writer.WriteLine('{"timestamp":"'+$stamp+'","type":"event_msg","payload":{"type":"item_completed"}}')
 }finally{$writer.Dispose()}
 [IO.File]::SetLastWriteTimeUtc($path,$now.AddHours(-1))
 $lock=Join-Path $lockDirectory ($id+'.lock')
 [void](New-Item -ItemType File -Path $lock -ErrorAction Stop)
 return [IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}
$start='{"timestamp":"'+$old+'","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-b"}}'
$finished='{"timestamp":"'+$old+'","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-b"}}'
$staleAbort='{"timestamp":"'+$old+'","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a"}}'
$owners=New-Object 'Collections.Generic.List[System.IO.FileStream]'
try{
 $owners.Add((Write-Fixture 'long-active' @($start) $true $false))
 $state=Thread-State 'long-active'
 if($state.State -ne 'active' -or $state.StartKey -ne 'turn:turn-b'){throw 'A fresh long-running turn was not recovered from earlier history.'}
 [void](Codex-Uncertain 'long-active' $state)
 [IO.File]::AppendAllText($script:sessionPaths['long-active'],('{"timestamp":"'+$recent+'","type":"event_msg","payload":{"type":"token_count"}}'+"`n"),[Text.UTF8Encoding]::new($false))
 if((Thread-State 'long-active').State -ne 'active'){throw 'An ongoing long turn was lost after an incremental update.'}

 $owners.Add((Write-Fixture 'completed' @($start,$finished) $true $false))
 if((Thread-State 'completed').State -ne 'completed'){throw 'A long completed turn was incorrectly marked active.'}

 $owners.Add((Write-Fixture 'old-silent' @($start) $false $false))
 $silent=Thread-State 'old-silent'
 if($silent.State -eq 'active' -or (Codex-Uncertain 'old-silent' $silent)){throw 'A silent task from before monitor startup became visible.'}

 $owners.Add((Write-Fixture 'old-abort' @($start,$staleAbort) $true $false))
 if((Thread-State 'old-abort').State -ne 'active'){throw 'An interruption from another turn stopped the current long turn.'}

 $owners.Add((Write-Fixture 'oversized-line' @($start) $true $true))
 if((Thread-State 'oversized-line').State -ne 'active'){throw 'A long non-event line hid the previous turn boundary.'}

 $owners.Add((Write-Fixture 'burst' @($start) $true $false))
 if((Thread-State 'burst').State -ne 'active'){throw 'The burst fixture did not start active.'}
 $writer=[IO.StreamWriter]::new($script:sessionPaths['burst'],$true,[Text.UTF8Encoding]::new($false))
 try{
  $writer.WriteLine($finished)
  for($i=0;$i -lt 48;$i++){$writer.WriteLine('{"type":"response_item","payload":{"text":"'+('x'*65536)+'"}}')}
  $writer.WriteLine('{"timestamp":"'+$recent+'","type":"event_msg","payload":{"type":"item_completed"}}')
 }finally{$writer.Dispose()}
 if((Thread-State 'burst').State -ne 'completed'){throw 'A completion hidden by a large append was missed.'}

 $owners.Add((Write-Fixture 'no-start' @() $true $false))
 if((Thread-State 'no-start').State -ne 'unknown' -or -not $script:lifecycleState[$script:sessionPaths['no-start']].PriorScanComplete){throw 'Missing lifecycle history was not handled conservatively.'}
 [IO.File]::AppendAllText($script:sessionPaths['no-start'],('{"timestamp":"'+$recent+'","type":"event_msg","payload":{"type":"token_count"}}'+"`n"),[Text.UTF8Encoding]::new($false))
 if((Thread-State 'no-start').State -ne 'unknown' -or -not $script:lifecycleState[$script:sessionPaths['no-start']].PriorScanComplete){throw 'A missing boundary was not retained safely across a small append.'}
 $writer=[IO.StreamWriter]::new($script:sessionPaths['no-start'],$true,[Text.UTF8Encoding]::new($false))
 try{
  $writer.WriteLine($start)
  for($i=0;$i -lt 48;$i++){$writer.WriteLine('{"type":"response_item","payload":{"text":"'+('x'*65536)+'"}}')}
  $writer.WriteLine('{"timestamp":"'+$recent+'","type":"event_msg","payload":{"type":"item_completed"}}')
 }finally{$writer.Dispose()}
 if((Thread-State 'no-start').State -ne 'active'){throw 'A new boundary hidden by a large append was missed after a negative scan.'}
 Write-Output 'Codex long turns: old boundaries, incremental updates, completion, stale tasks, mismatched aborts, oversized lines, large appends and absent boundaries verified.'
}finally{foreach($owner in $owners){$owner.Dispose()}}
'@
try{& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks)) $root}
finally{
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
