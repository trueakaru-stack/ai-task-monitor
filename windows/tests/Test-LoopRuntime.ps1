$ErrorActionPreference="Stop"
$appRoot=Join-Path $PSScriptRoot "..\app"
foreach($name in @("DiagnosticPolicy.ps1","DiagnosticStore.ps1","LoopDetection.ps1","DiagnosticCollector.ps1","DiagnosticRuntime.ps1")){. (Join-Path $appRoot $name)}
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-loop-test-"+[Guid]::NewGuid().ToString("N"))))
$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if(-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test directory."}
[void][IO.Directory]::CreateDirectory($root)
try{
    $now=[DateTimeOffset]::UtcNow
    $directory=Join-Path $root "diagnostics"
    $pathA=Join-Path $root "session-a.jsonl"
    $pathB=Join-Path $root "session-b.jsonl"
    [IO.File]::WriteAllText($pathA,"")
    [IO.File]::WriteAllText($pathB,"")
    $paths=@{"task-a"=$pathA;"task-b"=$pathB}
    $resolver={param($id) return $paths[$id]}.GetNewClosure()
    $stateResolver={param($id) return [PSCustomObject]@{State="unknown"}}
    $runtime=New-DiagnosticRuntime -Directory $directory -Since $now.AddSeconds(-1) -Now $now
    $tasks=@([PSCustomObject]@{Provider="codex";Id="task-a";State="active"},[PSCustomObject]@{Provider="codex";Id="task-b";State="active"})
    Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks -Unavailable @() -Now $now -SessionResolver $resolver -StateResolver $stateResolver
    $secret="SYNTHETIC_PRIVATE_COMMAND_AND_OUTPUT"
    function Append-Command([string]$path,[string]$id,[int]$seconds,[string]$status="failed",[int]$code=1){
        $record=@{timestamp=$now.AddSeconds($seconds).ToString("o");type="event_msg";payload=@{type="item_completed";item=@{type="CommandExecution";id=$id;status=$status;exit_code=$code;command=@("synthetic-tool",$secret);cwd="/private/synthetic";aggregated_output=$secret}}}
        [IO.File]::AppendAllText($path,(($record|ConvertTo-Json -Compress -Depth 6)+"`n"),[Text.UTF8Encoding]::new($false))
    }
    foreach($index in 1..4){Append-Command $pathA "a-$index" $index;Append-Command $pathB "b-$index" $index}
    Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks -Unavailable @() -Now $now.AddSeconds(5) -SessionResolver $resolver -StateResolver $stateResolver
    if($runtime.LoopStates["codex:task-a"].Times.Count -ne 4 -or $runtime.LoopStates["codex:task-b"].Times.Count -ne 4){throw "Independent tasks must retain independent failures."}
    Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks -Unavailable @() -Now $now.AddSeconds(5) -SessionResolver $resolver -StateResolver $stateResolver
    if($runtime.LoopStates["codex:task-a"].Times.Count -ne 4){throw "A repeated poll counted the same failures twice."}
    Append-Command $pathA "a-5" 6
    $journal=Join-Path $directory "diagnostic-events-v1.jsonl"
    $saved=[IO.File]::ReadAllBytes($journal)
    [IO.File]::WriteAllText($journal,"synthetic corruption")
    $threw=$false
    try{Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks -Unavailable @() -Now $now.AddSeconds(7) -SessionResolver $resolver -StateResolver $stateResolver}catch{$threw=$true}
    if(-not $threw -or $runtime.LoopStates["codex:task-a"].Times.Count -ne 4){throw "A journal failure must not advance loop state."}
    [IO.File]::WriteAllBytes($journal,$saved)
    Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks -Unavailable @() -Now $now.AddSeconds(7) -SessionResolver $resolver -StateResolver $stateResolver
    if(-not $runtime.LoopStates["codex:task-a"].Warning -or $runtime.LoopStates["codex:task-b"].Warning){throw "Only the task with five failures should be flagged."}
    $runtime.LoopStates["codex:task-a"].Dismissed=$true
    Append-Command $pathA "a-6" 8
    Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks -Unavailable @() -Now $now.AddSeconds(9) -SessionResolver $resolver -StateResolver $stateResolver
    if(-not $runtime.LoopStates["codex:task-a"].Dismissed){throw "Dismissal must survive the next refresh."}
    Append-Command $pathA "a-success" 10 "completed" 0
    Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks -Unavailable @() -Now $now.AddSeconds(11) -SessionResolver $resolver -StateResolver $stateResolver
    if($runtime.LoopStates["codex:task-a"].Warning -or $runtime.LoopStates["codex:task-a"].Times.Count -ne 0){throw "A successful command must reset the warning."}
    $events=@(Read-DiagnosticEvents -Directory $directory -Now $now.AddSeconds(11) -RetentionDays 7 -MaximumBytes 10000000)
    if(@($events|Where-Object type -eq "tool_failed").Count -ne 10){throw "Structured errors must reach the journal without duplication."}
    $raw=[IO.File]::ReadAllText($journal)
    if($raw.Contains($secret) -or $raw.Contains("/private/synthetic") -or $raw -match 'command|aggregated_output|exit_code'){throw "The journal contains private command metadata."}
    foreach($index in 1..5){
        $record=@{timestamp=$now.AddSeconds(11+$index).ToString("o");type="event_msg";payload=@{type="item_completed";item=@{type="CommandExecution";id="single-$index";status="failed";exit_code=1;command=@("synthetic-tool");cwd="/private/synthetic"}}}
        [IO.File]::AppendAllText($pathA,(($record|ConvertTo-Json -Compress -Depth 6)+"`n"),[Text.UTF8Encoding]::new($false))
    }
    Update-DiagnosticRuntime -Runtime $runtime -Tasks $tasks -Unavailable @() -Now $now.AddSeconds(17) -SessionResolver $resolver -StateResolver $stateResolver
    if(-not $runtime.LoopStates["codex:task-a"].Warning -or $runtime.LoopStates["codex:task-b"].Warning){throw "Single-argument command failures must warn only on the affected task."}
    Write-Output "Loop runtime: concurrent tasks, transactional retry, dismissal, reset and metadata-only journal verified."
}finally{
    if(Test-Path -LiteralPath $root){
        $resolved=(Resolve-Path -LiteralPath $root).Path
        if($resolved -ne $root -or -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test cleanup path."}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
