$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
$source=Join-Path (Join-Path $PSScriptRoot "..\app") "CodexProgress.ps1"
$tokens=$null
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw "The application does not parse."}
$definitions=foreach($name in @("Get-CursorHintPosition","New-CursorHint","Update-ConditionalHint","Add-ConditionalHint")){
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if($null -eq $function){throw "Missing tooltip function: $name"}
    $function.Extent.Text
}
$checks=@'
$area=[Windows.Rect]::new(0,0,400,300)
$size=[Windows.Size]::new(160,70)
$cases=@(
    @{pointer=[Windows.Point]::new(200,150);x=120;y=76},
    @{pointer=[Windows.Point]::new(10,150);x=0;y=76},
    @{pointer=[Windows.Point]::new(395,150);x=240;y=76},
    @{pointer=[Windows.Point]::new(200,8);x=120;y=12},
    @{pointer=[Windows.Point]::new(200,299);x=120;y=225}
)
foreach($case in $cases){
    $result=Get-CursorHintPosition $case.pointer $size $area
    if([Math]::Abs($result.X-$case.x) -gt 0.01 -or [Math]::Abs($result.Y-$case.y) -gt 0.01){throw "Incorrect tooltip position: $($case.pointer) => $result"}
}
$negative=Get-CursorHintPosition ([Windows.Point]::new(-1915,500)) $size ([Windows.Rect]::new(-1920,0,1920,1080))
if($negative.X -ne -1920 -or $negative.Y -ne 426){throw "Negative monitor coordinates were not handled."}
$shadow=[Windows.Thickness]::new(18,18,18,23)
$shadowedSize=[Windows.Size]::new(196,111)
$shadowed=Get-CursorHintPosition ([Windows.Point]::new(200,150)) $shadowedSize $area $shadow
if($shadowed.X -ne 102 -or $shadowed.Y -ne 58){throw "The visible tooltip must remain four units above the cursor when shadow margins are present."}

$HintSnapshotFile="synthetic-preview"
$PreviewActiveTasks=1
$window=New-Object Windows.Window
$window.Width=300;$window.Height=160;$window.WindowStyle="None";$window.ShowInTaskbar=$false
$work=[Windows.SystemParameters]::WorkArea
$window.Left=$work.Left+220;$window.Top=$work.Top+220
$canvas=New-Object Windows.Controls.Canvas
$block=New-Object Windows.Controls.TextBlock
$block.Width=100;$block.Height=20;$block.FontSize=12;$block.LineHeight=16
$block.Text="A long synthetic activity label that must be truncated"
$block.TextTrimming="CharacterEllipsis"
[Windows.Controls.Canvas]::SetLeft($block,10);[Windows.Controls.Canvas]::SetTop($block,10)
[void]$canvas.Children.Add($block);$window.Content=$canvas
Add-ConditionalHint $block $block.Text "line"
try{
    $window.Show();$window.UpdateLayout();Update-ConditionalHint $block
    if($block.ToolTip -isnot [Windows.Controls.ToolTip]){throw "A truncated label must have a tooltip."}
    if([Windows.Controls.ToolTipService]::GetPlacement($block) -ne [Windows.Controls.Primitives.PlacementMode]::Custom){throw "The tooltip does not use cursor placement."}
    $tip=$block.ToolTip
    $tip.StaysOpen=$true;$tip.IsOpen=$true
    $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $tip.UpdateLayout()
    $origin=$tip.PointToScreen([Windows.Point]::new(0,0))
    $pointer=$block.PointToScreen([Windows.Point]::new($block.ActualWidth/2,$block.ActualHeight/2))
    $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($block)
    $bottom=$origin.Y+$tip.ActualHeight*$dpi.DpiScaleY
    if($bottom -gt $pointer.Y-2*$dpi.DpiScaleY){throw "The tooltip was not displayed above the synthetic cursor."}
    $tip.IsOpen=$false
    $window.Left=$work.Right-$window.Width;$window.Top=$work.Top+220
    [Windows.Controls.Canvas]::SetLeft($block,$window.Width-$block.Width)
    $window.UpdateLayout();$tip.IsOpen=$true
    $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $tip.UpdateLayout()
    $origin=$tip.PointToScreen([Windows.Point]::new(0,0))
    $pointer=$block.PointToScreen([Windows.Point]::new($block.ActualWidth/2,$block.ActualHeight/2))
    $screen=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int]$pointer.X,[int]$pointer.Y))
    if($origin.X -lt $screen.WorkingArea.Left-1 -or ($origin.X+$tip.ActualWidth*$dpi.DpiScaleX) -gt $screen.WorkingArea.Right+1){throw "The tooltip was clipped at the monitor edge."}
    $tip.IsOpen=$false
    $window.Top=$work.Top
    [Windows.Controls.Canvas]::SetTop($block,0)
    $window.UpdateLayout();$tip.IsOpen=$true
    $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $tip.UpdateLayout()
    $origin=$tip.PointToScreen([Windows.Point]::new(0,0))
    $pointer=$block.PointToScreen([Windows.Point]::new($block.ActualWidth/2,$block.ActualHeight/2))
    if($origin.Y -lt $screen.WorkingArea.Top-1 -or $origin.Y -lt $pointer.Y){throw "The tooltip did not move below the cursor at the top screen edge."}
    $tip.IsOpen=$false
    $block.Text="Short";$block.Tag=[PSCustomObject]@{Text="Short";Mode="line"}
    Update-ConditionalHint $block
    if($null -ne $block.ToolTip){throw "A label that fits must not show a tooltip."}
    $block.Height=32;$block.TextWrapping="Wrap"
    $block.Text="A long synthetic activity that wraps over several lines and is hidden after the visible area."
    $block.Tag=[PSCustomObject]@{Text=$block.Text;Mode="wrap"}
    $window.UpdateLayout();Update-ConditionalHint $block
    if($block.ToolTip -isnot [Windows.Controls.ToolTip]){throw "Clipped wrapped text must have a tooltip."}
    $block.Text="Short";$block.Tag=[PSCustomObject]@{Text="Short";Mode="wrap"}
    Update-ConditionalHint $block
    if($null -ne $block.ToolTip){throw "Wrapped text that fits must not show a tooltip."}
}finally{$window.Close()}
Write-Output "Tooltip: cursor anchoring, monitor edges, negative coordinates, and truncation verified (DPI: $($dpi.PixelsPerInchX))."
'@
& ([scriptblock]::Create(($definitions -join "`n")+"`n"+$checks))
