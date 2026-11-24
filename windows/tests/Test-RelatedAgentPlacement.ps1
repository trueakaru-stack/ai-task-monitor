$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'The synthetic WPF control test requires STA.'
}
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
try {
    Add-Type -AssemblyName PresentationFramework
    $source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'The application source did not parse.' }
    $definitions = foreach ($name in @('Prop', 'Progress-Label', 'Active-PlanStepIndex', 'Compact-AgentStepLabel',
        'Compact-ProgressLabel', 'Compact-ExtraAgentStepLabel', 'Localized-TaskTitle', 'Related-AgentStatus',
        'New-RelatedAgentToggle', 'New-TaskTitleLine', 'Related-AgentActivity', 'Add-RelatedAgentList',
        'Add-RelatedAgentContent', 'Add-Steps', 'Compact-Height')) {
        $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true)
        if ($null -eq $node) { throw "Missing production function: $name" }
        $node.Extent.Text
    }
    . ([scriptblock]::Create(($definitions -join "`n")))
    function Require([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
    function Tr([string]$value) { return $value }
    function Brush([string]$value) { return [Windows.Media.BrushConverter]::new().ConvertFromString($value) }
    function Text([string]$value, [double]$size, [string]$color, [string]$weight = 'Normal') {
        $label = [Windows.Controls.TextBlock]::new(); $label.Text = $value; $label.FontSize = $size
        $label.Foreground = Brush $color; $label.FontWeight = [Windows.FontWeightConverter]::new().ConvertFromString($weight)
        return $label
    }
    function Add-ConditionalHint($block, [string]$text, [string]$mode = 'line') { }
    function Render-CurrentTasks($tasks, $allTasks) { }
    function Localized-TaskActivity($item) { return [string]$item.Activity }
    $window = [PSCustomObject]@{ Resources = @{ ProviderTabStyle = [Windows.Style]::new([Windows.Controls.Button]) } }
    $script:palette = [PSCustomObject]@{ Primary = '#222222'; Secondary = '#666666'; Activity = '#555555'; Raised = '#FFFFFF';
        Surface = '#FFFFFF'; Muted = '#777777'; Done = '#555555'; Pending = '#888888' }
    $script:accentHex = '#0066CC'; $script:resolvedLanguage = 'ru'; $script:compactShowProviderLabels = $false
    $script:relatedAgentsExpanded = @{}; $script:relatedAgentButtons = @{}
    $script:lastTasks = @(); $script:lastAllTasks = @(); $PreviewRelatedAgents = $false; $CompactMode = $true
    $task = [PSCustomObject]@{ Id = 'synthetic-task'; Provider = 'codex'; Title = 'Task'; TitleGenerated = $false;
        RelatedAgentCount = 3; RelatedAgentsUnconfirmed = $true; PlanConfirmed = $true; Status = 'В работе';
        Progress = 50; ProgressKind = 'exact'; ProgressBasis = 'steps'; RelatedAgents = @(
            [PSCustomObject]@{ AgentNickname = 'One'; Active = $true; Activity = 'First action' },
            [PSCustomObject]@{ AgentNickname = 'Two'; Active = $true; Activity = 'Second action' },
            [PSCustomObject]@{ AgentNickname = 'Three'; Active = $true; Activity = 'Third action' }); Steps = @(
            [PSCustomObject]@{ title = 'First'; status = 'done' },
            [PSCustomObject]@{ title = 'Current'; status = 'active' },
            [PSCustomObject]@{ title = 'Next'; status = 'pending' }) }

    Require ((Active-PlanStepIndex $task) -eq 1) 'The unique active step was not found.'
    Require ((Compact-ProgressLabel $task) -ceq 'Этап 2 из 3 (3 агента)') 'The compact count is not on the active step.'
    Require (-not (Compact-ExtraAgentStepLabel $task)) 'The current step was displayed twice.'
    $title = New-TaskTitleLine $task 10 $false
    Require ($title -is [Windows.Controls.TextBlock] -and $title.Text -ceq 'Task') 'The active-step count was duplicated at the title.'
    $container = [Windows.Controls.StackPanel]::new()
    Add-Steps $container $task.Steps $false $task
    $line = $container.Children[0].Content.Children[1].Children[1]
    Require ($line.Tag -ceq 'related-agent-step') 'The expanded count is not attached to the active step.'
    $button = $script:relatedAgentButtons['expanded|synthetic-task']
    Require ($null -ne $button -and $button.Parent -eq $line -and $button.Content.Children[0].Text -ceq ' (3 агента)') 'The expanded count control is missing.'
    Require ([Windows.Automation.AutomationProperties]::GetName($button).Contains('(3 агента)')) 'The agent count is missing from the accessible control name.'
    $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Require ($script:relatedAgentsExpanded.ContainsKey('synthetic-task')) 'The expanded agent list cannot be toggled from the step.'
    $shown = [Windows.Controls.StackPanel]::new(); Add-Steps $shown $task.Steps $false $task
    $planScroll = $shown.Children[0]; $rail = $planScroll.Content; $actions = $rail.Children[2]
    Require ($rail.Children.Count -eq 4 -and $rail.Children[1].Children[1].Tag -ceq 'related-agent-step' -and
        [Windows.Automation.AutomationProperties]::GetAutomationId($actions) -ceq 'related-agent-actions' -and
        $actions.Parent -eq $rail -and $actions.Children.Count -eq 3 -and $actions.Children[0].Text -ceq 'One: First action' -and
        $rail.Children[3].Children[1].Text -ceq 'Next') 'Expanded actions were not placed once, immediately after the active step.'
    Require ($planScroll.Height -eq 181 -and $actions.Margin.Left -eq 26 -and $actions.Margin.Top -eq 5 -and
        $actions -is [Windows.Controls.StackPanel]) 'The inline list did not reuse the plan viewport or align with the step text.'
    $headerOnly = [Windows.Controls.StackPanel]::new(); Add-RelatedAgentContent $headerOnly $task $false $true
    Require ($headerOnly.Children.Count -eq 1 -and $headerOnly.Children[0].Tag -ceq 'related-agent-status') 'The header duplicated the actions or lost uncertainty.'
    $manyTask = $task.PSObject.Copy(); $manyTask.RelatedAgentCount = 7
    $manyTask.RelatedAgents = @(1..7 | ForEach-Object { [PSCustomObject]@{ AgentNickname = "Agent $_"; Active = $true; Activity = "Action $_" } })
    $manyTask.Steps = @(0..8 | ForEach-Object { [PSCustomObject]@{ title = "Step $_"; status = $(if ($_ -eq 6) { 'active' } else { 'pending' }) } })
    $many = [Windows.Controls.StackPanel]::new(); Add-Steps $many $manyTask.Steps $false $manyTask
    $manyScroll = $many.Children[0]; $manyRail = $manyScroll.Content
    Require ($manyScroll.Height -eq 225 -and $manyScroll.VerticalScrollBarVisibility -eq [Windows.Controls.ScrollBarVisibility]::Auto -and
        $manyScroll.Tag -eq 132 -and $manyRail.Children[7].Children.Count -eq 7 -and
        $manyRail.Children[7].Children[6].Text -ceq 'Agent 7: Action 7') 'The shared viewport lost its bounded height, active-step focus, or overflow actions.'

    $task.ProgressBasis = 'task'; $task.Progress = 33
    Require ((Compact-ProgressLabel $task) -ceq '33%' -and (Compact-ExtraAgentStepLabel $task) -ceq 'Этап 2 из 3 (3 агента)') 'A task percentage replaced the active-step count.'
    $task.Steps[1].status = 'done'
    Require ((Active-PlanStepIndex $task) -eq -1) 'A plan without an active step was treated as active.'
    $fallback = New-TaskTitleLine $task 10 $false
    Require ($fallback.Tag -ceq 'related-agent-title' -and $fallback.Children[1].Text -ceq ' (3 агента)') 'The count did not move to the task title during the pause.'
    Require (-not (Compact-AgentStepLabel $task)) 'A nonexistent active step received the count.'
    $fallbackContent = [Windows.Controls.StackPanel]::new(); Add-RelatedAgentContent $fallbackContent $task
    $fallbackSteps = [Windows.Controls.StackPanel]::new(); Add-Steps $fallbackSteps $task.Steps $false $task
    Require ($fallbackContent.Children.Count -eq 2 -and $fallbackContent.Children[0].Tag -ceq 'related-agent-status' -and
        $fallbackContent.Children[1] -is [Windows.Controls.ScrollViewer] -and $fallbackContent.Children[1].Content.Parent -eq $fallbackContent.Children[1] -and
        $fallbackContent.Children[1].Content.Children.Count -eq 3 -and
        $fallbackSteps.Children[0].Content.Children.Count -eq 3) 'The paused task lost or duplicated the title-area agent list.'
    $task.Steps[1].status = 'active'; $task.PlanConfirmed = $false
    Require ((Active-PlanStepIndex $task) -eq -1 -and (New-TaskTitleLine $task 10 $false).Tag -ceq 'related-agent-title') 'An unconfirmed plan was shown as a current step.'
    $unconfirmedSteps = [Windows.Controls.StackPanel]::new(); Add-Steps $unconfirmedSteps $task.Steps $true $task
    Require ($unconfirmedSteps.Children[0].Content.Children.Count -eq 3) 'An unconfirmed plan received an inline agent list.'
    $task.PlanConfirmed = $null
    Require ((Active-PlanStepIndex $task) -eq -1) 'A missing plan confirmation was treated as confirmed.'
    $withoutConfirmation = $task | Select-Object * -ExcludeProperty PlanConfirmed
    Require ((Active-PlanStepIndex $withoutConfirmation) -eq -1) 'An absent plan confirmation was treated as confirmed.'
    $task.PlanConfirmed = $true; $task.Steps[2].status = 'active'
    Require ((Active-PlanStepIndex $task) -eq -1 -and (New-TaskTitleLine $task 10 $false).Tag -ceq 'related-agent-title') 'Ambiguous active steps received a guessed count.'
    $ambiguousSteps = [Windows.Controls.StackPanel]::new(); Add-Steps $ambiguousSteps $task.Steps $false $task
    Require ($ambiguousSteps.Children[0].Content.Children.Count -eq 3) 'An ambiguous plan received an inline agent list.'
    $task.Steps[2].status = 'pending'; $script:resolvedLanguage = 'en'; $task.RelatedAgentCount = 1; $task.ProgressBasis = 'steps'
    Require ((Compact-ProgressLabel $task) -ceq 'Step 2 of 3 (1 agent)') 'The English singular count is incorrect.'
    $task.RelatedAgentCount = 2
    Require ((Compact-ProgressLabel $task) -ceq 'Step 2 of 3 (2 agents)') 'The English plural count is incorrect.'
    $task.RelatedAgentCount = 0
    Require ((Compact-ProgressLabel $task) -ceq 'Step 2 of 3' -and -not (Related-AgentStatus $task)) 'A nonexistent count or agent status was shown.'
    Require ((Compact-Height 2 $false $false $false $true $true) -eq (Compact-Height 2 $false $false $false) + 40) 'Compact height did not reserve room for uncertainty and an extra step.'
    Write-Output 'Synthetic agent placement: active step, task fallback, uncertainty, progress and expanded action control verified.'
} finally {
    if (-not [string]::Equals($userPath, [Environment]::GetEnvironmentVariable('PATH', 'User'), [StringComparison]::Ordinal) -or
        -not [string]::Equals($machinePath, [Environment]::GetEnvironmentVariable('PATH', 'Machine'), [StringComparison]::Ordinal)) {
        throw 'Persistent PATH changed during the synthetic check.'
    }
}
