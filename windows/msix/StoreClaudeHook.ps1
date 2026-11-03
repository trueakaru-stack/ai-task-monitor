function Get-StoreClaudeHookCommand([string]$PackageDirectory) {
 $manifestPath=Join-Path $PackageDirectory 'AppxManifest.xml'
 if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'The Store package manifest is unavailable.'}
 $document=New-Object Xml.XmlDocument
 $document.XmlResolver=$null
 $document.Load($manifestPath)
 $identity=$document.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
 if($null -eq $identity){throw 'The Store package identity is unavailable.'}
 $name=[string]$identity.GetAttribute('Name');$publisher=[string]$identity.GetAttribute('Publisher')
 if($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$' -or -not $publisher -or $publisher.Length -gt 8192){throw 'The Store package identity is invalid.'}
 $nameLiteral="'"+$name.Replace("'","''")+"'"
 $publisherLiteral="'"+$publisher.Replace("'","''")+"'"
 $script='try { $p=@(Get-AppxPackage -Name '+$nameLiteral+' -ErrorAction SilentlyContinue | Where-Object { $_.Publisher -ceq '+$publisherLiteral+' }); if($p.Count -ne 1){exit 0}; $h=Join-Path $p[0].InstallLocation ''ClaudeTaskHook.ps1''; if(Test-Path -LiteralPath $h -PathType Leaf){& $h} } catch { exit 0 }'
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
 return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
}
