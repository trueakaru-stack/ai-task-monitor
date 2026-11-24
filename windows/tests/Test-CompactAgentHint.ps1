$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { throw 'The synthetic WPF check requires STA.' }
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
try {
    Add-Type -AssemblyName PresentationFramework
    $tokens = $null; $errors = $null
    $source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'The application source did not parse.' }
    $definitions = foreach ($name in @('Prop','Progress-Label','Active-PlanStepIndex','Compact-AgentStepLabel',
        'Compact-ProgressLabel','Compact-ExtraAgentStepLabel','Localized-TaskTitle','Related-AgentStatus',
        'Update-ConditionalHint','Add-ConditionalHint','Add-CompactTask')) {
        $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true)
        if ($null -eq $node) { throw "Missing production function: $name" }
        $node.Extent.Text
    }
    . ([scriptblock]::Create(($definitions -join "`n")))
    function Require([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
    function Tr([string]$value) { return $value }
    function Text([string]$value, [double]$size, [string]$color, [string]$weight = 'Normal') {
        $label = [Windows.Controls.TextBlock]::new(); $label.Text = $value; $label.FontSize = $size
        return $label
    }
    function New-TaskTitleLine($task, [double]$margin, [bool]$fixedHeight) { return [Windows.Controls.TextBlock]::new() }
    function Localized-CompactTaskActivity($task) { return '' }
    function New-ActivityIndicator([bool]$active) { return [Windows.Controls.Border]::new() }
    function Plan-StatusNote($task) { return '' }
    function Add-LoopWarning($panel, $task, [bool]$compact) { }
    function New-CursorHint($target, [string]$text) { $tip = [Windows.Controls.ToolTip]::new(); $tip.Content = $text; return $tip }
    $script:palette = [PSCustomObject]@{ Primary = '#222222'; Activity = '#555555'; Muted = '#777777' }
    $script:resolvedLanguage = 'en'; $script:compactShowProviderLabels = $false
    $script:previewHintTarget = $null; $PreviewActiveTasks = -1; $CompactMode = $true
    $compactTasksPanel = [Windows.Controls.StackPanel]::new()
    $task = [PSCustomObject]@{ Id = 'synthetic'; Provider = 'codex'; Title = 'Task'; TitleGenerated = $false;
        RelatedAgentCount = 3; RelatedAgentsUnconfirmed = $false; PlanConfirmed = $true; Status = 'active';
        Active = $true; Progress = 50; ProgressKind = 'exact'; ProgressBasis = 'steps'; Steps = @(
            [PSCustomObject]@{ title = 'One'; status = 'done' },
            [PSCustomObject]@{ title = 'Two'; status = 'active' }) }
    foreach ($basis in @('steps','task')) {
        $task.ProgressBasis = $basis
        $compactTasksPanel.Children.Clear(); Add-CompactTask $task
        $progress = $compactTasksPanel.Children[0].Children[0].Children[1]
        $count = if ($basis -eq 'task') { $progress.Children[1] } else { $progress }
        Require ([Windows.Automation.AutomationProperties]::GetAutomationId($count) -ceq 'related-agent-count') 'The agent count marker is missing.'
        Require ($count.Tag.Text -ceq $count.Text -and $count.Tag.Mode -ceq 'line') 'The count marker overwrote tooltip state.'
        $count.Measure([Windows.Size]::new(20,40)); $count.Arrange([Windows.Rect]::new(0,0,20,40))
        Update-ConditionalHint $count
        Require ($count.ToolTip -is [Windows.Controls.ToolTip] -and [string]$count.ToolTip.Content -ceq $count.Text) 'The clipped count lost its full-text hint.'
    }
    Write-Output 'Synthetic compact count hints: both progress variants retain their full-text tooltip state.'
} finally {
    if (-not [string]::Equals($userPath, [Environment]::GetEnvironmentVariable('PATH', 'User'), [StringComparison]::Ordinal) -or
        -not [string]::Equals($machinePath, [Environment]::GetEnvironmentVariable('PATH', 'Machine'), [StringComparison]::Ordinal)) {
        throw 'Persistent PATH changed during the synthetic check.'
    }
}
