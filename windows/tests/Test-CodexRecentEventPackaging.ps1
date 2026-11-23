param([string]$InstallerPath='')
$ErrorActionPreference='Stop'
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
$name='CodexRecentEventObserver.cs'
$source=Join-Path $app $name
if(-not [IO.File]::Exists($source)){throw 'The observer source is missing.'}
$build=[IO.File]::ReadAllText((Join-Path $app 'Build-Installer-v2.ps1'))
$extractor=[IO.File]::ReadAllText((Join-Path $app 'CodexProgressInstaller.cs'))
$store=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\msix\Build-StorePackage.ps1'))
$inventory=@(([IO.File]::ReadAllText((Join-Path $app 'Uninstall-Inventory.json'))|ConvertFrom-Json))
if(-not $build.Contains("'CodexRecentEventObserver.cs'),CodexRecentEventObserver.cs")){throw 'The installer build is missing the observer resource.'}
if(-not $extractor.Contains('Extract(installGuard, "CodexRecentEventObserver.cs", Path.Combine(stageDirectory, "CodexRecentEventObserver.cs"))')){throw 'The installer does not extract the observer.'}
if(-not $store.Contains("'CodexRecentEventObserver.cs'")){throw 'The Store package is missing the observer.'}
if($inventory -cnotcontains $name){throw 'The uninstall inventory is missing the observer.'}
if($InstallerPath){
 $installer=[IO.Path]::GetFullPath($InstallerPath)
 $assembly=[Reflection.Assembly]::ReflectionOnlyLoadFrom($installer)
 if($assembly.GetManifestResourceNames() -cnotcontains $name){throw 'The built installer is missing the observer resource.'}
 $stream=$assembly.GetManifestResourceStream($name)
 if($null -eq $stream){throw 'The observer installer resource cannot be opened.'}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{
  $packaged=[BitConverter]::ToString($sha.ComputeHash($stream))
  $file=[IO.File]::OpenRead($source)
  try{$expected=[BitConverter]::ToString($sha.ComputeHash($file))}finally{$file.Dispose()}
 }finally{$sha.Dispose();$stream.Dispose()}
 if($packaged -cne $expected){throw 'The packaged observer differs from its source.'}
 Write-Output 'Observer installer resource and source hashes match.'
}else{Write-Output 'Observer installer, Store and uninstall inventories include the source; built payload not checked.'}
