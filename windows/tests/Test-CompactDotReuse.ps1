$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'This WPF control test requires an STA PowerShell process.'
}
Add-Type -AssemblyName PresentationFramework
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The application source failed to parse.'}
$definitions=foreach($name in @('Add-CompactDot','Sync-CompactDots')){
    $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
    if($null -eq $node){throw "Missing function: $name"}
    $node.Extent.Text
}
$checks=@'
$compactDotsPanel=[Windows.Controls.StackPanel]::new()
$window=[PSCustomObject]@{Resources=@{CompactDotStyle=[Windows.Style]::new([Windows.Controls.Button])}}
$script:palette=[PSCustomObject]@{Scroll='#888888'}
$script:accentHex='#0066CC';$script:resolvedLanguage='ru';$script:compactTaskId='first';$script:renderCount=0
function Tr([string]$value){return $value}
function Brush([string]$value){return [Windows.Media.BrushConverter]::new().ConvertFromString($value)}
function Localized-TaskTitle($task){return [string]$task.Title}
function Render-CompactTasks($tasks){$script:renderCount++;Sync-CompactDots $tasks}
$tasks=@([PSCustomObject]@{Id='first';Title='First'},[PSCustomObject]@{Id='second';Title='Second'})
$script:lastAllTasks=$tasks
Sync-CompactDots $tasks
if($compactDotsPanel.Children.Count -ne 2){throw 'The two task buttons were not created.'}
$first=$compactDotsPanel.Children[0];$second=$compactDotsPanel.Children[1]
$tasks[1].Title='Renamed second'
Sync-CompactDots $tasks
if(-not [object]::ReferenceEquals($first,$compactDotsPanel.Children[0]) -or
   -not [object]::ReferenceEquals($second,$compactDotsPanel.Children[1])){throw 'A refresh replaced unchanged task buttons.'}
if([Windows.Automation.AutomationProperties]::GetName($second) -cne 'Показать задачу: Renamed second'){throw 'The accessible button name was not refreshed.'}
Sync-CompactDots @($tasks[1],$tasks[0])
if(-not [object]::ReferenceEquals($first,$compactDotsPanel.Children[0]) -or
   -not [object]::ReferenceEquals($second,$compactDotsPanel.Children[1])){throw 'Reordering unchanged tasks replaced or moved their buttons.'}
$third=[PSCustomObject]@{Id='third';Title='Third'}
Sync-CompactDots @($tasks[1],$tasks[0],$third)
if($compactDotsPanel.Children.Count -ne 3 -or -not [object]::ReferenceEquals($first,$compactDotsPanel.Children[0]) -or
   -not [object]::ReferenceEquals($second,$compactDotsPanel.Children[1])){throw 'Adding a task replaced an existing button.'}
$script:lastAllTasks=@($tasks[0],$tasks[1],$third)
$second.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if($script:compactTaskId -cne 'second' -or $script:renderCount -ne 1 -or
   -not [object]::ReferenceEquals($second,$compactDotsPanel.Children[1])){throw 'A dot click did not select the task while retaining the button.'}
if($second.Content.Background.Color -ne (Brush $script:accentHex).Color){throw 'The selected dot was not updated.'}
$newTasks=@($tasks[0],$third)
Sync-CompactDots $newTasks
if($compactDotsPanel.Children.Count -ne 2 -or -not [object]::ReferenceEquals($first,$compactDotsPanel.Children[0]) -or
   [string]$compactDotsPanel.Children[1].Tag -cne 'third'){throw 'Removing a task replaced a remaining button or left a stale dot.'}
Sync-CompactDots @($tasks[0])
if($compactDotsPanel.Visibility -ne [Windows.Visibility]::Collapsed){throw 'A single task should not show dot controls.'}
'Compact task dots: retained across refresh, updated and clickable without opening a window.'
'@
& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks))
