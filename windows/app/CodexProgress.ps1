param(
 [string]$ProgressFile = "",
 [string]$SnapshotFile = "",
 [switch]$CompactMode,
 [ValidateSet("","system","dark","light")][string]$ThemeOverride = "",
 [string]$SettingsSnapshotFile = "",
 [string]$JournalSnapshotFile = "",
 [switch]$PreviewJournalSettings,
 [switch]$PreviewJournalClearConfirmation,
 [string]$JournalDropdownSnapshotFile = "",
 [string]$JournalFilterDropdownSnapshotFile = "",
 [switch]$PreviewJournalFilterTask,
 [switch]$PreviewSettingsBackHover,
 [switch]$PreviewSettingsEnd,
 [switch]$PreviewAbout,
 [switch]$PreviewAboutUiTest,
 [switch]$PreviewUpdate,
 [switch]$PreviewUpdateUiTest,
 [switch]$PreviewLoopWarning,
 [switch]$PreviewLoopSettings,
 [switch]$PreviewLoopUiTest,
 [string]$PreviewClaudeLoopPipe = "",
 [switch]$PreviewClaudeLoopUiTest,
 [switch]$PreviewJournalRecoveryUiTest,
 [string]$JournalRecoverySnapshotFile = "",
 [switch]$PreviewIconUiTest,
 [string]$PreviewStartupReadyFile = "",
 [ValidateRange(0,5000)][int]$PreviewStartupDelayMilliseconds = 0,
 [ValidateRange(-1,3)][int]$PreviewActiveTasks = -1,
 [switch]$PreviewUnconfirmed,
 [ValidateSet("all","codex","claude")][string]$PreviewProvider = "all",
 [string]$ClaudeEventFile = "",
 [string]$DiagnosticDirectory = "",
 [string]$HintSnapshotFile = "",
 [string]$HintRawSnapshotFile = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
if($PreviewLoopUiTest){
 if($PreviewActiveTasks -lt 1 -or -not $PreviewLoopWarning -or -not $SnapshotFile -or -not $DiagnosticDirectory){throw "Loop UI tests require synthetic tasks, a snapshot, and an isolated diagnostic directory."}
 $previewDataPath=[IO.Path]::GetFullPath($DiagnosticDirectory)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $previewDataPath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Loop UI tests require a diagnostic directory inside the temporary folder."}
}
if($PreviewClaudeLoopPipe -or $PreviewClaudeLoopUiTest){
 if(-not $SnapshotFile -or -not $DiagnosticDirectory -or $PreviewActiveTasks -lt 2 -or $PreviewClaudeLoopPipe -cnotmatch '^AITM\.Test\.[A-Za-z0-9_.-]{1,100}$'){
  throw "Claude loop previews require synthetic tasks, a test pipe, a snapshot, and an isolated diagnostic directory."
 }
 $previewDataPath=[IO.Path]::GetFullPath($DiagnosticDirectory)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $previewDataPath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Claude loop previews require a diagnostic directory inside the temporary folder."}
}
if($PreviewJournalRecoveryUiTest){
 if(-not $SnapshotFile -or -not $DiagnosticDirectory -or $PreviewActiveTasks -lt 0){throw "Journal recovery tests require synthetic tasks, a snapshot, and an isolated diagnostic directory."}
 $previewDataPath=[IO.Path]::GetFullPath($DiagnosticDirectory)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $previewDataPath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Journal recovery tests require a diagnostic directory inside the temporary folder."}
}
if($PreviewIconUiTest -and (-not $SnapshotFile -or $PreviewActiveTasks -lt 1)){throw "Icon UI tests require a synthetic snapshot."}
if(($PreviewAbout -or $PreviewAboutUiTest) -and (-not $PreviewAbout -or -not $SnapshotFile -or $PreviewActiveTasks -lt 0)){throw "About previews require synthetic tasks and a snapshot."}
if(($PreviewUpdate -or $PreviewUpdateUiTest) -and (-not $PreviewUpdate -or -not $SnapshotFile -or $PreviewActiveTasks -lt 0)){throw "Update previews require synthetic tasks and a snapshot."}
if($PreviewStartupReadyFile){
 if(-not $SnapshotFile -or -not $DiagnosticDirectory -or $PreviewStartupDelayMilliseconds -le 0){throw "A startup probe requires an isolated snapshot test."}
 $probePath=[IO.Path]::GetFullPath($PreviewStartupReadyFile)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $probePath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "A startup probe must be inside the temporary folder."}
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$sessionIndex = Join-Path $codexHome "session_index.jsonl"
$sessionsDirectory = Join-Path $codexHome "sessions"
$lockDirectory = Join-Path $codexHome "thread-writer-locks"
$claudeEventPath = if($ClaudeEventFile){$ClaudeEventFile}else{Join-Path (Join-Path $env:LOCALAPPDATA "CodexTaskProgress") "claude-events-v2.jsonl"}
$claudeLegacyEventPath = if($ClaudeEventFile){""}else{Join-Path (Join-Path $env:LOCALAPPDATA "CodexTaskProgress") "claude-events.jsonl"}
$script:fingerprint = ""
$script:sessionFiles = @{}
$script:sessionDates = @{}
$script:planCache = @{}
$script:lifecycleState = @{}
$script:observedCodex = @{}
$script:monitorStartedUtc = [DateTime]::UtcNow
$script:allRollouts = $null
$script:lastTasks = @()
$script:lastAllTasks = @()
$script:lastCodexTasks = @()
$script:lastClaudeTasks = @()
$script:sourceErrors = @()
$script:compactTaskId = ""
$script:settingsPath = Join-Path (Join-Path $env:LOCALAPPDATA "CodexTaskProgress") "settings.json"
$script:diagnosticDirectory = if($DiagnosticDirectory){$DiagnosticDirectory}else{Join-Path (Split-Path -Parent $script:settingsPath) "diagnostics"}
$script:diagnosticRuntime = $null
$script:diagnosticError = ""
$script:diagnosticModulesAvailable = $true
$script:claudeLoopChannel=$null
$script:claudeLoopStates=New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
$script:claudeLoopError=""
$script:claudeLoopModulesAvailable=$false
try {
 foreach($module in @("DiagnosticPolicy.ps1","DiagnosticStore.ps1","LoopDetection.ps1","DiagnosticCollector.ps1","DiagnosticRuntime.ps1")){
  $modulePath=Join-Path $PSScriptRoot $module
  if(-not (Test-Path -LiteralPath $modulePath -PathType Leaf)){throw "Diagnostic module missing."}
  . $modulePath
 }
}catch{$script:diagnosticModulesAvailable=$false;$script:diagnosticError="Журнал недоступен"}
try{
 . (Join-Path $PSScriptRoot "ClaudeLoopDetection.ps1")
 if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "ClaudeLoopChannel.cs") -PathType Leaf)){throw "Claude loop channel missing."}
 $script:claudeLoopModulesAvailable=$true
}catch{$script:claudeLoopModulesAvailable=$false}
try { . (Join-Path $PSScriptRoot "ClaudeReaderCore.ps1") }catch{}
$script:releaseUpdatesAvailable=$false
try { . (Join-Path $PSScriptRoot "ReleaseUpdates.ps1");$script:releaseUpdatesAvailable=$true }catch{}
$script:currentVersion='0.2.1-alpha'
$script:availableUpdate=$null
$script:dismissedUpdate=''
$script:updateClient=$null
$script:updateRequest=$null
$script:lastUpdateCheck=[DateTime]::MinValue
$script:themeMode = "system"
$script:resolvedTheme = "dark"
$script:palette = @{}
$accentColor = [Windows.SystemParameters]::WindowGlassColor
$script:accentHex = "#{0:X2}{1:X2}{2:X2}" -f $accentColor.R, $accentColor.G, $accentColor.B
$accentLuma = (0.299 * $accentColor.R) + (0.587 * $accentColor.G) + (0.114 * $accentColor.B)
$script:accentForeground = if ($accentLuma -gt 155) { "#161616" } else { "#FFFFFF" }

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="AI task monitor" Width="590" Height="760" MinWidth="500" MinHeight="500" WindowStartupLocation="CenterScreen" Topmost="True"
 WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanResize" SnapsToDevicePixels="True"
 TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
 <Window.Resources>
  <SolidColorBrush x:Key="Surface" Color="#202020"/>
  <SolidColorBrush x:Key="SurfaceRaised" Color="#282828"/>
  <SolidColorBrush x:Key="Border" Color="#393939"/>
  <SolidColorBrush x:Key="TextPrimary" Color="#F1F1F1"/>
  <SolidColorBrush x:Key="TextSecondary" Color="#ACACAC"/>
  <SolidColorBrush x:Key="TextMuted" Color="#989898"/>
  <SolidColorBrush x:Key="Accent" Color="$script:accentHex"/>
  <SolidColorBrush x:Key="SurfaceHover" Color="#333333"/>
  <SolidColorBrush x:Key="SurfacePressed" Color="#3B3B3B"/>
  <SolidColorBrush x:Key="Divider" Color="#343434"/>
  <SolidColorBrush x:Key="Track" Color="#3A3A3A"/>
  <SolidColorBrush x:Key="ScrollThumbBrush" Color="#555555"/>
  <SolidColorBrush x:Key="ScrollThumbHoverBrush" Color="#747474"/>
  <SolidColorBrush x:Key="TooltipSurface" Color="#171717"/>
  <SolidColorBrush x:Key="TooltipBorder" Color="#3D3D3D"/>
  <Style TargetType="ToolTip">
   <Setter Property="OverridesDefaultStyle" Value="True"/>
   <Setter Property="Background" Value="Transparent"/>
   <Setter Property="BorderBrush" Value="Transparent"/>
   <Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Padding" Value="0"/>
   <Setter Property="SnapsToDevicePixels" Value="True"/>
   <Setter Property="UseLayoutRounding" Value="True"/>
   <Setter Property="Placement" Value="Bottom"/>
   <Setter Property="VerticalOffset" Value="4"/>
   <Setter Property="MaxWidth" Value="360"/>
   <Setter Property="HasDropShadow" Value="False"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip">
    <Grid Background="Transparent" SnapsToDevicePixels="True" UseLayoutRounding="True">
     <Border Background="{DynamicResource TooltipSurface}" BorderBrush="{DynamicResource TooltipBorder}" BorderThickness="1" CornerRadius="10" Padding="12,10" SnapsToDevicePixels="True">
      <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="5" Direction="270" Opacity="0.42" Color="#000000" RenderingBias="Quality"/></Border.Effect>
      <TextBlock Text="{TemplateBinding Content}" TextWrapping="Wrap" FontFamily="Segoe UI Variable Text" FontSize="12" LineHeight="17" Foreground="{DynamicResource TextPrimary}"/>
     </Border>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Thickness x:Key="CursorHintShadowInset">18,18,18,23</Thickness>
  <Style x:Key="CursorHintStyle" TargetType="ToolTip" BasedOn="{StaticResource {x:Type ToolTip}}">
   <Setter Property="MaxWidth" Value="396"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip">
    <Grid Background="Transparent" SnapsToDevicePixels="True" UseLayoutRounding="True">
     <Border Margin="{StaticResource CursorHintShadowInset}" Background="{DynamicResource TooltipSurface}" BorderBrush="{DynamicResource TooltipBorder}" BorderThickness="1" CornerRadius="10" Padding="12,10" SnapsToDevicePixels="True">
      <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="5" Direction="270" Opacity="0.42" Color="#000000" RenderingBias="Quality"/></Border.Effect>
      <TextBlock Text="{TemplateBinding Content}" TextWrapping="Wrap" FontFamily="Segoe UI Variable Text" FontSize="12" LineHeight="17" Foreground="{DynamicResource TextPrimary}"/>
     </Border>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="KeyboardFocusStyle">
   <Setter Property="Control.Template"><Setter.Value><ControlTemplate><Border BorderBrush="{DynamicResource Accent}" BorderThickness="1" CornerRadius="6"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="Button">
   <Setter Property="FontFamily" Value="Segoe UI Variable Text"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
  </Style>
  <Style x:Key="TitleButton" TargetType="Button">
   <Setter Property="Width" Value="36"/><Setter Property="Height" Value="34"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
   <Setter Property="Template">
    <Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="ButtonSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="5">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Border>
     <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value>
   </Setter>
  </Style>
  <Style x:Key="SettingsOptionStyle" TargetType="Button">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="10,0"/>
   <Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="OptionSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="5" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="OptionSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger>
     <Trigger Property="IsPressed" Value="True"><Setter TargetName="OptionSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="FooterNavStyle" TargetType="Button">
   <Setter Property="Height" Value="38"/><Setter Property="Padding" Value="10,0"/>
   <Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="FooterSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="7" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
    </Border>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="CompactDotStyle" TargetType="Button">
   <Setter Property="Width" Value="18"/><Setter Property="Height" Value="18"/><Setter Property="Padding" Value="0"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="CompactDotSurface" Background="Transparent" BorderBrush="Transparent" BorderThickness="0" CornerRadius="7"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="SourceActionStyle" TargetType="Button">
   <Setter Property="Height" Value="28"/><Setter Property="Padding" Value="10,0"/><Setter Property="Background" Value="{DynamicResource SurfaceHover}"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="SourceActionSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="SourceActionSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="UpdateActionStyle" TargetType="Button">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="12,0"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="Background" Value="{DynamicResource SurfaceHover}"/>
   <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="ActionSurface" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ActionSurface" Property="Opacity" Value="0.85"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="JournalComboItemStyle" TargetType="ComboBoxItem">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="10,0"/><Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
    <Border x:Name="ItemSurface" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}"><TextBlock Text="{TemplateBinding Content}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger>
     <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="JournalComboStyle" TargetType="ComboBox">
   <Setter Property="Height" Value="28"/><Setter Property="MinWidth" Value="108"/><Setter Property="FontFamily" Value="Segoe UI Variable Text"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="FontSize" Value="12"/><Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="Background" Value="{DynamicResource SurfaceHover}"/>
   <Setter Property="ItemContainerStyle" Value="{StaticResource JournalComboItemStyle}"/><Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
    <Grid>
     <ToggleButton x:Name="DropDownToggle" Focusable="False" Background="{TemplateBinding Background}" IsChecked="{Binding IsDropDownOpen,Mode=TwoWay,RelativeSource={RelativeSource TemplatedParent}}">
      <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border x:Name="ToggleSurface" Background="{TemplateBinding Background}" CornerRadius="7"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ToggleSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template>
     </ToggleButton>
     <TextBlock Text="{TemplateBinding SelectionBoxItem}" TextTrimming="CharacterEllipsis" Margin="10,0,28,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
     <Path Data="M 4,7 L 10,13 L 16,7" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="Uniform" Width="9" Height="6" HorizontalAlignment="Right" Margin="0,0,10,0" IsHitTestVisible="False"/>
     <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="None">
      <Border Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="7" Padding="4" MinWidth="{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}" MaxWidth="{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="248">
       <ScrollViewer CanContentScroll="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><ItemsPresenter/></ScrollViewer>
      </Border>
     </Popup>
    </Grid>
    <ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ProviderTabStyle" TargetType="Button">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="13,0"/><Setter Property="Margin" Value="0,0,4,0"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="RefreshButtonStyle" TargetType="Button">
   <Setter Property="Padding" Value="14,8"/><Setter Property="Background" Value="#2C2C2C"/>
   <Setter Property="Foreground" Value="#E7E7E7"/><Setter Property="BorderBrush" Value="#454545"/><Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="RefreshSurface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="RefreshSurface" Property="Background" Value="#363636"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ProgressBar">
   <Setter Property="Height" Value="3"/><Setter Property="Background" Value="{DynamicResource Track}"/><Setter Property="Foreground" Value="{DynamicResource Accent}"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar">
    <Grid>
     <Border x:Name="PART_Track" Height="3" VerticalAlignment="Center" Background="{TemplateBinding Background}" CornerRadius="1.5"/>
     <Grid x:Name="PART_Indicator" HorizontalAlignment="Left">
      <Border Height="3" VerticalAlignment="Center" Background="{TemplateBinding Foreground}" CornerRadius="1.5"/>
     </Grid>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ScrollRepeat" TargetType="RepeatButton">
   <Setter Property="Focusable" Value="False"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ScrollThumb" TargetType="Thumb">
   <Setter Property="MinHeight" Value="32"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
    <Border x:Name="ThumbSurface" Width="5" Margin="0,2" CornerRadius="2.5" Background="{DynamicResource ScrollThumbBrush}"/>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbSurface" Property="Background" Value="{DynamicResource ScrollThumbHoverBrush}"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ScrollBar">
   <Setter Property="Width" Value="7"/><Setter Property="Margin" Value="2,0,0,0"/><Setter Property="Background" Value="Transparent"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
    <Grid Background="Transparent">
     <Track x:Name="PART_Track" IsDirectionReversed="True">
      <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollRepeat}" Command="{x:Static ScrollBar.PageUpCommand}"/></Track.DecreaseRepeatButton>
      <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
      <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollRepeat}" Command="{x:Static ScrollBar.PageDownCommand}"/></Track.IncreaseRepeatButton>
     </Track>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>

 <Grid Background="Transparent">
  <Border x:Name="WindowFrame" Margin="28" Background="{DynamicResource Surface}" BorderThickness="0" SnapsToDevicePixels="True">
   <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="8" Direction="270" Opacity="0.48" Color="#000000"/></Border.Effect>
   <Grid>
   <Grid x:Name="ExpandedView">
    <Grid.RowDefinitions><RowDefinition Height="62"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="54"/></Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="18,0,12,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Image x:Name="ExpandedTitleIcon" Width="16" Height="16" Margin="0,0,16,0" VerticalAlignment="Center" Stretch="Uniform" Visibility="Collapsed" IsHitTestVisible="False" Focusable="False"/>
      <StackPanel VerticalAlignment="Center">
       <TextBlock Text="AI task monitor" FontFamily="Segoe UI Variable Display Semibold" FontSize="14" Foreground="{DynamicResource TextPrimary}"/>
      </StackPanel>
     </StackPanel>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="PinButton" Style="{StaticResource TitleButton}" Visibility="Collapsed" AutomationProperties.Name="Окно всегда поверх других окон">
       <Path x:Name="PinIcon" Data="M 7,3 L 13,3 L 12,8 L 15,11 L 15,12 L 10.7,12 L 10,17 L 9.3,12 L 5,12 L 5,11 L 8,8 Z" Fill="{DynamicResource TextSecondary}" Stretch="Uniform" Width="15" Height="15"/>
      </Button>
      <Button x:Name="TaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="MinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Компактный режим">
       <Path Data="M 4,7 L 10,13 L 16,7" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="CloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть">
       <Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
     </StackPanel>
    </Grid>

     <Border Grid.Row="1" BorderBrush="{DynamicResource Divider}" BorderThickness="0,0,0,1">
     <Grid Margin="20,18,20,17">
      <StackPanel>
       <TextBlock Text="Ход выполнения" FontFamily="Segoe UI Variable Display Semibold" FontSize="22" Foreground="{DynamicResource TextPrimary}"/>
       <Grid x:Name="ProviderTabsHost" Visibility="Collapsed" Margin="0,13,0,0" HorizontalAlignment="Left">
        <Path x:Name="ProviderTabsShape" Fill="{DynamicResource SurfaceRaised}"/>
        <Border Padding="3"><StackPanel x:Name="ProviderTabsPanel" Orientation="Horizontal"/></Border>
       </Grid>
      </StackPanel>
     </Grid>
    </Border>

    <Grid Grid.Row="2">
     <ScrollViewer x:Name="TasksScroll" Margin="20,16,20,18" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled">
      <StackPanel x:Name="TasksPanel"/>
     </ScrollViewer>
     <ScrollBar x:Name="TasksScrollBar" Orientation="Vertical" HorizontalAlignment="Right" Margin="0,16,2,18" Visibility="Hidden"/>
    </Grid>
    <Border Grid.Row="3" BorderBrush="{DynamicResource Divider}" BorderThickness="0,1,0,0" Padding="10,7,10,7">
     <Button x:Name="SettingsFooterButton" Style="{StaticResource FooterNavStyle}" HorizontalAlignment="Left" AutomationProperties.Name="Открыть настройки">
      <StackPanel Orientation="Horizontal">
       <Grid Width="16" Height="16" VerticalAlignment="Center">
        <Path Data="M 5.50,3.67 L 6.37,3.27 L 6.40,1.60 L 9.60,1.60 L 9.63,3.27 L 10.50,3.67 L 11.28,4.23 L 12.75,3.42 L 14.34,6.18 L 12.91,7.05 L 13,8 L 12.91,8.95 L 14.34,9.82 L 12.75,12.58 L 11.28,11.77 L 10.50,12.33 L 9.63,12.73 L 9.60,14.40 L 6.40,14.40 L 6.37,12.73 L 5.50,12.33 L 4.72,11.77 L 3.25,12.58 L 1.66,9.82 L 3.09,8.95 L 3,8 L 3.09,7.05 L 1.66,6.18 L 3.25,3.42 L 4.72,4.23 Z" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.15" StrokeLineJoin="Round" Fill="Transparent"/>
        <Ellipse Width="4.5" Height="4.5" HorizontalAlignment="Center" VerticalAlignment="Center" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.15" Fill="Transparent"/>
       </Grid>
       <TextBlock Text="Настройки" Margin="10,0,0,0" VerticalAlignment="Center" FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource TextPrimary}"/>
      </StackPanel>
     </Button>
    </Border>
   </Grid>

   <Grid x:Name="CompactView" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="50"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="16,0,8,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Image x:Name="CompactTitleIcon" Width="16" Height="16" Margin="0,0,16,0" VerticalAlignment="Center" Stretch="Uniform" Visibility="Collapsed" IsHitTestVisible="False" Focusable="False"/>
      <TextBlock Text="AI task monitor" FontFamily="Segoe UI Variable Display Semibold" FontSize="14" Foreground="{DynamicResource TextPrimary}"/>
     </StackPanel>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="CompactTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="ExpandButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Развернуть">
       <Path Data="M 4,13 L 10,7 L 16,13" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="CompactCloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть">
       <Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
     </StackPanel>
    </Grid>
    <Border Grid.Row="1" BorderThickness="0">
     <StackPanel Margin="16,10,16,12">
      <StackPanel x:Name="CompactTasksPanel"/>
      <StackPanel x:Name="CompactDotsPanel" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,1,0,0"/>
      <TextBlock x:Name="CompactMoreText" Visibility="Collapsed" Margin="0,6,0,0" FontFamily="Segoe UI Variable Text" FontSize="11.5" Foreground="{DynamicResource TextMuted}"/>
     </StackPanel>
    </Border>
   </Grid>

   <Grid x:Name="SettingsView" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="62"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="12,0,12,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Button x:Name="SettingsBackButton" Width="28" Height="28" HorizontalAlignment="Left" VerticalAlignment="Center" Style="{StaticResource TitleButton}" AutomationProperties.Name="Назад к задачам">
      <TextBlock Text="&#xE72B;" FontFamily="Segoe Fluent Icons" FontSize="13" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Button>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="SettingsTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="SettingsCloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть">
       <Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
     </StackPanel>
    </Grid>

    <Grid Grid.Row="1">
     <ScrollViewer x:Name="SettingsScroll" Margin="20,10,28,20" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>
      <TextBlock Text="Настройки" FontFamily="Segoe UI Variable Display Semibold" FontSize="22" Foreground="{DynamicResource TextPrimary}"/>
      <TextBlock Text="Внешний вид" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border Margin="0,12,0,0" Padding="6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Button x:Name="SystemThemeButton" Style="{StaticResource SettingsOptionStyle}" Content="Системная"/>
        <Button x:Name="DarkThemeButton" Style="{StaticResource SettingsOptionStyle}" Content="Тёмная"/>
        <Button x:Name="LightThemeButton" Style="{StaticResource SettingsOptionStyle}" Content="Светлая"/>
       </StackPanel>
      </Border>

      <TextBlock Text="Источники" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border Margin="0,12,0,0" Padding="16,6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Codex" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="CodexSourceStatus" Grid.Column="1" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="50">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Claude Code" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="ClaudeSourceStatus" Grid.Column="1" Margin="0,0,8,0" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <Button x:Name="ClaudeSourceAction" Grid.Column="2" Style="{StaticResource SourceActionStyle}"/>
        </Grid>
        <TextBlock Margin="0,0,0,12" Text="Приложение добавит локальные hooks в настройки Claude Code. Права администратора, токены и вход в аккаунт не нужны. После подключения перезапустите Claude Code. Затем задачи будут появляться автоматически во время работы." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
       </StackPanel>
      </Border>
      <TextBlock Text="Журнал" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border x:Name="JournalSettingsSection" Margin="0,12,0,0" Padding="16,6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Срок хранения" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="JournalDaysCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Срок хранения журнала"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Максимальный размер" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="JournalSizeCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Максимальный размер журнала"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <StackPanel Orientation="Horizontal" Margin="0,10,0,6">
         <Button x:Name="JournalOpenButton" Content="Открыть журнал" Style="{StaticResource SourceActionStyle}"/>
         <Button x:Name="JournalClearButton" Content="Очистить" Style="{StaticResource SourceActionStyle}" Margin="8,0,0,0"/>
        </StackPanel>
        <TextBlock x:Name="JournalSettingsError" Visibility="Collapsed" Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
        <StackPanel x:Name="JournalClearConfirmation" Visibility="Collapsed" Margin="0,6,0,8">
         <TextBlock Text="Удалить все события журнала? История Codex и Claude Code не изменится." TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
          <Button x:Name="JournalConfirmClearButton" Content="Удалить" Style="{StaticResource SourceActionStyle}"/>
          <Button x:Name="JournalCancelClearButton" Content="Отмена" Style="{StaticResource SourceActionStyle}" Margin="8,0,0,0"/>
         </StackPanel>
        </StackPanel>
       </StackPanel>
      </Border>
      <TextBlock Text="Возможный цикл" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border x:Name="LoopSettingsSection" Margin="0,12,0,0" Padding="16,6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Количество ошибок" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="LoopThresholdCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Количество повторных ошибок для предупреждения"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Интервал" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="LoopWindowCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Интервал для повторных ошибок"/>
        </Grid>
        <TextBlock Margin="0,0,0,8" Text="Предупреждение не останавливает задачу." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <TextBlock x:Name="LoopSettingsError" Visibility="Collapsed" Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
       </StackPanel>
      </Border>
      <Button x:Name="AboutSettingsButton" Content="О приложении" Margin="-10,22,0,0" HorizontalAlignment="Left" Style="{StaticResource FooterNavStyle}" FontSize="13" AutomationProperties.Name="О приложении"/>
      <Button x:Name="FeedbackSettingsButton" Content="Отзывы и предложения" Margin="-10,0,0,0" HorizontalAlignment="Left" Style="{StaticResource FooterNavStyle}" FontSize="13" AutomationProperties.Name="Отзывы и предложения"/>
      <TextBlock x:Name="FeedbackError" Visibility="Collapsed" Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}" Text="Не удалось открыть почтовое приложение. Напишите на truea.k.a.ru@gmail.com."/>
      </StackPanel>
     </ScrollViewer>
     <ScrollBar x:Name="SettingsScrollBar" Orientation="Vertical" HorizontalAlignment="Right" Margin="0,10,7,20" Visibility="Hidden"/>
    </Grid>
   </Grid>

   <Grid x:Name="AboutView" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="62"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="12,0,12,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Button x:Name="AboutBackButton" Width="28" Height="28" HorizontalAlignment="Left" VerticalAlignment="Center" Style="{StaticResource TitleButton}" AutomationProperties.Name="Назад к настройкам">
      <TextBlock Text="&#xE72B;" FontFamily="Segoe Fluent Icons" FontSize="13" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Button>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="AboutTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="AboutCloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть">
       <Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
     </StackPanel>
    </Grid>
    <Grid Grid.Row="1">
     <ScrollViewer x:Name="AboutScroll" Margin="20,10,28,20" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>
       <TextBlock x:Name="AboutHeading" Text="О приложении" FontFamily="Segoe UI Variable Display Semibold" FontSize="22" Foreground="{DynamicResource TextPrimary}"/>
       <TextBlock x:Name="AboutVersionText" Text="AI task monitor · версия $($script:currentVersion.Replace('-',' '))" Margin="0,18,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource TextPrimary}"/>
       <TextBlock x:Name="AboutProviders" Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="AI Task Monitor показывает активные задачи и текущее действие. Сейчас поддерживаются Codex и Claude Code."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="При нескольких источниках можно переключать задачи по вкладкам. Компактное окно остаётся поверх других и показывает до трёх задач с переключением между ними. Тему можно выбрать вручную или использовать тему Windows. Если источник недоступен, приложение сообщит об этом."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Если задача публикует план, приложение показывает выполненные, текущий и следующие этапы. В карточке одновременно видны до пяти этапов; остальные можно прокрутить. Без плана отображается текущее действие без списка этапов."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Точный процент показывается числом, приблизительная оценка — со знаком ≈. Если процент рассчитан по плану, он отражает долю выполненных этапов, а не всей работы. Без надёжной оценки процент скрыт."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Диагностический журнал хранится локально. В настройках можно выбрать срок и размер хранения, просмотреть события или очистить журнал."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Приложение может предупредить о возможном цикле при повторных ошибках одной команды. Это предположение, оно не останавливает задачу."/>
       <TextBlock Margin="0,12,0,8" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Данные задач обрабатываются локально. Для Claude Code после подключения используются локальные hooks. Самому монитору не нужны вход в аккаунт, токены или права администратора."/>
       <TextBlock Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="При запуске и раз в сутки приложение проверяет новые версии на GitHub, не отправляя данные задач. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению."/>
      </StackPanel>
     </ScrollViewer>
     <ScrollBar x:Name="AboutScrollBar" Orientation="Vertical" HorizontalAlignment="Right" Margin="0,10,7,20" Visibility="Hidden"/>
    </Grid>
   </Grid>

   <Grid x:Name="JournalView" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="62"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="12,0,12,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Button x:Name="JournalBackButton" Width="28" Height="28" HorizontalAlignment="Left" VerticalAlignment="Center" Style="{StaticResource TitleButton}" AutomationProperties.Name="Назад к настройкам">
      <TextBlock Text="&#xE72B;" FontFamily="Segoe Fluent Icons" FontSize="13" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Button>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="JournalTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач"><Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/></Button>
      <Button x:Name="JournalCloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть"><Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/></Button>
     </StackPanel>
    </Grid>
    <StackPanel Grid.Row="1" Margin="20,18,20,0">
     <TextBlock Text="Журнал" FontFamily="Segoe UI Variable Display Semibold" FontSize="22" Foreground="{DynamicResource TextPrimary}"/>
     <ComboBox x:Name="JournalTaskFilter" Style="{StaticResource JournalComboStyle}" HorizontalAlignment="Stretch" Margin="0,16,0,0" AutomationProperties.Name="Фильтр журнала по задаче"/>
    </StackPanel>
    <Grid Grid.Row="2" Margin="20,16,20,20">
     <ListBox x:Name="JournalEventsList" Background="Transparent" BorderThickness="0" ScrollViewer.CanContentScroll="True" ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Disabled" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" AutomationProperties.Name="События журнала">
      <ListBox.ItemContainerStyle><Style TargetType="ListBoxItem">
       <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
       <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="EventSurface" Background="Transparent" BorderBrush="{DynamicResource Divider}" BorderThickness="0,0,0,1" Padding="0,10"><ContentPresenter HorizontalAlignment="Stretch"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="EventSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
      </Style></ListBox.ItemContainerStyle>
      <ListBox.ItemTemplate><DataTemplate>
       <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="95"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBlock Text="{Binding TimeLabel}" FontFamily="Segoe UI Variable Text" FontSize="12" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" Text="{Binding SourceLabel}" FontFamily="Segoe UI Variable Text" FontSize="12" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="2" Text="{Binding EventLabel}" FontFamily="Segoe UI Variable Text" FontSize="13" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap" VerticalAlignment="Center"/>
       </Grid>
      </DataTemplate></ListBox.ItemTemplate>
     </ListBox>
     <TextBlock x:Name="JournalEmptyText" Visibility="Collapsed" FontSize="14" Foreground="{DynamicResource TextSecondary}" Margin="4,24,0,0" TextWrapping="Wrap"/>
    </Grid>
   </Grid>

   <Grid x:Name="UpdateOverlay" Visibility="Collapsed" Background="#99000000" Panel.ZIndex="19" KeyboardNavigation.TabNavigation="Cycle">
    <Grid x:Name="UpdateDialog" Width="368" HorizontalAlignment="Center" VerticalAlignment="Center">
     <Path x:Name="UpdateDialogShape" Fill="{DynamicResource SurfaceRaised}" Stroke="{DynamicResource Border}" StrokeThickness="1" IsHitTestVisible="False">
      <Path.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="8" Direction="270" Opacity="0.48" Color="#000000"/></Path.Effect>
     </Path>
     <StackPanel Margin="24">
      <TextBlock Text="Доступна новая версия" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap"/>
      <TextBlock x:Name="UpdateVersionText" Margin="0,14,0,0" FontSize="13" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap"/>
      <TextBlock Text="Скачайте приложение, полностью закройте старую версию и переустановите новую." Margin="0,12,0,0" FontSize="13" LineHeight="19" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap"/>
      <TextBlock x:Name="UpdateOpenError" Visibility="Collapsed" Text="Не удалось открыть страницу загрузки." Margin="0,10,0,0" FontSize="12" Foreground="{DynamicResource TextSecondary}" TextWrapping="Wrap"/>
      <Grid Margin="0,22,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
       <Button x:Name="UpdateLaterButton" Content="Позже" Style="{StaticResource UpdateActionStyle}" AutomationProperties.Name="Напомнить при следующем запуске"/>
       <Button x:Name="UpdateDownloadButton" Grid.Column="2" Content="Скачать" Style="{StaticResource UpdateActionStyle}" Background="{DynamicResource Accent}" Foreground="$script:accentForeground" AutomationProperties.Name="Скачать новую версию"/>
      </Grid>
     </StackPanel>
    </Grid>
   </Grid>
   <Path x:Name="WindowOutline" Stroke="{DynamicResource Border}" StrokeThickness="1" IsHitTestVisible="False" Panel.ZIndex="20"/>
   </Grid>
  </Border>
 </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$iconPath = Join-Path $PSScriptRoot "assets\app-icon.ico"
$script:applicationIcon = $null
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
 try {
  $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]::new($iconPath, [UriKind]::Absolute), [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
  $window.Icon = @($decoder.Frames | Where-Object { $_.PixelWidth -eq 32 } | Select-Object -First 1)[0]
  foreach($titleIconName in @("ExpandedTitleIcon","CompactTitleIcon")){
   $titleIcon=$window.FindName($titleIconName);$titleIcon.Source=$window.Icon;$titleIcon.Visibility="Visible"
  }
  $script:applicationIcon = [Drawing.Icon]::new($iconPath, 16, 16)
 } catch {
  Write-Warning "Не удалось загрузить иконку AI task monitor: $($_.Exception.Message)"
 }
}
$script:shellIdentityAvailable=$false
try{
 $identitySource=Join-Path $PSScriptRoot "AppShellIdentity.cs"
 if(Test-Path -LiteralPath $identitySource -PathType Leaf){
  if(-not ("AITaskMonitor.Windows.AppShellIdentity" -as [type])){Add-Type -Path $identitySource -ErrorAction Stop}
  $script:shellIdentityAvailable=$true
 }
}catch{Write-Warning "Не удалось настроить значок панели задач: $($_.Exception.Message)"}
$window.Add_SourceInitialized({
 if(-not $script:shellIdentityAvailable){return}
 try{
  $handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
  [AITaskMonitor.Windows.AppShellIdentity]::Apply($handle,$iconPath,(Join-Path $PSScriptRoot "AI task monitor.exe"))
 }catch{Write-Warning "Не удалось настроить значок панели задач: $($_.Exception.Message)"}
})
$window.Add_Closing({
 if(-not $script:shellIdentityAvailable){return}
 try{
  $handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
  if($handle -ne [IntPtr]::Zero){[AITaskMonitor.Windows.AppShellIdentity]::Clear($handle)}
 }catch{}
})
$windowFrame = $window.FindName("WindowFrame")
$windowOutline = $window.FindName("WindowOutline")
$expandedView = $window.FindName("ExpandedView")
$compactView = $window.FindName("CompactView")
$settingsView = $window.FindName("SettingsView")
$aboutView = $window.FindName("AboutView")
$journalView = $window.FindName("JournalView")
$updateOverlay = $window.FindName("UpdateOverlay")
$updateDialog = $window.FindName("UpdateDialog")
$updateDialogShape = $window.FindName("UpdateDialogShape")
$updateVersionText = $window.FindName("UpdateVersionText")
$updateOpenError = $window.FindName("UpdateOpenError")
$updateLaterButton = $window.FindName("UpdateLaterButton")
$updateDownloadButton = $window.FindName("UpdateDownloadButton")
$tasksPanel = $window.FindName("TasksPanel")
$tasksScroll = $window.FindName("TasksScroll")
$tasksScrollBar = $window.FindName("TasksScrollBar")
$providerTabsHost = $window.FindName("ProviderTabsHost")
$providerTabsShape = $window.FindName("ProviderTabsShape")
$providerTabsPanel = $window.FindName("ProviderTabsPanel")
$pinButton = $window.FindName("PinButton")
$pinIcon = $window.FindName("PinIcon")
$minimizeButton = $window.FindName("MinimizeButton")
$taskbarMinimizeButton = $window.FindName("TaskbarMinimizeButton")
$closeButton = $window.FindName("CloseButton")
$compactTasksPanel = $window.FindName("CompactTasksPanel")
$compactDotsPanel = $window.FindName("CompactDotsPanel")
$compactMoreText = $window.FindName("CompactMoreText")
$expandButton = $window.FindName("ExpandButton")
$compactTaskbarMinimizeButton = $window.FindName("CompactTaskbarMinimizeButton")
$compactCloseButton = $window.FindName("CompactCloseButton")
$settingsFooterButton = $window.FindName("SettingsFooterButton")
$settingsBackButton = $window.FindName("SettingsBackButton")
$settingsTaskbarMinimizeButton = $window.FindName("SettingsTaskbarMinimizeButton")
$settingsCloseButton = $window.FindName("SettingsCloseButton")
$settingsScroll = $window.FindName("SettingsScroll")
$settingsScrollBar = $window.FindName("SettingsScrollBar")
$aboutSettingsButton = $window.FindName("AboutSettingsButton")
$feedbackSettingsButton = $window.FindName("FeedbackSettingsButton")
$feedbackError = $window.FindName("FeedbackError")
$aboutBackButton = $window.FindName("AboutBackButton")
$aboutHeading = $window.FindName("AboutHeading")
$aboutVersionText = $window.FindName("AboutVersionText")
$aboutProviders = $window.FindName("AboutProviders")
$aboutTaskbarMinimizeButton = $window.FindName("AboutTaskbarMinimizeButton")
$aboutCloseButton = $window.FindName("AboutCloseButton")
$aboutScroll = $window.FindName("AboutScroll")
$aboutScrollBar = $window.FindName("AboutScrollBar")
$journalSettingsSection = $window.FindName("JournalSettingsSection")
$loopSettingsSection = $window.FindName("LoopSettingsSection")
$loopThresholdCombo = $window.FindName("LoopThresholdCombo")
$loopWindowCombo = $window.FindName("LoopWindowCombo")
$loopSettingsError = $window.FindName("LoopSettingsError")
$journalDaysCombo = $window.FindName("JournalDaysCombo")
$journalSizeCombo = $window.FindName("JournalSizeCombo")
$journalOpenButton = $window.FindName("JournalOpenButton")
$journalClearButton = $window.FindName("JournalClearButton")
$journalSettingsError = $window.FindName("JournalSettingsError")
$journalClearConfirmation = $window.FindName("JournalClearConfirmation")
$journalConfirmClearButton = $window.FindName("JournalConfirmClearButton")
$journalCancelClearButton = $window.FindName("JournalCancelClearButton")
$journalBackButton = $window.FindName("JournalBackButton")
$journalTaskbarMinimizeButton = $window.FindName("JournalTaskbarMinimizeButton")
$journalCloseButton = $window.FindName("JournalCloseButton")
$journalTaskFilter = $window.FindName("JournalTaskFilter")
$journalEventsList = $window.FindName("JournalEventsList")
$journalEmptyText = $window.FindName("JournalEmptyText")
$systemThemeButton = $window.FindName("SystemThemeButton")
$darkThemeButton = $window.FindName("DarkThemeButton")
$lightThemeButton = $window.FindName("LightThemeButton")
$codexSourceStatus = $window.FindName("CodexSourceStatus")
$claudeSourceStatus = $window.FindName("ClaudeSourceStatus")
$claudeSourceAction = $window.FindName("ClaudeSourceAction")
$script:isCompact = $false
$script:showingSettings = $false
$script:showingAbout = $false
$script:showingJournal = $false
$script:updatingJournalControls = $false
$script:updatingLoopControls = $false
$script:loopUiError = ""
$script:previewLoopDismissed = $false
$script:journalFingerprint = ""
$script:journalUiError = ""
$script:navigationByKeyboard = $false
$script:expandedBounds = $null
$script:selectedProvider = $PreviewProvider
$script:cardRadius = 12.0
$script:tabPadding = 3.0
$script:previewHintTarget = $null
$tasksScroll.Add_ScrollChanged({
 $tasksScrollBar.Maximum=$tasksScroll.ScrollableHeight
 $tasksScrollBar.ViewportSize=$tasksScroll.ViewportHeight
 $tasksScrollBar.Value=$tasksScroll.VerticalOffset
 $tasksScrollBar.Visibility=$(if($tasksScroll.ScrollableHeight -gt 0){"Visible"}else{"Hidden"})
})
$tasksScrollBar.Add_ValueChanged({if([Math]::Abs($tasksScroll.VerticalOffset-$tasksScrollBar.Value) -gt 0.5){$tasksScroll.ScrollToVerticalOffset($tasksScrollBar.Value)}})
$settingsScroll.Add_ScrollChanged({
 $settingsScrollBar.Maximum=$settingsScroll.ScrollableHeight
 $settingsScrollBar.ViewportSize=$settingsScroll.ViewportHeight
 $settingsScrollBar.Value=$settingsScroll.VerticalOffset
 $settingsScrollBar.Visibility=$(if($settingsScroll.ScrollableHeight -gt 0){"Visible"}else{"Hidden"})
})
$settingsScrollBar.Add_ValueChanged({if([Math]::Abs($settingsScroll.VerticalOffset-$settingsScrollBar.Value) -gt 0.5){$settingsScroll.ScrollToVerticalOffset($settingsScrollBar.Value)}})
$aboutScroll.Add_ScrollChanged({
 $aboutScrollBar.Maximum=$aboutScroll.ScrollableHeight
 $aboutScrollBar.ViewportSize=$aboutScroll.ViewportHeight
 $aboutScrollBar.Value=$aboutScroll.VerticalOffset
 $aboutScrollBar.Visibility=$(if($aboutScroll.ScrollableHeight -gt 0){"Visible"}else{"Hidden"})
})
$aboutScrollBar.Add_ValueChanged({if([Math]::Abs($aboutScroll.VerticalOffset-$aboutScrollBar.Value) -gt 0.5){$aboutScroll.ScrollToVerticalOffset($aboutScrollBar.Value)}})

function Prop($object, [string]$name, $fallback = $null) {
 if ($null -ne $object -and $null -ne $object.PSObject.Properties[$name]) { return $object.$name }
 return $fallback
}

function Brush([string]$color) { return [Windows.Media.BrushConverter]::new().ConvertFromString($color) }

function Squircle-Geometry([double]$width,[double]$height,[double]$radius,[double]$inset = 0) {
 $left=$inset; $top=$inset; $right=[Math]::Max($left,$width-$inset); $bottom=[Math]::Max($top,$height-$inset)
 $r=[Math]::Min($radius,[Math]::Min(($right-$left)/2,($bottom-$top)/2))
 $k=$r*0.72
 $figure=New-Object Windows.Media.PathFigure
 $figure.StartPoint=[Windows.Point]::new($left+$r,$top)
 $figure.IsClosed=$true
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($right-$r,$top),$true))
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($right-$r+$k,$top),[Windows.Point]::new($right,$top+$r-$k),[Windows.Point]::new($right,$top+$r),$true))
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($right,$bottom-$r),$true))
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($right,$bottom-$r+$k),[Windows.Point]::new($right-$r+$k,$bottom),[Windows.Point]::new($right-$r,$bottom),$true))
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($left+$r,$bottom),$true))
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($left+$r-$k,$bottom),[Windows.Point]::new($left,$bottom-$r+$k),[Windows.Point]::new($left,$bottom-$r),$true))
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($left,$top+$r),$true))
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($left,$top+$r-$k),[Windows.Point]::new($left+$r-$k,$top),[Windows.Point]::new($left+$r,$top),$true))
 $geometry=New-Object Windows.Media.PathGeometry
 $geometry.Figures.Add($figure)
 return $geometry
}

function Update-SquircleGeometry {
 if($windowFrame.ActualWidth -gt 0 -and $windowFrame.ActualHeight -gt 0){
  $windowFrame.Clip=Squircle-Geometry $windowFrame.ActualWidth $windowFrame.ActualHeight 16 0
  $windowOutline.Data=Squircle-Geometry $windowFrame.ActualWidth $windowFrame.ActualHeight 16 0.5
 }
 if($providerTabsHost.ActualWidth -gt 0 -and $providerTabsHost.ActualHeight -gt 0){
  $providerTabsShape.Data=Squircle-Geometry $providerTabsHost.ActualWidth $providerTabsHost.ActualHeight $script:cardRadius 0
 }
}

function Windows-Theme {
 try { if((Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme) -eq 1){return "light"} } catch {}
 return "dark"
}

function Load-ThemeMode {
 try {
  if(Test-Path -LiteralPath $script:settingsPath){
   $saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
   $mode=[string](Prop $saved "theme" "system")
   if($mode -in @("system","dark","light")){return $mode}
  }
 }catch{}
 return "system"
}

function Save-ThemeMode([string]$mode) {
 try {
  $folder=Split-Path -Parent $script:settingsPath; New-Item -ItemType Directory -Path $folder -Force|Out-Null
  [PSCustomObject]@{theme=$mode}|ConvertTo-Json|Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
 }catch{}
}

function Update-ThemeButtons {
 foreach($entry in @(@($systemThemeButton,"system"),@($darkThemeButton,"dark"),@($lightThemeButton,"light"))){
  $entry[0].Background=if($script:themeMode -eq $entry[1]){Brush $script:palette.Pressed}else{[Windows.Media.Brushes]::Transparent}
 }
}

function Update-SettingsButtonName {
 $modeName=switch($script:themeMode){"system"{"Системная"};"light"{"Светлая"};default{"Тёмная"}}
 $name="Открыть настройки. Тема: $modeName"
 [Windows.Automation.AutomationProperties]::SetName($settingsFooterButton,$name)
}

function Claude-ConnectionState {
 $path=Join-Path (Join-Path $env:USERPROFILE ".claude") "settings.json"
 try{$attributes=[IO.File]::GetAttributes($path)}
 catch [IO.FileNotFoundException]{return "disconnected"}
 catch [IO.DirectoryNotFoundException]{return "disconnected"}
 if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){throw "Claude Code settings are not a file."}
 $hookPath=Join-Path $PSScriptRoot "ClaudeTaskHook.ps1"
 $legacy='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$hookPath+'"'
 $hookScript="& '"+$hookPath.Replace("'","''")+"'"
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hookScript))
 $expected='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
 $raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
 if(-not $raw.Trim()){return "disconnected"}
 $settings=$raw|ConvertFrom-Json -ErrorAction Stop
 if($null -eq $settings -or $settings -is [array] -or $settings -is [string] -or $settings -is [ValueType]){throw "Claude Code settings are not a JSON object."}
 $hooksProperty=$settings.PSObject.Properties["hooks"]
 if($null -eq $hooksProperty){return "disconnected"}
 if($hooksProperty.Value -isnot [PSCustomObject]){throw "Claude Code hooks are not a JSON object."}
 $knownEvents=@("UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","TaskCreated","TaskCompleted","SubagentStart","SubagentStop","Stop","SessionEnd")
 $connected=$false
 foreach($eventProperty in $hooksProperty.Value.PSObject.Properties){
  if($eventProperty.Name -notin $knownEvents){continue}
  if($eventProperty.Value -isnot [array]){throw "Claude Code hook groups are not an array."}
  foreach($entry in $eventProperty.Value){
   if($entry -isnot [PSCustomObject]){throw "A Claude Code hook group is not an object."}
   $entryHooks=$entry.PSObject.Properties["hooks"]
   if($null -eq $entryHooks){continue}
   if($entryHooks.Value -isnot [array]){throw "Claude Code commands are not an array."}
   foreach($hook in $entryHooks.Value){
    if($hook -isnot [PSCustomObject]){throw "A Claude Code hook is not an object."}
    if($null -eq $hook.PSObject.Properties["type"] -or [string]$hook.type -ne "command" -or $null -eq $hook.PSObject.Properties["command"] -or $null -ne $hook.PSObject.Properties["args"]){continue}
    $hasExtraProperties=$false
    foreach($propertyName in $hook.PSObject.Properties.Name){if($propertyName -notin @("type","command","timeout")){$hasExtraProperties=$true;break}}
    if($hasExtraProperties){continue}
    $command=([string]$hook.command).Trim()
    if([string]::Equals($command,$expected,[StringComparison]::Ordinal) -or [string]::Equals($command,$legacy,[StringComparison]::OrdinalIgnoreCase)){$connected=$true}
   }
  }
 }
 if($connected){return "connected"}
 return "disconnected"
}

function Claude-HookConnected {
 try{return (Claude-ConnectionState) -eq "connected"}catch{return $false}
}

function Update-SourceSettings {
 $codexSourceStatus.Text=$(if($script:sourceErrors -contains "Codex"){"Нет данных"}elseif(Test-Path -LiteralPath $sessionIndex){"Подключён"}else{"Не найден"})
 $claudeHome=Join-Path $env:USERPROFILE ".claude"
 if(-not (Test-Path -LiteralPath $claudeHome)){
  $claudeSourceStatus.Text="Не найден"
  $claudeSourceAction.Visibility="Visible";$claudeSourceAction.IsEnabled=$false;$claudeSourceAction.Content="Подключить";$claudeSourceAction.Tag=""
  $claudeSourceAction.ToolTip="Claude Code не найден на этом компьютере"
  [Windows.Automation.AutomationProperties]::SetName($claudeSourceAction,"Подключить Claude Code. Claude Code не найден")
  return
 }
 try{$connected=(Claude-ConnectionState) -eq "connected"}
 catch{
  $claudeSourceStatus.Text="Нет данных"
  $claudeSourceAction.Visibility="Visible";$claudeSourceAction.IsEnabled=$false;$claudeSourceAction.Content="Подключить";$claudeSourceAction.Tag=""
  $claudeSourceAction.ToolTip="Не удалось прочитать настройки Claude Code"
  [Windows.Automation.AutomationProperties]::SetName($claudeSourceAction,"Claude Code: не удалось прочитать настройки")
  return
 }
 $claudeSourceStatus.Text=$(if($connected -and $script:sourceErrors -contains "Claude Code"){"Нет данных"}elseif($connected){"Подключён"}else{"Не подключён"})
 $claudeSourceAction.Visibility="Visible";$claudeSourceAction.IsEnabled=$true;$claudeSourceAction.ToolTip=$null
 $claudeSourceAction.Content=$(if($connected){"Отключить"}else{"Подключить"})
 $claudeSourceAction.Tag=$(if($connected){"Remove"}else{"Install"})
 [Windows.Automation.AutomationProperties]::SetName($claudeSourceAction,$claudeSourceAction.Content+" Claude Code")
}

function Apply-Theme([string]$mode,[bool]$persist) {
 $resolved=if($mode -eq "system"){Windows-Theme}else{$mode}
 $script:themeMode=$mode; $script:resolvedTheme=$resolved
 if($resolved -eq "light"){
  $script:palette=@{Surface="#F6F6F6";Raised="#FFFFFF";TooltipSurface="#ECECEC";TooltipBorder="#CDCDCD";Border="#D7D7D7";Primary="#1F1F1F";Secondary="#575757";Muted="#707070";Hover="#EAEAEA";Pressed="#DFDFDF";Divider="#E2E2E2";Track="#D8D8D8";Scroll="#B3B3B3";ScrollHover="#8F8F8F";CardBorder="#DADADA";Activity="#707070";Done="#707070";Pending="#4F4F4F"}
 }else{
  $script:palette=@{Surface="#202020";Raised="#282828";TooltipSurface="#171717";TooltipBorder="#3D3D3D";Border="#414141";Primary="#F1F1F1";Secondary="#ACACAC";Muted="#989898";Hover="#333333";Pressed="#3B3B3B";Divider="#343434";Track="#3A3A3A";Scroll="#555555";ScrollHover="#747474";CardBorder="#474747";Activity="#989898";Done="#989898";Pending="#B8B8B8"}
 }
 $resources=@{Surface=$script:palette.Surface;SurfaceRaised=$script:palette.Raised;TooltipSurface=$script:palette.TooltipSurface;TooltipBorder=$script:palette.TooltipBorder;Border=$script:palette.Border;TextPrimary=$script:palette.Primary;TextSecondary=$script:palette.Secondary;TextMuted=$script:palette.Muted;SurfaceHover=$script:palette.Hover;SurfacePressed=$script:palette.Pressed;Divider=$script:palette.Divider;Track=$script:palette.Track;ScrollThumbBrush=$script:palette.Scroll;ScrollThumbHoverBrush=$script:palette.ScrollHover}
 foreach($key in $resources.Keys){$window.Resources[$key]=Brush $resources[$key]}
 if($persist){Save-ThemeMode $mode}
 Update-ThemeButtons
 Update-SettingsButtonName
 $script:fingerprint=""
}

function Refresh-SystemTheme {
 if($script:themeMode -eq "system"){
  $resolved=Windows-Theme
  if($resolved -ne $script:resolvedTheme){Apply-Theme "system" $false}
 }
}

function Lock-State([string]$path) {
 if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { return "missing" }
 try {
  $sharing=[IO.FileShare]::Read -bor [IO.FileShare]::Delete
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
  $stream.Dispose()
  return "free"
 } catch {
  $exception=$_.Exception
  while($null -ne $exception.InnerException){$exception=$exception.InnerException}
  if($exception -is [IO.IOException] -and (($exception.HResult -band 65535) -in @(32,33))){return "held"}
  return "unavailable"
 }
}

function Thread-State([string]$id) {
 if($id -notmatch '^[A-Za-z0-9_-]{1,128}$'){return [PSCustomObject]@{State="unknown";HasStartMarker=$false;UpdatedUtc=[DateTime]::MinValue}}
 $path = Session-File $id
 if (-not $path -or -not (Test-Path -LiteralPath $path)) { return [PSCustomObject]@{State="unknown";HasStartMarker=$false;UpdatedUtc=[DateTime]::MinValue} }
 $file=Get-Item -LiteralPath $path
 $cached=if($script:lifecycleState.ContainsKey($path)){$script:lifecycleState[$path]}else{$null}
 if($null -ne $cached -and [long]$cached.Length -eq [long]$file.Length -and [long]$cached.Stamp -eq $file.LastWriteTimeUtc.Ticks){
  $lifecycle=[string]$cached.Lifecycle
  $lastEventUtc=[DateTime]$cached.LastEventUtc
 }else{
  $tail=Read-TailText $path 2097152
  $lifecycle=""; $turnId=""; $lastEventUtc=[DateTime]::MinValue
  foreach($line in ($tail -split "`r?`n")){
   if($line.Length -gt 1048576 -or $line -notmatch '"event_msg"'){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   if($null -eq $record.PSObject.Properties["type"] -or [string]$record.type -ne "event_msg" -or $null -eq $record.PSObject.Properties["payload"]){continue}
   $payload=$record.payload
   if($null -eq $payload -or $null -eq $payload.PSObject.Properties["type"]){continue}
   $eventType=[string]$payload.type
   $eventTurn=if($null -ne $payload.PSObject.Properties["turn_id"]){[string]$payload.turn_id}else{""}
   if($eventType -in @("task_started","turn_started")){$lifecycle="task_started";$turnId=$eventTurn;$lastEventUtc=[DateTime]::MinValue}
   elseif($eventType -notin @("task_complete","turn_complete","turn_aborted") -and $lifecycle -ne "task_started"){continue}
   if($turnId -and $eventTurn -and $eventTurn -ne $turnId){continue}
   if($eventType -in @("task_complete","turn_complete","turn_aborted")){
    $lifecycle=if($eventType -eq "turn_aborted"){"turn_aborted"}else{"task_complete"}
    continue
   }
   $timestampValue=if($null -ne $record.PSObject.Properties["timestamp"]){$record.timestamp}else{$null}
   $timestamp=[DateTime]::MinValue
   if($timestampValue -is [DateTime]){$timestamp=$timestampValue.ToUniversalTime()}
   elseif($timestampValue -is [DateTimeOffset]){$timestamp=$timestampValue.UtcDateTime}
   elseif($null -ne $timestampValue -and [DateTime]::TryParse([string]$timestampValue,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp)){$timestamp=$timestamp.ToUniversalTime()}
   if($timestamp -gt $lastEventUtc){$lastEventUtc=$timestamp}
  }
  $script:lifecycleState[$path]=[PSCustomObject]@{Length=[long]$file.Length;Stamp=$file.LastWriteTimeUtc.Ticks;Lifecycle=$lifecycle;LastEventUtc=$lastEventUtc}
 }
 $hasStart=$lifecycle -eq "task_started"
 $lock=if($hasStart){Lock-State (Join-Path $lockDirectory "$id.lock")}else{"missing"}
 if($lock -eq "unavailable"){throw "Codex session lock cannot be checked."}
 $state=if($lifecycle -eq "task_complete"){"completed"}elseif($lifecycle -eq "turn_aborted"){"interrupted"}elseif($hasStart -and $lock -eq "held"){
  if($lastEventUtc -ge $script:monitorStartedUtc -or $script:observedCodex.ContainsKey($id)){"active"}else{"unobserved"}
 }else{"unknown"}
 return [PSCustomObject]@{State=$state;HasStartMarker=$hasStart;UpdatedUtc=$file.LastWriteTimeUtc}
}

function Codex-Uncertain([string]$id,$threadState) {
 if($threadState.State -eq "active"){$script:observedCodex[$id]=$true}
 elseif($threadState.State -in @("completed","interrupted")){[void]$script:observedCodex.Remove($id)}
 elseif($threadState.State -eq "unknown" -and $threadState.HasStartMarker -and $threadState.UpdatedUtc -ge $script:monitorStartedUtc){$script:observedCodex[$id]=$true}
 return ($threadState.State -eq "unknown" -and $script:observedCodex.ContainsKey($id))
}

function Session-File([string]$id) {
 if ($script:sessionFiles.ContainsKey($id)) { return $script:sessionFiles[$id] }
 if ($script:sessionDates.ContainsKey($id)) {
  $folder = $script:sessionDates[$id]
  if (Test-Path -LiteralPath $folder) {
   $datedFile = Get-ChildItem -LiteralPath $folder -File -Filter ("*" + $id + ".jsonl") -ErrorAction SilentlyContinue | Select-Object -First 1
   if ($null -ne $datedFile) {
    $script:sessionFiles[$id] = $datedFile.FullName
    return $datedFile.FullName
   }
  }
 }
 if ($null -eq $script:allRollouts) { $script:allRollouts = @([IO.Directory]::EnumerateFiles($sessionsDirectory, "*.jsonl", [IO.SearchOption]::AllDirectories)) }
 $file = $script:allRollouts | Where-Object { $_.EndsWith($id + ".jsonl", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
 $path = if ($null -ne $file) { [string]$file } else { "" }
 $script:sessionFiles[$id] = $path
 return $path
}

function Session-Workspace([string]$id) {
 $path = Session-File $id
 if (-not $path) { return "" }
 try {
  foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8 -TotalCount 12) {
   if ($line -notmatch '"type":"session_meta"') { continue }
   $record = $line | ConvertFrom-Json
   return [string](Prop $record.payload "cwd" "")
  }
 } catch {}
 return ""
}

function Progress-Files($sessions) {
 $paths = New-Object Collections.Generic.List[string]
 if ($ProgressFile -and (Test-Path -LiteralPath $ProgressFile)) { $paths.Add((Resolve-Path -LiteralPath $ProgressFile).Path) }
 foreach ($session in $sessions) {
  $workspace = Session-Workspace ([string]$session.id)
  if (-not $workspace) { continue }
  foreach ($name in @("task-progress.json", "task-progress-v2.json")) {
   $candidate = Join-Path $workspace $name
   if ((Test-Path -LiteralPath $candidate) -and -not $paths.Contains($candidate)) { $paths.Add($candidate) }
  }
 }
 return @($paths)
}

function Manual-Tasks($sessions) {
 $map = @{}
 foreach ($path in @(Progress-Files $sessions)) {
  try {
   $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
   $all = if ($null -ne $data.PSObject.Properties["tasks"]) { @($data.tasks) } else { @($data) }
   foreach ($item in $all) {
    if ($null -eq $item) { continue }
    $id = [string](Prop $item "threadId" ""); $title = [string](Prop $item "title" "")
    if ($id) { $map[$id] = $item } elseif ($title) { $map["title:$title"] = $item }
   }
  } catch {}
 }
 return $map
}

function Read-TailText([string]$path,[long]$maxBytes) {
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try {
  $bytes=[Math]::Min($maxBytes,$stream.Length); [void]$stream.Seek(-$bytes,[IO.SeekOrigin]::End)
  $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true,4096,$true)
  try{return $reader.ReadToEnd()}finally{$reader.Dispose()}
 }finally{$stream.Dispose()}
}

function Codex-Plan([string]$id) {
 $path = Session-File $id
 if (-not $path) { return @() }
 $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
 $cacheKey = "$path|$stamp"
 if ($script:planCache.ContainsKey($cacheKey)) { return @($script:planCache[$cacheKey]) }
 $latest = @()
 try {
  $tail=Read-TailText $path 4194304
  foreach ($line in ($tail -split "`r?`n")) {
   if ($line -notmatch 'update_plan') { continue }
   try { $record = $line | ConvertFrom-Json } catch { continue }
   $payload = Prop $record "payload"
   if ($null -eq $payload -or [string](Prop $payload "type" "") -notin @("custom_tool_call","function_call")) { continue }
   $name = [string](Prop $payload "name" "")
   $input = [string](Prop $payload "input" (Prop $payload "arguments" ""))
   if (-not $input) { continue }
   $isDirectPlan = $name -eq "update_plan"
   if(-not $isDirectPlan -and $input -notmatch 'update_plan\s*\('){continue}
   $candidate = New-Object Collections.Generic.List[object]
   if($isDirectPlan){
    try{$parsed=$input|ConvertFrom-Json -ErrorAction Stop}catch{$parsed=$null}
    if($null -ne $parsed -and $null -ne $parsed.PSObject.Properties["plan"] -and $parsed.plan -is [array]){
     foreach($step in $parsed.plan){
      $label=[string](Prop $step "step" "");$status=[string](Prop $step "status" "")
      if(-not $label -or $status -notin @("completed","in_progress","pending")){continue}
      $state=switch($status){"completed"{"done"} "in_progress"{"active"} default{"pending"}}
      $candidate.Add([PSCustomObject]@{title=$label;status=$state})
     }
     if($parsed.plan.Count -eq 0 -or $candidate.Count -gt 0){$latest=$candidate.ToArray()}
     continue
    }
   }
   $matches = [regex]::Matches($input, 'step\s*:\s*"(?<step>(?:\\.|[^"\\])*)"\s*,\s*status\s*:\s*"(?<status>completed|in_progress|pending)"')
   if ($matches.Count -eq 0) { continue }
   foreach ($match in $matches) {
    $state = switch ($match.Groups["status"].Value) { "completed" { "done" } "in_progress" { "active" } default { "pending" } }
    $label = [regex]::Unescape($match.Groups["step"].Value)
    $candidate.Add([PSCustomObject]@{ title=$label; status=$state })
   }
   $latest = $candidate.ToArray()
  }
 } catch {}
 if($script:planCache.Count -ge 100){$script:planCache.Clear()}
 $script:planCache[$cacheKey] = $latest
 return @($latest)
}

function Codex-Activity([string]$id) {
 $path = Session-File $id
 if (-not $path) { return "" }
 try {
  $tail=Read-TailText $path 2097152
  $matches = [regex]::Matches($tail, '"type":"event_msg","payload":\{"type":"agent_reasoning","text":"(?<text>(?:\\.|[^"\\])*)"\}')
  if ($matches.Count -gt 0) {
   $value = [regex]::Unescape($matches[$matches.Count-1].Groups["text"].Value).Trim()
   $value = [regex]::Replace($value, '^\*\*(.*?)\*\*$', '$1')
   return [regex]::Replace($value, '\s+', ' ')
  }
  $latest=""
  foreach($line in ($tail -split "`r?`n")){
   if($line -notmatch '"phase":"commentary"'){continue}
   try{$record=$line|ConvertFrom-Json}catch{continue}
   $payload=Prop $record "payload"
   if([string](Prop $payload "type" "") -eq "message" -and [string](Prop $payload "phase" "") -eq "commentary"){
    foreach($part in @(Prop $payload "content" @())){if([string](Prop $part "type" "") -eq "output_text"){$latest=[string](Prop $part "text" "")}}
   }elseif([string](Prop $payload "type" "") -eq "item_completed"){
    $item=Prop $payload "item"
    if([string](Prop $item "type" "") -eq "AgentMessage" -and [string](Prop $item "phase" "") -eq "commentary"){
     foreach($part in @(Prop $item "content" @())){if([string](Prop $part "type" "") -eq "Text"){$latest=[string](Prop $part "text" "")}}
    }
   }
  }
  if($latest){return [regex]::Replace($latest.Trim(),'\s+',' ')}
 } catch {}
 return ""
}

function Plan-Progress($steps, [int]$fallback) {
 $all = @($steps)
 if ($all.Count -eq 0) { return $fallback }
 $done = @($all | Where-Object { [string](Prop $_ "status" "pending") -eq "done" }).Count
 return [int][Math]::Round(($done / $all.Count) * 100)
}

function Codex-Tasks {
 if (-not (Test-Path -LiteralPath $sessionIndex -ErrorAction Stop)) {
  if ($script:lastCodexTasks.Count -gt 0 -or (Test-Path -LiteralPath $codexHome -PathType Container -ErrorAction Stop)) { throw "Codex session index is unavailable." }
  return @()
 }
 $sessionMap = @{}
 foreach ($line in Get-Content -LiteralPath $sessionIndex -Encoding UTF8 -Tail 50) {
  if (-not $line) { continue }
  try {
   $session = $line | ConvertFrom-Json
   $sessionId=[string](Prop $session "id" "")
   if($sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$'){continue}
   $sessionMap[$sessionId] = $session
   $updated = [DateTime]$session.updated_at
   $yearFolder = Join-Path $sessionsDirectory ([string]$updated.Year)
   $monthFolder = Join-Path $yearFolder $updated.Month.ToString("00")
   $script:sessionDates[$sessionId] = Join-Path $monthFolder $updated.Day.ToString("00")
  } catch {}
 }
 $sessions = @($sessionMap.Values)
 $manual = Manual-Tasks $sessions
 $items = New-Object Collections.Generic.List[object]
 foreach ($session in $sessions) {
  $id = [string]$session.id; $title = [string]$session.thread_name
  if($title -eq "Guardian review"){continue}
  $threadState = Thread-State $id
  $eventActive = $threadState.State -eq "active"
  $uncertain = Codex-Uncertain $id $threadState
  if($threadState.State -in @("interrupted","unobserved")){continue}
  $override = if ($manual.ContainsKey($id)) { $manual[$id] } elseif ($manual.ContainsKey("title:$title")) { $manual["title:$title"] } else { $null }
  $paused = $false; $steps = @(); $source = "Оценка активности"
  if ($null -ne $override) {
   $title = [string](Prop $override "title" $title)
   $paused = [bool](Prop $override "paused" $false)
   $steps = @(Prop $override "steps" @())
   if ($steps.Count -gt 0) { $source = "План задачи" }
  }
  $uncertain=$uncertain -and -not $paused
  if ($steps.Count -eq 0 -and ($eventActive -or $uncertain)) {
   $steps = @(Codex-Plan $id)
   if ($steps.Count -gt 0) { $source = "План Codex" }
  }
  $running = $eventActive -and -not $paused
  $status = if ($paused) { "На паузе" } elseif ($running) { "В работе" } elseif ($uncertain) { "Статус не подтверждён" } else { "Ожидает" }
  $progress=$null; $progressKind="none"
  if($steps.Count -gt 0){$progress=Plan-Progress $steps 0;$progressKind="exact"}
  if ($null -ne $override) {
   $value = Prop $override "progress"
   if ($null -ne $value) {
    $progress = [Math]::Max(0, [Math]::Min(100, [int]$value))
    $progressKind=[string](Prop $override "progressKind" "approximate")
    if($progressKind -notin @("exact","approximate")){$progressKind="approximate"}
   }
   if(-not $uncertain){$status = [string](Prop $override "status" $status)}
  }
  if ($steps.Count -gt 0) {
   $doneCount = @($steps | Where-Object { [string](Prop $_ "status" "pending") -eq "done" }).Count
   if ($doneCount -eq $steps.Count) { $progress = 100; $progressKind="exact" }
   elseif ($null -ne $progress -and $progress -ge 100) { $progress = 99 }
  }
  $updated = if($threadState.UpdatedUtc -ne [DateTime]::MinValue){$threadState.UpdatedUtc.ToLocalTime()}else{[DateTime]::MinValue}
  $activity = if($uncertain){"Статус не подтверждён"}elseif($running){Codex-Activity $id}else{""}
  $items.Add([PSCustomObject]@{ Id=$id; Title=$title; Activity=$activity; Active=$running; Paused=$paused; Progress=$progress; ProgressKind=$progressKind; Provider="codex"; ProviderName="Codex"; Status=$status; Updated=$updated; Steps=$steps; Source=$source })
 }
 $runningItems = @($items | Where-Object Active | Sort-Object Updated -Descending)
 $trackedItems = @($items | Where-Object { -not $_.Active -and ($_.Status -in @("Статус не подтверждён","Ожидает подтверждения") -or $_.Paused) } | Sort-Object Updated -Descending)
 return @($runningItems + $trackedItems)
}

function Claude-Tasks {
 try{$attributes=[IO.File]::GetAttributes($claudeEventPath)}
 catch [IO.FileNotFoundException]{if($script:lastClaudeTasks.Count -gt 0){throw};return @()}
 catch [IO.DirectoryNotFoundException]{if($script:lastClaudeTasks.Count -gt 0){throw};return @()}
 if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){throw "Claude event source is not a file."}
 $tail=Read-TailText $claudeEventPath 4194304
 $legacyTail=""
 if($claudeLegacyEventPath){
  try{
   if(Test-Path -LiteralPath $claudeLegacyEventPath -PathType Leaf -ErrorAction Stop){
    $legacyTail=Read-TailText $claudeLegacyEventPath 4194304
   }
  }catch{}
 }
 if(-not ("AITaskMonitor.Claude.Reader" -as [type])){throw "Claude event reader is unavailable."}
 $sessions=@([AITaskMonitor.Claude.Reader]::Read($tail,$legacyTail,[DateTime]::UtcNow,$script:monitorStartedUtc))
 $items=New-Object Collections.Generic.List[object]
 foreach($state in $sessions){
  $steps=@($state.Steps)
  $progress=$null;$kind="none"
  if($steps.Count -gt 0){$progress=Plan-Progress $steps 0;$kind="exact"}
  $title="Задача Claude Code"
  $unconfirmed=[bool]$state.Unconfirmed
  $activity=if($unconfirmed){"Статус не подтверждён"}else{$state.Activity}
  $status=if($unconfirmed){"Статус не подтверждён"}else{"В работе"}
  $items.Add([PSCustomObject]@{Id="claude:"+$state.Id;Title=$title;Activity=$activity;Active=(-not $unconfirmed);Paused=$false;Progress=$progress;ProgressKind=$kind;Provider="claude";ProviderName="Claude Code";Status=$status;Updated=$state.Updated.ToLocalTime();Steps=$steps;Source="Claude Code"})
 }
 return @($items|Sort-Object Updated -Descending)
}

function Source-Snapshot {
 $codex=@(); $claude=@(); $unavailable=New-Object Collections.Generic.List[string]
 try{$codex=@(Codex-Tasks);$script:lastCodexTasks=$codex}catch{[void]$unavailable.Add("Codex");$codex=@(Unconfirmed-Tasks $script:lastCodexTasks)}
 try{
  $connected=if($ClaudeEventFile){$true}else{(Claude-ConnectionState) -eq "connected"}
  if($connected){$claude=@(Claude-Tasks);$script:lastClaudeTasks=$claude}else{$script:lastClaudeTasks=@()}
 }catch{[void]$unavailable.Add("Claude Code");$claude=@(Unconfirmed-Tasks $script:lastClaudeTasks)}
 return [PSCustomObject]@{Tasks=@($codex+$claude);Unavailable=$unavailable.ToArray()}
}

function Sync-ClaudeLoopChannel {
 try{
  $wanted=if($PreviewClaudeLoopPipe){$true}elseif($PreviewActiveTasks -ge 0){$false}else{(Claude-ConnectionState) -eq 'connected'}
  if(-not $wanted -or $script:sourceErrors -contains 'Claude Code'){
   if($null -ne $script:claudeLoopChannel){$script:claudeLoopChannel.Dispose();$script:claudeLoopChannel=$null}
   $script:claudeLoopStates.Clear();$script:claudeLoopError=''
   return
  }
  if($null -eq $script:diagnosticRuntime -or -not $script:claudeLoopModulesAvailable){
   if($null -ne $script:claudeLoopChannel){$script:claudeLoopChannel.Dispose();$script:claudeLoopChannel=$null}
   $script:claudeLoopStates.Clear()
   $script:claudeLoopError='Предупреждение Claude Code недоступно'
   return
  }
  if($null -eq $script:claudeLoopChannel){
   if(-not ('AITaskMonitor.ClaudeLoop.Channel' -as [type])){
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    Add-Type -Path (Join-Path $PSScriptRoot 'ClaudeLoopChannel.cs') -ReferencedAssemblies 'System.Web.Extensions' -ErrorAction Stop
   }
   $script:claudeLoopChannel=[AITaskMonitor.ClaudeLoop.Channel]::new($PreviewClaudeLoopPipe)
  }
  $script:claudeLoopError=''
  $now=[DateTimeOffset]::UtcNow
  $threshold=[int]$script:diagnosticRuntime.Settings.LoopThreshold
  $windowMinutes=[int]$script:diagnosticRuntime.Settings.LoopWindowMinutes
  $batch=$script:claudeLoopChannel.Drain()
  if($batch.Gap){$script:claudeLoopStates.Clear()}
  foreach($event in $batch.Events){
   $session=[string]$event.SessionId
   if(-not $script:claudeLoopStates.ContainsKey($session)){
    if($event.Kind -cne 'start'){continue}
    if($script:claudeLoopStates.Count -ge 256){
     $oldest=@($script:claudeLoopStates.Keys|Sort-Object {$script:claudeLoopStates[$_].LastSeen}|Select-Object -First 1)
     if($oldest.Count){$script:claudeLoopStates.Remove([string]$oldest[0])}
    }
    $script:claudeLoopStates[$session]=New-ClaudeLoopTracker -Threshold $threshold -WindowMinutes $windowMinutes
   }
   $tracker=$script:claudeLoopStates[$session]
   if($tracker.Threshold -ne $threshold -or $tracker.WindowMinutes -ne $windowMinutes){
    Reset-ClaudeLoopTracker $tracker;$tracker.Threshold=$threshold;$tracker.WindowMinutes=$windowMinutes
   }
   Update-ClaudeLoopTracker $tracker $event $now
   if($event.Kind -ceq 'stop'){$script:claudeLoopStates.Remove($session)}
  }
  foreach($session in @($script:claudeLoopStates.Keys)){
   $tracker=$script:claudeLoopStates[$session]
   if($tracker.Threshold -ne $threshold -or $tracker.WindowMinutes -ne $windowMinutes){
    Reset-ClaudeLoopTracker $tracker;$tracker.Threshold=$threshold;$tracker.WindowMinutes=$windowMinutes
   }
   Refresh-ClaudeLoopTracker $tracker $now
   if($tracker.LastSeen -lt $now.AddMinutes(-30)){$script:claudeLoopStates.Remove($session)}
  }
 }catch{
  $script:claudeLoopStates.Clear();$script:claudeLoopError='Предупреждение Claude Code недоступно'
  if($null -ne $script:claudeLoopChannel){try{$script:claudeLoopChannel.Dispose()}catch{};$script:claudeLoopChannel=$null}
 }
}

function Refresh-Diagnostics($tasks) {
 if($null -eq $script:diagnosticRuntime){return}
 $observations=@(foreach($task in $tasks){
  $provider=[string](Prop $task "Provider" "")
  $id=[string](Prop $task "Id" "")
  if($provider -eq "claude" -and $id.StartsWith("claude:")){$id=$id.Substring(7)}
  $status=[string](Prop $task "Status" "")
  $state=if([bool](Prop $task "Active" $false)){"active"}elseif($status -eq "Статус не подтверждён"){"unknown"}else{""}
  if($state){[PSCustomObject]@{Provider=$provider;Id=$id;State=$state}}
 })
 $resolver=if($PreviewActiveTasks -ge 0){{param($id) return ""}}else{{param($id) return (Session-File $id)}}
 $stateResolver=if($PreviewActiveTasks -ge 0){{param($id) return [PSCustomObject]@{State="unknown"}}}else{{param($id) return (Thread-State $id)}}
 try{
  Update-DiagnosticRuntime -Runtime $script:diagnosticRuntime -Tasks $observations -Unavailable $script:sourceErrors -Now ([DateTimeOffset]::UtcNow) -SessionResolver $resolver -StateResolver $stateResolver
  $script:diagnosticError=""
 }catch{$script:diagnosticError="Не удалось обновить журнал"}
}

function Unconfirmed-Tasks($tasks) {
 foreach($task in $tasks){
  if(-not $task.Active -and [string](Prop $task "Status" "") -ne "Статус не подтверждён"){continue}
  $copy=$task.PSObject.Copy()
  $copy.Active=$false; $copy.Status="Статус не подтверждён"; $copy.Activity="Статус не подтверждён"
  $copy
 }
}

function Text([string]$value, [double]$size, [string]$color, [string]$weight = "Normal") {
 $block = New-Object Windows.Controls.TextBlock
 $block.Text=$value; $block.FontFamily=New-Object Windows.Media.FontFamily("Segoe UI Variable Text"); $block.FontSize=$size
 $block.Foreground=Brush $color; $block.FontWeight=$weight; $block.TextWrapping="Wrap"; $block.LineHeight=$size*1.35
 return $block
}

function Get-CursorHintPosition([Windows.Point]$pointer,[Windows.Size]$hintSize,[Windows.Rect]$workArea,[Windows.Thickness]$inset=[Windows.Thickness]::new(0)) {
 $gap=4.0
 $maximumX=[Math]::Max($workArea.Left,$workArea.Right-$hintSize.Width)
 $visibleWidth=[Math]::Max(0,$hintSize.Width-$inset.Left-$inset.Right)
 $x=[Math]::Max($workArea.Left,[Math]::Min($pointer.X-$inset.Left-$visibleWidth/2,$maximumX))
 $maximumY=[Math]::Max($workArea.Top,$workArea.Bottom-$hintSize.Height)
 $above=$pointer.Y-$hintSize.Height+$inset.Bottom-$gap
 $below=$pointer.Y+$gap-$inset.Top
 if($above -ge $workArea.Top){$y=[Math]::Min($above,$maximumY)}
 elseif($below -le $maximumY){$y=[Math]::Max($below,$workArea.Top)}
 else{$y=[Math]::Max($workArea.Top,[Math]::Min($above,$maximumY))}
 return [Windows.Point]::new($x,$y)
}

function New-CursorHint($block,[string]$text) {
 $hint=New-Object Windows.Controls.ToolTip
 $hint.Content=$text
 $hint.SetResourceReference([Windows.FrameworkElement]::StyleProperty,"CursorHintStyle")
 $hint.PlacementTarget=$block
 $hint.Placement=[Windows.Controls.Primitives.PlacementMode]::Custom
 $hint.HorizontalOffset=0; $hint.VerticalOffset=0
 $target=$block
 $positioner=${function:Get-CursorHintPosition}
 $preview=[bool]($HintSnapshotFile -and $PreviewActiveTasks -ge 0)
 $place={
  param($popupSize,$targetSize,$offset)
  $pointer=if($preview){[Windows.Point]::new($target.ActualWidth/2,$target.ActualHeight/2)}else{[Windows.Input.Mouse]::GetPosition($target)}
  $screenPoint=$target.PointToScreen($pointer)
  $screen=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int][Math]::Round($screenPoint.X),[int][Math]::Round($screenPoint.Y)))
  $work=$screen.WorkingArea
  $first=$target.PointFromScreen([Windows.Point]::new($work.Left,$work.Top))
  $last=$target.PointFromScreen([Windows.Point]::new($work.Right,$work.Bottom))
  $area=[Windows.Rect]::new($first,[Windows.Size]::new([Math]::Max(0,$last.X-$first.X),[Math]::Max(0,$last.Y-$first.Y)))
  $inset=$target.TryFindResource("CursorHintShadowInset")
  if($inset -isnot [Windows.Thickness]){$inset=[Windows.Thickness]::new(0)}
  $position=& $positioner $pointer $popupSize $area $inset
  return ,([Windows.Controls.Primitives.CustomPopupPlacement[]]@([Windows.Controls.Primitives.CustomPopupPlacement]::new($position,[Windows.Controls.Primitives.PopupPrimaryAxis]::Horizontal)))
 }.GetNewClosure()
 $hint.CustomPopupPlacementCallback=[Windows.Controls.Primitives.CustomPopupPlacementCallback]$place
 return $hint
}

function Update-ConditionalHint($block) {
 $data=$block.Tag
 if($null -eq $data -or $block.ActualWidth -le 0){return}
 $probe=New-Object Windows.Controls.TextBlock
 $probe.Text=[string]$data.Text
 $probe.FontFamily=$block.FontFamily
 $probe.FontSize=$block.FontSize
 $probe.FontWeight=$block.FontWeight
 $probe.FontStyle=$block.FontStyle
 $probe.FontStretch=$block.FontStretch
 $probe.LineHeight=$block.LineHeight
 $probe.TextTrimming="None"
 if([string]$data.Mode -eq "wrap"){
  $probe.TextWrapping="Wrap"
  $probe.Width=$block.ActualWidth
  $probe.Measure([Windows.Size]::new($block.ActualWidth,[double]::PositiveInfinity))
  $truncated=$probe.DesiredSize.Height -gt ($block.ActualHeight+0.5)
 }else{
  $probe.TextWrapping="NoWrap"
  $probe.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
  $truncated=$probe.DesiredSize.Width -gt ($block.ActualWidth+0.5)
 }
 if($truncated){
  if($block.ToolTip -isnot [Windows.Controls.ToolTip]){$block.ToolTip=New-CursorHint $block ([string]$data.Text)}
  else{$block.ToolTip.Content=[string]$data.Text}
 }else{$block.ToolTip=$null}
}

function Add-ConditionalHint($block,[string]$text,[ValidateSet("line","wrap")][string]$mode="line") {
 $block.Tag=[PSCustomObject]@{Text=$text;Mode=$mode}
 [Windows.Controls.ToolTipService]::SetInitialShowDelay($block,350)
 [Windows.Controls.ToolTipService]::SetShowDuration($block,30000)
 [Windows.Controls.ToolTipService]::SetPlacement($block,[Windows.Controls.Primitives.PlacementMode]::Custom)
 [Windows.Controls.ToolTipService]::SetHorizontalOffset($block,0)
 [Windows.Controls.ToolTipService]::SetVerticalOffset($block,0)
 $block.Add_Loaded({param($sender,$args) Update-ConditionalHint $sender})
 $block.Add_SizeChanged({param($sender,$args) Update-ConditionalHint $sender})
}

function Progress-Label($task) {
 $kind=[string](Prop $task "ProgressKind" "none")
 $value=Prop $task "Progress"
 if($kind -eq "none" -or $null -eq $value){return ""}
 $prefix=if($kind -eq "approximate"){"≈ "}else{""}
 return $prefix+([int]$value).ToString()+"%"
}

function Get-LoopWarning($task) {
 if(-not $task.Active){return $null}
 $provider=[string]$task.Provider
 if($provider -eq 'claude'){
  $session=[string]$task.Id
  if($session.StartsWith('claude:')){$session=$session.Substring(7)}
  if(-not $script:claudeLoopStates.ContainsKey($session)){return $null}
  $loop=$script:claudeLoopStates[$session]
  if(-not $loop.Warning -or $loop.Dismissed){return $null}
  return $loop
 }
 if($provider -ne 'codex'){return $null}
 if($PreviewActiveTasks -ge 0 -and $PreviewLoopWarning -and [string]$task.Id -eq "preview-0" -and -not $script:previewLoopDismissed){
  return [PSCustomObject]@{Threshold=5;WindowMinutes=10}
 }
 if($null -eq $script:diagnosticRuntime){return $null}
 $key="codex:"+[string]$task.Id
 if(-not $script:diagnosticRuntime.LoopStates.ContainsKey($key)){return $null}
 $loop=$script:diagnosticRuntime.LoopStates[$key]
 if(-not $loop.Warning -or $loop.Dismissed){return $null}
 return $loop
}

function Add-LoopWarning($container,$task,[bool]$compact) {
 $loop=Get-LoopWarning $task
 if($null -eq $loop){return}
 $row=New-Object Windows.Controls.Grid
 $row.Margin=$(if($compact){New-Object Windows.Thickness(12,6,0,0)}else{New-Object Windows.Thickness(0,8,0,0)})
 $messageColumn=New-Object Windows.Controls.ColumnDefinition; $messageColumn.Width=New-Object Windows.GridLength(1,"Star")
 $actionColumn=New-Object Windows.Controls.ColumnDefinition; $actionColumn.Width=[Windows.GridLength]::Auto
 $row.ColumnDefinitions.Add($messageColumn);$row.ColumnDefinitions.Add($actionColumn)
 $message="Возможный цикл: одна команда завершилась с одинаковым кодом ошибки не менее $($loop.Threshold) раз за $($loop.WindowMinutes) мин."
 $label=Text $message $(if($compact){11.5}else{12}) $script:palette.Secondary
 $label.TextWrapping="Wrap"; $label.Margin=New-Object Windows.Thickness(0,0,8,0)
 [Windows.Automation.AutomationProperties]::SetName($label,$message)
 $dismiss=New-Object Windows.Controls.Button; $dismiss.Content="Скрыть"; $dismiss.Style=$window.Resources["SourceActionStyle"]; $dismiss.FontSize=11.5
 $dismiss.VerticalAlignment="Top"; $dismiss.Tag=[PSCustomObject]@{Id=[string]$task.Id;Provider=[string]$task.Provider}; $dismiss.FocusVisualStyle=$window.Resources["KeyboardFocusStyle"]
 [Windows.Automation.AutomationProperties]::SetName($dismiss,"Скрыть предупреждение о возможном цикле для задачи: "+[string]$task.Title)
 $dismiss.Add_Click({param($sender,$eventArgs)
  $id=[string]$sender.Tag.Id;$provider=[string]$sender.Tag.Provider
  if($PreviewActiveTasks -ge 0 -and $provider -eq 'codex' -and $id -eq "preview-0"){$script:previewLoopDismissed=$true}
  elseif($provider -eq 'claude'){
   $session=if($id.StartsWith('claude:')){$id.Substring(7)}else{$id}
   if($script:claudeLoopStates.ContainsKey($session)){$script:claudeLoopStates[$session].Dismissed=$true}
  }elseif($null -ne $script:diagnosticRuntime){$key="codex:"+$id;if($script:diagnosticRuntime.LoopStates.ContainsKey($key)){$script:diagnosticRuntime.LoopStates[$key].Dismissed=$true}}
  $script:fingerprint="";Update-View
 })
 [Windows.Controls.Grid]::SetColumn($dismiss,1);$row.Children.Add($label)|Out-Null;$row.Children.Add($dismiss)|Out-Null
 $container.Children.Add($row)|Out-Null
}

function Add-Steps($container, $steps) {
 $all = @($steps)
 if($all.Count -eq 0){
  $empty = Text "План ещё не опубликован этой задачей" 12.5 $script:palette.Activity
  $empty.Margin=New-Object Windows.Thickness(0,11,0,0); $container.Children.Add($empty)|Out-Null
  return
 }
 $scroll = New-Object Windows.Controls.ScrollViewer; $scroll.Height=110; $scroll.Margin=New-Object Windows.Thickness(0,11,0,0); $scroll.VerticalScrollBarVisibility=$(if($all.Count -gt 5){"Auto"}else{"Hidden"}); $scroll.HorizontalScrollBarVisibility="Disabled"
 $rail = New-Object Windows.Controls.StackPanel
 $activeIndex=-1; $pendingIndex=-1; $stepIndex=0
 foreach ($step in $all) {
  $row=New-Object Windows.Controls.Grid; $row.Height=22
  $c1=New-Object Windows.Controls.ColumnDefinition; $c1.Width=New-Object Windows.GridLength(22)
  $c2=New-Object Windows.Controls.ColumnDefinition; $c2.Width=New-Object Windows.GridLength(1,"Star")
  $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)
  $state=[string](Prop $step "status" "pending")
  if($state -eq "active" -and $activeIndex -lt 0){$activeIndex=$stepIndex}
  if($state -eq "pending" -and $pendingIndex -lt 0){$pendingIndex=$stepIndex}
  $marker=New-Object Windows.Controls.Border; $marker.Width=14; $marker.Height=14; $marker.CornerRadius=New-Object Windows.CornerRadius(7); $marker.HorizontalAlignment="Center"; $marker.VerticalAlignment="Top"; $marker.Margin=New-Object Windows.Thickness(0,2,0,0)
  if($state -eq "done"){
   $marker.Background=Brush $script:palette.Raised
   $check=New-Object Windows.Shapes.Path; $check.Data=[Windows.Media.Geometry]::Parse("M 2,7 L 5.2,10 L 11.5,3.5"); $check.Width=11; $check.Height=9; $check.Stretch="Uniform"; $check.Stroke=Brush $script:accentHex; $check.StrokeThickness=1.5; $check.StrokeStartLineCap="Round"; $check.StrokeEndLineCap="Round"; $check.StrokeLineJoin="Round"; $check.HorizontalAlignment="Center"; $check.VerticalAlignment="Center"; $marker.Child=$check
  }elseif($state -eq "active"){
   $marker.Background=Brush $script:accentHex
  }else{$marker.Background=Brush $script:palette.Surface; $marker.BorderBrush=Brush $script:palette.Muted; $marker.BorderThickness=New-Object Windows.Thickness(1)}
  [Windows.Controls.Grid]::SetColumn($marker,0)
  $labelColor=if($state -eq "active"){$script:palette.Primary}elseif($state -eq "done"){$script:palette.Done}else{$script:palette.Pending}
  $labelWeight=if($state -eq "active"){"SemiBold"}else{"Normal"}
  $stepTitle=[string](Prop $step "title" "Без названия")
  $label=Text $stepTitle 13 $labelColor $labelWeight
  $label.Margin=New-Object Windows.Thickness(4,0,0,0); $label.TextWrapping="NoWrap"; $label.TextTrimming="CharacterEllipsis"; Add-ConditionalHint $label $stepTitle "line"; $label.VerticalAlignment="Center"; [Windows.Controls.Grid]::SetColumn($label,1)
  $row.Children.Add($marker)|Out-Null; $row.Children.Add($label)|Out-Null; $rail.Children.Add($row)|Out-Null
  $stepIndex++
 }
 $focusIndex=if($activeIndex -ge 0){$activeIndex}elseif($pendingIndex -ge 0){$pendingIndex}else{[Math]::Max(0,$all.Count-2)}
 $scroll.Tag=[double]($focusIndex*22)
 $scroll.Add_Loaded({param($sender,$args) $sender.ScrollToVerticalOffset([double]$sender.Tag)})
 $scroll.Add_PreviewMouseWheel({
  param($sender,$eventArgs)
  $atTop=$sender.VerticalOffset -le 0.5
  $atBottom=$sender.VerticalOffset -ge ($sender.ScrollableHeight-0.5)
  $passToCards=$sender.ScrollableHeight -le 0 -or ($eventArgs.Delta -gt 0 -and $atTop) -or ($eventArgs.Delta -lt 0 -and $atBottom)
  if($passToCards){
   $eventArgs.Handled=$true
   $distance=if($eventArgs.Delta -gt 0){-48}else{48}
   $tasksScroll.ScrollToVerticalOffset($tasksScroll.VerticalOffset+$distance)
  }
 })
 $scroll.Content=$rail; $container.Children.Add($scroll)|Out-Null
}

function Add-Card($task) {
 $stepCount=@($task.Steps).Count
 $hasLoopWarning=$null -ne (Get-LoopWarning $task)
 $card=New-Object Windows.Controls.Grid; if($stepCount -gt 0){$card.Height=$(if($script:showProviderLabels){278}else{258})+$(if($hasLoopWarning){64}else{0})}; $card.Margin=New-Object Windows.Thickness(0,0,0,12)
 $cardShape=New-Object Windows.Shapes.Path; $cardShape.Fill=Brush $script:palette.Raised; $cardShape.Stroke=Brush $(if($task.Active){$script:palette.CardBorder}else{$script:palette.Border}); $cardShape.StrokeThickness=1; $cardShape.IsHitTestVisible=$false
 $cardContent=New-Object Windows.Controls.Border; $cardContent.Padding=New-Object Windows.Thickness(16,15,16,14)
 $card.Children.Add($cardShape)|Out-Null; $card.Children.Add($cardContent)|Out-Null
 $card.Tag=$cardShape
 $card.Add_SizeChanged({param($sender,$args) if($sender.ActualWidth -gt 0 -and $sender.ActualHeight -gt 0){$sender.Tag.Data=Squircle-Geometry $sender.ActualWidth $sender.ActualHeight $script:cardRadius 0.5}})
 $stack=New-Object Windows.Controls.StackPanel
 if($script:showProviderLabels){$providerLabel=Text ([string]$task.ProviderName) 11.5 $script:accentHex "SemiBold";$providerLabel.Margin=New-Object Windows.Thickness(0,0,0,3);$stack.Children.Add($providerLabel)|Out-Null}
 $header=New-Object Windows.Controls.Grid
 $c1=New-Object Windows.Controls.ColumnDefinition; $c1.Width=New-Object Windows.GridLength(1,"Star"); $c2=New-Object Windows.Controls.ColumnDefinition; $c2.Width=[Windows.GridLength]::Auto; $header.ColumnDefinitions.Add($c1); $header.ColumnDefinitions.Add($c2)
 $titleStack=New-Object Windows.Controls.StackPanel
 $title=Text $task.Title 16 $script:palette.Primary "SemiBold"; $title.Margin=New-Object Windows.Thickness(0,0,14,0); $title.Height=22; $title.MaxWidth=390; $title.HorizontalAlignment="Left"; $title.TextWrapping="NoWrap"; $title.TextTrimming="CharacterEllipsis"; Add-ConditionalHint $title ([string]$task.Title) "line"; $titleStack.Children.Add($title)|Out-Null
 $activityText=[string]$task.Activity; $activity=Text $activityText 12 $script:palette.Activity; $activity.Margin=New-Object Windows.Thickness(0,5,14,0); $activity.Width=390; $activity.HorizontalAlignment="Left"; $activity.Height=34; $activity.MaxHeight=34; $activity.TextTrimming="CharacterEllipsis"; if($activityText){Add-ConditionalHint $activity $activityText "wrap"}; $titleStack.Children.Add($activity)|Out-Null
 if(-not $CompactMode -and $PreviewActiveTasks -ge 0 -and $null -eq $script:previewHintTarget -and $activityText){$script:previewHintTarget=$activity}
 $progressLabel=Progress-Label $task
 $percent=Text $progressLabel 16 $script:palette.Primary "SemiBold"; $percent.Height=22; $percent.VerticalAlignment="Top"; if($task.ProgressKind -eq "approximate"){$percent.ToolTip="Приблизительная оценка"}; [Windows.Controls.Grid]::SetColumn($percent,1)
 $header.Children.Add($titleStack)|Out-Null; $header.Children.Add($percent)|Out-Null; $stack.Children.Add($header)|Out-Null
 Add-LoopWarning $stack $task $false
 if($task.ProgressKind -ne "none" -and $null -ne $task.Progress){$bar=New-Object Windows.Controls.ProgressBar; $bar.Maximum=100; $bar.Value=$task.Progress; $bar.Margin=New-Object Windows.Thickness(0,14,0,0); $stack.Children.Add($bar)|Out-Null}
 if($stepCount -gt 0){
  Add-Steps $stack $task.Steps
  $metaText="План задачи · $stepCount этапов"
  if($task.Updated -ne [DateTime]::MinValue){$metaText += " · "+$task.Updated.ToString("HH:mm")}
  $meta=Text $metaText 11.5 $script:palette.Muted; $meta.Margin=New-Object Windows.Thickness(0,11,0,0); $stack.Children.Add($meta)|Out-Null
 }
 $cardContent.Child=$stack; $tasksPanel.Children.Add($card)|Out-Null
}

function Add-CompactTask($task) {
 if($script:showProviderLabels){$providerLabel=Text ([string]$task.ProviderName) 10.5 $script:accentHex "SemiBold";$providerLabel.Margin=New-Object Windows.Thickness(12,0,0,2);$compactTasksPanel.Children.Add($providerLabel)|Out-Null}
 $container=New-Object Windows.Controls.Grid; $container.Margin=New-Object Windows.Thickness(0,0,0,10)
 $r1=New-Object Windows.Controls.RowDefinition; $r1.Height=[Windows.GridLength]::Auto
 $r2=New-Object Windows.Controls.RowDefinition; $r2.Height=[Windows.GridLength]::Auto
 $r3=New-Object Windows.Controls.RowDefinition; $r3.Height=[Windows.GridLength]::Auto
 $r4=New-Object Windows.Controls.RowDefinition; $r4.Height=[Windows.GridLength]::Auto
 $container.RowDefinitions.Add($r1); $container.RowDefinitions.Add($r2); $container.RowDefinitions.Add($r3); $container.RowDefinitions.Add($r4)

 $header=New-Object Windows.Controls.Grid
 $c1=New-Object Windows.Controls.ColumnDefinition; $c1.Width=New-Object Windows.GridLength(12)
 $c2=New-Object Windows.Controls.ColumnDefinition; $c2.Width=New-Object Windows.GridLength(1,"Star")
 $c3=New-Object Windows.Controls.ColumnDefinition; $c3.Width=[Windows.GridLength]::Auto
 $header.ColumnDefinitions.Add($c1); $header.ColumnDefinitions.Add($c2); $header.ColumnDefinitions.Add($c3)
 $dot=New-Object Windows.Controls.Border; $dot.Width=6; $dot.Height=6; $dot.CornerRadius=New-Object Windows.CornerRadius(3); $dot.Background=Brush $(if($task.Active){$script:accentHex}else{$script:palette.Muted}); $dot.VerticalAlignment="Center"; $dot.HorizontalAlignment="Left"
 $title=Text $task.Title 13.5 $script:palette.Primary "SemiBold"; $title.TextWrapping="NoWrap"; $title.TextTrimming="CharacterEllipsis"; $title.Margin=New-Object Windows.Thickness(0,0,10,0); Add-ConditionalHint $title ([string]$task.Title) "line"; [Windows.Automation.AutomationProperties]::SetName($title,[string]$task.Title)
 $progressLabel=Progress-Label $task
 $percent=Text $progressLabel 13.5 $script:palette.Primary "SemiBold"; $percent.VerticalAlignment="Center"; if($task.ProgressKind -eq "approximate"){$percent.ToolTip="Приблизительная оценка"}
 [Windows.Controls.Grid]::SetColumn($dot,0); [Windows.Controls.Grid]::SetColumn($title,1); [Windows.Controls.Grid]::SetColumn($percent,2)
 $header.Children.Add($dot)|Out-Null; $header.Children.Add($title)|Out-Null; $header.Children.Add($percent)|Out-Null
 [Windows.Controls.Grid]::SetRow($header,0); $container.Children.Add($header)|Out-Null

 $activityText=if($task.Activity){[string]$task.Activity}else{"Выполняется"}
 $activity=Text $activityText 11.5 $script:palette.Activity; $activity.TextWrapping="NoWrap"; $activity.TextTrimming="CharacterEllipsis"; $activity.Margin=New-Object Windows.Thickness(12,2,0,0); Add-ConditionalHint $activity $activityText "line"; [Windows.Automation.AutomationProperties]::SetName($activity,$activityText)
 if($CompactMode -and $PreviewActiveTasks -ge 0 -and $null -eq $script:previewHintTarget){$script:previewHintTarget=$activity}
 [Windows.Controls.Grid]::SetRow($activity,1); $container.Children.Add($activity)|Out-Null
 $warningPanel=New-Object Windows.Controls.StackPanel; Add-LoopWarning $warningPanel $task $true; [Windows.Controls.Grid]::SetRow($warningPanel,2); $container.Children.Add($warningPanel)|Out-Null
 if($task.ProgressKind -ne "none" -and $null -ne $task.Progress){$bar=New-Object Windows.Controls.ProgressBar; $bar.Maximum=100; $bar.Value=$task.Progress; $bar.Height=2; $bar.Margin=New-Object Windows.Thickness(12,7,0,0); [Windows.Controls.Grid]::SetRow($bar,3); $container.Children.Add($bar)|Out-Null}
 $compactTasksPanel.Children.Add($container)|Out-Null
}

function Add-CompactDot($task,[bool]$selected) {
 $button=New-Object Windows.Controls.Button
 $button.Style=$window.Resources["CompactDotStyle"]
 $button.Tag=[string]$task.Id
 [Windows.Automation.AutomationProperties]::SetName($button,"Показать задачу: "+[string]$task.Title)
 $dot=New-Object Windows.Controls.Border
 $dot.Width=7; $dot.Height=7; $dot.CornerRadius=New-Object Windows.CornerRadius(3.5)
 $dot.Background=Brush $(if($selected){$script:accentHex}else{$script:palette.Scroll})
 $button.Content=$dot
 $button.Add_Click({param($sender,$eventArgs) $script:compactTaskId=[string]$sender.Tag; Render-CompactTasks $script:lastTasks})
 $compactDotsPanel.Children.Add($button)|Out-Null
}

function Compact-VisibleTasks($tasks) {
 return @($tasks|Where-Object {$_.Active -or [string](Prop $_ "Status" "") -in @("Статус не подтверждён","Ожидает подтверждения")})
}

function Render-CompactTasks($tasks) {
 $compactTasksPanel.Children.Clear(); $compactDotsPanel.Children.Clear()
 $compactTasks=@(Compact-VisibleTasks $tasks)
 $visibleTasks=@($compactTasks|Select-Object -First 3)
 $unavailable=@($script:sourceErrors)
 $warningText=if($unavailable.Count -gt 0){"Нет данных от "+($unavailable -join ", ")}else{""}
 if($visibleTasks.Count -eq 0){
  $script:compactTaskId=""
  $compactEmpty=Text $(if($warningText){$warningText}else{"Активных задач сейчас нет"}) 12.5 $script:palette.Activity
  $compactEmpty.Margin=New-Object Windows.Thickness(0,5,0,5)
  $compactTasksPanel.Children.Add($compactEmpty)|Out-Null
  $compactDotsPanel.Visibility="Collapsed"
 } else {
  $selected=@($visibleTasks|Where-Object {[string]$_.Id -eq $script:compactTaskId}|Select-Object -First 1)
  if($selected.Count -eq 0){$selected=@($visibleTasks[0]);$script:compactTaskId=[string]$visibleTasks[0].Id}
  Add-CompactTask $selected[0]
  if($warningText){
   $warning=Text $warningText 11.5 $script:palette.Muted
   $warning.Margin=New-Object Windows.Thickness(12,0,0,6)
   $compactTasksPanel.Children.Add($warning)|Out-Null
  }
  if($visibleTasks.Count -gt 1){
   $compactDotsPanel.Visibility="Visible"
   foreach($task in $visibleTasks){Add-CompactDot $task ([string]$task.Id -eq $script:compactTaskId)}
  }else{$compactDotsPanel.Visibility="Collapsed"}
 }
 $hiddenCount=[Math]::Max(0,$compactTasks.Count-3)
 $compactMoreText.Visibility=$(if($hiddenCount -gt 0){"Visible"}else{"Collapsed"})
 $compactMoreText.Text=$(if($hiddenCount -gt 0){"Ещё $hiddenCount задач"}else{""})
 $hasLoopWarning=$visibleTasks.Count -gt 0 -and $null -ne (Get-LoopWarning $selected[0])
 if($script:isCompact){$window.Height=Compact-Height $compactTasks.Count ($unavailable.Count -gt 0) $hasLoopWarning; Move-CompactWindow}
}

function Compact-Height([int]$activeCount,[bool]$hasSourceErrors=$false,[bool]$hasLoopWarning=$false) {
 if($activeCount -le 0){return 132}
 $dots=if($activeCount -gt 1){18}else{0}
 $more=if($activeCount -gt 3){20}else{0}
 $provider=if($script:showProviderLabels){18}else{0}
 $warning=if($hasSourceErrors){20}else{0}
 $loopSpace=if($hasLoopWarning){72}else{0}
 return 162+$dots+$more+$provider+$warning+$loopSpace
}

function Move-CompactWindow {
 $work=[Windows.SystemParameters]::WorkArea
 $window.UpdateLayout()
 $window.Left=$work.Right-$window.Width
 $window.Top=$work.Bottom-$window.Height
}

function Set-CompactMode([bool]$compact) {
 if($compact -eq $script:isCompact){return}
 if($compact){
  $script:expandedBounds=[PSCustomObject]@{Left=$window.Left;Top=$window.Top;Width=$window.Width;Height=$window.Height}
  $expandedView.Visibility="Collapsed"; $settingsView.Visibility="Collapsed"; $aboutView.Visibility="Collapsed"; $journalView.Visibility="Collapsed"; $compactView.Visibility="Visible"
  $script:showingSettings=$false; $script:showingAbout=$false; $script:showingJournal=$false
  $window.ResizeMode="NoResize"; $window.MinWidth=0; $window.MinHeight=0; $window.Width=390
  $compactCount=@(Compact-VisibleTasks $script:lastTasks).Count
  $selectedTask=@($script:lastTasks|Where-Object {[string]$_.Id -eq $script:compactTaskId}|Select-Object -First 1)
  $hasLoopWarning=$selectedTask.Count -gt 0 -and $null -ne (Get-LoopWarning $selectedTask[0])
  $window.Height=Compact-Height $compactCount ($script:sourceErrors.Count -gt 0) $hasLoopWarning
  $windowFrame.Margin=New-Object Windows.Thickness(16)
  $script:isCompact=$true; $window.Topmost=$true; Move-CompactWindow
 }else{
  $compactView.Visibility="Collapsed"; $expandedView.Visibility="Visible"
  $window.ResizeMode="CanResize"; $window.MinWidth=500; $window.MinHeight=500
  $windowFrame.Margin=New-Object Windows.Thickness(28)
  if($null -ne $script:expandedBounds){$window.Left=$script:expandedBounds.Left;$window.Top=$script:expandedBounds.Top;$window.Width=$script:expandedBounds.Width;$window.Height=$script:expandedBounds.Height}else{$window.Width=590;$window.Height=760;$window.WindowStartupLocation="CenterScreen"}
  $script:isCompact=$false; $window.Topmost=$true
  Show-PendingUpdate
 }
}

function Show-PendingUpdate {
 if($script:isCompact -or $null -eq $script:availableUpdate -or $script:availableUpdate.Version -ceq $script:dismissedUpdate){return}
 $updateVersionText.Text='Версия '+$script:availableUpdate.Version+' доступна для скачивания'
 $updateOpenError.Visibility='Collapsed';$updateOverlay.Visibility='Visible'
 $updateLaterButton.Focus()|Out-Null
}

function Hide-UpdateForSession {
 if($null -ne $script:availableUpdate){$script:dismissedUpdate=[string]$script:availableUpdate.Version}
 $updateOverlay.Visibility='Collapsed'
 [Windows.Input.Keyboard]::ClearFocus()|Out-Null
}

function Invoke-UpdateDownload {
 if($null -eq $script:availableUpdate){return}
 $url=[string]$script:availableUpdate.Url
 try{
  $uri=[Uri]$url;$parts=$uri.AbsolutePath.Split('/')
  if($parts.Count -ne 7 -or -not (Get-TrustedReleaseUrl $url $parts[5] $parts[6] 'windows')){throw 'Untrusted release URL'}
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$url;$info.UseShellExecute=$true
  [void][Diagnostics.Process]::Start($info)
  Hide-UpdateForSession
 }catch{$updateOpenError.Visibility='Visible'}
}

function Invoke-UpdateCheckTick {
 if(-not $script:releaseUpdatesAvailable){return}
 if($null -ne $script:updateRequest){
  if(-not $script:updateRequest.IsCompleted){return}
  try{
   $json=$script:updateRequest.GetAwaiter().GetResult()
   $found=Find-PlatformUpdate $json $script:currentVersion 'windows'
   if($null -ne $found){$script:availableUpdate=$found;Show-PendingUpdate}
  }catch{}finally{$script:updateRequest=$null}
 }
 if(([DateTime]::UtcNow-$script:lastUpdateCheck).TotalHours -lt 24){return}
 $script:lastUpdateCheck=[DateTime]::UtcNow
 try{
  if($null -eq $script:updateClient){
   Add-Type -AssemblyName System.Net.Http
   $handler=New-Object Net.Http.HttpClientHandler;$handler.UseCookies=$false;$handler.AllowAutoRedirect=$false;$handler.UseDefaultCredentials=$false
   $script:updateClient=New-Object Net.Http.HttpClient($handler)
   $script:updateClient.Timeout=[TimeSpan]::FromSeconds(12)
   $script:updateClient.MaxResponseContentBufferSize=1048576
   $script:updateClient.DefaultRequestHeaders.UserAgent.ParseAdd('AI-Task-Monitor/0.2')
   $script:updateClient.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
  }
  $script:updateRequest=$script:updateClient.GetStringAsync('https://api.github.com/repos/trueakaru-stack/ai-task-monitor/releases?per_page=100')
 }catch{$script:updateRequest=$null}
}

function Show-SettingsView([bool]$keyboardNavigation = $false,[bool]$fromJournal = $false,[bool]$fromAbout = $false) {
 if($script:isCompact){Set-CompactMode $false}
 $expandedView.Visibility="Collapsed"
 $compactView.Visibility="Collapsed"
 $journalView.Visibility="Collapsed"
 $aboutView.Visibility="Collapsed"
 $settingsView.Visibility="Visible"
 $script:showingSettings=$true; $script:showingAbout=$false; $script:showingJournal=$false
 Update-SourceSettings
 Update-JournalSettings
 Update-LoopSettings
 if($keyboardNavigation){if($fromJournal){$journalOpenButton.Focus()|Out-Null}elseif($fromAbout){$aboutSettingsButton.Focus()|Out-Null}else{$settingsBackButton.Focus()|Out-Null}}else{[Windows.Input.Keyboard]::ClearFocus()|Out-Null}
}

function Get-FeedbackUri {
 return 'mailto:truea.k.a.ru@gmail.com?subject='+[Uri]::EscapeDataString('Отзыв или предложение об AI Task Monitor')
}

function Open-FeedbackDraft {
 try{
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=Get-FeedbackUri; $info.UseShellExecute=$true
  [void][Diagnostics.Process]::Start($info)
  $feedbackError.Visibility="Collapsed"
 }catch{$feedbackError.Visibility="Visible"}
}

function Show-TasksView([bool]$keyboardNavigation = $false) {
 $settingsView.Visibility="Collapsed"
 $aboutView.Visibility="Collapsed"
 $journalView.Visibility="Collapsed"
 $compactView.Visibility="Collapsed"
 $expandedView.Visibility="Visible"
 $script:showingSettings=$false; $script:showingAbout=$false; $script:showingJournal=$false
 if($keyboardNavigation){$settingsFooterButton.Focus()|Out-Null}else{[Windows.Input.Keyboard]::ClearFocus()|Out-Null}
}

function Show-AboutView([bool]$keyboardNavigation = $false) {
 if($script:isCompact){Set-CompactMode $false}
 $expandedView.Visibility="Collapsed"; $compactView.Visibility="Collapsed"
 $settingsView.Visibility="Collapsed"; $journalView.Visibility="Collapsed"; $aboutView.Visibility="Visible"
 $script:showingSettings=$false; $script:showingAbout=$true; $script:showingJournal=$false
 $aboutScroll.ScrollToTop()
 if($keyboardNavigation){$aboutBackButton.Focus()|Out-Null}else{[Windows.Input.Keyboard]::ClearFocus()|Out-Null}
}

function New-JournalComboItem([string]$label,$tag) {
 $item=New-Object Windows.Controls.ComboBoxItem
 $item.Content=$label; $item.Tag=$tag
 [Windows.Automation.AutomationProperties]::SetName($item,$label)
 $item.Add_SizeChanged({param($sender,$eventArgs)
  $probe=New-Object Windows.Controls.TextBlock
  $probe.Text=[string]$sender.Content; $probe.FontFamily=$sender.FontFamily; $probe.FontSize=$sender.FontSize; $probe.FontWeight=$sender.FontWeight
  $probe.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
  $sender.ToolTip=$(if($sender.ActualWidth -gt 0 -and $probe.DesiredSize.Width -gt [Math]::Max(0,$sender.ActualWidth-20)){[string]$sender.Content}else{$null})
 })
 return $item
}

function Update-JournalComboHint($combo) {
 if($null -eq $combo.SelectedItem -or $combo.ActualWidth -le 0){$combo.ToolTip=$null;return}
 $value=[string]$combo.SelectedItem.Content
 $probe=New-Object Windows.Controls.TextBlock
 $probe.Text=$value; $probe.FontFamily=$combo.FontFamily; $probe.FontSize=$combo.FontSize; $probe.FontWeight=$combo.FontWeight
 $probe.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
 $combo.ToolTip=$(if($probe.DesiredSize.Width -gt [Math]::Max(0,$combo.ActualWidth-38)){$value}else{$null})
}

function Update-JournalSettings {
 $script:updatingJournalControls=$true
 try{
  if($journalDaysCombo.Items.Count -eq 0){
   foreach($day in 1..7){$unit=if($day -eq 1){"день"}elseif($day -le 4){"дня"}else{"дней"};[void]$journalDaysCombo.Items.Add((New-JournalComboItem "$day $unit" $day))}
   foreach($size in 1..10){[void]$journalSizeCombo.Items.Add((New-JournalComboItem "$size МБ" $size))}
  }
  $ready=$null -ne $script:diagnosticRuntime
  $journalDaysCombo.IsEnabled=$ready; $journalSizeCombo.IsEnabled=$ready; $journalOpenButton.IsEnabled=$ready; $journalClearButton.IsEnabled=$script:diagnosticModulesAvailable -and $journalClearConfirmation.Visibility -ne "Visible"
  if($ready){
   foreach($item in $journalDaysCombo.Items){if([int]$item.Tag -eq [int]$script:diagnosticRuntime.Settings.RetentionDays){$journalDaysCombo.SelectedItem=$item;break}}
   foreach($item in $journalSizeCombo.Items){if([int]$item.Tag -eq [int]$script:diagnosticRuntime.Settings.MaximumMB){$journalSizeCombo.SelectedItem=$item;break}}
  }
  $error=if($script:journalUiError){$script:journalUiError}elseif($script:diagnosticError){$script:diagnosticError}elseif(-not $ready){"Журнал недоступен"}else{""}
  $journalSettingsError.Text=$error
  $journalSettingsError.Visibility=$(if($error){"Visible"}else{"Collapsed"})
 }finally{$script:updatingJournalControls=$false}
 Update-JournalComboHint $journalDaysCombo
 Update-JournalComboHint $journalSizeCombo
}

function Update-LoopSettings {
 $script:updatingLoopControls=$true
 try{
  if($loopThresholdCombo.Items.Count -eq 0){
   foreach($count in 3..10){[void]$loopThresholdCombo.Items.Add((New-JournalComboItem ([string]$count) $count))}
   foreach($minutes in 1..30){[void]$loopWindowCombo.Items.Add((New-JournalComboItem "$minutes мин" $minutes))}
  }
  $ready=$null -ne $script:diagnosticRuntime
  $loopThresholdCombo.IsEnabled=$ready; $loopWindowCombo.IsEnabled=$ready
  if($ready){
   foreach($item in $loopThresholdCombo.Items){if([int]$item.Tag -eq [int]$script:diagnosticRuntime.Settings.LoopThreshold){$loopThresholdCombo.SelectedItem=$item;break}}
   foreach($item in $loopWindowCombo.Items){if([int]$item.Tag -eq [int]$script:diagnosticRuntime.Settings.LoopWindowMinutes){$loopWindowCombo.SelectedItem=$item;break}}
  }
  $error=if($script:loopUiError){$script:loopUiError}elseif(-not $ready){"Настройка недоступна"}elseif($script:claudeLoopError){$script:claudeLoopError}else{""}
  $loopSettingsError.Text=$error; $loopSettingsError.Visibility=$(if($error){"Visible"}else{"Collapsed"})
 }finally{$script:updatingLoopControls=$false}
 Update-JournalComboHint $loopThresholdCombo
 Update-JournalComboHint $loopWindowCombo
}

function Save-LoopControls {
 if($script:updatingLoopControls -or $null -eq $script:diagnosticRuntime -or $null -eq $loopThresholdCombo.SelectedItem -or $null -eq $loopWindowCombo.SelectedItem){return}
 try{
  Save-DiagnosticSettings -Directory $script:diagnosticDirectory -LoopThreshold ([int]$loopThresholdCombo.SelectedItem.Tag) -LoopWindowMinutes ([int]$loopWindowCombo.SelectedItem.Tag)
  $script:diagnosticRuntime.Settings=Get-DiagnosticSettings -Directory $script:diagnosticDirectory
  $script:loopUiError=""; $script:fingerprint=""
 }catch{$script:loopUiError="Не удалось сохранить настройки предупреждения"}
 Update-LoopSettings
}

function Reveal-JournalSettings {
 $window.UpdateLayout()
 $point=$journalSettingsSection.TranslatePoint([Windows.Point]::new(0,0),$settingsScroll)
 $target=[Math]::Max(0,$settingsScroll.VerticalOffset+$point.Y-40)
 $settingsScroll.ScrollToVerticalOffset($target)
 $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
 $window.UpdateLayout()
}

function Save-JournalControls {
 if($script:updatingJournalControls -or $null -eq $script:diagnosticRuntime -or $null -eq $journalDaysCombo.SelectedItem -or $null -eq $journalSizeCombo.SelectedItem){return}
 $days=[int]$journalDaysCombo.SelectedItem.Tag; $size=[int]$journalSizeCombo.SelectedItem.Tag
 try{
  Save-DiagnosticSettings -Directory $script:diagnosticDirectory -RetentionDays $days -MaximumMB $size
  $script:diagnosticRuntime.Settings=Get-DiagnosticSettings -Directory $script:diagnosticDirectory
  $script:journalUiError=""
 }catch{$script:journalUiError="Не удалось сохранить настройки журнала";Update-JournalSettings;return}
 try{
  $now=[DateTimeOffset]::UtcNow; $limit=[long]$size*1000000
  Remove-ExpiredDiagnosticEvents -Directory $script:diagnosticDirectory -Now $now -RetentionDays $days -MaximumBytes $limit
  $events=@(Read-DiagnosticEvents -Directory $script:diagnosticDirectory -Now $now -RetentionDays $days -MaximumBytes $limit)
  Set-DiagnosticNextCleanup $script:diagnosticRuntime $events
  $script:journalFingerprint=""
 }catch{$script:journalUiError="Не удалось применить очистку журнала"}
 Update-JournalSettings
}

function Get-JournalTaskOptions($references) {
 $targetKeys=@{}
 foreach($reference in $references){$targetKeys[[string]$reference.Key]=[string]$reference.Provider}
 $known=@{}
 foreach($task in $script:lastAllTasks){
  $provider=[string](Prop $task "Provider" "");$id=[string](Prop $task "Id" "")
  if($provider -eq "claude" -and $id.StartsWith("claude:")){$id=$id.Substring(7)}
  if($provider -notin @("codex","claude") -or $id -notmatch '^[A-Za-z0-9_-]{1,128}$'){continue}
  $key=Get-DiagnosticTaskKey -Provider $provider -TaskId $id -Key $script:diagnosticRuntime.Key
  if($targetKeys.ContainsKey($key)){$known[$key]=[regex]::Replace(([string](Prop $task "Title" "")).Trim(),'\s+',' ')}
 }
 if(Test-Path -LiteralPath $sessionIndex){
  try{
   foreach($line in Get-Content -LiteralPath $sessionIndex -Encoding UTF8 -Tail 100){
    try{
     $session=$line|ConvertFrom-Json;$id=[string](Prop $session "id" "")
     if($id -notmatch '^[A-Za-z0-9_-]{1,128}$'){continue}
     $key=Get-DiagnosticTaskKey -Provider "codex" -TaskId $id -Key $script:diagnosticRuntime.Key
     if($targetKeys.ContainsKey($key) -and -not $known.ContainsKey($key)){$known[$key]=[regex]::Replace(([string](Prop $session "thread_name" "")).Trim(),'\s+',' ')}
    }catch{}
   }
  }catch{}
 }
 $labels=@{};$options=New-Object 'Collections.Generic.List[object]'
 foreach($reference in $references){
  $key=[string]$reference.Key
  $provider=[string]$reference.Provider
  $label=if($known.ContainsKey($key) -and $known[$key]){[string]$known[$key]}elseif($provider -eq "claude"){"Задача Claude Code"}else{"Задача Codex"}
  if($provider -eq "codex" -and $label -ne "Задача Codex"){$label="$label (Codex)"}
  if($labels.ContainsKey($label)){$labels[$label]++;$label="$label $($labels[$label])"}else{$labels[$label]=1}
  $options.Add([PSCustomObject]@{Key=$key;Label=$label})
 }
 return $options.ToArray()
}

function Render-Journal {
 if(-not $script:showingJournal){return}
 if($null -eq $script:diagnosticRuntime){$journalEventsList.ItemsSource=$null;$journalEmptyText.Text="Журнал недоступен";$journalEmptyText.Visibility="Visible";return}
 try{
  $filter=if($null -ne $journalTaskFilter.SelectedItem){[string]$journalTaskFilter.SelectedItem.Tag}else{""}
  $path=Join-Path $script:diagnosticDirectory "diagnostic-events-v1.jsonl"
  $fileVersion=if(Test-Path -LiteralPath $path){$file=Get-Item -LiteralPath $path;[string]$file.Length+":"+[string]$file.LastWriteTimeUtc.Ticks}else{"none"}
  $titles=(($script:lastAllTasks|ForEach-Object{"$($_.Provider):$($_.Id):$($_.Title)"}) -join "|")
  $fingerprint=$fileVersion+"|"+$filter+"|"+$titles
  if($fingerprint -eq $script:journalFingerprint){return}
  $settings=$script:diagnosticRuntime.Settings
  $events=@(Read-DiagnosticEvents -Directory $script:diagnosticDirectory -Now ([DateTimeOffset]::UtcNow) -RetentionDays $settings.RetentionDays -MaximumBytes ([long]$settings.MaximumMB*1000000))
  # Storage returns chronological records; the journal displays the newest first.
  [Array]::Reverse($events)
  $references=@([AITaskMonitor.Diagnostics.Policy]::DistinctTasks($events))
  $options=@(Get-JournalTaskOptions $references)
  $script:updatingJournalControls=$true
  try{
   $journalTaskFilter.Items.Clear()
   [void]$journalTaskFilter.Items.Add((New-JournalComboItem "Все задачи" ""))
   $selected=0
   foreach($option in $options){[void]$journalTaskFilter.Items.Add((New-JournalComboItem $option.Label $option.Key));if($option.Key -eq $filter){$selected=$journalTaskFilter.Items.Count-1}}
   $journalTaskFilter.SelectedIndex=$selected
  }finally{$script:updatingJournalControls=$false}
  $filter=if($null -ne $journalTaskFilter.SelectedItem){[string]$journalTaskFilter.SelectedItem.Tag}else{""}
  $labels=@{
   task_observed="Задача обнаружена";task_started="Работа началась";task_completed="Работа завершена";task_interrupted="Работа прервана";task_unconfirmed="Статус не подтверждён"
   source_unavailable="Источник недоступен";source_recovered="Источник восстановлен";tool_started="Действие началось";tool_finished="Действие завершено";tool_failed="Ошибка действия"
  }
  $rows=@([AITaskMonitor.Diagnostics.Policy]::MakeRows($events,$filter,$labels))
  $journalEventsList.ItemsSource=$rows
  $journalEmptyText.Text=$(if($filter){"Нет событий для этой задачи"}else{"Пока нет событий"})
  $journalEmptyText.Visibility=$(if($rows.Count -eq 0){"Visible"}else{"Collapsed"})
  $script:journalFingerprint=$fileVersion+"|"+$filter+"|"+$titles
  Update-JournalComboHint $journalTaskFilter
 }catch{$journalEventsList.ItemsSource=$null;$journalEmptyText.Text="Не удалось открыть журнал";$journalEmptyText.Visibility="Visible"}
}

function Show-JournalView([bool]$keyboardNavigation = $false) {
 if($null -eq $script:diagnosticRuntime){return}
 $expandedView.Visibility="Collapsed";$compactView.Visibility="Collapsed";$settingsView.Visibility="Collapsed";$aboutView.Visibility="Collapsed";$journalView.Visibility="Visible"
 $script:showingSettings=$false;$script:showingAbout=$false;$script:showingJournal=$true;$script:journalFingerprint=""
 Render-Journal
 if($keyboardNavigation){$journalBackButton.Focus()|Out-Null}else{[Windows.Input.Keyboard]::ClearFocus()|Out-Null}
}

function Minimize-ToTaskbar {
 $window.WindowState=[Windows.WindowState]::Minimized
}

function Restore-Window {
 $window.WindowState=[Windows.WindowState]::Normal
 $window.Show()
 $window.Activate()
}

function Invoke-HiddenProviderSetup([string]$configScript,[ValidateSet("Install","Remove")][string]$mode) {
 $powerShell=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) "WindowsPowerShell\v1.0\powershell.exe"
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=$powerShell
 $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$configScript+'" -Mode '+$mode
 $start.WorkingDirectory=Split-Path -Parent $configScript
 $start.UseShellExecute=$false
 $start.CreateNoWindow=$true
 $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $process=[Diagnostics.Process]::Start($start)
 try{$process.WaitForExit();if($process.ExitCode -ne 0){throw "Configuration failed"}}finally{$process.Dispose()}
}

function Filtered-Tasks($tasks){
 if($script:selectedProvider -eq "all"){return @($tasks)}
 return @($tasks|Where-Object {[string]$_.Provider -eq $script:selectedProvider})
}

function Add-ProviderTab([string]$id,[string]$label,[int]$count){
 $button=New-Object Windows.Controls.Button
 $button.Style=$window.Resources["ProviderTabStyle"]
 $button.Tag=$id
 $surfaceGrid=New-Object Windows.Controls.Grid
 $tabShape=New-Object Windows.Shapes.Path
 $tabShape.IsHitTestVisible=$false
 $surfaceGrid.Children.Add($tabShape)|Out-Null
 $contentBorder=New-Object Windows.Controls.Border
 $contentBorder.Padding=New-Object Windows.Thickness(13,0,13,0)
 $content=New-Object Windows.Controls.Grid
 $labelColumn=New-Object Windows.Controls.ColumnDefinition;$labelColumn.Width=[Windows.GridLength]::Auto
 $countColumn=New-Object Windows.Controls.ColumnDefinition;$countColumn.Width=[Windows.GridLength]::Auto
 $content.ColumnDefinitions.Add($labelColumn);$content.ColumnDefinitions.Add($countColumn)
 $selected=$script:selectedProvider -eq $id
 $tabForeground=Brush $(if($selected){$script:accentForeground}else{$script:palette.Secondary})
 $button.Foreground=$tabForeground
 $labelText=Text $label 13 $script:palette.Secondary "SemiBold"
 $labelText.Foreground=$tabForeground;$labelText.VerticalAlignment="Center";$labelText.TextWrapping="NoWrap"
 $countText=Text $count.ToString() 11.5 $script:palette.Secondary "SemiBold"
 $countText.Foreground=$tabForeground;$countText.Margin=New-Object Windows.Thickness(3,-5,0,0);$countText.VerticalAlignment="Center"
 [Windows.Controls.Grid]::SetColumn($countText,1);$content.Children.Add($labelText)|Out-Null;$content.Children.Add($countText)|Out-Null
 $contentBorder.Child=$content
 $surfaceGrid.Children.Add($contentBorder)|Out-Null
 $button.Content=$surfaceGrid
 $button.DataContext=$tabShape
 $button.Add_SizeChanged({param($sender,$args) if($sender.ActualWidth -gt 0 -and $sender.ActualHeight -gt 0){$sender.DataContext.Data=Squircle-Geometry $sender.ActualWidth $sender.ActualHeight ($script:cardRadius-$script:tabPadding) 0}})
 $button.Add_MouseEnter({param($sender,$args) if($script:selectedProvider -ne [string]$sender.Tag){$sender.DataContext.Fill=Brush $script:palette.Hover}})
 $button.Add_MouseLeave({param($sender,$args) if($script:selectedProvider -ne [string]$sender.Tag){$sender.DataContext.Fill=[Windows.Media.Brushes]::Transparent}})
 [Windows.Automation.AutomationProperties]::SetName($button,"Показать задачи: $label, $count")
 $tabShape.Fill=$(if($selected){Brush $script:accentHex}else{[Windows.Media.Brushes]::Transparent})
 $button.Add_Click({param($sender,$args) $script:selectedProvider=[string]$sender.Tag;$script:fingerprint="";Update-View})
 $providerTabsPanel.Children.Add($button)|Out-Null
}

function Render-ProviderTabs($tasks){
 $providers=@($tasks|ForEach-Object{[string]$_.Provider}|Where-Object{$_}|Sort-Object -Unique)
 $script:showProviderLabels=$providers.Count -ge 2
 if($providers.Count -lt 2){$providerTabsHost.Visibility="Collapsed";$script:selectedProvider="all";return}
 if($script:selectedProvider -ne "all" -and $script:selectedProvider -notin $providers){$script:selectedProvider="all"}
 $providerTabsHost.Visibility="Visible";$providerTabsPanel.Children.Clear()
 Add-ProviderTab "all" "Все" @($tasks|Where-Object Active).Count
 Add-ProviderTab "codex" "Codex" @($tasks|Where-Object {$_.Active -and $_.Provider -eq "codex"}).Count
 Add-ProviderTab "claude" "Claude Code" @($tasks|Where-Object {$_.Active -and $_.Provider -eq "claude"}).Count
 if($providerTabsPanel.Children.Count -gt 0){$providerTabsPanel.Children[$providerTabsPanel.Children.Count-1].Margin=New-Object Windows.Thickness(0)}
 $providerTabsHost.UpdateLayout()
 Update-SquircleGeometry
}

function Update-View {
 try {
  $sourceSnapshot=Source-Snapshot
  $allTasks=@($sourceSnapshot.Tasks)
  $script:sourceErrors=@($sourceSnapshot.Unavailable)
  if($PreviewActiveTasks -ge 0){
   $previewTitles=@("Создать индикатор прогресса задач","Задача Claude Code","Задача Claude Code")
   $previewActivities=@("Проверяю карточки планов, переключение источников и прокрутку этапов перед публикацией новой версии, светлую тему и поведение длинных описаний","Запускаю визуальную проверку","Собираю данные для переноса")
   $previewProgress=@(50,33,$null);$previewKinds=@("exact","exact","none");$previewProviders=@("codex","claude","claude");$previewProviderNames=@("Codex","Claude Code","Claude Code")
   $allTasks=@()
   for($i=0;$i -lt $PreviewActiveTasks;$i++){
    $previewSteps=$(if($i -eq 0){
     @(
      [PSCustomObject]@{title="Синхронизировать список задач";status="done"},
      [PSCustomObject]@{title="Восстановить карточки планов";status="done"},
      [PSCustomObject]@{title="Исправить прокрутку этапов";status="done"},
      [PSCustomObject]@{title="Применить системный акцент";status="done"},
      [PSCustomObject]@{title="Проверить скругления и фокус";status="active"},
      [PSCustomObject]@{title="Снять тёмный и светлый экран";status="pending"},
      [PSCustomObject]@{title="Провести финальную проверку";status="pending"},
      [PSCustomObject]@{title="Опубликовать исходники";status="pending"}
     )
    }elseif($i -eq 1){
     @(
      [PSCustomObject]@{title="Проверить локальное окружение";status="done"},
      [PSCustomObject]@{title="Подготовить тестовые данные";status="done"},
      [PSCustomObject]@{title="Запустить визуальную проверку";status="active"},
      [PSCustomObject]@{title="Проверить светлую тему";status="pending"},
      [PSCustomObject]@{title="Зафиксировать результат";status="pending"},
      [PSCustomObject]@{title="Очистить временные данные";status="pending"}
     )
    }else{@()})
    $previewIsUnconfirmed=$PreviewUnconfirmed -and $i -eq 0
    $previewActivity=if($previewIsUnconfirmed){"Статус не подтверждён"}else{$previewActivities[$i]}
    $previewStatus=if($previewIsUnconfirmed){"Статус не подтверждён"}else{"В работе"}
    $allTasks += [PSCustomObject]@{Id="preview-$i";Title=$previewTitles[$i];Activity=$previewActivity;Active=(-not $previewIsUnconfirmed);Paused=$false;Progress=$previewProgress[$i];ProgressKind=$previewKinds[$i];Provider=$previewProviders[$i];ProviderName=$previewProviderNames[$i];Status=$previewStatus;Updated=[DateTime]::Now;Steps=$previewSteps;Source="Предпросмотр"}
   }
  }
  $script:lastAllTasks=$allTasks
  Sync-ClaudeLoopChannel
  Refresh-Diagnostics $allTasks
  Render-ProviderTabs $allTasks
  $tasks=@(Filtered-Tasks $allTasks)
  $script:lastTasks=$tasks
  $next=$script:selectedProvider+"|"+($script:sourceErrors -join ",")+"|"+(($tasks|ForEach-Object{$stepState=(@($_.Steps)|ForEach-Object{"$(Prop $_ 'title' '')=$(Prop $_ 'status' '')"})-join","; $loop=Get-LoopWarning $_;$loopState=if($null -ne $loop){"$($loop.Threshold):$($loop.WindowMinutes)"}else{"none"}; "$($_.Id):$($_.Provider):$($_.Active):$($_.ProgressKind):$($_.Progress):$($_.Status):$($_.Activity):$stepState`:$loopState"})-join"|")
  if($next -ne $script:fingerprint){
   $script:fingerprint=$next; $tasksPanel.Children.Clear()
   if($script:sourceErrors.Count -gt 0){$warning=Text ("Нет данных от "+($script:sourceErrors -join ", ")) 14 $script:palette.Secondary; $warning.Margin=New-Object Windows.Thickness(4,0,0,12); $tasksPanel.Children.Add($warning)|Out-Null}
   foreach($task in $tasks){Add-Card $task}
   if($tasks.Count -eq 0 -and $script:sourceErrors.Count -eq 0){$empty=Text "Активных задач сейчас нет" 14 $script:palette.Secondary; $empty.Margin=New-Object Windows.Thickness(4,24,0,0); $tasksPanel.Children.Add($empty)|Out-Null}
   Render-CompactTasks $tasks
  }
  if($script:showingJournal){Render-Journal}
  if($script:showingSettings -and -not $journalDaysCombo.IsDropDownOpen -and -not $journalSizeCombo.IsDropDownOpen){Update-JournalSettings}
  if($script:showingSettings -and -not $loopThresholdCombo.IsDropDownOpen -and -not $loopWindowCombo.IsDropDownOpen){Update-LoopSettings}
 } catch {
  $tasksPanel.Children.Clear()
  $errorText=Text "Не удалось обновить задачи" 14 $script:palette.Secondary
  $errorText.Margin=New-Object Windows.Thickness(4,24,0,0)
  $tasksPanel.Children.Add($errorText)|Out-Null
 }
}

$window.Add_MouseLeftButtonDown({if($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed){$window.DragMove()}})
$pinButton.Add_Click({$window.Topmost=$true})
$minimizeButton.Add_Click({Set-CompactMode $true})
$expandButton.Add_Click({Set-CompactMode $false})
$taskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$compactTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$settingsTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$aboutTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$journalTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$settingsFooterButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$settingsBackButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$settingsFooterButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$settingsBackButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$journalOpenButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$journalBackButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$journalOpenButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$journalBackButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$settingsFooterButton.Add_Click({Show-SettingsView $script:navigationByKeyboard;$script:navigationByKeyboard=$false})
$settingsBackButton.Add_Click({Show-TasksView $script:navigationByKeyboard;$script:navigationByKeyboard=$false})
$aboutSettingsButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$aboutSettingsButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$aboutSettingsButton.Add_Click({Show-AboutView $script:navigationByKeyboard;$script:navigationByKeyboard=$false})
$feedbackSettingsButton.Add_Click({Open-FeedbackDraft})
$aboutBackButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$aboutBackButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$aboutBackButton.Add_Click({Show-SettingsView $script:navigationByKeyboard $false $true;$script:navigationByKeyboard=$false})
$updateLaterButton.Add_Click({Hide-UpdateForSession})
$updateDownloadButton.Add_Click({Invoke-UpdateDownload})
$updateOverlay.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq [Windows.Input.Key]::Escape){Hide-UpdateForSession;$eventArgs.Handled=$true}})
$updateDialog.Add_SizeChanged({if($updateDialog.ActualWidth -gt 0 -and $updateDialog.ActualHeight -gt 0){$updateDialogShape.Data=Squircle-Geometry $updateDialog.ActualWidth $updateDialog.ActualHeight 16 0.5}})
$journalOpenButton.Add_Click({$journalClearConfirmation.Visibility="Collapsed";Show-JournalView $script:navigationByKeyboard;$script:navigationByKeyboard=$false})
$journalBackButton.Add_Click({Show-SettingsView $script:navigationByKeyboard $true;$script:navigationByKeyboard=$false})
$journalDaysCombo.Add_SelectionChanged({Save-JournalControls})
$journalSizeCombo.Add_SelectionChanged({Save-JournalControls})
$loopThresholdCombo.Add_SelectionChanged({Save-LoopControls})
$loopWindowCombo.Add_SelectionChanged({Save-LoopControls})
$journalTaskFilter.Add_SelectionChanged({if(-not $script:updatingJournalControls){$script:journalFingerprint="";Render-Journal}})
foreach($combo in @($journalDaysCombo,$journalSizeCombo,$journalTaskFilter,$loopThresholdCombo,$loopWindowCombo)){$combo.Add_SizeChanged({param($sender,$eventArgs) Update-JournalComboHint $sender})}
$journalClearButton.Add_Click({$journalClearConfirmation.Visibility="Visible";Update-JournalSettings;Reveal-JournalSettings})
$journalCancelClearButton.Add_Click({$journalClearConfirmation.Visibility="Collapsed";Update-JournalSettings})
$journalConfirmClearButton.Add_Click({
 try{
  Clear-DiagnosticEvents -Directory $script:diagnosticDirectory
  if($null -ne $script:diagnosticRuntime){$script:diagnosticRuntime.NextCleanup=[DateTimeOffset]::MaxValue}
  else{
   try{$script:diagnosticRuntime=New-DiagnosticRuntime -Directory $script:diagnosticDirectory -Since ([DateTimeOffset]$script:monitorStartedUtc) -Now ([DateTimeOffset]::UtcNow);$script:diagnosticError=""}
   catch{$script:diagnosticError="Журнал очищен, но недоступен"}
  }
  $script:journalUiError="";$script:journalFingerprint=""
 }
 catch{$script:journalUiError="Не удалось очистить журнал"}
 $journalClearConfirmation.Visibility="Collapsed";Update-JournalSettings
})
$systemThemeButton.Add_Click({Apply-Theme "system" $true;Update-View})
$darkThemeButton.Add_Click({Apply-Theme "dark" $true;Update-View})
$lightThemeButton.Add_Click({Apply-Theme "light" $true;Update-View})
$claudeSourceAction.Add_Click({
 $mode=[string]$claudeSourceAction.Tag
 $configScript=Join-Path $PSScriptRoot "Configure-ClaudeIntegration.ps1"
 if(-not (Test-Path -LiteralPath $configScript)){$claudeSourceStatus.Text="Файл настройки не найден";return}
 try{
  Invoke-HiddenProviderSetup $configScript $mode
  Update-SourceSettings
  Update-View
 }catch{$claudeSourceStatus.Text="Ошибка подключения"}
})
$closeButton.Add_Click({$window.Close()})
$compactCloseButton.Add_Click({$window.Close()})
$settingsCloseButton.Add_Click({$window.Close()})
$aboutCloseButton.Add_Click({$window.Close()})
$journalCloseButton.Add_Click({$window.Close()})
$windowFrame.Add_SizeChanged({Update-SquircleGeometry})
$tray=New-Object Windows.Forms.NotifyIcon; $tray.Icon=if($null -ne $script:applicationIcon){$script:applicationIcon}else{[Drawing.SystemIcons]::Application}; $tray.Text="AI task monitor"; $tray.Visible=$true; $tray.Add_DoubleClick({Restore-Window})
$menu=New-Object Windows.Forms.ContextMenuStrip; $show=$menu.Items.Add("Развернуть"); $exit=$menu.Items.Add("Выход"); $show.Add_Click({Restore-Window;Set-CompactMode $false}); $exit.Add_Click({$window.Close()}); $tray.ContextMenuStrip=$menu
$timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[TimeSpan]::FromSeconds(2); $timer.Add_Tick({Refresh-SystemTheme;Update-View;if(-not $SnapshotFile -and $PreviewActiveTasks -lt 0){Invoke-UpdateCheckTick}}); $timer.Start(); $window.Add_Closed({$timer.Stop();if($null -ne $script:updateClient){$script:updateClient.Dispose();$script:updateClient=$null};if($null -ne $script:claudeLoopChannel){try{$script:claudeLoopChannel.Dispose()}catch{};$script:claudeLoopChannel=$null};$script:claudeLoopStates.Clear();$tray.Visible=$false;$tray.Dispose();if($null -ne $script:applicationIcon){$script:applicationIcon.Dispose()}})
$initialTheme=if($ThemeOverride){$ThemeOverride}else{Load-ThemeMode}
Apply-Theme $initialTheme $false
if($script:diagnosticModulesAvailable -and (($PreviewActiveTasks -lt 0 -and -not $SnapshotFile) -or $DiagnosticDirectory)){
 try{$script:diagnosticRuntime=New-DiagnosticRuntime -Directory $script:diagnosticDirectory -Since ([DateTimeOffset]$script:monitorStartedUtc) -Now ([DateTimeOffset]::UtcNow);$script:diagnosticError=""}
 catch{$script:diagnosticError="Журнал недоступен"}
}
if($PreviewStartupReadyFile){
 $probe=[IO.File]::Open($probePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$probe.WriteByte(1)}finally{$probe.Dispose()}
 Start-Sleep -Milliseconds $PreviewStartupDelayMilliseconds
}
Update-View
if($CompactMode){Set-CompactMode $true}
if($PreviewAbout){Show-AboutView}
if($PreviewUpdate){$script:availableUpdate=[PSCustomObject]@{Version='0.3.0-alpha';Url='https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0-alpha/AITaskMonitor.exe'};Show-PendingUpdate}
if ($SnapshotFile) {
 $window.Show(); $window.UpdateLayout()
 if($PreviewUpdateUiTest){
  if($updateOverlay.Visibility -ne 'Visible' -or $updateVersionText.Text -ne 'Версия 0.3.0-alpha доступна для скачивания'){throw 'Update dialog content is incorrect.'}
  $updateLaterButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Show-PendingUpdate
  if($updateOverlay.Visibility -ne 'Collapsed'){throw 'Dismissed update returned during this session.'}
  $script:dismissedUpdate='';Set-CompactMode $true;Show-PendingUpdate
  if($updateOverlay.Visibility -ne 'Collapsed'){throw 'Update appeared while compact.'}
  Set-CompactMode $false
  if($updateOverlay.Visibility -ne 'Visible'){throw 'Deferred update did not appear after expanding.'}
  $bad=[PSCustomObject]@{Version='9.0.0';Url='https://evil.example/setup.exe'}
  $script:availableUpdate=$bad;Invoke-UpdateDownload
  if($updateOpenError.Visibility -ne 'Visible'){throw 'Untrusted download URL was not rejected.'}
  $script:availableUpdate=$null;$script:dismissedUpdate='';$updateOverlay.Visibility='Collapsed'
  $script:lastUpdateCheck=[DateTime]::UtcNow
  $completed=New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
  $completed.SetResult('[{"tag_name":"v0.3.0-alpha","draft":false,"assets":[{"name":"app.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0-alpha/app.exe"}]}]')
  $script:updateRequest=$completed.Task;Invoke-UpdateCheckTick
  if($updateOverlay.Visibility -ne 'Visible' -or $script:availableUpdate.Version -ne '0.3.0-alpha'){throw 'Asynchronous release result did not reach the dialog.'}
  $window.UpdateLayout()
  Write-Output 'Update UI: asynchronous result, copy, link rejection, dismissal and compact deferral verified.'
 }
 if($PreviewAboutUiTest){
  if($aboutView.Visibility -ne "Visible" -or $aboutHeading.Text -ne "О приложении" -or $aboutVersionText.Text -ne ('AI task monitor · версия '+$script:currentVersion.Replace('-',' ')) -or
     -not $aboutProviders.Text.Contains("Codex") -or -not $aboutProviders.Text.Contains("Claude Code")){
   throw "The About page does not expose the expected content."
  }
  $aboutBackButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($settingsView.Visibility -ne "Visible" -or $aboutView.Visibility -ne "Collapsed"){throw "The About back action did not return to settings."}
  if((Get-FeedbackUri) -notmatch '^mailto:truea\.k\.a\.ru@gmail\.com\?subject=' -or (Get-FeedbackUri) -match '&body='){throw "The feedback draft is not private or correctly addressed."}
  if($settingsView.Visibility -ne "Visible" -or $aboutView.Visibility -ne "Collapsed"){throw "Settings and About cannot be visible together."}
  $aboutSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($aboutView.Visibility -ne "Visible" -or $settingsView.Visibility -ne "Collapsed"){throw "The About entry did not open the page."}
  $window.Height=520; $window.UpdateLayout()
  $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
  $window.UpdateLayout()
  if($aboutScroll.ScrollableHeight -le 0){throw "About content must scroll in a small window."}
  $aboutScroll.ScrollToEnd();$window.UpdateLayout()
  if($aboutScroll.VerticalOffset -le 0){throw "About scrolling did not reach the content."}
  $window.Height=760; Show-AboutView; $window.UpdateLayout()
  Write-Output "About UI: content, navigation, isolation and small-window scrolling verified."
 }
 if($PreviewIconUiTest){
  if(-not $script:shellIdentityAvailable -or $null -eq $window.Icon){throw "Application icon or shell identity is unavailable."}
  $handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
  if([AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle,5) -cne [AITaskMonitor.Windows.AppShellIdentity]::AppId){throw "The application window has no taskbar identity."}
  if([AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle,3) -cne ($iconPath+",0")){throw "The application window has no taskbar icon resource."}
  foreach($titleIconName in @("ExpandedTitleIcon","CompactTitleIcon")){
   $titleIcon=$window.FindName($titleIconName)
   if($titleIcon.Visibility -ne "Visible" -or $null -eq $titleIcon.Source -or $titleIcon.Width -ne 16 -or $titleIcon.Height -ne 16){throw "The title-bar icon is unavailable."}
  }
  Write-Output "Application icon: window identity and both title-bar icons verified in the real WPF view."
 }
 if($PreviewClaudeLoopUiTest){
  if($null -eq $script:claudeLoopChannel -or $null -eq $script:diagnosticRuntime){throw 'The synthetic Claude loop channel is unavailable.'}
  function Send-PreviewClaudeLoop([string]$session,[int]$number,[string]$kind){
   $testEvent=[PSCustomObject]@{
    session_id=$session;tool_use_id=('synthetic-'+$session+'-'+$number);tool_name='Bash';cwd='synthetic-private-project'
    tool_input=[PSCustomObject]@{command='synthetic-private-command'};is_interrupt=$false;error="Exit code 7`nsynthetic-private-output"
    hook_event_name=$(if($kind -eq 'start'){'PreToolUse'}else{'PostToolUseFailure'})
   }
   $hookStart=[Diagnostics.ProcessStartInfo]::new()
   $hookStart.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
   $hookStart.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'ClaudeTaskHook.ps1')+'" -LoopTestPipe '+$PreviewClaudeLoopPipe
   $hookStart.UseShellExecute=$false;$hookStart.CreateNoWindow=$true
   $hookStart.RedirectStandardInput=$true;$hookStart.RedirectStandardOutput=$true
   $hookStart.EnvironmentVariables['LOCALAPPDATA']=$previewDataPath
   $hookStart.EnvironmentVariables['AI_TASK_MONITOR_AUDIT']='1'
   $hook=[Diagnostics.Process]::Start($hookStart)
   try{
    $hook.StandardInput.WriteLine(($testEvent|ConvertTo-Json -Compress -Depth 4));$hook.StandardInput.Close()
    if(-not $hook.WaitForExit(5000) -or $hook.ExitCode -ne 0 -or $hook.StandardOutput.ReadToEnd()){throw 'The synthetic Claude hook failed.'}
   }finally{$hook.Dispose()}
   $watch=[Diagnostics.Stopwatch]::StartNew()
   do{
    Sync-ClaudeLoopChannel
    if($script:claudeLoopStates.ContainsKey($session)){
     $state=$script:claudeLoopStates[$session]
     if(($kind -eq 'start' -and $state.InFlight.ContainsKey($testEvent.tool_use_id)) -or ($kind -eq 'failed' -and $state.Times.Count -eq $number)){return}
    }
    Start-Sleep -Milliseconds 15
   }while($watch.ElapsedMilliseconds -lt 2000)
   throw 'A synthetic Claude loop event was not applied.'
  }
  for($number=1;$number -le 5;$number++){
   Send-PreviewClaudeLoop 'preview-1' $number 'start'
   Send-PreviewClaudeLoop 'preview-1' $number 'failed'
  }
  if(-not $script:claudeLoopStates['preview-1'].Warning){throw 'The Claude warning did not reach the task.'}
  if($PreviewActiveTasks -ge 3){
   for($number=1;$number -le 3;$number++){
    Send-PreviewClaudeLoop 'preview-2' $number 'start'
    Send-PreviewClaudeLoop 'preview-2' $number 'failed'
   }
   if($script:claudeLoopStates['preview-2'].Warning){throw 'A separate Claude session received the warning.'}
  }
  $script:fingerprint='';Update-View;$window.UpdateLayout()
  $claudeTask=@($script:lastTasks|Where-Object {$_.Provider -eq 'claude' -and $_.Id -eq 'preview-1'})
  if($claudeTask.Count -ne 1 -or $null -eq (Get-LoopWarning $claudeTask[0])){throw 'The Claude task did not expose its warning.'}
  $realId=$claudeTask[0].PSObject.Copy();$realId.Id='claude:preview-1'
  if($null -eq (Get-LoopWarning $realId)){throw 'The real Claude task identifier did not expose its warning.'}
  $inactive=$claudeTask[0].PSObject.Copy();$inactive.Active=$false
  if($null -ne (Get-LoopWarning $inactive)){throw 'An unconfirmed task exposed a live warning.'}
  function Find-ClaudeLoopDismiss($parent){
   if($parent -is [Windows.Controls.Button] -and $parent.IsVisible -and [Windows.Automation.AutomationProperties]::GetName($parent).StartsWith('Скрыть предупреждение о возможном цикле')){return $parent}
   for($index=0;$index -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);$index++){
    $match=Find-ClaudeLoopDismiss ([Windows.Media.VisualTreeHelper]::GetChild($parent,$index))
    if($null -ne $match){return $match}
   }
   return $null
  }
  $dismiss=Find-ClaudeLoopDismiss $window
  if($null -eq $dismiss){throw 'The Claude warning action is not visible.'}
  $dismiss.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if(-not $script:claudeLoopStates['preview-1'].Dismissed -or $null -ne (Get-LoopWarning $claudeTask[0])){throw 'The Claude warning did not dismiss.'}
  $script:claudeLoopStates['preview-1'].Dismissed=$false;$script:fingerprint='';Update-View;$window.UpdateLayout()
  Write-Output 'Claude loop UI: warning, session isolation and dismissal verified.'
 }
 if($PreviewJournalRecoveryUiTest){
  Show-SettingsView
  Reveal-JournalSettings
  $window.UpdateLayout()
  if($null -ne $script:diagnosticRuntime -or -not $journalClearButton.IsEnabled){throw "A failed journal must leave the confirmed-clear action available."}
  if($JournalRecoverySnapshotFile){
   $recoveryWidth=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth));$recoveryHeight=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
   $recoveryBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($recoveryWidth,$recoveryHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
   $recoveryBitmap.Render($window)
   $recoveryEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
   $recoveryEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($recoveryBitmap))
   $recoveryStream=[IO.File]::Create($JournalRecoverySnapshotFile)
   try{$recoveryEncoder.Save($recoveryStream)}finally{$recoveryStream.Dispose()}
  }
  $journalClearButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($journalClearConfirmation.Visibility -ne "Visible"){throw "Journal clearing must require confirmation."}
  $journalConfirmClearButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($null -eq $script:diagnosticRuntime -or $script:diagnosticError -or $script:journalUiError){throw "Journal access did not recover after confirmed clearing."}
  Show-TasksView
  Write-Output "Journal recovery UI: confirmation and restored access verified."
 }
 if($PreviewLoopUiTest){
  if($PreviewActiveTasks -lt 1 -or -not $PreviewLoopWarning -or -not $DiagnosticDirectory -or $null -eq $script:diagnosticRuntime){throw "Loop UI tests require synthetic tasks and an isolated diagnostic directory."}
  function Find-VisibleLoopDismiss($parent){
   if($parent -is [Windows.Controls.Button] -and $parent.IsVisible -and [Windows.Automation.AutomationProperties]::GetName($parent).StartsWith("Скрыть предупреждение о возможном цикле")){return $parent}
   for($childIndex=0;$childIndex -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);$childIndex++){
    $match=Find-VisibleLoopDismiss ([Windows.Media.VisualTreeHelper]::GetChild($parent,$childIndex))
    if($null -ne $match){return $match}
   }
   return $null
  }
  $dismiss=Find-VisibleLoopDismiss $window
  if($null -eq $dismiss){throw "Visible loop warning action not found."}
  $dismiss.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if(-not $script:previewLoopDismissed -or $null -ne (Get-LoopWarning $script:lastTasks[0])){throw "Dismissing the loop warning did not update the task view."}
  $script:previewLoopDismissed=$false; $script:fingerprint=""; Update-View
  Show-SettingsView
  $loopThresholdCombo.SelectedIndex=0; $loopWindowCombo.SelectedIndex=0
  $saved=Get-DiagnosticSettings -Directory $script:diagnosticDirectory
  if($saved.LoopThreshold -ne 3 -or $saved.LoopWindowMinutes -ne 1){throw "Loop warning settings did not persist."}
  $loopThresholdCombo.SelectedIndex=7; $loopWindowCombo.SelectedIndex=29
  $saved=Get-DiagnosticSettings -Directory $script:diagnosticDirectory
  if($saved.LoopThreshold -ne 10 -or $saved.LoopWindowMinutes -ne 30){throw "Loop warning maximum settings did not persist."}
  $loopThresholdCombo.SelectedIndex=2; $loopWindowCombo.SelectedIndex=9
  Show-TasksView
  if($CompactMode){Set-CompactMode $true}
  $window.UpdateLayout()
  Write-Output "Loop warning UI: dismissal and configurable limits passed."
 }
 $width=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth)); $height=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
 $bitmap.Render($window)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
 $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create($SnapshotFile)
 try {$encoder.Save($stream)} finally {$stream.Dispose()}
 if($HintSnapshotFile -and $null -ne $script:previewHintTarget -and $script:previewHintTarget.ToolTip){
  $hint=$script:previewHintTarget.ToolTip
  $hint.StaysOpen=$true
  $hint.IsOpen=$true
  $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
  Start-Sleep -Milliseconds 180
  $frameOrigin=$window.PointToScreen([Windows.Point]::new(0,0))
  $hintOrigin=$hint.PointToScreen([Windows.Point]::new(0,0))
  $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($window)
  $frameRight=$frameOrigin.X+($window.ActualWidth*$dpi.DpiScaleX)
  $frameBottom=$frameOrigin.Y+($window.ActualHeight*$dpi.DpiScaleY)
  $hintRight=$hintOrigin.X+($hint.ActualWidth*$dpi.DpiScaleX)
  $hintBottom=$hintOrigin.Y+($hint.ActualHeight*$dpi.DpiScaleY)
  $captureLeft=[int][Math]::Floor([Math]::Min($frameOrigin.X,$hintOrigin.X)-12)
  $captureTop=[int][Math]::Floor([Math]::Min($frameOrigin.Y,$hintOrigin.Y)-12)
  $captureRight=[int][Math]::Ceiling([Math]::Max($frameRight,$hintRight)+12)
  $captureBottom=[int][Math]::Ceiling([Math]::Max($frameBottom,$hintBottom)+12)
  $captureWidth=[Math]::Max(1,$captureRight-$captureLeft)
  $captureHeight=[Math]::Max(1,$captureBottom-$captureTop)
  $hintPixelWidth=[Math]::Max(1,[int][Math]::Ceiling($hint.ActualWidth*$dpi.DpiScaleX))
  $hintPixelHeight=[Math]::Max(1,[int][Math]::Ceiling($hint.ActualHeight*$dpi.DpiScaleY))
  $hintRender=[Windows.Media.Imaging.RenderTargetBitmap]::new($hintPixelWidth,$hintPixelHeight,96*$dpi.DpiScaleX,96*$dpi.DpiScaleY,[Windows.Media.PixelFormats]::Pbgra32)
  $hintRender.Render($hint)
  if($HintRawSnapshotFile){
   $rawEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
   $rawEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($hintRender))
   $rawStream=[IO.File]::Create($HintRawSnapshotFile)
   try{$rawEncoder.Save($rawStream)}finally{$rawStream.Dispose()}
  }
  $canvas=New-Object Windows.Media.DrawingVisual
  $drawing=$canvas.RenderOpen()
  try{
   $drawing.DrawRectangle((Brush "#111111"),$null,[Windows.Rect]::new(0,0,$captureWidth,$captureHeight))
   $drawing.DrawImage($bitmap,[Windows.Rect]::new($frameOrigin.X-$captureLeft,$frameOrigin.Y-$captureTop,$frameRight-$frameOrigin.X,$frameBottom-$frameOrigin.Y))
   $drawing.DrawImage($hintRender,[Windows.Rect]::new($hintOrigin.X-$captureLeft,$hintOrigin.Y-$captureTop,$hintRight-$hintOrigin.X,$hintBottom-$hintOrigin.Y))
  }finally{$drawing.Close()}
  $capture=[Windows.Media.Imaging.RenderTargetBitmap]::new($captureWidth,$captureHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
  $capture.Render($canvas)
  $captureEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
  $captureEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($capture))
  $memory=New-Object IO.MemoryStream
  try{
   $captureEncoder.Save($memory);$memory.Position=0
   $hintBitmap=[Drawing.Bitmap]::new($memory)
   $hintGraphics=[Drawing.Graphics]::FromImage($hintBitmap)
   try{
    $pointer=$script:previewHintTarget.PointToScreen([Windows.Point]::new($script:previewHintTarget.ActualWidth/2,$script:previewHintTarget.ActualHeight/2))
    $cursorSize=[Windows.Forms.SystemInformation]::CursorSize
    [Windows.Forms.Cursors]::Arrow.Draw($hintGraphics,[Drawing.Rectangle]::new([int]($pointer.X-$captureLeft),[int]($pointer.Y-$captureTop),$cursorSize.Width,$cursorSize.Height))
    $hintBitmap.Save($HintSnapshotFile,[Drawing.Imaging.ImageFormat]::Png)
   }finally{$hintGraphics.Dispose();$hintBitmap.Dispose()}
  }finally{$memory.Dispose();$hint.IsOpen=$false}
 }
 if($SettingsSnapshotFile -or $JournalDropdownSnapshotFile){
  Show-SettingsView
  if($PreviewSettingsBackHover){$settingsBackButton.Background=Brush $script:palette.Hover}
  $window.UpdateLayout()
  if($PreviewJournalClearConfirmation){$journalClearConfirmation.Visibility="Visible";Update-JournalSettings;$window.UpdateLayout()}
  if($PreviewJournalSettings -or $PreviewJournalClearConfirmation -or $JournalDropdownSnapshotFile){
   Reveal-JournalSettings
  }
  if($PreviewLoopSettings){
   $point=$loopSettingsSection.TranslatePoint([Windows.Point]::new(0,0),$settingsScroll)
   $settingsScroll.ScrollToVerticalOffset([Math]::Max(0,$settingsScroll.VerticalOffset+$point.Y-90))
   $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$window.UpdateLayout()
  }
  if($PreviewSettingsEnd){$settingsScroll.ScrollToEnd();$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$window.UpdateLayout()}
  if($SettingsSnapshotFile){
   $settingsWidth=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth)); $settingsHeight=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
   $settingsBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($settingsWidth,$settingsHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32); $settingsBitmap.Render($window)
   $settingsEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder; $settingsEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($settingsBitmap)); $settingsStream=[IO.File]::Create($SettingsSnapshotFile)
   try{$settingsEncoder.Save($settingsStream)}finally{$settingsStream.Dispose()}
  }
  if($JournalDropdownSnapshotFile){
   $journalDaysCombo.IsDropDownOpen=$true;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
   $popup=$journalDaysCombo.Template.FindName("PART_Popup",$journalDaysCombo)
   if($null -eq $popup -or $null -eq $popup.Child){throw "Journal dropdown was not rendered."}
   $popup.Child.UpdateLayout();$popupWidth=[Math]::Max(1,[int][Math]::Ceiling($popup.Child.RenderSize.Width));$popupHeight=[Math]::Max(1,[int][Math]::Ceiling($popup.Child.RenderSize.Height))
   $popupBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($popupWidth,$popupHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$popupBitmap.Render($popup.Child)
   $popupEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$popupEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($popupBitmap));$popupStream=[IO.File]::Create($JournalDropdownSnapshotFile)
   try{$popupEncoder.Save($popupStream)}finally{$popupStream.Dispose();$journalDaysCombo.IsDropDownOpen=$false}
  }
 }
 if($JournalSnapshotFile){
  Show-JournalView
  if($PreviewJournalFilterTask -and $journalTaskFilter.Items.Count -gt 1){$journalTaskFilter.SelectedIndex=1;$script:journalFingerprint="";Render-Journal}
  $window.UpdateLayout()
  $journalWidth=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth));$journalHeight=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
  $journalBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($journalWidth,$journalHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$journalBitmap.Render($window)
  $journalEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$journalEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($journalBitmap));$journalStream=[IO.File]::Create($JournalSnapshotFile)
  try{$journalEncoder.Save($journalStream)}finally{$journalStream.Dispose()}
  if($JournalFilterDropdownSnapshotFile){
   $journalTaskFilter.IsDropDownOpen=$true;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
   $popup=$journalTaskFilter.Template.FindName("PART_Popup",$journalTaskFilter)
   if($null -eq $popup -or $null -eq $popup.Child){throw "Journal task filter was not rendered."}
   $popup.Child.UpdateLayout();$popupWidth=[Math]::Max(1,[int][Math]::Ceiling($popup.Child.RenderSize.Width));$popupHeight=[Math]::Max(1,[int][Math]::Ceiling($popup.Child.RenderSize.Height))
   $popupBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($popupWidth,$popupHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$popupBitmap.Render($popup.Child)
   $popupEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$popupEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($popupBitmap));$popupStream=[IO.File]::Create($JournalFilterDropdownSnapshotFile)
   try{$popupEncoder.Save($popupStream)}finally{$popupStream.Dispose();$journalTaskFilter.IsDropDownOpen=$false}
  }
 }
 $window.Close()
} else {
 $window.ShowDialog()|Out-Null
}

