function Get-DeepSeekUncertainScopes {
 param([Parameter(Mandatory=$true)]$Controller)
 $result=New-Object 'Collections.Generic.List[string]'
 # Two profiles claiming the same namespace cannot be separated by v1 frames.
 $owners=@{}
 foreach($profile in @($Controller.Profiles)){
  $scope=[string]$profile.Scope
  if($scope -cnotmatch '^[a-f0-9]{32}$'){continue}
  if($owners.ContainsKey($scope)){$result.Add($scope)}else{$owners[$scope]=$true}
 }
 foreach($name in @($Controller.Seen.Keys)){
  $scope=[string]$Controller.Seen[$name]
  if($scope -cnotmatch '^[a-f0-9]{32}$'){continue}
  $match=@($Controller.Profiles | Where-Object {$_.Name -ceq $name})
  if($Controller.LastError -or $match.Count -ne 1 -or $match[0].State -in @('partial','error')){$result.Add($scope)}
 }
 return $result.ToArray()
}
