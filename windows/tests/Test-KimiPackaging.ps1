$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
$build=[IO.File]::ReadAllText((Join-Path $app 'Build-Installer-v2.ps1'))
$store=[IO.File]::ReadAllText([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../msix/Build-StorePackage.ps1')))
$entries=@(
 @('KimiRuntime.ps1','integrations.KimiRuntime.ps1'),
 @('kimi-integration.mjs','integrations.kimi-integration.mjs'),
 @('kimi-setup.mjs','integrations.kimi-setup.mjs'),
 @('kimi-plugin\kimi.plugin.json','integrations.kimi-plugin.kimi.plugin.json'),
 @('kimi-plugin\kimi-hook.mjs','integrations.kimi-plugin.kimi-hook.mjs'),
 @('kimi-plugin\kimi-observer.mjs','integrations.kimi-plugin.kimi-observer.mjs'),
 @('kimi-plugin\provider-transport.mjs','integrations.kimi-plugin.provider-transport.mjs')
)
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-kimi-packaging-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($root)
try {
 $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
 if(-not [IO.File]::Exists($compiler)){throw 'C# compiler is unavailable.'}
 $output=Join-Path $root 'fixture.dll'
 $compileArgs=@('/nologo','/target:library',"/out:$output",'/reference:System.Windows.Forms.dll')
 foreach($entry in $entries){
  $path=Join-Path (Join-Path $app 'integrations') $entry[0]
  if(-not [IO.File]::Exists($path) -or -not $build.Contains($entry[1]) -or -not $store.Contains([IO.Path]::GetFileName($path))){throw 'A Kimi packaging source or resource is missing.'}
  $compileArgs+="/resource:$path,$($entry[1])"
 }
 $compileArgs+=(Join-Path $app 'CodexProgressInstaller.cs')
 & $compiler $compileArgs
 if($LASTEXITCODE -ne 0){throw 'Kimi extraction fixture did not compile.'}
 $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($output))
 $type=$assembly.GetType('CodexProgressInstaller',$true)
 $extract=$type.GetMethod('Extract',[Reflection.BindingFlags]'NonPublic,Static')
 foreach($entry in $entries){
  $destination=Join-Path $root ([Guid]::NewGuid().ToString('N'))
  $invokeArgs=[object[]]::new(2)
  $invokeArgs[0]=[string]$entry[1];$invokeArgs[1]=[string]$destination
  [void]$extract.Invoke($null,$invokeArgs)
  $source=Join-Path (Join-Path $app 'integrations') $entry[0]
  if((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash){throw 'An extracted Kimi resource changed.'}
 }
 'Kimi packaging: source declarations and isolated resource extraction verified.'
} finally {
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
