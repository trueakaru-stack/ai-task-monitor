param(
 [Parameter(Mandatory=$true)][string]$Fixture,
 [Parameter(Mandatory=$true)][string]$Output,
 [Parameter(Mandatory=$true)][string]$Reference
)
$ErrorActionPreference='Stop'
. $Reference
$cases=Get-Content -LiteralPath $Fixture -Raw -Encoding UTF8 | ConvertFrom-Json
$rows=New-Object 'Collections.Generic.List[object]'
foreach($case in $cases){
 $valid=($case.Platform -in @('windows','macos')) -and ($null -ne (ConvertTo-ReleaseVersion $case.Current)) -and (Test-ReleasePayload $case.Json)
 $selected=if($valid){Find-PlatformUpdate $case.Json $case.Current $case.Platform}else{$null}
 $rows.Add([PSCustomObject]@{valid=[bool]$valid;version=if($null -ne $selected){[string]$selected.Version}else{$null};url=if($null -ne $selected){[string]$selected.Url}else{$null}})
}
[IO.File]::WriteAllText($Output,([object[]]$rows.ToArray()|ConvertTo-Json -Depth 6 -Compress),[Text.UTF8Encoding]::new($false))
