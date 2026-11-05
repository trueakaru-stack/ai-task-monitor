param(
    [Parameter(Mandatory=$true)][string]$ReferenceSource,
    [Parameter(Mandatory=$true)][string]$FixtureRoot
)
$ErrorActionPreference='Stop'
$reference=[IO.Path]::GetFullPath($ReferenceSource)
$fixture=[IO.Path]::GetFullPath($FixtureRoot)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($reference,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Reference source could not be parsed.'}
foreach($name in @('Prop','Session-File')){
    $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
    if($null -eq $node){throw "Reference function is missing: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$tasks=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Codex-Tasks'},$true)
$refresh=$tasks.Find({param($item) $item -is [Management.Automation.Language.IfStatementAst] -and
    $item.Extent.Text.StartsWith('if ($null -ne $discoveryVariable -and $null -ne $discoveryVariable.Value)')},$true)
if($null -eq $refresh){throw 'The reference index refresh block is missing.'}
$refreshBlock=[scriptblock]::Create('$discoveryVariable=Get-Variable -Scope Script -Name sessionDiscovery'+"`n"+$refresh.Extent.Text)
$script:cases=New-Object 'Collections.Generic.List[object]'
function Start-Case([string]$name,[bool]$createRoot=$true){
    $script:case=[ordered]@{Name=$name;Steps=(New-Object 'Collections.Generic.List[object]')}
    $script:cases.Add($script:case)
    $sessionsDirectory=Join-Path (Join-Path $fixture $name) 'sessions'
    Set-Variable -Name sessionsDirectory -Scope Script -Value $sessionsDirectory
    if($createRoot){[void][IO.Directory]::CreateDirectory($sessionsDirectory)}
    $script:sessionDates=@{}
    $script:sessionDiscovery=[PSCustomObject]@{
        Gate=[object]::new();Files=@{};Rollouts=$null;LastScanTicks=[long]0;Attempted=$false;ScanFailed=$false
        RetrySeconds=5;HotUntilTicks=[long]0;IndexVersions=@{};DatedMisses=@{};RolloutMisses=@{}
    }
    $script:case.Steps.Add([ordered]@{Operation='root';Present=$createRoot})
}
function Mkdir([string]$relative){
    [void][IO.Directory]::CreateDirectory((Join-Path $sessionsDirectory $relative))
    $script:case.Steps.Add([ordered]@{Operation='mkdir';Path=$relative})
}
function Write-Fixture([string]$relative){
    $path=Join-Path $sessionsDirectory $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path,"{}`n",[Text.UTF8Encoding]::new($false))
    $script:case.Steps.Add([ordered]@{Operation='write';Path=$relative})
}
function Set-FixtureAttributes([string]$relative,[ValidateSet('Hidden','System','HiddenSystem')][string]$attribute){
    $path=Join-Path $sessionsDirectory $relative
    $flag=if($attribute -eq 'HiddenSystem'){[IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System}else{[IO.FileAttributes][Enum]::Parse([IO.FileAttributes],$attribute)}
    [IO.File]::SetAttributes($path,([IO.File]::GetAttributes($path) -bor $flag))
    if(([IO.File]::GetAttributes($path) -band $flag) -ne $flag){throw 'Synthetic file attribute was not applied.'}
    $recorded=if($attribute -eq 'HiddenSystem'){'Hidden, System'}else{$attribute}
    $script:case.Steps.Add([ordered]@{Operation='attributes';Path=$relative;Attributes=$recorded})
}
function Move-Fixture([string]$from,[string]$to){
    $target=Join-Path $sessionsDirectory $to
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Move((Join-Path $sessionsDirectory $from),$target)
    $script:case.Steps.Add([ordered]@{Operation='move';Path=$from;Target=$to})
}
function Delete-Fixture([string]$relative){
    [IO.File]::Delete((Join-Path $sessionsDirectory $relative))
    $script:case.Steps.Add([ordered]@{Operation='delete';Path=$relative})
}
function Advance([int]$seconds){
    $ticks=[long][Diagnostics.Stopwatch]::Frequency*$seconds
    if($script:sessionDiscovery.Attempted){$script:sessionDiscovery.LastScanTicks-=$ticks}
    $script:sessionDiscovery.HotUntilTicks-=$ticks
    foreach($miss in $script:sessionDiscovery.DatedMisses.Values){$miss.Tick-=$ticks}
    $script:case.Steps.Add([ordered]@{Operation='advance';Seconds=$seconds})
}
function Cycle([object[]]$entries){
    $sessions=foreach($entry in $entries){
        if($entry.Date){
            $date=[DateTime]::ParseExact([string]$entry.Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
            $script:sessionDates[[string]$entry.Id]=Join-Path (Join-Path (Join-Path $sessionsDirectory ([string]$date.Year)) $date.ToString('MM')) $date.ToString('dd')
        }
        [PSCustomObject]@{id=[string]$entry.Id;updated_at=[string]$entry.Version}
    }
    . $refreshBlock
    $script:case.Steps.Add([ordered]@{Operation='cycle';Entries=@($entries);Retry=$script:sessionDiscovery.RetrySeconds})
}
function Find-Fixture([string]$id,[object]$expectedRelative=$null){
    $before=[long]$script:sessionDiscovery.LastScanTicks;$errorFound=$false;$result=''
    try{$result=[string](Session-File $id)}catch{$errorFound=$true}
    $relative=''
    if($result){
        $prefix=$sessionsDirectory.TrimEnd('\')+'\'
        if(-not $result.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Reference returned a path outside the synthetic root.'}
        $relative=$result.Substring($prefix.Length)
    }
    if($null -ne $expectedRelative -and ($errorFound -or $relative -cne [string]$expectedRelative)){
        throw "Original synthetic lookup $id returned '$relative'; expected '$expectedRelative'; error=$errorFound."
    }
    $script:case.Steps.Add([ordered]@{Operation='find';Id=$id;Result=$relative;Error=$errorFound;
        Scanned=($before -ne [long]$script:sessionDiscovery.LastScanTicks);Retry=$script:sessionDiscovery.RetrySeconds})
}
function Entry([string]$id,[string]$version,[string]$date=''){return [ordered]@{Id=$id;Version=$version;Date=$date}}

Start-Case 'dated-and-moves'
Mkdir '2026\11\05'
Mkdir 'other'
Cycle @((Entry 'late' 'v1' '2026-11-05'))
Find-Fixture 'late'
Write-Fixture '2026\11\05\rollout-late.jsonl'
Find-Fixture 'late'
Advance 2
Find-Fixture 'late'
Find-Fixture 'late'
Move-Fixture '2026\11\05\rollout-late.jsonl' 'other\rollout-late.jsonl'
Find-Fixture 'late'
Advance 6
Find-Fixture 'late'
Delete-Fixture 'other\rollout-late.jsonl'
Find-Fixture 'late'
Write-Fixture 'other\rollout-late.jsonl'
Find-Fixture 'late'

Start-Case 'refresh-dated-miss'
Mkdir '2026\11\05'
Cycle @((Entry 'fresh' 'v1' '2026-11-05'))
Find-Fixture 'fresh'
Write-Fixture '2026\11\05\rollout-fresh.jsonl'
Find-Fixture 'fresh'
Cycle @((Entry 'fresh' 'v1' '2026-11-05'))
Find-Fixture 'fresh'

Start-Case 'shared-negative'
Mkdir 'other'
for($i=0;$i -lt 20;$i++){Find-Fixture ('absent-{0:D2}' -f $i)}
Write-Fixture 'other\rollout-outside.jsonl'
Find-Fixture 'outside'
Advance 6
Find-Fixture 'outside'

Start-Case 'backoff-and-index'
Find-Fixture 'missing'
foreach($interval in @(6,11,21,41,61,61)){Advance $interval;Find-Fixture 'missing'}
Cycle @((Entry 'missing' 'v1'))
Find-Fixture 'missing'
Advance 6
Find-Fixture 'missing'
Advance 31
Find-Fixture 'missing'
Advance 11
Find-Fixture 'missing'
Cycle @((Entry 'missing' 'v1'))
Find-Fixture 'missing'
Cycle @((Entry 'missing' 'v2'))
Find-Fixture 'missing'

Start-Case 'known-versus-missing-index'
Mkdir '2026\11\05'
Write-Fixture '2026\11\05\rollout-known.jsonl'
Cycle @((Entry 'known' 'v1' '2026-11-05'),(Entry 'missing' 'v1'))
Find-Fixture 'known'
Find-Fixture 'missing'
foreach($interval in @(31,11,21,41)){Advance $interval;Find-Fixture 'missing'}
Cycle @((Entry 'known' 'v2' '2026-11-05'),(Entry 'missing' 'v1'))
Find-Fixture 'missing'
Cycle @((Entry 'known' 'v2' '2026-11-05'),(Entry 'missing' 'v2'))
Find-Fixture 'missing'
Advance 6
Find-Fixture 'missing'

Start-Case 'changed-date-and-case'
Mkdir '2026\11\05'
Mkdir '2026\11\06'
Cycle @((Entry 'ID-Case' 'v1' '2026-11-05'))
Find-Fixture 'id-case'
Write-Fixture '2026\11\06\rollout-ID-CASE.JSONL'
Cycle @((Entry 'id-case' 'v2' '2026-11-06'))
Find-Fixture 'id-case'

Start-Case 'hidden-and-system'
Mkdir '2026\11\05'
Mkdir 'other'
Write-Fixture '2026\11\05\a-hidden-shared.jsonl'
Set-FixtureAttributes '2026\11\05\a-hidden-shared.jsonl' 'Hidden'
Write-Fixture '2026\11\05\b-system-shared.jsonl'
Set-FixtureAttributes '2026\11\05\b-system-shared.jsonl' 'System'
Write-Fixture '2026\11\05\c-hidden-system-shared.jsonl'
Set-FixtureAttributes '2026\11\05\c-hidden-system-shared.jsonl' 'HiddenSystem'
Write-Fixture '2026\11\05\z-visible-shared.jsonl'
Write-Fixture '2026\11\05\a-hidden-hiddenonly.jsonl'
Set-FixtureAttributes '2026\11\05\a-hidden-hiddenonly.jsonl' 'Hidden'
Write-Fixture '2026\11\05\z-visible-hiddenonly.jsonl'
Write-Fixture '2026\11\05\a-system-systemonly.jsonl'
Set-FixtureAttributes '2026\11\05\a-system-systemonly.jsonl' 'System'
Write-Fixture '2026\11\05\z-visible-systemonly.jsonl'
Write-Fixture '2026\11\05\a-hidden-system-hiddensystemonly.jsonl'
Set-FixtureAttributes '2026\11\05\a-hidden-system-hiddensystemonly.jsonl' 'HiddenSystem'
Write-Fixture '2026\11\05\z-visible-hiddensystemonly.jsonl'
Write-Fixture '2026\11\05\a-hidden-fallbackhidden.jsonl'
Set-FixtureAttributes '2026\11\05\a-hidden-fallbackhidden.jsonl' 'Hidden'
Write-Fixture '2026\11\05\a-hidden-system-fallbackboth.jsonl'
Set-FixtureAttributes '2026\11\05\a-hidden-system-fallbackboth.jsonl' 'HiddenSystem'
Write-Fixture 'other\a-system-fallbacksystem.jsonl'
Set-FixtureAttributes 'other\a-system-fallbacksystem.jsonl' 'System'
Cycle @((Entry 'shared' 'v1' '2026-11-05'),(Entry 'hiddenonly' 'v1' '2026-11-05'),
    (Entry 'systemonly' 'v1' '2026-11-05'),(Entry 'hiddensystemonly' 'v1' '2026-11-05'),
    (Entry 'fallbackhidden' 'v1' '2026-11-05'),(Entry 'fallbackboth' 'v1' '2026-11-05'),(Entry 'fallbacksystem' 'v1' '2026-11-05'))
Find-Fixture 'shared' '2026\11\05\b-system-shared.jsonl'
Find-Fixture 'hiddenonly' '2026\11\05\z-visible-hiddenonly.jsonl'
Find-Fixture 'systemonly' '2026\11\05\a-system-systemonly.jsonl'
Find-Fixture 'hiddensystemonly' '2026\11\05\z-visible-hiddensystemonly.jsonl'
Find-Fixture 'fallbackhidden' '2026\11\05\a-hidden-fallbackhidden.jsonl'
Find-Fixture 'fallbackboth' '2026\11\05\a-hidden-system-fallbackboth.jsonl'
Find-Fixture 'fallbacksystem' 'other\a-system-fallbacksystem.jsonl'

Start-Case 'ordinary-match-order'
Mkdir '2026\11\05'
Write-Fixture '2026\11\05\z-rollout-ordinary.jsonl'
Write-Fixture '2026\11\05\a-rollout-ordinary.jsonl'
Cycle @((Entry 'ordinary' 'v1' '2026-11-05'))
Find-Fixture 'ordinary'

Start-Case 'missing-root' $false
Find-Fixture 'unavailable'
Mkdir '.'
Write-Fixture 'rollout-unavailable.jsonl'
Find-Fixture 'unavailable'

ConvertTo-Json -InputObject $script:cases.ToArray() -Depth 15 -Compress
