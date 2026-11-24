$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'The synthetic source action check requires STA.'}
$userPath=[Environment]::GetEnvironmentVariable('PATH','User');$machinePath=[Environment]::GetEnvironmentVariable('PATH','Machine')
Add-Type -AssemblyName PresentationFramework
function Require([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Tr([string]$value){return $value}
function Invoke-HiddenProviderSetup {throw 'Synthetic setup failure.'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'),[ref]$tokens,[ref]$errors)
Require ($errors.Count -eq 0) 'The production source action did not parse.'
$status=$ast.Find({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -ceq 'Update-ClaudeSourceStatus'},$true)
$actions=@($ast.FindAll({param($item)$item -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $item.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $item.Expression.VariablePath.UserPath -ceq 'claudeSourceAction' -and [string]$item.Member.Value -ceq 'Add_Click'},$true))
Require ($null -ne $status -and $actions.Count -eq 1 -and $actions[0].Arguments.Count -eq 1) 'The production source action was not identified.'
. ([scriptblock]::Create($status.Extent.Text))
$body=$actions[0].Arguments[0].ScriptBlock.Extent.Text.Trim()
if($body.StartsWith('{') -and $body.EndsWith('}')){$body=$body.Substring(1,$body.Length-2)}
$needle='Join-Path $PSScriptRoot "Configure-ClaudeIntegration.ps1"'
Require ($body.Contains($needle)) 'The synthetic source-action path could not be isolated.'
$body=$body.Replace($needle,'$script:syntheticConfigScript')
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=[IO.Path]::GetFullPath((Join-Path $temp ('aitm-source-action-'+[Guid]::NewGuid().ToString('N'))))
Require ($root.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe synthetic source-action fixture.'
[void][IO.Directory]::CreateDirectory($root)
try{
 $script:syntheticConfigScript=Join-Path $root 'synthetic-config.ps1'
 $script:sourceErrors=@();$script:sourcePartialData=@();$claudeSourceStatus=[Windows.Controls.TextBlock]::new()
 foreach($mode in @('missing','failure')){
  if($mode -ceq 'failure'){[IO.File]::WriteAllText($script:syntheticConfigScript,'synthetic')}
  $claudeSourceAction=[Windows.Controls.Button]::new();$claudeSourceAction.Tag='Install'
  $script:claudeSourceStatusContext=[PSCustomObject]@{Connection='connected';Installation='available'}
  $handler=[Windows.RoutedEventHandler]([scriptblock]::Create($body));$claudeSourceAction.Add_Click($handler)
  $claudeSourceAction.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  $reported=$claudeSourceStatus.Text
  Require (-not [string]::IsNullOrEmpty($reported) -and $null -eq $script:claudeSourceStatusContext) ('The '+$mode+' action did not clear the stale status context.')
  Update-ClaudeSourceStatus
  Require ($claudeSourceStatus.Text -ceq $reported) ('A later snapshot overwrote the '+$mode+' action error.')
 }
 Write-Output 'Claude source action: missing configuration and setup failure survived a later status update.'
}finally{
 $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $root).Path)
 if($resolved -cne $root -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic source-action cleanup.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 if(-not [string]::Equals($userPath,[Environment]::GetEnvironmentVariable('PATH','User'),[StringComparison]::Ordinal) -or -not [string]::Equals($machinePath,[Environment]::GetEnvironmentVariable('PATH','Machine'),[StringComparison]::Ordinal)){throw 'Persistent PATH changed.'}
}
