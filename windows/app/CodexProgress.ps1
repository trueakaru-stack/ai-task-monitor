param(
 [string]$ProgressFile = "",
 [string]$SnapshotFile = "",
 [switch]$CompactMode,
 [ValidateSet("","system","dark","light")][string]$ThemeOverride = "",
 [string]$SettingsSnapshotFile = "",
 [switch]$PreviewSettingsBackHover,
 [ValidateRange(-1,3)][int]$PreviewActiveTasks = -1,
 [ValidateSet("all","codex","claude")][string]$PreviewProvider = "all",
 [string]$ClaudeEventFile = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$sessionIndex = Join-Path $codexHome "session_index.jsonl"
$sessionsDirectory = Join-Path $codexHome "sessions"
$lockDirectory = Join-Path $codexHome "thread-writer-locks"
$claudeEventPath = if($ClaudeEventFile){$ClaudeEventFile}else{Join-Path (Join-Path $env:LOCALAPPDATA "CodexTaskProgress") "claude-events.jsonl"}
$script:fingerprint = ""
$script:sessionFiles = @{}
$script:sessionDates = @{}
$script:planCache = @{}
$script:lifecycleState = @{}
$script:allRollouts = $null
$script:lastTasks = @()
$script:compactTaskId = ""
$script:settingsPath = Join-Path (Join-Path $env:LOCALAPPDATA "CodexTaskProgress") "settings.json"
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
  <Style TargetType="Button">
   <Setter Property="FontFamily" Value="Segoe UI Variable Text"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
      <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonSurface" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="ButtonSurface" Property="BorderThickness" Value="1"/></Trigger>
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
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="OptionSurface" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="OptionSurface" Property="BorderThickness" Value="1"/></Trigger>
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
    <ControlTemplate.Triggers>
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="FooterSurface" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="FooterSurface" Property="BorderThickness" Value="1"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="CompactDotStyle" TargetType="Button">
   <Setter Property="Width" Value="18"/><Setter Property="Height" Value="18"/><Setter Property="Padding" Value="0"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="CompactDotSurface" Background="Transparent" BorderBrush="Transparent" BorderThickness="0" CornerRadius="7"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="CompactDotSurface" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="CompactDotSurface" Property="BorderThickness" Value="1"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="SourceActionStyle" TargetType="Button">
   <Setter Property="Height" Value="28"/><Setter Property="Padding" Value="10,0"/><Setter Property="Background" Value="{DynamicResource SurfaceHover}"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="SourceActionSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="SourceActionSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="SourceActionSurface" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="SourceActionSurface" Property="BorderThickness" Value="1"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ProviderTabStyle" TargetType="Button">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="13,0"/><Setter Property="Margin" Value="0,0,4,0"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="TabSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="8" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="TabSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger>
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="TabSurface" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="TabSurface" Property="BorderThickness" Value="1"/></Trigger>
    </ControlTemplate.Triggers>
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
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="RefreshSurface" Property="BorderBrush" Value="#8C8C8C"/></Trigger>
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
       <TextBlock x:Name="SummaryText" Text="Поиск задач Codex" Margin="0,4,0,0" FontSize="12.5" Foreground="{DynamicResource TextSecondary}"/>
       <Border x:Name="ProviderTabsHost" Visibility="Collapsed" Margin="0,13,0,0" Padding="3" HorizontalAlignment="Left" Background="{DynamicResource SurfaceRaised}" CornerRadius="10">
        <StackPanel x:Name="ProviderTabsPanel" Orientation="Horizontal"/>
       </Border>
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
     <StackPanel VerticalAlignment="Center">
      <TextBlock Text="AI task monitor" FontFamily="Segoe UI Variable Display Semibold" FontSize="14" Foreground="{DynamicResource TextPrimary}"/>
     </StackPanel>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="ExpandButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Развернуть">
       <Path Data="M 4,13 L 10,7 L 16,13" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="CompactTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
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

    <ScrollViewer Grid.Row="1" Margin="20,10,20,20" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
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
      <TextBlock Text="О приложении" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <TextBlock Text="AI task monitor · версия 0.2.0 alpha" Margin="0,12,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource TextPrimary}"/>
      <TextBlock Margin="0,8,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Показывает активные задачи Codex и Claude Code, текущее действие и прогресс, когда его можно определить. Точный процент выводится числом, приблизительный — со знаком ≈; без надёжной оценки показывается только активность."/>
      <TextBlock Margin="0,12,0,8" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Данные обрабатываются локально. Для Codex приложение читает локальные данные задач; для Claude Code после подключения используются локальные hooks. Вход в аккаунт, токены и права администратора не требуются."/>
     </StackPanel>
    </ScrollViewer>
   </Grid>

   <Path x:Name="WindowOutline" Stroke="{DynamicResource Border}" StrokeThickness="1" IsHitTestVisible="False" Panel.ZIndex="20"/>
   </Grid>
  </Border>
 </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$windowFrame = $window.FindName("WindowFrame")
$windowOutline = $window.FindName("WindowOutline")
$expandedView = $window.FindName("ExpandedView")
$compactView = $window.FindName("CompactView")
$settingsView = $window.FindName("SettingsView")
$tasksPanel = $window.FindName("TasksPanel")
$tasksScroll = $window.FindName("TasksScroll")
$tasksScrollBar = $window.FindName("TasksScrollBar")
$summaryText = $window.FindName("SummaryText")
$providerTabsHost = $window.FindName("ProviderTabsHost")
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
$systemThemeButton = $window.FindName("SystemThemeButton")
$darkThemeButton = $window.FindName("DarkThemeButton")
$lightThemeButton = $window.FindName("LightThemeButton")
$codexSourceStatus = $window.FindName("CodexSourceStatus")
$claudeSourceStatus = $window.FindName("ClaudeSourceStatus")
$claudeSourceAction = $window.FindName("ClaudeSourceAction")
$script:isCompact = $false
$script:showingSettings = $false
$script:expandedBounds = $null
$script:selectedProvider = $PreviewProvider
$tasksScroll.Add_ScrollChanged({
 $tasksScrollBar.Maximum=$tasksScroll.ScrollableHeight
 $tasksScrollBar.ViewportSize=$tasksScroll.ViewportHeight
 $tasksScrollBar.Value=$tasksScroll.VerticalOffset
 $tasksScrollBar.Visibility=$(if($tasksScroll.ScrollableHeight -gt 0){"Visible"}else{"Hidden"})
})
$tasksScrollBar.Add_ValueChanged({if([Math]::Abs($tasksScroll.VerticalOffset-$tasksScrollBar.Value) -gt 0.5){$tasksScroll.ScrollToVerticalOffset($tasksScrollBar.Value)}})

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

function Claude-HookConnected {
 $path=Join-Path (Join-Path $env:USERPROFILE ".claude") "settings.json"
 if(-not (Test-Path -LiteralPath $path)){return $false}
 $expected='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot "ClaudeTaskHook.ps1")+'"'
 try{
  $settings=Get-Content -Raw -Encoding UTF8 -LiteralPath $path|ConvertFrom-Json
  $hooksProperty=$settings.PSObject.Properties["hooks"]
  if($null -eq $hooksProperty){return $false}
  foreach($eventProperty in $hooksProperty.Value.PSObject.Properties){
   foreach($entry in @($eventProperty.Value)){
    if($null -eq $entry){continue}
    $entryHooks=$entry.PSObject.Properties["hooks"]
    if($null -eq $entryHooks){continue}
    foreach($hook in @($entryHooks.Value)){
     if([string]::Equals(([string]$hook.command).Trim(),$expected,[StringComparison]::OrdinalIgnoreCase)){return $true}
    }
   }
  }
 }catch{}
 return $false
}

function Update-SourceSettings {
 $codexSourceStatus.Text=$(if(Test-Path -LiteralPath $sessionIndex){"Подключён"}else{"Не найден"})
 $claudeHome=Join-Path $env:USERPROFILE ".claude"
 if(-not (Test-Path -LiteralPath $claudeHome)){
  $claudeSourceStatus.Text="Не найден"
  $claudeSourceAction.Visibility="Visible";$claudeSourceAction.IsEnabled=$false;$claudeSourceAction.Content="Подключить";$claudeSourceAction.Tag=""
  $claudeSourceAction.ToolTip="Claude Code не найден на этом компьютере"
  [Windows.Automation.AutomationProperties]::SetName($claudeSourceAction,"Подключить Claude Code. Claude Code не найден")
  return
 }
 $connected=Claude-HookConnected
 $claudeSourceStatus.Text=$(if($connected){"Подключён"}else{"Не подключён"})
 $claudeSourceAction.Visibility="Visible";$claudeSourceAction.IsEnabled=$true;$claudeSourceAction.ToolTip=$null
 $claudeSourceAction.Content=$(if($connected){"Отключить"}else{"Подключить"})
 $claudeSourceAction.Tag=$(if($connected){"Remove"}else{"Install"})
 [Windows.Automation.AutomationProperties]::SetName($claudeSourceAction,$claudeSourceAction.Content+" Claude Code")
}

function Apply-Theme([string]$mode,[bool]$persist) {
 $resolved=if($mode -eq "system"){Windows-Theme}else{$mode}
 $script:themeMode=$mode; $script:resolvedTheme=$resolved
 if($resolved -eq "light"){
  $script:palette=@{Surface="#F6F6F6";Raised="#FFFFFF";Border="#D7D7D7";Primary="#1F1F1F";Secondary="#575757";Muted="#707070";Hover="#EAEAEA";Pressed="#DFDFDF";Divider="#E2E2E2";Track="#D8D8D8";Scroll="#B3B3B3";ScrollHover="#8F8F8F";CardBorder="#DADADA";Activity="#707070";Done="#707070";Pending="#4F4F4F"}
 }else{
  $script:palette=@{Surface="#202020";Raised="#282828";Border="#414141";Primary="#F1F1F1";Secondary="#ACACAC";Muted="#989898";Hover="#333333";Pressed="#3B3B3B";Divider="#343434";Track="#3A3A3A";Scroll="#555555";ScrollHover="#747474";CardBorder="#474747";Activity="#989898";Done="#989898";Pending="#B8B8B8"}
 }
 $resources=@{Surface=$script:palette.Surface;SurfaceRaised=$script:palette.Raised;Border=$script:palette.Border;TextPrimary=$script:palette.Primary;TextSecondary=$script:palette.Secondary;TextMuted=$script:palette.Muted;SurfaceHover=$script:palette.Hover;SurfacePressed=$script:palette.Pressed;Divider=$script:palette.Divider;Track=$script:palette.Track;ScrollThumbBrush=$script:palette.Scroll;ScrollThumbHoverBrush=$script:palette.ScrollHover}
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

function Lock-Held([string]$path) {
 if (-not (Test-Path -LiteralPath $path)) { return $false }
 try { $stream = [IO.File]::Open($path, "Open", "ReadWrite", "None"); $stream.Dispose(); return $false } catch { return $true }
}

function Thread-Running([string]$id) {
 $path = Session-File $id
 if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
 try {
  $file = Get-Item -LiteralPath $path
  $cached = if ($script:lifecycleState.ContainsKey($path)) { $script:lifecycleState[$path] } else { $null }
  if ($null -ne $cached -and [long]$cached.Length -eq [long]$file.Length) { return [bool]$cached.Running }

  $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
   $bytes=[Math]::Min([long]2097152,$stream.Length)
   [void]$stream.Seek(-$bytes,[IO.SeekOrigin]::End)
   $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
   try { $tail=$reader.ReadToEnd() } finally { $reader.Dispose() }
  } finally { $stream.Dispose() }
  $matches=[regex]::Matches($tail,'"type":"event_msg","payload":\{"type":"(?<state>task_started|task_complete)"')
  if($matches.Count -gt 0){$running=($matches[$matches.Count-1].Groups["state"].Value -eq "task_started") -and (([DateTime]::UtcNow-$file.LastWriteTimeUtc).TotalMinutes -lt 120)}
  else{$running=(Lock-Held (Join-Path $lockDirectory "$id.lock")) -and (([DateTime]::UtcNow-$file.LastWriteTimeUtc).TotalSeconds -lt 15)}
  $script:lifecycleState[$path] = [PSCustomObject]@{ Length=[long]$file.Length; Running=$running }
  return $running
 } catch { return $false }
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
   if ($null -eq $payload -or [string](Prop $payload "type" "") -ne "custom_tool_call") { continue }
   $input = [string](Prop $payload "input" "")
   if (-not $input) { continue }
   $matches = [regex]::Matches($input, 'step\s*:\s*"(?<step>(?:\\.|[^"\\])*)"\s*,\s*status\s*:\s*"(?<status>completed|in_progress|pending)"')
   if ($matches.Count -eq 0) { continue }
   $candidate = New-Object Collections.Generic.List[object]
   foreach ($match in $matches) {
    $state = switch ($match.Groups["status"].Value) { "completed" { "done" } "in_progress" { "active" } default { "pending" } }
    $label = [regex]::Unescape($match.Groups["step"].Value)
    $candidate.Add([PSCustomObject]@{ title=$label; status=$state })
   }
   $latest = @($candidate)
  }
 } catch {}
 $script:planCache.Clear()
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
 if (-not (Test-Path -LiteralPath $sessionIndex)) { return @() }
 $sessionMap = @{}
 foreach ($line in Get-Content -LiteralPath $sessionIndex -Encoding UTF8 -Tail 50) {
  if (-not $line) { continue }
  try {
   $session = $line | ConvertFrom-Json
   $sessionMap[[string]$session.id] = $session
   $updated = [DateTime]$session.updated_at
   $yearFolder = Join-Path $sessionsDirectory ([string]$updated.Year)
   $monthFolder = Join-Path $yearFolder $updated.Month.ToString("00")
   $script:sessionDates[[string]$session.id] = Join-Path $monthFolder $updated.Day.ToString("00")
  } catch {}
 }
 $sessions = @($sessionMap.Values)
 $manual = Manual-Tasks $sessions
 $items = New-Object Collections.Generic.List[object]
 foreach ($session in $sessions) {
  $id = [string]$session.id; $title = [string]$session.thread_name
  if($title -eq "Guardian review"){continue}
  $eventActive = Thread-Running $id
  $override = if ($manual.ContainsKey($id)) { $manual[$id] } elseif ($manual.ContainsKey("title:$title")) { $manual["title:$title"] } else { $null }
  $paused = $false; $steps = @(); $source = "Оценка активности"
  if ($null -ne $override) {
   $title = [string](Prop $override "title" $title)
   $paused = [bool](Prop $override "paused" $false)
   $steps = @(Prop $override "steps" @())
   if ($steps.Count -gt 0) { $source = "План задачи" }
  }
  if ($steps.Count -eq 0 -and $eventActive) {
   $steps = @(Codex-Plan $id)
   if ($steps.Count -gt 0) { $source = "План Codex" }
  }
  $running = $eventActive -and -not $paused
  $status = if ($paused) { "На паузе" } elseif ($running) { "В работе" } else { "Ожидает" }
  $progress=$null; $progressKind="none"
  if($steps.Count -gt 0){$progress=Plan-Progress $steps 0;$progressKind="exact"}
  if ($null -ne $override) {
   $value = Prop $override "progress"
   if ($null -ne $value) {
    $progress = [Math]::Max(0, [Math]::Min(100, [int]$value))
    $progressKind=[string](Prop $override "progressKind" "approximate")
    if($progressKind -notin @("exact","approximate")){$progressKind="approximate"}
   }
   $status = [string](Prop $override "status" $status)
  }
  if ($steps.Count -gt 0) {
   $doneCount = @($steps | Where-Object { [string](Prop $_ "status" "pending") -eq "done" }).Count
   if ($doneCount -eq $steps.Count) { $progress = 100; $progressKind="exact" }
   elseif ($null -ne $progress -and $progress -ge 100) { $progress = 99 }
  }
  $path = Session-File $id
  $updated = if ($path) { (Get-Item -LiteralPath $path).LastWriteTime } else { [DateTime]::MinValue }
  $activity = if ($running) { Codex-Activity $id } else { "" }
  $items.Add([PSCustomObject]@{ Id=$id; Title=$title; Activity=$activity; Active=$running; Paused=$paused; Progress=$progress; ProgressKind=$progressKind; Provider="codex"; ProviderName="Codex"; Status=$status; Updated=$updated; Steps=$steps; Source=$source })
 }
 $runningItems = @($items | Where-Object Active | Sort-Object Updated -Descending)
 $trackedItems = @($items | Where-Object { -not $_.Active -and ($manual.ContainsKey($_.Id) -or $_.Paused) } | Sort-Object Updated -Descending)
 return @($runningItems + $trackedItems)
}

function Claude-Tasks {
 if(-not (Test-Path -LiteralPath $claudeEventPath)){return @()}
 $sessions=[ordered]@{}
 try{$tail=Read-TailText $claudeEventPath 4194304}catch{return @()}
 foreach($line in ($tail -split "`r?`n")){
  if(-not $line){continue}
  try{$event=$line|ConvertFrom-Json}catch{continue}
  $id=[string](Prop $event "session_id" "")
  if(-not $id){continue}
  if(-not $sessions.Contains($id)){
   $sessions[$id]=[PSCustomObject]@{Id=$id;Title="";Activity="";Active=$false;Updated=[DateTime]::MinValue;Cwd="";Steps=[ordered]@{}}
  }
  $state=$sessions[$id]
  try{$state.Updated=[DateTime](Prop $event "timestamp" [DateTime]::UtcNow)}catch{$state.Updated=[DateTime]::UtcNow}
  $cwd=[string](Prop $event "cwd" "");if($cwd){$state.Cwd=$cwd}
  $eventName=[string](Prop $event "event" "")
  $toolName=[string](Prop $event "tool_name" "")
  $eventSubject=[string](Prop $event "task_subject" "")
  $activity=switch($eventName){
   "UserPromptSubmit" {"Обрабатывает новый запрос"}
   "PreToolUse" {if($toolName){"Выполняет: $toolName"}else{"Выполняет действие"}}
   "PostToolUse" {if($toolName){"Завершено: $toolName"}else{"Действие завершено"}}
   "PostToolUseFailure" {if($toolName){"Ошибка: $toolName"}else{"Ошибка действия"}}
   "TaskCreated" {if($eventSubject){"Добавлен этап: $eventSubject"}else{"Добавлен этап"}}
   "TaskCompleted" {if($eventSubject){"Завершён этап: $eventSubject"}else{"Этап завершён"}}
   "SubagentStart" {"Запущен дополнительный агент"}
   "SubagentStop" {"Дополнительный агент завершён"}
   default {[string](Prop $event "activity" "")}
  }
  if($activity){$state.Activity=$activity}
  $state.Active=[bool](Prop $event "active" $state.Active)
  if($eventName -eq "UserPromptSubmit"){
   $prompt=[regex]::Replace(([string](Prop $event "prompt" "")).Trim(),'\s+',' ')
   if($prompt){$state.Title=if($prompt.Length -gt 120){$prompt.Substring(0,119)+"…"}else{$prompt}}
  }
  $taskId=[string](Prop $event "task_id" "")
  $subject=[string](Prop $event "task_subject" "")
  if($eventName -eq "TaskCreated" -and $taskId){$state.Steps[$taskId]=[PSCustomObject]@{title=$(if($subject){$subject}else{"Этап $taskId"});status="pending"}}
  if($taskId -and -not $state.Steps.Contains($taskId)){$state.Steps[$taskId]=[PSCustomObject]@{title=$(if($subject){$subject}else{"Этап $taskId"});status="pending"}}
  if($taskId){
   $status=[string](Prop $event "task_status" "")
   if($eventName -eq "TaskCompleted" -or $status -eq "completed"){$state.Steps[$taskId].status="done"}
   elseif($status -eq "in_progress"){$state.Steps[$taskId].status="active"}
   elseif($status -eq "pending"){$state.Steps[$taskId].status="pending"}
  }
 }
 $items=New-Object Collections.Generic.List[object]
 foreach($state in $sessions.Values){
  if(-not $state.Active -or ([DateTime]::UtcNow-$state.Updated.ToUniversalTime()).TotalMinutes -ge 120){continue}
  $steps=@($state.Steps.Values)
  $progress=$null;$kind="none"
  if($steps.Count -gt 0){$progress=Plan-Progress $steps 0;$kind="exact"}
  $title=[string]$state.Title
  if(-not $title){$title=if($state.Cwd){"Claude Code · "+[IO.Path]::GetFileName($state.Cwd.TrimEnd('\','/'))}else{"Claude Code"}}
  $items.Add([PSCustomObject]@{Id="claude:"+$state.Id;Title=$title;Activity=$state.Activity;Active=$true;Paused=$false;Progress=$progress;ProgressKind=$kind;Provider="claude";ProviderName="Claude Code";Status="В работе";Updated=$state.Updated.ToLocalTime();Steps=$steps;Source="Claude Code"})
 }
 return @($items|Sort-Object Updated -Descending)
}

function Text([string]$value, [double]$size, [string]$color, [string]$weight = "Normal") {
 $block = New-Object Windows.Controls.TextBlock
 $block.Text=$value; $block.FontFamily=New-Object Windows.Media.FontFamily("Segoe UI Variable Text"); $block.FontSize=$size
 $block.Foreground=Brush $color; $block.FontWeight=$weight; $block.TextWrapping="Wrap"; $block.LineHeight=$size*1.35
 return $block
}

function Progress-Label($task) {
 $kind=[string](Prop $task "ProgressKind" "none")
 $value=Prop $task "Progress"
 if($kind -eq "none" -or $null -eq $value){return ""}
 $prefix=if($kind -eq "approximate"){"≈ "}else{""}
 return $prefix+([int]$value).ToString()+"%"
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
  $label.Margin=New-Object Windows.Thickness(4,0,0,0); $label.TextWrapping="NoWrap"; $label.TextTrimming="CharacterEllipsis"; $label.ToolTip=$stepTitle; $label.VerticalAlignment="Center"; [Windows.Controls.Grid]::SetColumn($label,1)
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
 $card=New-Object Windows.Controls.Border; if($stepCount -gt 0){$card.Height=$(if($script:showProviderLabels){278}else{258})}; $card.Background=Brush $script:palette.Raised; $card.BorderBrush=Brush $(if($task.Active){$script:palette.CardBorder}else{$script:palette.Border}); $card.BorderThickness=New-Object Windows.Thickness(1); $card.CornerRadius=New-Object Windows.CornerRadius(8); $card.Padding=New-Object Windows.Thickness(16,15,16,14); $card.Margin=New-Object Windows.Thickness(0,0,0,12)
 $stack=New-Object Windows.Controls.StackPanel
 if($script:showProviderLabels){$providerLabel=Text ([string]$task.ProviderName) 11.5 $script:accentHex "SemiBold";$providerLabel.Margin=New-Object Windows.Thickness(0,0,0,3);$stack.Children.Add($providerLabel)|Out-Null}
 $header=New-Object Windows.Controls.Grid
 $c1=New-Object Windows.Controls.ColumnDefinition; $c1.Width=New-Object Windows.GridLength(1,"Star"); $c2=New-Object Windows.Controls.ColumnDefinition; $c2.Width=[Windows.GridLength]::Auto; $header.ColumnDefinitions.Add($c1); $header.ColumnDefinitions.Add($c2)
 $titleStack=New-Object Windows.Controls.StackPanel
 $title=Text $task.Title 16 $script:palette.Primary "SemiBold"; $title.Margin=New-Object Windows.Thickness(0,0,14,0); $title.Height=22; $title.MaxWidth=390; $title.HorizontalAlignment="Left"; $title.TextWrapping="NoWrap"; $title.TextTrimming="CharacterEllipsis"; $title.ToolTip=$task.Title; $titleStack.Children.Add($title)|Out-Null
 $activityText=[string]$task.Activity; $activity=Text $activityText 12 $script:palette.Activity; $activity.Margin=New-Object Windows.Thickness(0,5,14,0); $activity.Width=390; $activity.HorizontalAlignment="Left"; $activity.Height=34; $activity.MaxHeight=34; $activity.TextTrimming="CharacterEllipsis"; if($activityText){$activity.ToolTip=$activityText}; $titleStack.Children.Add($activity)|Out-Null
 $progressLabel=Progress-Label $task
 $percent=Text $progressLabel 16 $script:palette.Primary "SemiBold"; $percent.Height=22; $percent.VerticalAlignment="Top"; if($task.ProgressKind -eq "approximate"){$percent.ToolTip="Приблизительная оценка"}; [Windows.Controls.Grid]::SetColumn($percent,1)
 $header.Children.Add($titleStack)|Out-Null; $header.Children.Add($percent)|Out-Null; $stack.Children.Add($header)|Out-Null
 if($task.ProgressKind -ne "none" -and $null -ne $task.Progress){$bar=New-Object Windows.Controls.ProgressBar; $bar.Maximum=100; $bar.Value=$task.Progress; $bar.Margin=New-Object Windows.Thickness(0,14,0,0); $stack.Children.Add($bar)|Out-Null}
 Add-Steps $stack $task.Steps
 $metaText=$(if($script:showProviderLabels){"$stepCount этапов"}else{$task.ProviderName+" · "+$task.Source+" · "+$stepCount+" этапов"})
 if($task.Updated -ne [DateTime]::MinValue){$metaText += " · "+$task.Updated.ToString("HH:mm")}
 $meta=Text $metaText 11.5 $script:palette.Muted; $meta.Margin=New-Object Windows.Thickness(0,11,0,0); $stack.Children.Add($meta)|Out-Null
 $card.Child=$stack; $tasksPanel.Children.Add($card)|Out-Null
}

function Add-CompactTask($task) {
 if($script:showProviderLabels){$providerLabel=Text ([string]$task.ProviderName) 10.5 $script:accentHex "SemiBold";$providerLabel.Margin=New-Object Windows.Thickness(12,0,0,2);$compactTasksPanel.Children.Add($providerLabel)|Out-Null}
 $container=New-Object Windows.Controls.Grid; $container.Margin=New-Object Windows.Thickness(0,0,0,10)
 $r1=New-Object Windows.Controls.RowDefinition; $r1.Height=[Windows.GridLength]::Auto
 $r2=New-Object Windows.Controls.RowDefinition; $r2.Height=[Windows.GridLength]::Auto
 $r3=New-Object Windows.Controls.RowDefinition; $r3.Height=[Windows.GridLength]::Auto
 $container.RowDefinitions.Add($r1); $container.RowDefinitions.Add($r2); $container.RowDefinitions.Add($r3)

 $header=New-Object Windows.Controls.Grid
 $c1=New-Object Windows.Controls.ColumnDefinition; $c1.Width=New-Object Windows.GridLength(12)
 $c2=New-Object Windows.Controls.ColumnDefinition; $c2.Width=New-Object Windows.GridLength(1,"Star")
 $c3=New-Object Windows.Controls.ColumnDefinition; $c3.Width=[Windows.GridLength]::Auto
 $header.ColumnDefinitions.Add($c1); $header.ColumnDefinitions.Add($c2); $header.ColumnDefinitions.Add($c3)
 $dot=New-Object Windows.Controls.Border; $dot.Width=6; $dot.Height=6; $dot.CornerRadius=New-Object Windows.CornerRadius(3); $dot.Background=Brush $script:accentHex; $dot.VerticalAlignment="Center"; $dot.HorizontalAlignment="Left"
 $title=Text $task.Title 13.5 $script:palette.Primary "SemiBold"; $title.TextWrapping="NoWrap"; $title.TextTrimming="CharacterEllipsis"; $title.Margin=New-Object Windows.Thickness(0,0,10,0); [Windows.Automation.AutomationProperties]::SetName($title,[string]$task.Title)
 $progressLabel=Progress-Label $task
 $percent=Text $progressLabel 13.5 $script:palette.Primary "SemiBold"; $percent.VerticalAlignment="Center"; if($task.ProgressKind -eq "approximate"){$percent.ToolTip="Приблизительная оценка"}
 [Windows.Controls.Grid]::SetColumn($dot,0); [Windows.Controls.Grid]::SetColumn($title,1); [Windows.Controls.Grid]::SetColumn($percent,2)
 $header.Children.Add($dot)|Out-Null; $header.Children.Add($title)|Out-Null; $header.Children.Add($percent)|Out-Null
 [Windows.Controls.Grid]::SetRow($header,0); $container.Children.Add($header)|Out-Null

 $activityText=if($task.Activity){[string]$task.Activity}else{"Выполняется"}
 $activity=Text $activityText 11.5 $script:palette.Activity; $activity.TextWrapping="NoWrap"; $activity.TextTrimming="CharacterEllipsis"; $activity.Margin=New-Object Windows.Thickness(12,2,0,0); [Windows.Automation.AutomationProperties]::SetName($activity,$activityText)
 [Windows.Controls.Grid]::SetRow($activity,1); $container.Children.Add($activity)|Out-Null
 if($task.ProgressKind -ne "none" -and $null -ne $task.Progress){$bar=New-Object Windows.Controls.ProgressBar; $bar.Maximum=100; $bar.Value=$task.Progress; $bar.Height=2; $bar.Margin=New-Object Windows.Thickness(12,7,0,0); [Windows.Controls.Grid]::SetRow($bar,2); $container.Children.Add($bar)|Out-Null}
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

function Render-CompactTasks($tasks) {
 $compactTasksPanel.Children.Clear(); $compactDotsPanel.Children.Clear()
 $activeTasks=@($tasks|Where-Object Active)
 $visibleTasks=@($activeTasks|Select-Object -First 3)
 if($visibleTasks.Count -eq 0){
  $script:compactTaskId=""
  $compactEmpty=Text "Активных задач сейчас нет" 12.5 $script:palette.Activity
  $compactEmpty.Margin=New-Object Windows.Thickness(0,5,0,5)
  $compactTasksPanel.Children.Add($compactEmpty)|Out-Null
  $compactDotsPanel.Visibility="Collapsed"
 } else {
  $selected=@($visibleTasks|Where-Object {[string]$_.Id -eq $script:compactTaskId}|Select-Object -First 1)
  if($selected.Count -eq 0){$selected=@($visibleTasks[0]);$script:compactTaskId=[string]$visibleTasks[0].Id}
  Add-CompactTask $selected[0]
  if($visibleTasks.Count -gt 1){
   $compactDotsPanel.Visibility="Visible"
   foreach($task in $visibleTasks){Add-CompactDot $task ([string]$task.Id -eq $script:compactTaskId)}
  }else{$compactDotsPanel.Visibility="Collapsed"}
 }
 $hiddenCount=[Math]::Max(0,$activeTasks.Count-3)
 $compactMoreText.Visibility=$(if($hiddenCount -gt 0){"Visible"}else{"Collapsed"})
 $compactMoreText.Text=$(if($hiddenCount -gt 0){"Ещё $hiddenCount активных"}else{""})
 if($script:isCompact){$window.Height=Compact-Height $activeTasks.Count; Move-CompactWindow}
}

function Compact-Height([int]$activeCount) {
 if($activeCount -le 0){return 132}
 $dots=if($activeCount -gt 1){18}else{0}
 $more=if($activeCount -gt 3){20}else{0}
 $provider=if($script:showProviderLabels){18}else{0}
 return 162+$dots+$more+$provider
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
  $expandedView.Visibility="Collapsed"; $settingsView.Visibility="Collapsed"; $compactView.Visibility="Visible"
  $window.ResizeMode="NoResize"; $window.MinWidth=0; $window.MinHeight=0; $window.Width=390
  $activeCount=@($script:lastTasks|Where-Object Active).Count
  $window.Height=Compact-Height $activeCount
  $windowFrame.Margin=New-Object Windows.Thickness(16)
  $script:isCompact=$true; $window.Topmost=$true; Move-CompactWindow
 }else{
  $compactView.Visibility="Collapsed"; $expandedView.Visibility="Visible"
  $window.ResizeMode="CanResize"; $window.MinWidth=500; $window.MinHeight=500
  $windowFrame.Margin=New-Object Windows.Thickness(28)
  if($null -ne $script:expandedBounds){$window.Left=$script:expandedBounds.Left;$window.Top=$script:expandedBounds.Top;$window.Width=$script:expandedBounds.Width;$window.Height=$script:expandedBounds.Height}else{$window.Width=590;$window.Height=760;$window.WindowStartupLocation="CenterScreen"}
  $script:isCompact=$false; $window.Topmost=$true
 }
}

function Show-SettingsView {
 if($script:isCompact){Set-CompactMode $false}
 $expandedView.Visibility="Collapsed"
 $compactView.Visibility="Collapsed"
 $settingsView.Visibility="Visible"
 Update-SourceSettings
 $settingsBackButton.Focus()|Out-Null
}

function Show-TasksView {
 $settingsView.Visibility="Collapsed"
 $compactView.Visibility="Collapsed"
 $expandedView.Visibility="Visible"
 $settingsFooterButton.Focus()|Out-Null
}

function Minimize-ToTaskbar {
 $window.WindowState=[Windows.WindowState]::Minimized
}

function Restore-Window {
 $window.WindowState=[Windows.WindowState]::Normal
 $window.Show()
 $window.Activate()
}

function Filtered-Tasks($tasks){
 if($script:selectedProvider -eq "all"){return @($tasks)}
 return @($tasks|Where-Object {[string]$_.Provider -eq $script:selectedProvider})
}

function Add-ProviderTab([string]$id,[string]$label,[int]$count){
 $button=New-Object Windows.Controls.Button
 $button.Style=$window.Resources["ProviderTabStyle"]
 $button.Tag=$id
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
 $button.Content=$content
 [Windows.Automation.AutomationProperties]::SetName($button,"Показать задачи: $label, $count")
 if($selected){$button.Background=Brush $script:accentHex}
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
}

function Update-View {
 try {
  $allTasks=@(Codex-Tasks)+@(Claude-Tasks)
  if($PreviewActiveTasks -ge 0){
   $previewTitles=@("Создать индикатор прогресса задач","Проверить локальную CMS","Подготовить перенос проекта")
   $previewActivities=@("Проверяю компактный режим","Запускаю визуальную проверку","Собираю данные для переноса")
   $previewProgress=@(74,46,$null);$previewKinds=@("exact","approximate","none");$previewProviders=@("codex","claude","claude");$previewProviderNames=@("Codex","Claude Code","Claude Code")
   $allTasks=@()
   for($i=0;$i -lt $PreviewActiveTasks;$i++){
    $allTasks += [PSCustomObject]@{Id="preview-$i";Title=$previewTitles[$i];Activity=$previewActivities[$i];Active=$true;Paused=$false;Progress=$previewProgress[$i];ProgressKind=$previewKinds[$i];Provider=$previewProviders[$i];ProviderName=$previewProviderNames[$i];Status="В работе";Updated=[DateTime]::Now;Steps=@();Source="Предпросмотр"}
   }
  }
  Render-ProviderTabs $allTasks
  $tasks=@(Filtered-Tasks $allTasks)
  $script:lastTasks=$tasks
  $next=$script:selectedProvider+"|"+(($tasks|ForEach-Object{$stepState=(@($_.Steps)|ForEach-Object{"$(Prop $_ 'title' '')=$(Prop $_ 'status' '')"})-join","; "$($_.Id):$($_.Provider):$($_.Active):$($_.ProgressKind):$($_.Progress):$($_.Status):$($_.Activity):$stepState"})-join"|")
  if($next -ne $script:fingerprint){
   $script:fingerprint=$next; $tasksPanel.Children.Clear()
   foreach($task in $tasks){Add-Card $task}
   if($tasks.Count -eq 0){$empty=Text "Активных задач сейчас нет" 14 $script:palette.Secondary; $empty.Margin=New-Object Windows.Thickness(4,24,0,0); $tasksPanel.Children.Add($empty)|Out-Null}
   Render-CompactTasks $tasks
  }
  $activeCount=@($tasks|Where-Object Active).Count
  $summaryText.Text="$activeCount в работе · $($tasks.Count) показано · обновление каждые 2 сек"
 } catch {$summaryText.Text="Ошибка синхронизации"}
}

$window.Add_MouseLeftButtonDown({if($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed){$window.DragMove()}})
$pinButton.Add_Click({$window.Topmost=$true})
$minimizeButton.Add_Click({Set-CompactMode $true})
$expandButton.Add_Click({Set-CompactMode $false})
$taskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$compactTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$settingsTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$settingsFooterButton.Add_Click({Show-SettingsView})
$settingsBackButton.Add_Click({Show-TasksView})
$systemThemeButton.Add_Click({Apply-Theme "system" $true;Update-View})
$darkThemeButton.Add_Click({Apply-Theme "dark" $true;Update-View})
$lightThemeButton.Add_Click({Apply-Theme "light" $true;Update-View})
$claudeSourceAction.Add_Click({
 $mode=[string]$claudeSourceAction.Tag
 $configScript=Join-Path $PSScriptRoot "Configure-ClaudeIntegration.ps1"
 if(-not (Test-Path -LiteralPath $configScript)){$claudeSourceStatus.Text="Файл настройки не найден";return}
 try{
  $process=Start-Process powershell.exe -WindowStyle Hidden -Wait -PassThru -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"'+$configScript+'"'),"-Mode",$mode)
  if($process.ExitCode -ne 0){throw "Configuration failed"}
  Update-SourceSettings
 }catch{$claudeSourceStatus.Text="Ошибка подключения"}
})
$closeButton.Add_Click({$window.Close()})
$compactCloseButton.Add_Click({$window.Close()})
$settingsCloseButton.Add_Click({$window.Close()})
$windowFrame.Add_SizeChanged({Update-SquircleGeometry})
$tray=New-Object Windows.Forms.NotifyIcon; $tray.Icon=[Drawing.SystemIcons]::Application; $tray.Text="AI task monitor"; $tray.Visible=$true; $tray.Add_DoubleClick({Restore-Window})
$menu=New-Object Windows.Forms.ContextMenuStrip; $show=$menu.Items.Add("Развернуть"); $exit=$menu.Items.Add("Выход"); $show.Add_Click({Restore-Window;Set-CompactMode $false}); $exit.Add_Click({$window.Close()}); $tray.ContextMenuStrip=$menu
$timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[TimeSpan]::FromSeconds(2); $timer.Add_Tick({Refresh-SystemTheme;Update-View}); $timer.Start(); $window.Add_Closed({$timer.Stop();$tray.Visible=$false;$tray.Dispose()})
$initialTheme=if($ThemeOverride){$ThemeOverride}else{Load-ThemeMode}
Apply-Theme $initialTheme $false
Update-View
if($CompactMode){Set-CompactMode $true}
if ($SnapshotFile) {
 $window.Show(); $window.UpdateLayout()
 $width=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth)); $height=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
 $bitmap.Render($window)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
 $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create($SnapshotFile)
 try {$encoder.Save($stream)} finally {$stream.Dispose()}
 if($SettingsSnapshotFile){
  Show-SettingsView
  if($PreviewSettingsBackHover){$settingsBackButton.Background=Brush $script:palette.Hover}
  $window.UpdateLayout()
  $settingsWidth=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth)); $settingsHeight=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
  $settingsBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($settingsWidth,$settingsHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32); $settingsBitmap.Render($window)
  $settingsEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder; $settingsEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($settingsBitmap)); $settingsStream=[IO.File]::Create($SettingsSnapshotFile)
  try{$settingsEncoder.Save($settingsStream)}finally{$settingsStream.Dispose()}
 }
 $window.Close()
} else {
 $window.ShowDialog()|Out-Null
}

