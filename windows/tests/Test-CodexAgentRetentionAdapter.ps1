$ErrorActionPreference='Stop'
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
try{
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The application source did not parse.'}
 $definitions=foreach($name in @('Prop','Group-CodexTasks')){
  $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
  if($null -eq $node){throw 'A grouping function is missing.'};$node.Extent.Text
 }
 . ([scriptblock]::Create(($definitions -join "`n")))
 . (Join-Path $PSScriptRoot '..\app\CodexAgentRetention.ps1')
 . (Join-Path $PSScriptRoot '..\app\CodexAgentRetentionAdapter.ps1')
 function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
 $parentId='50000000-0000-0000-0000-000000000001';$childId='50000000-0000-0000-0000-000000000002'
 $parent=[PSCustomObject]@{Id=$parentId;Provider='codex';Source='local';Title='Synthetic parent';ActivityIdentity='root-file';Active=$true;Paused=$false;Status='running';Activity='Checking'}
 $child=[PSCustomObject]@{Id=$childId;Provider='codex';Source='local';Title='Synthetic child';AgentNickname='reader';ActivityIdentity='child-file';Active=$true;Paused=$false;Status='running';Activity='Checking'}
 $links=@{};$links[$parentId]=[PSCustomObject]@{IsRoot=$true;IdentityToken='root-file'};$links[$childId]=[PSCustomObject]@{IsRoot=$false;ParentThreadId=$parentId;IdentityToken='child-file'}
 $titles=@{};$titles[$parentId]='Synthetic parent';$state=New-CodexAgentRetention
 $pendingChild=$child.PSObject.Copy();$pendingChild.ActivityIdentity=''
 $pendingState=New-CodexAgentRetention
 $pending=Update-CodexAgentRetention -State $pendingState -Tasks @($parent,$pendingChild) -Links $links -SourcePartial $true
 $pendingLinks=Select-CodexRetentionLinks $links $pending
 $pendingGrouped=@(Group-CodexTasks @($parent,$pendingChild) $pendingLinks $titles)
 Require ($pendingGrouped.Count -eq 2 -and @($pendingGrouped|Where-Object {$null -ne $_.PSObject.Properties['RelatedAgentCount']}).Count -eq 0) 'A count appeared before the child identity entered retention.'
 $evidence=Update-CodexAgentRetention -State $state -Tasks @($parent,$child) -Links $links -SourcePartial $true
 $effective=Select-CodexRetentionLinks $links $evidence
 $grouped=@(Group-CodexTasks @($parent,$child) $effective $titles)
 $result=@(Apply-CodexAgentRetention $grouped @($parent,$child) $evidence)
 Require ($result.Count -eq 1 -and $result[0].RelatedAgentCount -eq 1 -and -not $result[0].RelatedAgentsUnconfirmed -and $result[0].RelatedAgents[0].ActivityIdentity -ceq 'child-file') 'Current identity or count was lost by the adapter.'
 $newId='50000000-0000-0000-0000-000000000003';$newChild=$child.PSObject.Copy();$newChild.Id=$newId;$newChild.ActivityIdentity=''
 $withNew=$links.Clone();$withNew[$newId]=[PSCustomObject]@{IsRoot=$false;ParentThreadId=$parentId;IdentityToken='new-child-file'}
 $evidence=Update-CodexAgentRetention -State $state -Tasks @($parent,$child,$newChild) -Links $withNew -SourcePartial $true
 $effective=Select-CodexRetentionLinks $withNew $evidence
 $grouped=@(Group-CodexTasks @($parent,$child,$newChild) $effective $titles)
 $result=@(Apply-CodexAgentRetention $grouped @($parent,$child,$newChild) $evidence)
 Require ($result.Count -eq 2 -and @($result|Where-Object {$_.Id -ceq $newId}).Count -eq 1 -and
  @($result|Where-Object {$_.Id -ceq $parentId -and $_.RelatedAgentCount -eq 1}).Count -eq 1) 'An unverified new child disappeared into a previously accepted group.'
 $newChild.ActivityIdentity='new-child-file'
 $evidence=Update-CodexAgentRetention -State $state -Tasks @($parent,$child,$newChild) -Links $withNew -SourcePartial $true
 $effective=Select-CodexRetentionLinks $withNew $evidence
 $grouped=@(Group-CodexTasks @($parent,$child,$newChild) $effective $titles)
 $result=@(Apply-CodexAgentRetention $grouped @($parent,$child,$newChild) $evidence)
 Require ($result.Count -eq 1 -and $result[0].RelatedAgentCount -eq 2 -and @($result[0].RelatedAgentIds) -ccontains $newId) 'A newly verified child did not join its existing group.'
 # Use a fresh state for the original one-child loss and conflict scenarios.
 $state=New-CodexAgentRetention
 [void](Update-CodexAgentRetention -State $state -Tasks @($parent,$child) -Links $links -SourcePartial $true)
 $onlyRoot=@{};$onlyRoot[$parentId]=$links[$parentId]
 $evidence=Update-CodexAgentRetention -State $state -Tasks @($parent) -Links $onlyRoot -SourcePartial $true
 $effective=Select-CodexRetentionLinks $onlyRoot $evidence
 $result=@(Apply-CodexAgentRetention @($parent) @($parent) $evidence)
 Require ($result.Count -eq 1 -and $result[0].RelatedAgentCount -eq 1 -and $result[0].RelatedAgentsUnconfirmed -and
  $null -eq $result[0].RelatedAgents[0].PSObject.Properties['ActivityIdentity']) 'The missing child was removed or presented as current.'
 $replacement=$parent.PSObject.Copy();$replacement.ActivityIdentity='another-root-file'
 $evidence=Update-CodexAgentRetention -State $state -Tasks @($replacement,$child) -Links $links -SourcePartial $true
 $effective=Select-CodexRetentionLinks $links $evidence
 $result=@(Group-CodexTasks @($replacement,$child) $effective $titles)
 Require ($result.Count -eq 2 -and @($result|Where-Object {$null -ne $_.PSObject.Properties['RelatedAgentCount']}).Count -eq 0) 'A conflicting root received a retained count.'
 Write-Output 'Synthetic retention adapter: verified links, missing agents and conflicting root identity checked.'
}finally{
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or
    -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed during the synthetic check.'}
}
