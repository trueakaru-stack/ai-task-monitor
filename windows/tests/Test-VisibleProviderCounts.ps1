param([Parameter(Mandatory=$true)][string]$SourcePath)

$ErrorActionPreference='Stop'
$tokens=$null;$parseErrors=$null
$source=[System.Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($SourcePath),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count -ne 0){throw 'The source could not be parsed.'}
$definitions=@($source.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Render-ProviderTabs'},$true))
if($definitions.Count -ne 1){throw 'The provider-tab renderer was not found exactly once.'}
Invoke-Expression $definitions[0].Extent.Text
Add-Type -AssemblyName PresentationFramework

$script:selectedProvider='all';$script:providerLastSelected='';$script:providerTabsFingerprint=''
$script:resolvedLanguage='ru';$script:palette=@{Surface='surface';Primary='primary';Hover='hover'}
$script:providerTabsHost=[pscustomobject]@{Visibility='Collapsed'}
$script:providerTabsPanel=[pscustomobject]@{Children=[Collections.ArrayList]::new()}
$script:providerTabsScroll=[pscustomobject]@{HorizontalOffset=0.0}
$script:providerTabsHost|Add-Member ScriptMethod UpdateLayout {}
$script:providerTabsScroll|Add-Member ScriptMethod ScrollToHorizontalOffset {param($offset) $this.HorizontalOffset=$offset}
function Tr([string]$text){return $text}
function Update-ProviderTabSizing{}
function Update-SquircleGeometry{}
function Add-ProviderTab([string]$id,[string]$label,[int]$count){
 $tab=[pscustomobject]@{Tag=$id;Label=$label;Count=$count;IsKeyboardFocusWithin=$false;Margin=$null}
 $tab|Add-Member ScriptMethod BringIntoView {}
 $tab|Add-Member ScriptMethod Focus {return $true}
 $script:providerTabsPanel.Children.Add($tab)|Out-Null
}

$script:checks=0
function Check([bool]$condition,[string]$message){$script:checks++;if(-not $condition){throw $message}}
function Check-Counts([int]$all,[int]$codex,[int]$claude){
 $tabs=@{};foreach($tab in $script:providerTabsPanel.Children){$tabs[[string]$tab.Tag]=$tab}
 Check ($tabs.Count -eq 3) 'Expected three provider tabs.'
 Check ($tabs['all'].Count -eq $all) 'The All count must include every displayed task.'
 Check ($tabs['codex'].Count -eq $codex) 'The Codex count must include every displayed Codex task.'
 Check ($tabs['claude'].Count -eq $claude) 'The Claude count must include every displayed Claude task.'
}

$tasks=@(
 [pscustomobject]@{Provider='codex';Active=$true},
 [pscustomobject]@{Provider='codex';Active=$false},
 [pscustomobject]@{Provider='claude';Active=$false},
 [pscustomobject]@{Provider='claude';Active=$false}
)
Render-ProviderTabs $tasks
Check-Counts 4 2 2
$firstFingerprint=$script:providerTabsFingerprint
$tasks=@($tasks[0..2])
Render-ProviderTabs $tasks
Check ($script:providerTabsFingerprint -ne $firstFingerprint) 'Removing an unconfirmed task must refresh the cached tabs.'
Check-Counts 3 2 1
$script:selectedProvider='claude'
Render-ProviderTabs $tasks
Check ($script:selectedProvider -eq 'claude') 'The selected provider changed.'
Check-Counts 3 2 1
$tasks=@([pscustomobject]@{Provider='codex';Active=$false},[pscustomobject]@{Provider='claude';Active=$false})
Render-ProviderTabs $tasks
Check-Counts 2 1 1
Render-ProviderTabs @([pscustomobject]@{Provider='claude';Active=$false})
Check ($script:providerTabsHost.Visibility -eq 'Collapsed' -and $script:selectedProvider -eq 'all') 'A single provider must hide the tabs and reset the filter.'
Write-Output "Provider tab counts: $script:checks synthetic checks passed."
