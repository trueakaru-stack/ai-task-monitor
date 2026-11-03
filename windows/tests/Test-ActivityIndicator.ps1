$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'Run this WPF test with powershell.exe -STA.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$source = Join-Path $PSScriptRoot '..\app\CodexProgress.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Application source could not be parsed.' }
$definitions = foreach ($name in @('Refresh-ActivityMotion', 'New-ActivityIndicator')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $function) { throw "Missing function: $name" }
    $function.Extent.Text
}
$checks = @'
$script:accentHex = '#645AD1'
$script:palette = @{ Muted = '#777777' }
$script:motionEnabled = $true
$script:fingerprint = 'old'
$PreviewMotion = 'off'
function Brush([string]$color) { return [Windows.Media.BrushConverter]::new().ConvertFromString($color) }
function Require($condition, [string]$message) { if (-not $condition) { throw $message } }
function Wait-Dispatcher([int]$milliseconds) {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $delay = [Windows.Threading.DispatcherTimer]::new()
    $delay.Interval = [TimeSpan]::FromMilliseconds($milliseconds)
    $delay.Add_Tick({ $delay.Stop(); $frame.Continue = $false }.GetNewClosure())
    $delay.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}
Refresh-ActivityMotion
Require (-not $script:motionEnabled -and $script:fingerprint -eq '') 'Motion preference changes did not trigger a redraw'
$static = New-ActivityIndicator $true
Require (-not $static.Children[0].Data.HasAnimatedProperties) 'The static preview still animated an active indicator'
$PreviewMotion = 'on'; $script:fingerprint = 'old'
Refresh-ActivityMotion
Require ($script:motionEnabled -and $script:fingerprint -eq '') 'Re-enabling animations did not trigger a redraw'
$unconfirmed = New-ActivityIndicator $false
Require (-not $unconfirmed.Children[0].Data.HasAnimatedProperties) 'An unconfirmed task was animated'
Require ($static.Width -eq 16 -and $unconfirmed.Width -eq 16 -and $static.Height -eq 4) 'Indicator geometry changed between states'
$active = New-ActivityIndicator $true
$geometry = $active.Children[0].Data
Require ($geometry -is [Windows.Media.RectangleGeometry] -and $geometry.RadiusX -eq 2 -and $geometry.RadiusY -eq 2 -and $active.Children[0].RenderTransform.Value.IsIdentity) 'The indicator does not have constant circular ends'
Require ($geometry.HasAnimatedProperties) 'An active task did not receive its animation'
$window = [Windows.Window]::new()
$window.Width = 100; $window.Height = 100; $window.ShowInTaskbar = $false; $window.Content = $active
try {
    $window.Show()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $sawStretch = $false; $sawRight = $false; $returnedLeft = $false
    while ($watch.ElapsedMilliseconds -lt 5000 -and -not ($sawStretch -and $sawRight -and $returnedLeft)) {
        Wait-Dispatcher 45
        $rect = $geometry.Rect; $width = [double]$rect.Width; $x = [double]$rect.X
        Require ($geometry.RadiusX -eq 2 -and $geometry.RadiusY -eq 2 -and $rect.Height -eq 4) 'The indicator ends were distorted during animation'
        Require ($width -ge 3.999 -and $width -le 16.01 -and $x -ge -0.001 -and ($x + $width) -le 16.01) 'The moving indicator escaped its reserved space'
        if ($width -ge 13) { $sawStretch = $true }
        if ($x -ge 9) { $sawRight = $true }
        if ($sawRight -and $x -le 0.5 -and $width -le 5.8) { $returnedLeft = $true }
    }
    Require ($sawStretch -and $sawRight -and $returnedLeft) 'The indicator did not stretch, move right and return left'
} finally { $window.Close() }
$PreviewMotion = 'default'
$script:motionEnabled = $false
$script:fingerprint = 'old'
Refresh-ActivityMotion
Require ($script:motionEnabled -and $script:fingerprint -eq '') 'Default activity motion incorrectly depends on system animation effects'
Write-Output 'Activity indicator: circular ends, 16 by 4 px trajectory, bounds, task state and system independence verified.'
'@
& ([scriptblock]::Create(($definitions -join "`n") + "`n" + $checks))
