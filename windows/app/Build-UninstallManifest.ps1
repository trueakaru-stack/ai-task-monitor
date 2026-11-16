param(
 [Parameter(Mandatory=$true)][hashtable]$Files,
 [Parameter(Mandatory=$true)][string]$TemplatePath,
 [Parameter(Mandatory=$true)][string]$OutputPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$encoding=[Text.UTF8Encoding]::new($false,$true)
$inventoryPath=Join-Path $PSScriptRoot 'Uninstall-Inventory.json'
$expected=@(($encoding.GetString([IO.File]::ReadAllBytes($inventoryPath))|ConvertFrom-Json))
$unique=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($name in $expected){
 if($name -isnot [string] -or $name -notmatch '^[A-Za-z0-9_. -]+(?:/[A-Za-z0-9_. -]+)*$' -or
    @($name.Split('/')|Where-Object {$_ -in @('.','..') -or $_.EndsWith('.') -or $_.EndsWith(' ')}).Count -gt 0 -or
    -not $unique.Add($name)){throw 'Invalid uninstall inventory.'}
}
if($Files.Count -ne $expected.Count){throw 'The uninstall inventory does not match the installer payload.'}
$hashes=[ordered]@{}
foreach($name in $expected){
 if(-not $Files.ContainsKey($name)){throw 'An installer payload entry is missing from the uninstall inventory.'}
 $path=[IO.Path]::GetFullPath([string]$Files[$name])
 if(-not [IO.File]::Exists($path)){throw 'An installer payload file is missing.'}
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{
  if($stream.Length -gt 134217728){throw 'An installer payload exceeds the uninstall size limit.'}
  $algorithm=[Security.Cryptography.SHA256]::Create()
  try{$hashes[$name]=[BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','')}finally{$algorithm.Dispose()}
 }finally{$stream.Dispose()}
}
$manifest=[ordered]@{version=1;files=$hashes}|ConvertTo-Json -Compress -Depth 4
$encoded=[Convert]::ToBase64String($encoding.GetBytes($manifest))
$template=$encoding.GetString([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($TemplatePath)))
$manifestLine='$embeddedManifest = '+"'BUILD_MANIFEST_REQUIRED'"
$selfLine='$embeddedSelfHash = '+"'"+('0'*64)+"'"
if($template.IndexOf($manifestLine,[StringComparison]::Ordinal) -lt 0 -or
   $template.IndexOf($manifestLine,[StringComparison]::Ordinal) -ne $template.LastIndexOf($manifestLine,[StringComparison]::Ordinal) -or
   $template.IndexOf($selfLine,[StringComparison]::Ordinal) -lt 0 -or
   $template.IndexOf($selfLine,[StringComparison]::Ordinal) -ne $template.LastIndexOf($selfLine,[StringComparison]::Ordinal)){throw 'Uninstaller template markers are invalid.'}
$rendered=$template.Replace($manifestLine,('$embeddedManifest = '+"'"+$encoded+"'"))
$algorithm=[Security.Cryptography.SHA256]::Create()
try{$selfHash=[BitConverter]::ToString($algorithm.ComputeHash($encoding.GetBytes($rendered))).Replace('-','')}finally{$algorithm.Dispose()}
$rendered=$rendered.Replace($selfLine,('$embeddedSelfHash = '+"'"+$selfHash+"'"))
$destination=[IO.Path]::GetFullPath($OutputPath)
$stream=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$bytes=$encoding.GetBytes($rendered);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
