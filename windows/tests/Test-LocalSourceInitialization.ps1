$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-source-initialize-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic source directory.'}
[void][IO.Directory]::CreateDirectory($root)
try{
 . (Join-Path $PSScriptRoot '..\app\LocalSourceCore.ps1')
 Initialize-LocalSourceReader -CodexHome (Join-Path $root 'codex') -ProfileRoot (Join-Path $root 'profile') -DataDirectory (Join-Path $root 'data') -MonitorStartedUtc ([DateTime]::UtcNow)
 Write-Output 'The synthetic local source initialized.'
}finally{
 foreach($name in @('codexTitleReader','codexRolloutReader','codexRecentEventObserver','codexRootEvidenceReader')){
  $item=Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
  if($null -ne $item -and $null -ne $item.Value){$item.Value.Dispose()}
 }
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic source cleanup target.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
