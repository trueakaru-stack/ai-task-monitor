$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '../app/integrations/DeepSeekRuntime.ps1')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$fixture=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-discovery-'+[Guid]::NewGuid().ToString('N'))))
if(-not $fixture.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($fixture)
$old=@{}
foreach($name in @('PATH','USERPROFILE','APPDATA','DSH_HOME')){$old[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
 $bin=Join-Path $fixture 'bin';$app=Join-Path $fixture 'app';$assets=Join-Path $app 'integrations'
 foreach($directory in @($bin,$assets,(Join-Path $bin 'node_modules\@deepseek-ai\dsh'),(Join-Path $bin 'node_modules\pnpm\bin'))){[void][IO.Directory]::CreateDirectory($directory)}
 foreach($name in @('node.exe','dsh.cmd','pnpm.cmd')){[IO.File]::WriteAllText((Join-Path $bin $name),'fixture')}
 [IO.File]::WriteAllText((Join-Path $assets 'deepseek-setup.mjs'),'fixture')
 [IO.File]::WriteAllText((Join-Path $bin 'node_modules\@deepseek-ai\dsh\package.json'),'{}')
 [IO.File]::WriteAllText((Join-Path $bin 'node_modules\pnpm\bin\pnpm.mjs'),'fixture')
 $env:PATH=$bin;$env:USERPROFILE=$fixture;$env:APPDATA=$fixture;$env:DSH_HOME=Join-Path $fixture 'custom-home'
 $context=Get-DeepSeekRuntimeContext -AppRoot $app
 if($null -eq $context -or $context.Home -cne $env:DSH_HOME -or $context.Node -cne (Join-Path $bin 'node.exe')){throw 'The isolated installation was not discovered.'}
 foreach($invalidHome in @('relative-path','C:relative','C:','\relative','/relative','\\server','\\?\C:\device')){
  $env:DSH_HOME=$invalidHome
  if($null -ne (Get-DeepSeekRuntimeContext -AppRoot $app)){throw "A non-absolute DeepSeek home must not be guessed: $invalidHome"}
 }
 $env:DSH_HOME='\\server\share\custom-home'
 if($null -eq (Get-DeepSeekRuntimeContext -AppRoot $app)){throw 'A complete UNC DeepSeek home was rejected.'}
 $env:DSH_HOME=Join-Path $fixture 'custom-home'
 [IO.File]::Delete((Join-Path $bin 'dsh.cmd'))
 if($null -ne (Get-DeepSeekRuntimeContext -AppRoot $app)){throw 'A missing DeepSeek installation must not be claimed.'}
 'DeepSeek discovery: isolated installation, fully qualified home, and UNC paths verified.'
}finally{
 foreach($name in $old.Keys){[Environment]::SetEnvironmentVariable($name,$old[$name],'Process')}
 if(Test-Path -LiteralPath $fixture){
  $resolved=(Resolve-Path -LiteralPath $fixture).Path
  if($resolved -ne $fixture -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
