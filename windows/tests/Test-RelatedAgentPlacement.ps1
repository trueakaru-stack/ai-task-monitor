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
        'New-RelatedAgentToggle', 'New-TaskTitleLine', 'Add-Steps', 'Compact-Height')) {
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
    $window = [PSCustomObject]@{ Resources = @{ ProviderTabStyle = [Windows.Style]::new([Windows.Controls.Button]) } }
    $script:palette = [PSCustomObject]@{ Primary = '#222222'; Secondary = '#666666'; Raised = '#FFFFFF';
        Surface = '#FFFFFF'; Muted = '#777777'; Done = '#555555'; Pending = '#888888' }
    $script:accentHex = '#0066CC'; $script:resolvedLanguage = 'ru'; $script:compactShowProviderLabels = $false
    $script:relatedAgentsExpanded = @{}; $script:relatedAgentButtons = @{}
    $script:lastTasks = @(); $script:lastAllTasks = @(); $PreviewRelatedAgents = $false; $CompactMode = $true
    $task = [PSCustomObject]@{ Id = 'synthetic-task'; Provider = 'codex'; Title = 'Task'; TitleGenerated = $false;
        RelatedAgentCount = 3; RelatedAgentsUnconfirmed = $true; PlanConfirmed = $true; Status = 'В работе';
        Progress = 50; ProgressKind = 'exact'; ProgressBasis = 'steps'; Steps = @(
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
    $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Require ($script:relatedAgentsExpanded.ContainsKey('synthetic-task')) 'The expanded agent list cannot be toggled from the step.'

    $task.ProgressBasis = 'task'; $task.Progress = 33
    Require ((Compact-ProgressLabel $task) -ceq '33%' -and (Compact-ExtraAgentStepLabel $task) -ceq 'Этап 2 из 3 (3 агента)') 'A task percentage replaced the active-step count.'
    $task.Steps[1].status = 'done'
    Require ((Active-PlanStepIndex $task) -eq -1) 'A plan without an active step was treated as active.'
    $fallback = New-TaskTitleLine $task 10 $false
    Require ($fallback.Tag -ceq 'related-agent-title' -and $fallback.Children[1].Text -ceq ' (3 агента)') 'The count did not move to the task title during the pause.'
    Require (-not (Compact-AgentStepLabel $task)) 'A nonexistent active step received the count.'
    $task.Steps[1].status = 'active'; $task.PlanConfirmed = $false
    Require ((Active-PlanStepIndex $task) -eq -1 -and (New-TaskTitleLine $task 10 $false).Tag -ceq 'related-agent-title') 'An unconfirmed plan was shown as a current step.'
    $task.PlanConfirmed = $true; $task.Steps[2].status = 'active'
    Require ((Active-PlanStepIndex $task) -eq -1 -and (New-TaskTitleLine $task 10 $false).Tag -ceq 'related-agent-title') 'Ambiguous active steps received a guessed count.'
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
