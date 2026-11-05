param(
    [Parameter(Mandatory=$true)][string]$ReferenceSource,
    [Parameter(Mandatory=$true)][string]$FixtureRoot
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($ReferenceSource),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The pinned reference failed to parse.'}
foreach($name in @('Prop','Lock-State','Codex-IndexCandidates')){
    $node=$ast.Find({param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $name},$true)
    if($null -eq $node){throw 'A reference index function is missing.'}
    . ([scriptblock]::Create($node.Extent.Text))
}
$fixture=[IO.Path]::GetFullPath($FixtureRoot)
[void][IO.Directory]::CreateDirectory($fixture)
$script:cases=New-Object 'Collections.Generic.List[object]'
$script:queryNumber=0
function Start-Case([string]$name){
    $script:case=[ordered]@{Name=$name;Steps=(New-Object 'Collections.Generic.List[object]')}
    $script:cases.Add($script:case)
    $script:caseRoot=Join-Path $fixture $name
    [void][IO.Directory]::CreateDirectory($script:caseRoot)
    $script:sessionIndex=Join-Path $script:caseRoot 'index.jsonl'
    $script:sessionsDirectory=Join-Path $script:caseRoot 'sessions'
    $script:sessionIndexLookup=@{}
    $script:sessionDates=@{}
    $script:observedCodex=@{}
}
function Record([string]$id,[string]$title,[string]$updated='2026-11-05T12:00:00Z'){
    return ([ordered]@{id=$id;thread_name=$title;updated_at=$updated}|ConvertTo-Json -Compress)
}
function Write-Index([string[]]$lines,[string]$separator,[bool]$trailing,[string]$encoding,[int]$version){
    $content=$lines -join $separator
    if($trailing){$content+=$separator}
    $onDisk=$content
    if($onDisk.Contains('__AITM_SYNTHETIC_LIMIT__')){$onDisk=$onDisk.Replace('__AITM_SYNTHETIC_LIMIT__',('x'*1048576))}
    if($onDisk.Contains('__AITM_SYNTHETIC_OVERSIZE__')){$onDisk=$onDisk.Replace('__AITM_SYNTHETIC_OVERSIZE__',('x'*1048577))}
    $enc=switch($encoding){
        'utf8'{[Text.UTF8Encoding]::new($false)}
        'utf8bom'{[Text.UTF8Encoding]::new($true)}
        'utf16le'{[Text.UnicodeEncoding]::new($false,$true)}
        'utf16be'{[Text.UnicodeEncoding]::new($true,$true)}
        'utf32le'{[Text.UTF32Encoding]::new($false,$true)}
        'utf32be'{[Text.UTF32Encoding]::new($true,$true)}
        default{throw 'Unsupported synthetic encoding.'}
    }
    [IO.File]::WriteAllText($script:sessionIndex,$onDisk,$enc)
    $stamp=[DateTime]::SpecifyKind([DateTime]::new(2026,1,1).AddSeconds($version),[DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($script:sessionIndex,$stamp)
    $script:case.Steps.Add([ordered]@{Operation='write';Content=$content;Encoding=$encoding;Version=$version})
}
function Query([string[]]$observed,[string[]]$held,[string[]]$free,[bool]$unsupported=$false,[bool]$failedCacheDivergence=$false){
    $script:queryNumber++
    $script:observedCodex=@{}
    foreach($id in $observed){$script:observedCodex[$id]=$true}
    $script:sessionDates=@{}
    $script:lockDirectory=Join-Path $script:caseRoot ('locks-'+$script:queryNumber)
    [void][IO.Directory]::CreateDirectory($script:lockDirectory)
    $handles=New-Object 'Collections.Generic.List[IO.FileStream]'
    try{
        foreach($id in $free){[IO.File]::WriteAllText((Join-Path $script:lockDirectory ($id+'.lock')),'')}
        foreach($id in $held){$handles.Add([IO.File]::Open((Join-Path $script:lockDirectory ($id+'.lock')),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))}
        $failed=$false;$result=@()
        try{
            $sessions=@(Codex-IndexCandidates)
            $result=@(foreach($session in $sessions){
                $id=[string](Prop $session 'id' '')
                $date=$null
                $directory=$script:sessionDates[$id]
                if($directory){
                    $pieces=$directory.Substring($script:sessionsDirectory.Length).TrimStart('\').Split('\')
                    $date=('{0:D4}-{1:D2}-{2:D2}' -f [int]$pieces[0],[int]$pieces[1],[int]$pieces[2])
                }
                [ordered]@{Id=$id;Title=[string](Prop $session 'thread_name' '');UpdatedVersion=[string](Prop $session 'updated_at' '');Date=$date}
            })
        }catch{$failed=$true}
        $script:case.Steps.Add([ordered]@{Operation='read';Observed=@($observed);Held=@($held);Free=@($free);
            Failed=$failed;Expected=@($result);Unsupported=$unsupported;FailedCacheDivergence=$failedCacheDivergence})
    }finally{foreach($handle in $handles){$handle.Dispose()}}
}

Start-Case 'basic'
Write-Index @(
    (Record 'one' 'Synthetic one'),
    (Record 'Case-ID' 'Synthetic first'),
    (Record 'case-id' 'Synthetic final' '2026-11-05T23:30:00-05:00'),
    (Record '../unsafe' 'Synthetic unsafe'),
    '{"id":"upper","THREAD_NAME":"Synthetic uppercase","UPDATED_AT":"2026-11-04"}',
    '{"id":"same-old","id":"same-new","thread_name":"Synthetic duplicate","updated_at":"invalid"}',
    '{"id":"missing-title","updated_at":null}',
    '{"id":"unicode","thread_name":"\u041f\u0440\u0438\u0432\u0435\u0442 \ud83d\ude80","updated_at":"2026-11-05"}',
    (Record 'utc-near-midnight' 'Synthetic UTC date' '2026-11-05T23:59:59.1234567Z'),
    (Record 'east-offset' 'Synthetic offset date' '2026-11-05T00:30:00+14:00'),
    (Record 'local-time' 'Synthetic local date' '2026-11-05T23:59:59'),
    (Record ('a'*128) 'Synthetic maximum ID'),
    (Record ('b'*129) 'Synthetic rejected ID')
) "`n" $true 'utf8' 1
Query @() @() @() $true

Start-Case 'history-and-cache'
$rows=New-Object 'Collections.Generic.List[string]'
$rows.Add((Record 'older' 'Synthetic title A'))
for($i=0;$i -lt 60;$i++){$rows.Add((Record ('recent-'+$i) ('Synthetic recent '+$i)))}
Write-Index $rows.ToArray() "`r`n" $true 'utf8bom' 1
Query @('older','unknown','../unsafe') @() @() $true
Query @('older','unknown') @() @()
$rows[0]=Record 'older' 'Synthetic title B'
Write-Index $rows.ToArray() "`r`n" $true 'utf8bom' 1
Query @('older','unknown') @() @()
Write-Index $rows.ToArray() "`r`n" $true 'utf8bom' 2
Query @('older','unknown') @() @()
Query @() @('older') @('unknown')

Start-Case 'filter-escaping'
$rows=New-Object 'Collections.Generic.List[string]'
$rows.Add('{"id":"\u0065scape","thread_name":"Synthetic hidden","updated_at":"2026-11-05"}')
$rows.Add('{"id":"\u0071uoted","thread_name":"quoted","updated_at":"2026-11-05"}')
for($i=0;$i -lt 55;$i++){$rows.Add((Record ('filler-'+$i) 'Synthetic'))}
Write-Index $rows.ToArray() "`n" $true 'utf8' 3
Query @('escape','quoted') @() @()

foreach($encoding in @('utf8','utf8bom','utf16le','utf16be','utf32le','utf32be')){
    foreach($separator in @("`n","`r`n","`r")){
        $label=if($separator -eq "`n"){'lf'}elseif($separator -eq "`r`n"){'crlf'}else{'cr'}
        Start-Case ($encoding+'-'+$label)
        $rows=New-Object 'Collections.Generic.List[string]'
        for($i=0;$i -lt 53;$i++){$rows.Add((Record ('i-'+$i) ('Synthetic '+$i)))}
        $rows.Insert(3,'')
        $rows.Add('')
        Write-Index $rows.ToArray() $separator $false $encoding 4
        Query @() @() @()
    }
}

Start-Case 'reverse-block-boundary'
$rows=New-Object 'Collections.Generic.List[string]'
for($i=0;$i -lt 70;$i++){$rows.Add((Record ('id-'+$i) ('Synthetic '+('x'*155)+$i)))}
Write-Index $rows.ToArray() "`r`n" $true 'utf8' 5
Query @('id-0') @() @()

foreach($count in @(0,49,50,51)){
    Start-Case ('nonterminated-count-'+$count)
    $rows=New-Object 'Collections.Generic.List[string]'
    for($i=0;$i -lt $count;$i++){$rows.Add((Record ('id-'+$i) ('Synthetic '+$i)))}
    Write-Index $rows.ToArray() "`n" $false 'utf8' 9
    Query @() @() @()
}

Start-Case 'malformed-and-noncanonical'
Write-Index @(
    (Record 'valid' 'Synthetic valid'),
    'not json',
    '{"id":"one","ID":"two","thread_name":"Synthetic"}',
    "{id:'unquoted',thread_name:'Synthetic'}",
    '{"id":true,"thread_name":"Synthetic"}',
    '{"id":"unsafe\n","thread_name":"Synthetic"}',
    '{"id":"\u0130","thread_name":"Synthetic"}'
) "`n" $true 'utf8' 6
Query @() @() @() $true

Start-Case 'missing-null-empty-id'
Write-Index @(
    '{"thread_name":"Synthetic missing ID"}',
    '{"id":null,"thread_name":"Synthetic null ID"}',
    '{"id":"","thread_name":"Synthetic empty ID"}'
) "`n" $true 'utf8' 10
Query @() @() @() $true

Start-Case 'invalid-unmatched-history'
$rows=New-Object 'Collections.Generic.List[string]'
$rows.Add('{"thread_name":"Synthetic missing ID in history"}')
for($i=0;$i -lt 55;$i++){$rows.Add((Record ('recent-'+$i) 'Synthetic'))}
Write-Index $rows.ToArray() "`n" $true 'utf8' 11
Query @('unmatched') @() @() $true

Start-Case 'failed-history-cache'
$rows=New-Object 'Collections.Generic.List[string]'
$rows.Add('__AITM_SYNTHETIC_OVERSIZE__')
$rows.Add((Record 'older' 'Synthetic older'))
for($i=0;$i -lt 55;$i++){$rows.Add((Record ('recent-'+$i) 'Synthetic'))}
Write-Index $rows.ToArray() "`n" $true 'utf8' 7
Query @('older') @() @()
Query @('older') @() @() $false $true

Start-Case 'history-exact-limit'
$rows=New-Object 'Collections.Generic.List[string]'
$rows.Add('__AITM_SYNTHETIC_LIMIT__')
$rows.Add((Record 'older' 'Synthetic exact limit'))
for($i=0;$i -lt 55;$i++){$rows.Add((Record ('recent-'+$i) 'Synthetic'))}
Write-Index $rows.ToArray() "`n" $true 'utf8' 8
Query @('older') @() @() $true

# Keep the routine reference check bounded: Get-Content -Tail is very slow
# for unusually long lines on Windows PowerShell 5.1.
$manualRoot=Join-Path $fixture 'large-tail-manual'
[void][IO.Directory]::CreateDirectory($manualRoot)
$sessionIndex=Join-Path $manualRoot 'index.jsonl'
$sessionsDirectory=Join-Path $manualRoot 'sessions'
$lockDirectory=Join-Path $manualRoot 'no-locks'
$script:sessionDates=@{};$script:sessionIndexLookup=@{};$script:observedCodex=@{}
$largeTitle='z'*65536
[IO.File]::WriteAllText($sessionIndex,((Record 'large' $largeTitle)+"`n"),[Text.UTF8Encoding]::new($false))
$largeResult=@(Codex-IndexCandidates)
if($largeResult.Count -ne 1 -or ([string]$largeResult[0].thread_name).Length -ne 65536){
    throw 'The reference did not accept the synthetic long tail row.'
}

ConvertTo-Json -InputObject ($script:cases.ToArray()) -Depth 15 -Compress
