Set-StrictMode -Version 2.0

# Read only documented CLI output; do not return response summaries or URLs.
function ConvertFrom-CodexCloudPage {
 param([Parameter(Mandatory=$true)][string]$Json)
 if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 1048576){throw 'Invalid cloud response.'}
 try{$response=$Json|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Invalid cloud response.'}
 if($null -eq $response -or $null -eq $response.PSObject.Properties['tasks'] -or $response.tasks -isnot [array] -or $response.tasks.Count -gt 20){throw 'Invalid cloud response.'}
 $cursor=''
 if($null -ne $response.PSObject.Properties['cursor'] -and $null -ne $response.cursor){
  if($response.cursor -isnot [string] -or -not $response.cursor -or [Text.Encoding]::UTF8.GetByteCount($response.cursor) -gt 1024 -or $response.cursor -match '[\x00-\x1f\x7f]'){throw 'Invalid cloud response.'}
  $cursor=[string]$response.cursor
 }
 $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
 $items=New-Object 'Collections.Generic.List[object]'
 foreach($item in $response.tasks){
  if($null -eq $item -or $null -eq $item.PSObject.Properties['id'] -or $item.id -isnot [string] -or -not $item.id -or [Text.Encoding]::UTF8.GetByteCount($item.id) -gt 512 -or $item.id -match '[\x00-\x1f\x7f]' -or -not $seen.Add([string]$item.id)){throw 'Invalid cloud response.'}
  $hasher=[Security.Cryptography.SHA256]::Create()
  try{$digest=$hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$item.id))}finally{$hasher.Dispose()}
  $id='codex-cloud:'+(-join ($digest | ForEach-Object {$_.ToString('x2')})).Substring(0,32)
  $title=''
  if($null -ne $item.PSObject.Properties['title'] -and $null -ne $item.title){
   if($item.title -isnot [string]){throw 'Invalid cloud response.'}
   $title=([string]$item.title -replace '[\p{Cc}\s]+',' ').Trim()
   if($title.Length -gt 240){$title=$title.Substring(0,239)+[char]0x2026}
  }
  $status=if($null -ne $item.PSObject.Properties['status'] -and $null -ne $item.status){
   if($item.status -isnot [string]){throw 'Invalid cloud response.'}
   switch -CaseSensitive ([string]$item.status){'pending'{'pending'}'ready'{'terminal'}'error'{'terminal'}default{'unknown'}}
  }else{'unknown'}
  $updated=[DateTimeOffset]::MinValue
  if($null -ne $item.PSObject.Properties['updated_at'] -and $null -ne $item.updated_at){
   if($item.updated_at -isnot [string]){throw 'Invalid cloud response.'}
   [void][DateTimeOffset]::TryParse([string]$item.updated_at,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$updated)
  }
  $items.Add([PSCustomObject]@{Id=$id;Title=$title;State=$status;Updated=$updated})
 }
 return [PSCustomObject]@{Tasks=$items.ToArray();Cursor=$cursor}
}

function Get-CodexCloudExecutable {
 $commands=@(Get-Command -Name 'codex.exe' -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
 foreach($path in $commands){if([IO.File]::Exists($path)){return [IO.Path]::GetFullPath($path)}}
 if($env:LOCALAPPDATA){
  $candidate=Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'
  if([IO.File]::Exists($candidate)){return [IO.Path]::GetFullPath($candidate)}
 }
 try{
  $packages=@(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
  foreach($package in $packages){
   $candidate=Join-Path $package.InstallLocation 'app\resources\codex.exe'
   if([IO.File]::Exists($candidate)){return [IO.Path]::GetFullPath($candidate)}
  }
 }catch{}
 return ''
}

function New-CodexCloudController {
 param([bool]$Enabled=$false,[string]$FixtureExecutable='')
 return [PSCustomObject]@{
  Enabled=$Enabled;FixtureExecutable=$FixtureExecutable;Executable='';Request=$null;Tasks=@();LastError='';Partial=$false;Scanned=$false
  NextScan=[DateTimeOffset]::MinValue;Deadline=[DateTimeOffset]::MinValue;Pages=0;Incoming=@()
  SeenIds=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
  SeenCursors=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
 }
}

function Set-CodexCloudControllerEnabled {
 param([Parameter(Mandatory=$true)]$Controller,[bool]$Enabled)
 if($null -ne $Controller.Request){$Controller.Request.Cancel();$Controller.Request.Dispose();$Controller.Request=$null}
 $Controller.Enabled=$Enabled;$Controller.Tasks=@();$Controller.Incoming=@();$Controller.LastError='';$Controller.Partial=$false;$Controller.Scanned=$false
 $Controller.NextScan=[DateTimeOffset]::MinValue;$Controller.Pages=0
}

function ConvertTo-CodexCloudMonitorTasks {
 param([object[]]$Tasks,[string]$CloudPrefix,[string]$DefaultTitle,[string]$Unconfirmed)
 foreach($item in @($Tasks)){
  if($item.State -eq 'terminal'){continue}
  $title=if($item.Title){[string]$item.Title}else{$DefaultTitle}
  $updated=if($item.Updated -eq [DateTimeOffset]::MinValue){[DateTime]::MinValue}else{$item.Updated.LocalDateTime}
  [PSCustomObject]@{Id=[string]$item.Id;Title=$CloudPrefix+$title;Activity=$Unconfirmed;ActivityGenerated=$true;Active=$false;Paused=$false;Progress=$null;ProgressKind='none';ProgressBasis='task';Provider='codex';ProviderName='Codex';Status=$Unconfirmed;Updated=$updated;Started=[DateTime]::MinValue;StartKey='';Steps=@();Source='Codex Cloud';PlanConfirmed=$false}
 }
}

function Update-CodexCloudController {
 param([Parameter(Mandatory=$true)]$Controller,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if(-not $Controller.Enabled){return}
 if($null -ne $Controller.Request){
  if(-not $Controller.Request.Completed -and $Now -ge $Controller.Deadline){$Controller.Request.Cancel()}
  if(-not $Controller.Request.Completed){return}
  $result=$Controller.Request.GetResult();$Controller.Request.Dispose();$Controller.Request=$null
  try{
   if($null -eq $result -or -not $result.Ok){throw 'Cloud command failed.'}
   $page=ConvertFrom-CodexCloudPage ([string]$result.Json)
   foreach($item in $page.Tasks){if(-not $Controller.SeenIds.Add([string]$item.Id)){throw 'Duplicate cloud task.'}}
   $Controller.Incoming=@($Controller.Incoming)+@($page.Tasks);$Controller.Pages++
   if($page.Cursor -and $Controller.Pages -lt 5){
    if(-not $Controller.SeenCursors.Add([string]$page.Cursor) -or $Now -ge $Controller.Deadline){throw 'Invalid cloud cursor.'}
    $remaining=[Math]::Max(1,[int][Math]::Min(12000,($Controller.Deadline-$Now).TotalMilliseconds))
    $Controller.Request=[AITaskMonitor.CodexCloud.Command]::new([string]$Controller.Executable,[string]$page.Cursor,$remaining)
    return
   }
   $Controller.Partial=[bool]$page.Cursor
   $next=New-Object 'Collections.Generic.List[object]'
   foreach($item in $Controller.Incoming){if($item.State -ne 'terminal'){$next.Add($item)}}
   if($Controller.Partial){foreach($old in $Controller.Tasks){if(-not $Controller.SeenIds.Contains([string]$old.Id)){$next.Add($old)}}}
   $Controller.Tasks=$next.ToArray();$Controller.LastError='';$Controller.Scanned=$true;$Controller.Incoming=@();$Controller.NextScan=$Now.AddSeconds(30)
  }catch{
   $Controller.LastError='unavailable';$Controller.Incoming=@();$Controller.NextScan=$Now.AddSeconds(30)
  }
 }
 if($null -eq $Controller.Request -and $Now -ge $Controller.NextScan){
  try{
   $executable=if($Controller.FixtureExecutable){$Controller.FixtureExecutable}else{Get-CodexCloudExecutable}
   if(-not $executable -or -not [IO.File]::Exists($executable)){throw 'Codex command unavailable.'}
   $Controller.Executable=$executable
   $Controller.Pages=0;$Controller.Incoming=@();$Controller.SeenIds.Clear();$Controller.SeenCursors.Clear();$Controller.Deadline=$Now.AddSeconds(30)
   $Controller.Request=[AITaskMonitor.CodexCloud.Command]::new($executable,'',12000)
  }catch{$Controller.LastError='unavailable';$Controller.NextScan=$Now.AddSeconds(30)}
 }
}
