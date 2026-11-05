param([string]$FixturePython='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '../app/integrations/HermesRuntime.ps1')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-hermes-runtime-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path.'}
[void][IO.Directory]::CreateDirectory($root)
$old=@{}
foreach($name in @('LOCALAPPDATA','HERMES_HOME','HERMES_MANAGED_DIR','HERMES_CONFIG_BACKEND')){$old[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
 $profileName=-join @(0x41f,0x440,0x43e,0x444,0x438,0x43b,0x44c | ForEach-Object {[char]$_})
 $local=Join-Path $root $profileName;$hermesRoot=Join-Path $local 'hermes';$project=Join-Path $hermesRoot 'hermes-agent'
 $app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../app'))
 foreach($dir in @($hermesRoot,(Join-Path $project 'hermes_cli'),(Join-Path $project 'pm'))){[void][IO.Directory]::CreateDirectory($dir)}
 [IO.File]::WriteAllText((Join-Path $hermesRoot 'config.yaml'),'unrelated: KEEP')
 [IO.File]::WriteAllText((Join-Path $project 'hermes_cli\active_sessions.py'),'fixture')
 [IO.File]::WriteAllText((Join-Path $project 'pm\publication.py'),'fixture')
 $env:LOCALAPPDATA=$local
 foreach($name in @('HERMES_HOME','HERMES_MANAGED_DIR','HERMES_CONFIG_BACKEND')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
 if($null -ne (Get-HermesRuntimeContext -AppRoot $app)){throw 'A missing Python environment was accepted.'}
 $legacy=Join-Path $project 'venv';[void][IO.Directory]::CreateDirectory((Join-Path $legacy 'Scripts'))
 [IO.File]::WriteAllText((Join-Path $legacy 'pyvenv.cfg'),'fixture')
 [IO.File]::WriteAllText((Join-Path $legacy 'Scripts\python.exe'),'fixture')
 $found=Get-HermesRuntimeContext -AppRoot $app
 if($null -eq $found -or $found.Python -cne (Join-Path $legacy 'Scripts\python.exe')){throw 'The legacy Python environment was not discovered.'}
 $python=$FixturePython
 if(-not $python){$python=(Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source}
 $program='import hashlib,sys;from pathlib import Path;print(hashlib.sha256(str(Path(sys.argv[1]).resolve()).encode()).hexdigest()[:16])'
 $pythonOutput=@(& $python -c $program $project)
 if($LASTEXITCODE -ne 0 -or $pythonOutput.Count -ne 1){throw 'Could not derive the upstream install key.'}
 $key=([string]$pythonOutput[0]).Trim()
 if($key -cnotmatch '^[a-f0-9]{16}$'){throw 'Could not derive the upstream install key.'}
 $install=Join-Path (Join-Path $hermesRoot 'installs') $key
 $generation=Join-Path $install 'environments\generation-1'
 [void][IO.Directory]::CreateDirectory((Join-Path $generation 'Scripts'))
 [IO.File]::WriteAllText((Join-Path $generation 'pyvenv.cfg'),'fixture')
 [IO.File]::WriteAllText((Join-Path $generation 'Scripts\python.exe'),'fixture')
 $facts=Join-Path $install 'facts.json'
 $valid=@{packages=@{venv=@{environment=$generation}}} | ConvertTo-Json -Depth 5 -Compress
 [IO.File]::WriteAllText($facts,$valid,[Text.UTF8Encoding]::new($false))
 $found=Get-HermesRuntimeContext -AppRoot $app
 if($null -eq $found -or $found.Python -cne (Join-Path $generation 'Scripts\python.exe')){throw 'The committed environment was not selected.'}
 $profile=Join-Path $hermesRoot 'profiles\one';[void][IO.Directory]::CreateDirectory($profile);$env:HERMES_HOME=$profile
 $found=Get-HermesRuntimeContext -AppRoot $app
 if($null -eq $found -or $found.Home -cne $hermesRoot){throw 'The named profile did not resolve to its shared home.'}
 $customHome=Join-Path $hermesRoot 'custom-install';$customProject=Join-Path $customHome 'hermes-agent'
 foreach($dir in @($customHome,(Join-Path $customProject 'hermes_cli'),(Join-Path $customProject 'pm'),(Join-Path $customProject 'venv\Scripts'))){[void][IO.Directory]::CreateDirectory($dir)}
 [IO.File]::WriteAllText((Join-Path $customHome 'config.yaml'),'custom: KEEP')
 [IO.File]::WriteAllText((Join-Path $customProject 'hermes_cli\active_sessions.py'),'fixture')
 [IO.File]::WriteAllText((Join-Path $customProject 'pm\publication.py'),'fixture')
 [IO.File]::WriteAllText((Join-Path $customProject 'venv\pyvenv.cfg'),'fixture')
 [IO.File]::WriteAllText((Join-Path $customProject 'venv\Scripts\python.exe'),'fixture')
 $env:HERMES_HOME=$customHome
 $found=Get-HermesRuntimeContext -AppRoot $app
 if($null -eq $found -or $found.Home -cne $customHome){throw 'A custom installation under the default root was misidentified.'}
 $env:HERMES_CONFIG_BACKEND='remote'
 if(-not (Get-HermesRuntimeContext -AppRoot $app).Managed){throw 'A remote config backend was not treated as uncertain.'}
 $env:HERMES_CONFIG_BACKEND='file'
 if((Get-HermesRuntimeContext -AppRoot $app).Managed){throw 'The default file backend was rejected.'}
 $env:HERMES_MANAGED_DIR='synthetic-directory'
 if(-not (Get-HermesRuntimeContext -AppRoot $app).Managed){throw 'A managed configuration was not treated as uncertain.'}
 foreach($name in @('HERMES_MANAGED_DIR','HERMES_CONFIG_BACKEND')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
 foreach($bad in @('relative','C:relative','\relative','\\server','\\?\C:\device')){
  $env:HERMES_HOME=$bad
  if($null -ne (Get-HermesRuntimeContext -AppRoot $app)){throw 'A non-absolute Hermes home was accepted.'}
 }
 $env:HERMES_HOME=$hermesRoot
 $outside=@{packages=@{venv=@{environment=$legacy}}} | ConvertTo-Json -Depth 5 -Compress
 [IO.File]::WriteAllText($facts,$outside,[Text.UTF8Encoding]::new($false))
 if($null -ne (Get-HermesRuntimeContext -AppRoot $app)){throw 'A committed environment outside the installation was accepted.'}
 [IO.File]::WriteAllText($facts,'{invalid',[Text.UTF8Encoding]::new($false))
 if($null -ne (Get-HermesRuntimeContext -AppRoot $app)){throw 'Malformed facts fell back to another environment.'}
 if([IO.File]::ReadAllText((Join-Path $hermesRoot 'config.yaml')) -ne 'unrelated: KEEP'){throw 'Runtime discovery changed Hermes settings.'}
 'Hermes runtime discovery: isolated environments, profile homes and invalid facts passed.'
}finally{
 foreach($name in $old.Keys){[Environment]::SetEnvironmentVariable($name,$old[$name],'Process')}
 if(Test-Path -LiteralPath $root){
  $resolved=(Resolve-Path -LiteralPath $root).Path
  if($resolved -ne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
