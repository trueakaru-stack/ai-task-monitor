$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows') { throw 'Requires a GitHub-hosted Windows runner.' }
if ($env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH -cne '0') { throw 'The dotnet path protection is missing.' }
if ($env:AITM_CURSOR_THEME -notin @('dark','light')) { throw 'Unexpected theme.' }

$parent = (git rev-parse HEAD^).Trim()
if ($LASTEXITCODE -ne 0 -or -not $parent.StartsWith('5fedcb3', [StringComparison]::Ordinal)) { throw "Unexpected product revision: $parent" }
git diff --quiet HEAD^ HEAD -- windows/app
if ($LASTEXITCODE -ne 0) { throw 'The test commit must not alter the application.' }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CursorDesktop {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct INFO { public int cbSize; public uint flags; public IntPtr cursor; public POINT point; }
    [StructLayout(LayoutKind.Sequential)] public struct ICONINFO {
        [MarshalAs(UnmanagedType.Bool)] public bool icon; public uint hotspotX, hotspotY; public IntPtr mask, color;
    }
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref INFO info);
    [DllImport("user32.dll")] public static extern int ShowCursor(bool show);
    [DllImport("user32.dll")] public static extern IntPtr LoadCursor(IntPtr module, IntPtr name);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr icon, out ICONINFO info);
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr dc, int x, int y, IntPtr icon, int cx, int cy, uint step, IntPtr brush, uint flags);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
}
'@

$root = [IO.Path]::GetFullPath($env:AITM_CURSOR_ROOT)
$tempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
if (-not $root.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test directory must be inside the runner temporary directory.' }
$evidence = Join-Path $root 'evidence'
$profile = Join-Path $root 'profile'
[IO.Directory]::CreateDirectory($evidence) | Out-Null
[IO.Directory]::CreateDirectory($profile) | Out-Null
$env:TEMP = $root
$env:TMP = $root
$env:LOCALAPPDATA = Join-Path $profile 'local'
$env:APPDATA = Join-Path $profile 'appdata'
$env:USERPROFILE = $profile
$env:CODEX_HOME = Join-Path $profile 'codex'
foreach ($folder in @($env:LOCALAPPDATA,$env:APPDATA,$env:CODEX_HOME)) { [IO.Directory]::CreateDirectory($folder) | Out-Null }
$records = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
$hand = [CursorDesktop]::LoadCursor([IntPtr]::Zero, [IntPtr]32649)
$arrow = [CursorDesktop]::LoadCursor([IntPtr]::Zero, [IntPtr]32512)
if ($hand -eq [IntPtr]::Zero -or $arrow -eq [IntPtr]::Zero -or $hand -eq $arrow) { throw 'Standard Windows cursors could not be loaded.' }
for ($attempt=0; $attempt -lt 16; $attempt++) { if ([CursorDesktop]::ShowCursor($true) -ge 0) { break } }

function Current-Cursor {
    $info = New-Object CursorDesktop+INFO
    $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][CursorDesktop+INFO])
    if (-not [CursorDesktop]::GetCursorInfo([ref]$info)) { throw 'GetCursorInfo failed.' }
    if (($info.flags -band 1) -eq 0) { throw 'The desktop cursor is not visible.' }
    return $info
}
function Move-Pointer([int]$x, [int]$y, [IntPtr]$expected, [string]$description) {
    if (-not [CursorDesktop]::SetCursorPos($x,$y)) { throw "SetCursorPos failed: $description" }
    $until = [DateTime]::UtcNow.AddMilliseconds(400)
    do {
        Start-Sleep -Milliseconds 20
        $cursor = Current-Cursor
        if ($cursor.point.X -eq $x -and $cursor.point.Y -eq $y -and $cursor.cursor -eq $expected) { return }
    } while ([DateTime]::UtcNow -lt $until)
    throw ("Unexpected cursor at {0}: position {1},{2}; handle {3}; expected {4}" -f $description,$cursor.point.X,$cursor.point.Y,$cursor.cursor,$expected)
}
function Find-Dots($window) {
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button)
    $items = $window.FindAll([Windows.Automation.TreeScope]::Descendants,$condition)
    $buttons = @($items | Where-Object { $_.Current.Name.StartsWith('Show task: ', [StringComparison]::Ordinal) } | Sort-Object { $_.Current.BoundingRectangle.Left })
    if ($buttons.Count -ne 2) { throw "Expected two accessible task buttons; found $($buttons.Count)." }
    return $buttons
}
function Has-Title($window, [string]$title) {
    $conditions = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Text),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$title))
    return $null -ne $window.FindFirst([Windows.Automation.TreeScope]::Descendants,$conditions)
}
function Wait-Title($window, [string]$title) {
    $until = [DateTime]::UtcNow.AddSeconds(4)
    do { Start-Sleep -Milliseconds 80; if (Has-Title $window $title) { return } } while ([DateTime]::UtcNow -lt $until)
    throw "The selected task title did not appear: $title"
}
function Click-At([int]$x,[int]$y) {
    if (-not [CursorDesktop]::SetCursorPos($x,$y)) { throw 'Cannot move the desktop pointer.' }
    Start-Sleep -Milliseconds 100
    [CursorDesktop]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
    [CursorDesktop]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
function Save-Cursor-Frame($window,[string]$path) {
    $bounds=$window.Current.BoundingRectangle
    $left=[int][Math]::Floor($bounds.Left); $top=[int][Math]::Floor($bounds.Top)
    $width=[int][Math]::Ceiling($bounds.Right)-$left; $height=[int][Math]::Ceiling($bounds.Bottom)-$top
    $bitmap=[Drawing.Bitmap]::new($width,$height)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($left,$top,0,0,[Drawing.Size]::new($width,$height))
        $cursor=Current-Cursor
        $details=New-Object CursorDesktop+ICONINFO
        if (-not [CursorDesktop]::GetIconInfo($cursor.cursor,[ref]$details)) { throw 'Cannot inspect the active system cursor.' }
        try {
            $dc=$graphics.GetHdc()
            try {
                $x=$cursor.point.X-$left-[int]$details.hotspotX; $y=$cursor.point.Y-$top-[int]$details.hotspotY
                if (-not [CursorDesktop]::DrawIconEx($dc,$x,$y,$cursor.cursor,0,0,0,[IntPtr]::Zero,3)) { throw 'Cannot draw the active system cursor.' }
            } finally { $graphics.ReleaseHdc($dc) }
        } finally {
            if ($details.mask -ne [IntPtr]::Zero) { [void][CursorDesktop]::DeleteObject($details.mask) }
            if ($details.color -ne [IntPtr]::Zero) { [void][CursorDesktop]::DeleteObject($details.color) }
        }
        $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

$appSource = Join-Path (Get-Location).Path 'windows\app'
$lf = [string][char]10
$product = [IO.File]::ReadAllText((Join-Path $appSource 'CodexProgress.ps1')).Replace(([string][char]13+$lf),$lf)
$styleStart = '  <Style x:Key="CompactDotStyle" TargetType="Button">'
$styleEnd = '  <Style x:Key="SourceActionStyle" TargetType="Button">'
$styleIndex = $product.IndexOf($styleStart,[StringComparison]::Ordinal)
$styleEndIndex = $product.IndexOf($styleEnd,$styleIndex,[StringComparison]::Ordinal)
if ($styleIndex -lt 0 -or $styleEndIndex -le $styleIndex) { throw 'Cannot find compact dot style.' }
$style = $product.Substring($styleIndex,$styleEndIndex-$styleIndex)
$cursorSetter = '   <Setter Property="Cursor" Value="Hand"/>' + $lf
if (($style.Split(@($cursorSetter),[StringSplitOptions]::None).Count - 1) -ne 1) { throw 'Expected exactly one cursor setter in the dot style.' }
$baseline = $product.Substring(0,$styleIndex) + $style.Replace($cursorSetter,'') + $product.Substring($styleEndIndex)
$marker = ' $window.Show(); $window.UpdateLayout()'
if ($product.IndexOf($marker,[StringComparison]::Ordinal) -lt 0 -or $product.IndexOf($marker,[StringComparison]::Ordinal) -ne $product.LastIndexOf($marker,[StringComparison]::Ordinal)) { throw 'Preview entry point is missing or ambiguous.' }

# Extend the lifetime of the normal synthetic preview so a separate process can
# use the actual WPF controls through Windows input and UI Automation.
$hold = @'
 $window.Show(); $window.UpdateLayout()
 Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class AITMCursorVisibility { [DllImport("user32.dll")] public static extern int ShowCursor(bool show); }'
 for($cursorAttempt=0;$cursorAttempt -lt 16;$cursorAttempt++){if([AITMCursorVisibility]::ShowCursor($true) -ge 0){break}}
 $cursorFrame=[Windows.Threading.DispatcherFrame]::new()
 $cursorTimer=[Windows.Threading.DispatcherTimer]::new()
 $cursorTimer.Interval=[TimeSpan]::FromMilliseconds(50)
 $cursorDeadline=[Diagnostics.Stopwatch]::StartNew()
 $cursorTimer.Add_Tick({
  if([IO.File]::Exists($env:AITM_CURSOR_RELEASE) -or $cursorDeadline.Elapsed.TotalSeconds -gt 180){
   $cursorTimer.Stop();$cursorFrame.Continue=$false
  }
 }.GetNewClosure())
 $cursorTimer.Start()
 $cursorHandle=[Windows.Interop.WindowInteropHelper]::new($window).Handle.ToInt64()
 $cursorButtonValues=@($compactDotsPanel.Children | ForEach-Object {
  [ordered]@{
   value=$(if($null -eq $_.Cursor){'Default'}else{[string]$_.Cursor})
   source=[string]([Windows.DependencyPropertyHelper]::GetValueSource($_,[Windows.FrameworkElement]::CursorProperty).BaseValueSource)
  }
 })
 $cursorProperties=[ordered]@{
  buttons=$cursorButtonValues
  window=$(if($null -eq $window.Cursor){'Default'}else{[string]$window.Cursor})
  panel=$(if($null -eq $compactDotsPanel.Cursor){'Default'}else{[string]$compactDotsPanel.Cursor})
  content=$(if($null -eq $compactTasksPanel.Cursor){'Default'}else{[string]$compactTasksPanel.Cursor})
  mouseOverride=$(if($null -eq [Windows.Input.Mouse]::OverrideCursor){'None'}else{[string][Windows.Input.Mouse]::OverrideCursor})
 }
 [IO.File]::WriteAllText($env:AITM_CURSOR_PROPERTIES,($cursorProperties|ConvertTo-Json -Depth 4))
 [IO.File]::WriteAllText($env:AITM_CURSOR_READY,("{0}|{1}" -f $PID,$cursorHandle))
 [Windows.Threading.Dispatcher]::PushFrame($cursorFrame)
'@
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) { throw 'The Windows C# compiler is unavailable.' }

foreach ($variant in @('fixed','baseline')) {
    $copy = Join-Path $root $variant
    Copy-Item -LiteralPath $appSource -Destination $copy -Recurse
    $text = if ($variant -eq 'baseline') { $baseline } else { $product }
    $text = $text.Replace($marker,$hold)
    $errorTrap = @'
trap {
 try { [IO.File]::WriteAllText($env:AITM_CURSOR_ERROR,($_ | Format-List * -Force | Out-String)) } catch {}
 break
}
Set-StrictMode -Version 2.0
'@
    $text = $text.Replace('Set-StrictMode -Version 2.0',$errorTrap)
    [IO.File]::WriteAllText((Join-Path $copy 'CodexProgress.ps1'),$text,[Text.UTF8Encoding]::new($true))
    $parseTokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $copy 'CodexProgress.ps1'),[ref]$parseTokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    $launcher = Join-Path $copy 'AI task monitor.exe'
    & $compiler /nologo /target:winexe /optimize+ "/out:$launcher" "/win32icon:$(Join-Path $copy 'assets\app-icon.ico')" (Join-Path $copy 'CodexTasksLauncher.cs') (Join-Path $copy 'VersionInfo.cs')
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($launcher)) { throw 'The product launcher could not be built.' }
    $env:AITM_CURSOR_READY = Join-Path $root ($variant + '.ready')
    $env:AITM_CURSOR_RELEASE = Join-Path $root ($variant + '.release')
    $env:AITM_CURSOR_ERROR = Join-Path $evidence ($variant + '-error.txt')
    $env:AITM_CURSOR_PROPERTIES = Join-Path $evidence ($variant + '-cursor-properties.json')
    $snapshot = Join-Path $evidence ($variant + '-' + $env:AITM_CURSOR_THEME + '.png')
    $preferences = Join-Path $root ($variant + '-preferences.json')
    $arguments = @('-PreviewActiveTasks','2','-CompactMode','-PreviewProviderLabelsUiTest','-PreviewMotion','off','-ThemeOverride',$env:AITM_CURSOR_THEME,'-LanguageOverride','en','-SnapshotFile',('"'+$snapshot+'"'),'-PreferencesFile',('"'+$preferences+'"')) -join ' '
    $launched = Start-Process -FilePath $launcher -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $child = $null
    try {
        $until = [DateTime]::UtcNow.AddSeconds(50)
        while (-not [IO.File]::Exists($env:AITM_CURSOR_READY) -and -not [IO.File]::Exists($env:AITM_CURSOR_ERROR) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 200 }
        if (-not [IO.File]::Exists($env:AITM_CURSOR_READY)) {
            if ([IO.File]::Exists($env:AITM_CURSOR_ERROR)) { Write-Output ([IO.File]::ReadAllText($env:AITM_CURSOR_ERROR)) }
            throw "The $variant application did not open the preview window."
        }
        $properties = Get-Content -Raw -LiteralPath $env:AITM_CURSOR_PROPERTIES | ConvertFrom-Json
        if ($properties.buttons.Count -ne 2 -or $properties.window -cne 'Default' -or $properties.panel -cne 'Default' -or $properties.content -cne 'Default' -or $properties.mouseOverride -cne 'None') { throw 'Unexpected cursor inheritance or global cursor override.' }
        foreach ($buttonProperty in $properties.buttons) {
            if ($variant -eq 'fixed' -and ($buttonProperty.value -cne 'Hand' -or $buttonProperty.source -cne 'Style')) { throw 'The fixed button does not use the Hand style value.' }
            if ($variant -eq 'baseline' -and $buttonProperty.value -ceq 'Hand') { throw 'The baseline button unexpectedly uses Hand.' }
        }
        Write-Output ("{0}: WPF button values {1}, window {2}, panel {3}, content {4}, global override {5}." -f $variant,(@($properties.buttons | ForEach-Object { $_.value+'/'+$_.source }) -join ','),$properties.window,$properties.panel,$properties.content,$properties.mouseOverride)
        $parts = ([IO.File]::ReadAllText($env:AITM_CURSOR_READY)).Split('|')
        if ($parts.Count -ne 2) { throw 'Invalid preview readiness marker.' }
        $child = Get-Process -Id ([int]$parts[0])
        $handle = [IntPtr]([long]$parts[1])
        $window = [Windows.Automation.AutomationElement]::FromHandle($handle)
        if ($null -eq $window) { throw 'The real preview window is not accessible.' }
        [void][CursorDesktop]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 300
        $dots = @(Find-Dots $window)
        $firstName = $dots[0].Current.Name.Substring('Show task: '.Length)
        $secondName = $dots[1].Current.Name.Substring('Show task: '.Length)
        if (-not (Has-Title $window $firstName)) { throw "The initial task title is not visible: $firstName" }
        $expectedCursor = if ($variant -eq 'fixed') { $hand } else { $arrow }
        $samples = 0
        $cursorResult = 'not checked: hosted desktop cursor is not visible'
        foreach ($dot in $dots) {
            $rect=$dot.Current.BoundingRectangle
            if ($rect.Width -lt 16 -or $rect.Height -lt 16 -or -not $dot.Current.IsKeyboardFocusable) { throw 'The task button geometry or keyboard focus is invalid.' }
        }
        $mouseResult='passed'
        try {
            $target = $dots[1].Current.BoundingRectangle
            Click-At ([int]($target.Left+$target.Width/2)) ([int]($target.Top+$target.Height/2))
            Wait-Title $window $secondName
        } catch {
            $mouseResult=$_.Exception.Message
            $failures.Add($variant+' mouse: '+$mouseResult)
            Write-Warning ($variant+' mouse: '+$mouseResult)
        }
        $keyboardResult='passed'
        try {
            $dots = @(Find-Dots $window)
            $keyIndex=if (Has-Title $window $secondName) { 0 } else { 1 }
            $keyTitle=if ($keyIndex -eq 0) { $firstName } else { $secondName }
            $dots[$keyIndex].SetFocus()
            Start-Sleep -Milliseconds 100
            if ([Windows.Automation.AutomationElement]::FocusedElement.Current.Name -cne $dots[$keyIndex].Current.Name) { throw 'The task button did not receive keyboard focus.' }
            [CursorDesktop]::keybd_event(0x20,0,0,[UIntPtr]::Zero)
            [CursorDesktop]::keybd_event(0x20,0,2,[UIntPtr]::Zero)
            Wait-Title $window $keyTitle
        } catch {
            $keyboardResult=$_.Exception.Message
            $failures.Add($variant+' keyboard: '+$keyboardResult)
            Write-Warning ($variant+' keyboard: '+$keyboardResult)
        }
        $records.Add([pscustomobject]@{theme=$env:AITM_CURSOR_THEME;variant=$variant;pointerSamples=$samples;cursor=$cursorResult;mouseSwitch=$mouseResult;keyboardFocusSpace=$keyboardResult;productCommit=$parent})
        $records | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $evidence 'results.json') -Encoding UTF8
        Write-Output ("{0} {1}: cursor={2}; mouse={3}; keyboard={4}." -f $variant,$env:AITM_CURSOR_THEME,$cursorResult,$mouseResult,$keyboardResult)
    } finally {
        [IO.File]::WriteAllText($env:AITM_CURSOR_RELEASE,'done')
        if ($child) { [void]$child.WaitForExit(20000) }
    }
    if (-not [IO.File]::Exists($snapshot)) { throw "The $variant application did not save its preview frame." }
}
$a = (Get-FileHash -LiteralPath (Join-Path $evidence ('baseline-'+$env:AITM_CURSOR_THEME+'.png')) -Algorithm SHA256).Hash
$b = (Get-FileHash -LiteralPath (Join-Path $evidence ('fixed-'+$env:AITM_CURSOR_THEME+'.png')) -Algorithm SHA256).Hash
Write-Output "Baseline frame SHA-256: $a"
Write-Output "Fixed frame SHA-256: $b"
Write-Output "Frames identical: $($a -ceq $b)"
if ($failures.Count -gt 0) { throw ($failures -join '; ') }
