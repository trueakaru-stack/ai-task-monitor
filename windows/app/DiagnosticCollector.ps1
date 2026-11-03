function Read-CodexToolEvents {
 param(
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$TaskKey,
  [Parameter(Mandatory=$true)][byte[]]$Key,
  [Parameter(Mandatory=$true)][DateTimeOffset]$Since
 )
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{
  $take=[Math]::Min([long]2097152,$stream.Length)
  $truncated=$stream.Length -gt $take
  [void]$stream.Seek(-$take,[IO.SeekOrigin]::End)
  $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,4096,$true)
  try{$tail=$reader.ReadToEnd()}finally{$reader.Dispose()}
 }finally{$stream.Dispose()}
 if($truncated){$first=$tail.IndexOf("`n");if($first -lt 0){return @()};$tail=$tail.Substring($first+1)}
 $last=$tail.LastIndexOf("`n")
 if($last -lt 0){return @()}
 $tail=$tail.Substring(0,$last+1)
 $records=New-Object 'Collections.Generic.List[object]'
 foreach($line in ($tail -split "`r?`n")){
  if(-not $line){continue}
  try{$records.Add(($line|ConvertFrom-Json -ErrorAction Stop))}catch{}
 }
 return @(Convert-CodexToolEvents -Records $records.ToArray() -TaskKey $TaskKey -Key $Key -Since $Since)
}

function Get-CodexDiagnosticAnchor([IO.Stream]$Stream,[long]$Offset) {
 if($Offset -le 0){return ""}
 $start=[Math]::Max([long]0,$Offset-64)
 $count=[int]($Offset-$start)
 $buffer=New-Object byte[] $count
 $position=$Stream.Position
 try{
  [void]$Stream.Seek($start,[IO.SeekOrigin]::Begin)
  $read=0
  while($read -lt $count){$n=$Stream.Read($buffer,$read,$count-$read);if($n -le 0){throw "Session log changed during an update."};$read+=$n}
  $sha=[Security.Cryptography.SHA256]::Create()
  try{return [Convert]::ToBase64String($sha.ComputeHash($buffer))}finally{$sha.Dispose()}
 }finally{[void]$Stream.Seek($position,[IO.SeekOrigin]::Begin)}
}

function New-CodexDiagnosticCursor {
 param([Parameter(Mandatory=$true)][string]$Path,[ValidateRange(128,2097152)][int]$MaximumBytes=2097152)
 $file=Get-Item -LiteralPath $Path -ErrorAction Stop
 $offset=[Math]::Max([long]0,[long]$file.Length-$MaximumBytes)
 return [PSCustomObject]@{Offset=$offset;Skipping=($offset -gt 0);Anchor="";CreationTicks=$file.CreationTimeUtc.Ticks;Calls=@{}}
}

function Read-CodexToolEventsIncremental {
 param(
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)]$Cursor,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$TaskKey,
  [Parameter(Mandatory=$true)][byte[]]$Key,
  [Parameter(Mandatory=$true)][DateTimeOffset]$Since,
  [ValidateRange(128,2097152)][int]$MaximumBytes=2097152,
  [scriptblock]$OnRecord=$null,
  [scriptblock]$OnReset=$null
 )
 $file=Get-Item -LiteralPath $Path -ErrorAction Stop
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{
  $changed=$stream.Length -lt [long]$Cursor.Offset -or $file.CreationTimeUtc.Ticks -ne [long]$Cursor.CreationTicks
  if(-not $changed -and $Cursor.Anchor){$changed=(Get-CodexDiagnosticAnchor $stream $Cursor.Offset) -cne [string]$Cursor.Anchor}
  if($changed){$Cursor.Offset=0;$Cursor.Skipping=$false;$Cursor.Anchor="";$Cursor.CreationTicks=$file.CreationTimeUtc.Ticks;$Cursor.Calls.Clear();if($null -ne $OnReset){[void](& $OnReset)}}
  $base=[long]$Cursor.Offset
  $remaining=$stream.Length-$base
  if($remaining -le 0){return @()}
  $take=[int][Math]::Min([long]$MaximumBytes,$remaining)
  $buffer=New-Object byte[] $take
  [void]$stream.Seek($base,[IO.SeekOrigin]::Begin)
  $read=0
  while($read -lt $take){$n=$stream.Read($buffer,$read,$take-$read);if($n -le 0){break};$read+=$n}
  if($read -le 0){return @()}
  $start=0
  if($Cursor.Skipping){
   $first=[Array]::IndexOf($buffer,[byte]10,0,$read)
   if($first -lt 0){$Cursor.Offset=$base+$read;$Cursor.Anchor=Get-CodexDiagnosticAnchor $stream $Cursor.Offset;return @()}
   $start=$first+1;$Cursor.Offset=$base+$start;$Cursor.Skipping=$false
  }
  if($start -ge $read){$Cursor.Anchor=Get-CodexDiagnosticAnchor $stream $Cursor.Offset;return @()}
  $last=[Array]::LastIndexOf($buffer,[byte]10,$read-1,$read-$start)
  if($last -lt $start){
   if($start -eq 0 -and $read -ge $MaximumBytes){$Cursor.Offset=$base+$read;$Cursor.Skipping=$true}
   $Cursor.Anchor=Get-CodexDiagnosticAnchor $stream $Cursor.Offset
   return @()
  }
  $text=[Text.Encoding]::UTF8.GetString($buffer,$start,$last-$start+1)
  $Cursor.Offset=$base+$last+1
  $Cursor.Anchor=Get-CodexDiagnosticAnchor $stream $Cursor.Offset
  $records=New-Object 'Collections.Generic.List[object]'
  foreach($line in ($text -split "`r?`n")){
   if(-not $line){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   $records.Add($record)
   if($null -ne $OnRecord){[void](& $OnRecord $record)}
  }
  return @(Convert-CodexToolEvents -Records $records.ToArray() -TaskKey $TaskKey -Key $Key -Since $Since -Calls $Cursor.Calls)
 }finally{$stream.Dispose()}
}
