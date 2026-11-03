# Public release metadata contains no task data. These helpers do not access the network.
function ConvertTo-ReleaseVersion([string]$value) {
 if($value.Length -gt 80 -or $value -cnotmatch '^v?(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'){return $null}
 $pre=[string]$Matches[4]
 if($pre -and @($pre.Split('.') | Where-Object {$_ -cmatch '^\d+$' -and $_.Length -gt 1 -and $_.StartsWith('0')}).Count){return $null}
 return [PSCustomObject]@{Major=[int]$Matches[1];Minor=[int]$Matches[2];Patch=[int]$Matches[3];Pre=$pre}
}

function Compare-ReleaseVersions($left,$right) {
 foreach($key in @('Major','Minor','Patch')){if($left.$key -lt $right.$key){return -1};if($left.$key -gt $right.$key){return 1}}
 if(-not $left.Pre -and -not $right.Pre){return 0}
 if(-not $left.Pre){return 1};if(-not $right.Pre){return -1}
 $a=$left.Pre.Split('.');$b=$right.Pre.Split('.')
 for($i=0;$i -lt [Math]::Max($a.Length,$b.Length);$i++){
  if($i -ge $a.Length){return -1};if($i -ge $b.Length){return 1}
  $an=$a[$i] -cmatch '^\d+$';$bn=$b[$i] -cmatch '^\d+$'
  if($an -and $bn){if($a[$i].Length -ne $b[$i].Length){if($a[$i].Length -lt $b[$i].Length){return -1}else{return 1}};$c=[string]::CompareOrdinal($a[$i],$b[$i])}
  elseif($an){return -1}elseif($bn){return 1}else{$c=[string]::CompareOrdinal($a[$i],$b[$i])}
  if($c -lt 0){return -1};if($c -gt 0){return 1}
 }
 return 0
}

function Get-ReleaseProperty($item,[string]$name) {
 if($null -eq $item){return $null}
 $prop=$item.PSObject.Properties[$name]
 if($null -eq $prop){return $null}
 return $prop.Value
}

function Get-TrustedReleaseUrl([string]$url,[string]$tag,[string]$asset,[string]$platform) {
 if($tag -cnotmatch '^v?[0-9A-Za-z.-]{1,80}$' -or $asset -cnotmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,127}$'){return $null}
 if($platform -eq 'windows' -and $asset -inotmatch '\.(exe|msi)$'){return $null}
 if($platform -eq 'macos' -and $asset -inotmatch '\.(dmg|pkg)$'){return $null}
 try{$uri=[Uri]$url}catch{return $null}
 $path='/trueakaru-stack/ai-task-monitor/releases/download/'+$tag+'/'+$asset
 if(-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'github.com' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne $path){return $null}
 return $uri.AbsoluteUri
}

function Find-PlatformUpdate([string]$json,[string]$currentVersion,[string]$platform='windows') {
 if($platform -notin @('windows','macos') -or $json.Length -gt 1048576){return $null}
 $current=ConvertTo-ReleaseVersion $currentVersion
 if($null -eq $current){return $null}
 $trimmed=$json.Trim()
 if(-not $trimmed.StartsWith('[') -or -not $trimmed.EndsWith(']')){return $null}
 try{$decoded=ConvertFrom-Json -InputObject $json -ErrorAction Stop}catch{return $null}
 if($null -eq $decoded){return $null}
 if($decoded -is [array]){$releases=$decoded}else{$releases=@($decoded)}
 $best=$null;$bestVersion=$current
 foreach($release in $releases){
  if((Get-ReleaseProperty $release 'draft') -ne $false){continue}
  $tag=[string](Get-ReleaseProperty $release 'tag_name');$version=ConvertTo-ReleaseVersion $tag
  if($null -eq $version -or (Compare-ReleaseVersions $version $bestVersion) -le 0){continue}
  foreach($asset in @(Get-ReleaseProperty $release 'assets')){
   $name=[string](Get-ReleaseProperty $asset 'name');$url=[string](Get-ReleaseProperty $asset 'browser_download_url')
   $safe=Get-TrustedReleaseUrl $url $tag $name $platform
   if($safe){$best=[PSCustomObject]@{Version=$tag.TrimStart('v');Url=$safe};$bestVersion=$version;break}
  }
 }
 return $best
}
