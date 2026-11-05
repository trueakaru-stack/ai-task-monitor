param(
 [Parameter(Mandatory=$true)][string]$Fixture,
 [Parameter(Mandatory=$true)][string]$Output,
 [Parameter(Mandatory=$true)][string]$ReferenceDirectory
)
$ErrorActionPreference='Stop'
. (Join-Path $ReferenceDirectory 'DiagnosticPolicy.ps1')
. (Join-Path $ReferenceDirectory 'LoopDetection.ps1')
$fixtureData=Get-Content -LiteralPath $Fixture -Raw -Encoding UTF8 | ConvertFrom-Json
$tracker=New-CodexLoopTracker -Key ([byte[]](0..31)) -Since ([DateTimeOffset]::Parse($fixtureData.Since)) -Threshold $fixtureData.Threshold -WindowMinutes $fixtureData.WindowMinutes
$outputRows=New-Object 'Collections.Generic.List[object]'
foreach($op in $fixtureData.Operations) {
 switch($op.Kind) {
  'event' {
   $item=[PSCustomObject]@{type=$op.ItemType;id=$op.Id;status=$op.Status;exit_code=$op.ExitCode;command=$op.Command;cwd=$op.WorkingDirectory}
   $record=[PSCustomObject]@{type=$op.RecordType;timestamp=$op.Time;payload=[PSCustomObject]@{type=$op.EventType;item=$item}}
   Update-CodexLoopTracker $tracker $record ([DateTimeOffset]::Parse($op.Now))
  }
  'dismiss' { $tracker.Dismissed=$true }
  'refresh' { Refresh-CodexLoopTracker $tracker ([DateTimeOffset]::Parse($op.Now)) }
  'reset' { Reset-CodexLoopSequence $tracker }
  'configure' {
   if($tracker.Threshold -ne $op.Threshold -or $tracker.WindowMinutes -ne $op.WindowMinutes){
    Reset-CodexLoopSequence $tracker;$tracker.Threshold=$op.Threshold;$tracker.WindowMinutes=$op.WindowMinutes
   }
  }
  default { throw 'Unknown synthetic operation.' }
 }
 $outputRows.Add([PSCustomObject]@{warning=[bool]$tracker.Warning;dismissed=[bool]$tracker.Dismissed;count=[int]$tracker.Times.Count})
}
[IO.File]::WriteAllText($Output,([object[]]$outputRows.ToArray() | ConvertTo-Json -Depth 5 -Compress),[Text.UTF8Encoding]::new($false))
