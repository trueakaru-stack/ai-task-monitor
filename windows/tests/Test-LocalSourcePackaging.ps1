$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 $app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\app'))
 $build=[IO.File]::ReadAllText((Join-Path $app 'Build-Installer-v2.ps1'))
 $extractor=[IO.File]::ReadAllText((Join-Path $app 'CodexProgressInstaller.cs'))
 $store=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\msix\Build-StorePackage.ps1'))
 $inventory=@(([IO.File]::ReadAllText((Join-Path $app 'Uninstall-Inventory.json'))|ConvertFrom-Json))
 foreach($name in @('ClaudeLoopBackground.cs','CodexTitlesCore.cs','CodexAgentRetention.ps1','CodexAgentRetentionAdapter.ps1',
  'LocalReadOwner.cs','LocalSourceClient.ps1','LocalSourceCore.ps1','LocalSourceWorker.ps1','DiagnosticClient.ps1','DiagnosticWorker.ps1')){
  if(-not [IO.File]::Exists((Join-Path $app $name))){throw 'A local source component is missing.'}
  if(-not $build.Contains("'$name'),$name")){throw 'An installer resource is missing.'}
  if(-not $extractor.Contains(('Extract(installGuard, "{0}", Path.Combine(stageDirectory, "{0}"))' -f $name))){throw 'An installer extraction is missing.'}
  if(-not $store.Contains("'$name'")){throw 'A store package component is missing.'}
  if(@($inventory|Where-Object {$_ -ceq $name}).Count -ne 1){throw 'An uninstall entry is missing or duplicated.'}
 }
 Write-Output 'Local source packaging declarations: installer resources, extraction, store layout and uninstall inventory agree.'
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the packaging declaration check.'}
}
