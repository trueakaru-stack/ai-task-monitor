$ErrorActionPreference = "Stop"
$appRoot = Join-Path $PSScriptRoot "..\app"
$policy = Join-Path $appRoot "DiagnosticPolicy.ps1"
$store = Join-Path $appRoot "DiagnosticStore.ps1"
if (-not (Test-Path -LiteralPath $policy) -or -not (Test-Path -LiteralPath $store)) { throw "Diagnostic storage is missing." }
. $policy
. $store

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-journal-" + [Guid]::NewGuid().ToString("N"))
$expectedRoot = [IO.Path]::GetFullPath($testRoot)
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $expectedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test directory." }
[void][IO.Directory]::CreateDirectory($expectedRoot)

try {
    $now = [DateTimeOffset]::Parse("2026-11-02T12:00:00Z")
    $key = Get-DiagnosticInstallationKey -Directory $expectedRoot
    $again = Get-DiagnosticInstallationKey -Directory $expectedRoot
    if ($key.Length -ne 32 -or [Convert]::ToBase64String($key) -ne [Convert]::ToBase64String($again)) { throw "The protected diagnostic key must persist for the current user." }
    $keyPath = Join-Path $expectedRoot "diagnostic-key-v1.bin"
    $keyFile = [IO.File]::ReadAllBytes($keyPath)
    for ($offset = 0; $offset -le $keyFile.Length - $key.Length; $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $key.Length; $index++) { if ($keyFile[$offset + $index] -ne $key[$index]) { $matches = $false; break } }
        if ($matches) { throw "The diagnostic key must not be stored as plaintext." }
    }
    $task = Get-DiagnosticTaskKey -Provider "codex" -TaskId "synthetic-task" -Key $key
    $secret = "SYNTHETIC_SECRET_DO_NOT_STORE"
    $event = [PSCustomObject]@{
        version=1; time=$now.ToString("o"); source="codex"; task=$task
        type="tool_started"; id=("b"*64); prompt=$secret; command=$secret; output=$secret
    }
    Write-DiagnosticEvent -Directory $expectedRoot -Event $event -Now $now -RetentionDays 7 -MaximumBytes 10000
    Write-DiagnosticEvent -Directory $expectedRoot -Event $event -Now $now -RetentionDays 7 -MaximumBytes 10000
    $file = Join-Path $expectedRoot "diagnostic-events-v1.jsonl"
    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    if ($raw.Contains($secret) -or $raw -match 'prompt|command|output') { throw "Sensitive fields were written to the journal." }
    $events = @(Read-DiagnosticEvents -Directory $expectedRoot -Now $now -RetentionDays 7 -MaximumBytes 10000)
    if ($events.Count -ne 1 -or $events[0].id -ne ("b"*64)) { throw "Duplicate events must not be persisted." }
    $batchDirectory = Join-Path $expectedRoot "batch"
    $batch = @(
        $event,
        [PSCustomObject]@{version=1;time=$now.ToString("o");source="codex";task=$task;type="tool_finished";id=("d"*64)},
        [PSCustomObject]@{version=1;time=$now.ToString("o");source="codex";task=$task;type="tool_finished";id=("d"*64)}
    )
    Write-DiagnosticEvents -Directory $batchDirectory -Events $batch -Now $now -RetentionDays 7 -MaximumBytes 10000
    if (@(Read-DiagnosticEvents -Directory $batchDirectory -Now $now -RetentionDays 7 -MaximumBytes 10000).Count -ne 2) { throw "A batch must be safely deduplicated." }
    $sanitizeDirectory = Join-Path $expectedRoot "sanitize"
    [void][IO.Directory]::CreateDirectory($sanitizeDirectory)
    $sanitizeFile = Join-Path $sanitizeDirectory "diagnostic-events-v1.jsonl"
    $unsanitized = $event | ConvertTo-Json -Compress -Depth 4
    [IO.File]::WriteAllText($sanitizeFile, ($script:DiagnosticHeader + "`n" + $unsanitized + "`n" + '{"partial":'), [Text.UTF8Encoding]::new($false))
    $originalUnrecognized = [IO.File]::ReadAllText($sanitizeFile)
    $threw = $false
    try { Write-DiagnosticEvent -Directory $sanitizeDirectory -Event $batch[1] -Now $now -RetentionDays 7 -MaximumBytes 10000 } catch { $threw = $true }
    if (-not $threw -or [IO.File]::ReadAllText($sanitizeFile) -cne $originalUnrecognized) { throw "An unsupported or incomplete record must be preserved during an update." }
    $threw = $false
    try { Remove-ExpiredDiagnosticEvents -Directory $sanitizeDirectory -Now $now -RetentionDays 7 -MaximumBytes 10000 } catch { $threw = $true }
    if (-not $threw -or [IO.File]::ReadAllText($sanitizeFile) -cne $originalUnrecognized) { throw "Automatic cleanup must preserve unsupported records." }
    Clear-DiagnosticEvents -Directory $sanitizeDirectory
    if ([IO.File]::ReadAllText($sanitizeFile).Contains($secret) -or @(Read-DiagnosticEvents -Directory $sanitizeDirectory -Now $now -RetentionDays 7 -MaximumBytes 10000).Count -ne 0) { throw "Confirmed clearing must remove records from the recognized journal." }

    $later = [PSCustomObject]@{
        version=1; time=$now.AddDays(1).ToString("o"); source="codex"; task=$task
        type="tool_finished"; id=("c"*64)
    }
    Write-DiagnosticEvent -Directory $expectedRoot -Event $later -Now $now.AddDays(1) -RetentionDays 1 -MaximumBytes 390
    $events = @(Read-DiagnosticEvents -Directory $expectedRoot -Now $now.AddDays(1) -RetentionDays 1 -MaximumBytes 390)
    if ($events.Count -ne 1 -or $events[0].id -ne ("c"*64)) { throw "Oldest events must be removed to satisfy the size cap." }
    if ((Get-Item -LiteralPath $file).Length -gt 390) { throw "The stored file exceeded the size limit." }
    Remove-ExpiredDiagnosticEvents -Directory $expectedRoot -Now $now.AddDays(9) -RetentionDays 7 -MaximumBytes 10000
    if (@(Read-DiagnosticEvents -Directory $expectedRoot -Now $now.AddDays(9) -RetentionDays 7 -MaximumBytes 10000).Count -ne 0) { throw "Expired events must be removed." }
    $sentinel = Join-Path $expectedRoot "unrelated.txt"
    [IO.File]::WriteAllText($sentinel, "preserve")
    Write-DiagnosticEvent -Directory $expectedRoot -Event $event -Now $now -RetentionDays 7 -MaximumBytes 10000
    Clear-DiagnosticEvents -Directory $expectedRoot
    if (@(Read-DiagnosticEvents -Directory $expectedRoot -Now $now -RetentionDays 7 -MaximumBytes 10000).Count -ne 0 -or [IO.File]::ReadAllText($sentinel) -ne "preserve") { throw "Clearing must affect only diagnostic records." }

    $foreignDirectory = Join-Path $expectedRoot "foreign"
    [void][IO.Directory]::CreateDirectory($foreignDirectory)
    $foreignFile = Join-Path $foreignDirectory "diagnostic-events-v1.jsonl"
    $foreignContent = "This is not an AI Task Monitor journal."
    [IO.File]::WriteAllText($foreignFile, $foreignContent, [Text.UTF8Encoding]::new($false))
    $threw = $false
    try { Write-DiagnosticEvent -Directory $foreignDirectory -Event $event -Now $now -RetentionDays 7 -MaximumBytes 10000 } catch { $threw = $true }
    if (-not $threw -or [IO.File]::ReadAllText($foreignFile) -ne $foreignContent) { throw "An unrecognized file must not be overwritten." }
    $threw = $false
    try { Clear-DiagnosticEvents -Directory $foreignDirectory } catch { $threw = $true }
    if (-not $threw -or [IO.File]::ReadAllText($foreignFile) -ne $foreignContent) { throw "Clearing must not modify an unrecognized file." }
    $foreignKey = Join-Path $foreignDirectory "diagnostic-key-v1.bin"
    [IO.File]::WriteAllText($foreignKey, "unrelated key data")
    $threw = $false
    try { [void](Get-DiagnosticInstallationKey -Directory $foreignDirectory) } catch { $threw = $true }
    if (-not $threw -or [IO.File]::ReadAllText($foreignKey) -ne "unrelated key data") { throw "An unrecognized key file must not be overwritten." }
    $lostKeyDirectory = Join-Path $expectedRoot "lost-key"
    [void][IO.Directory]::CreateDirectory($lostKeyDirectory)
    $preservedJournal = Join-Path $lostKeyDirectory "diagnostic-events-v1.jsonl"
    [IO.File]::WriteAllText($preservedJournal, "preserve old journal")
    $threw = $false
    try { [void](Get-DiagnosticInstallationKey -Directory $lostKeyDirectory) } catch { $threw = $true }
    if (-not $threw -or [IO.File]::ReadAllText($preservedJournal) -ne "preserve old journal" -or (Test-Path -LiteralPath (Join-Path $lostKeyDirectory "diagnostic-key-v1.bin"))) { throw "A missing key must not silently replace an existing journal." }
    $emptyKeyDirectory = Join-Path $expectedRoot "empty-journal-key"
    [void][IO.Directory]::CreateDirectory($emptyKeyDirectory)
    $emptyJournal = Join-Path $emptyKeyDirectory "diagnostic-events-v1.jsonl"
    [IO.File]::WriteAllText($emptyJournal, ($script:DiagnosticHeader + "`n"), [Text.UTF8Encoding]::new($false))
    if ((Get-DiagnosticInstallationKey -Directory $emptyKeyDirectory).Length -ne 32 -or [IO.File]::ReadAllText($emptyJournal) -cne ($script:DiagnosticHeader + "`n")) { throw "An empty recognized journal should allow a new key without rewriting data." }

    $junctionTarget = Join-Path $expectedRoot "junction-target"
    $junction = Join-Path $expectedRoot "junction-link"
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    [void](New-Item -ItemType Junction -Path $junction -Target $junctionTarget -ErrorAction Stop)
    try {
        $threw = $false
        try { [void](Get-DiagnosticInstallationKey -Directory (Join-Path $junction "data")) } catch { $threw = $true }
        if (-not $threw -or (Test-Path -LiteralPath (Join-Path $junctionTarget "data"))) { throw "A reparse-point ancestor must not redirect diagnostic writes." }
    } finally { Remove-Item -LiteralPath $junction -Force }

    $parallelDirectory = Join-Path $expectedRoot "parallel"
    $gateName='Local\AITMDiagnosticWriters-'+[Guid]::NewGuid().ToString('N')
    $gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$gateName)
    $children=New-Object 'Collections.Generic.List[Diagnostics.Process]'
    $readySignals=New-Object 'Collections.Generic.List[Threading.EventWaitHandle]'
    $startedSignals=New-Object 'Collections.Generic.List[Threading.EventWaitHandle]'
    $policySignals=New-Object 'Collections.Generic.List[Threading.EventWaitHandle]'
    try {
        $fixture=Join-Path $PSScriptRoot 'fixtures\DiagnosticStoreWriter.ps1'
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        foreach($index in 1..8){
            $readyName=$gateName+'-ready-'+$index
            $startedName=$gateName+'-started-'+$index
            $policyName=$gateName+'-policy-'+$index
            $readySignals.Add([Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$readyName))
            $startedSignals.Add([Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$startedName))
            $policySignals.Add([Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$policyName))
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe
            $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$fixture+'" -PolicyPath "'+$policy+'" -StorePath "'+$store+'" -Directory "'+$parallelDirectory+'" -Number '+$index+' -Time "'+$now.ToString('o')+'" -GateName "'+$gateName+'" -ReadyName "'+$readyName+'" -StartedName "'+$startedName+'" -PolicyReadyName "'+$policyName+'"'
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $children.Add([Diagnostics.Process]::Start($start))
        }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        foreach($index in 0..($readySignals.Count-1)){
            while(-not $readySignals[$index].WaitOne(100)){
                foreach($childIndex in 0..($children.Count-1)){
                    if($children[$childIndex].HasExited){
                        throw ('A synthetic writer exited before the gate: index={0}; exit={1}; started={2}; policy={3}; ready={4}.' -f ($childIndex+1),$children[$childIndex].ExitCode,$startedSignals[$childIndex].WaitOne(0),$policySignals[$childIndex].WaitOne(0),$readySignals[$childIndex].WaitOne(0))
                    }
                }
                if($clock.ElapsedMilliseconds -ge 30000){
                    throw ('A synthetic writer timed out before the gate: index={0}; started={1}; policy={2}; ready={3}; exited={4}.' -f ($index+1),$startedSignals[$index].WaitOne(0),$policySignals[$index].WaitOne(0),$readySignals[$index].WaitOne(0),$children[$index].HasExited)
                }
            }
        }
        [void]$gate.Set();$clock.Restart()
        foreach($child in $children){
            $remaining=[Math]::Max(0,30000-[int]$clock.ElapsedMilliseconds)
            if(-not $child.WaitForExit($remaining) -or $child.ExitCode -ne 0){throw 'A concurrent synthetic diagnostic writer failed or timed out.'}
        }
        $parallel = @(Read-DiagnosticEvents -Directory $parallelDirectory -Now $now -RetentionDays 7 -MaximumBytes 10000)
        if ($parallel.Count -ne 8) { throw "Concurrent diagnostic writes lost events." }
    } finally {
        [void]$gate.Set()
        foreach($child in $children){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)};$child.Dispose()}
        foreach($ready in $readySignals){$ready.Dispose()}
        foreach($started in $startedSignals){$started.Dispose()}
        foreach($policyReady in $policySignals){$policyReady.Dispose()}
        $gate.Dispose()
    }
    Write-Output "Diagnostic store: safe fields, deduplication, retention, size and foreign-file protection verified."
} finally {
    if (Test-Path -LiteralPath $expectedRoot) {
        $resolved = (Resolve-Path -LiteralPath $expectedRoot).Path
        if ($resolved -ne $expectedRoot -or -not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
