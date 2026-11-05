$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
$build=[IO.File]::ReadAllText((Join-Path $app 'Build-Installer-v2.ps1'))
$installer=[IO.File]::ReadAllText((Join-Path $app 'CodexProgressInstaller.cs'))
$store=[IO.File]::ReadAllText([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../msix/Build-StorePackage.ps1')))
$entries=@('HermesRuntime.ps1','HermesBridgeProcess.cs','hermes-setup.py','hermes-manager.py','provider_bundle.py',
 'hermes-entry.py','hermes-plugin.yaml','hermes_observer.py','provider_hooks.py','provider_sender.py','provider_transport.py','ruamel.yaml-0.18.16-py3-none-any.whl','ruamel.yaml-LICENSE.txt')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-hermes-packaging-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($root)
try{
 $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
 if(-not [IO.File]::Exists($compiler)){throw 'C# compiler is unavailable.'}
 $output=Join-Path $root 'fixture.dll'
 $compileArgs=@('/nologo','/target:library',"/out:$output",'/reference:System.Windows.Forms.dll')
 foreach($name in $entries){
  $path=Join-Path (Join-Path $app 'integrations') $name
  $resource='integrations.'+$name
  if(-not [IO.File]::Exists($path) -or -not $build.Contains($resource) -or -not $store.Contains("'$name'") -or -not $installer.Contains('"'+$name+'"')){throw ('A Hermes packaging declaration is missing: '+$name)}
  $compileArgs+="/resource:$path,$resource"
 }
 $compileArgs+=(Join-Path $app 'CodexProgressInstaller.cs')
 & $compiler $compileArgs
 if($LASTEXITCODE -ne 0){throw 'Hermes extraction fixture did not compile.'}
 $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($output))
 $extract=$assembly.GetType('CodexProgressInstaller',$true).GetMethod('Extract',[Reflection.BindingFlags]'NonPublic,Static')
 foreach($name in $entries){
  $destination=Join-Path $root ([Guid]::NewGuid().ToString('N'))
  $invokeArgs=[object[]]::new(2);$invokeArgs[0]='integrations.'+$name;$invokeArgs[1]=[string]$destination
  [void]$extract.Invoke($null,$invokeArgs)
  $source=Join-Path (Join-Path $app 'integrations') $name
  if((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash){throw ('An extracted Hermes resource changed: '+$name)}
 }
 'Hermes packaging: source declarations and isolated resource extraction verified.'
}finally{
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
