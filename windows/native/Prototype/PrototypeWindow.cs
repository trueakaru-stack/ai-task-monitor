using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Input;
using System.Windows.Documents;
using System.Windows.Threading;
using System.Globalization;
using AITaskMonitor.NativeUpdateController;
using AITaskMonitor.Claude;
using AITaskMonitor.CodexCloud;
using AITaskMonitor.Prototype.Settings;
using ShapePath = System.Windows.Shapes.Path;

namespace AITaskMonitor.Prototype;

internal sealed record LoopWarningView(int Threshold, int WindowMinutes);
internal sealed record WarningFocusKey(string TaskId);

// This isolated preview uses synthetic data and the published WPF layout only.
internal sealed class PrototypeWindow
{
    private readonly Window window;
    private Options options;
    private readonly Border frame;
    private readonly ShapePath outline;
    private readonly Grid expanded;
    private readonly Grid compactView;
    private readonly Grid tabsHost;
    private readonly ShapePath tabsShape;
    private readonly StackPanel tabs;
    private readonly ScrollViewer tabsScroll;
    private readonly StackPanel tasks;
    private readonly StackPanel compactTasks;
    private readonly StackPanel dots;
    private readonly TextBlock compactMore;
    private readonly ScrollViewer tasksScroll;
    private readonly ScrollBar tasksScrollBar;
    private IReadOnlyDictionary<string, string> palette;
    private readonly DisplayPreferenceService? preferences;
    private readonly Func<bool?> windowsUsesLightTheme;
    private readonly Func<string> systemLanguage;
    private readonly Dictionary<TextBlock, string> staticText = new();
    private readonly Dictionary<Button, string> staticButtons = new();
    private readonly Dictionary<DependencyObject, string> staticNames = new();
    private string? themeMode, languageMode;
    private string preferenceError = "";
    private ClaudeSourceSnapshot? latestClaude;
    private CloudSnapshot? latestCloud;
    private readonly Color accent = SystemParameters.WindowGlassColor;
    private string selectedProvider = "all";
    private string compactSelection = "";
    private bool compact;
    private readonly SyntheticProviderScenarios? scenario;
    private readonly SyntheticClaudeScenario? claudeScenario;
    private List<SampleTask> samples = [];
    private readonly Dictionary<string, long> taskPriority = new(StringComparer.Ordinal);
    private long taskPriorityCounter;
    private bool showProviderLabels;
    private bool equalProviderWidths;
    private string lastRenderedProvider = "";
    private bool claudeSourceUnavailable, claudeSourceObserved;
    private bool cloudEnabled, cloudScanned, cloudUnavailable;
    private readonly HashSet<string> cloudTaskIds = new(StringComparer.Ordinal);
    private Dictionary<string, LoopWarningView> loopWarnings = new(StringComparer.Ordinal);
    private Func<string, bool>? dismissLoopWarning;
    // The live distribution/version contract is not available yet. This state
    // is supplied only by the isolated synthetic update-host test.
    private UpdateInfo? syntheticUpdate;
    private string dismissedSyntheticVersion = "";
    private Action? syntheticDownload;

    public PrototypeWindow(Window window, Options options, DisplayPreferenceService? preferences = null,
        Func<bool?>? windowsUsesLightTheme = null, Func<string>? systemLanguage = null)
    {
        this.window = window;
        this.preferences = preferences;
        this.windowsUsesLightTheme = windowsUsesLightTheme ?? WindowsUsesLightTheme;
        this.systemLanguage = systemLanguage ?? (() => CultureInfo.CurrentUICulture.Name);
        if (preferences is not null)
        {
            PreferenceLoad loaded = preferences.Load();
            if (loaded.Status == PreferenceStatus.Success && loaded.Modes is not null)
            {
                themeMode = loaded.Modes.Theme;
                languageMode = loaded.Modes.Language;
                options = options with {
                    Theme = DisplayPreferenceDocument.ResolveTheme(themeMode, this.windowsUsesLightTheme()),
                    Language = DisplayPreferenceDocument.ResolveLanguage(languageMode, this.systemLanguage())
                };
            }
            else preferenceError = "load";
        }
        this.options = options;
        frame = Find<Border>("WindowFrame");
        outline = Find<ShapePath>("WindowOutline");
        expanded = Find<Grid>("ExpandedView");
        compactView = Find<Grid>("CompactView");
        tabsHost = Find<Grid>("ProviderTabsHost");
        tabsShape = Find<ShapePath>("ProviderTabsShape");
        tabs = Find<StackPanel>("ProviderTabsPanel");
        tabsScroll = Find<ScrollViewer>("ProviderTabsScroll");
        tasks = Find<StackPanel>("TasksPanel");
        compactTasks = Find<StackPanel>("CompactTasksPanel");
        dots = Find<StackPanel>("CompactDotsPanel");
        compactMore = Find<TextBlock>("CompactMoreText");
        tasksScroll = Find<ScrollViewer>("TasksScroll");
        tasksScrollBar = Find<ScrollBar>("TasksScrollBar");

        palette = options.Theme == "light" ? LightPalette : DarkPalette;
        ApplyPalette();
        ApplyIcon();
        CaptureStaticTranslations(window);
        ApplyStaticTranslations();

        var updateDialog = Find<Grid>("UpdateDialog");
        updateDialog.SizeChanged += (_, _) =>
        {
            if (updateDialog.ActualWidth > 0 && updateDialog.ActualHeight > 0)
                Find<ShapePath>("UpdateDialogShape").Data =
                    Squircle.Create(updateDialog.ActualWidth, updateDialog.ActualHeight, 16, 0.5);
        };
        Find<Button>("UpdateLaterButton").Click += (_, _) => DismissSyntheticUpdate();
        Find<Button>("UpdateDownloadButton").Click += (_, _) =>
        {
            if (syntheticDownload is null) return;
            try { syntheticDownload(); DismissSyntheticUpdate(); }
            catch { Find<TextBlock>("UpdateOpenError").Visibility = Visibility.Visible; }
        };
        Find<Grid>("UpdateOverlay").PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            DismissSyntheticUpdate();
            e.Handled = true;
        };

        frame.SizeChanged += (_, _) => UpdateShapes();
        tabsHost.SizeChanged += (_, _) => { SizeTabs(); UpdateShapes(); };
        tabsScroll.PreviewMouseWheel += (_, e) =>
        {
            if (tabsScroll.ScrollableWidth <= 0) return;
            tabsScroll.ScrollToHorizontalOffset(tabsScroll.HorizontalOffset - e.Delta);
            e.Handled = true;
        };
        tasksScroll.ScrollChanged += (_, _) =>
        {
            tasksScrollBar.Maximum = tasksScroll.ScrollableHeight;
            tasksScrollBar.ViewportSize = tasksScroll.ViewportHeight;
            tasksScrollBar.Value = tasksScroll.VerticalOffset;
            tasksScrollBar.Visibility = tasksScroll.ScrollableHeight > 0 ? Visibility.Visible : Visibility.Hidden;
        };
        tasksScrollBar.ValueChanged += (_, _) =>
        {
            if (Math.Abs(tasksScroll.VerticalOffset - tasksScrollBar.Value) > 0.5)
                tasksScroll.ScrollToVerticalOffset(tasksScrollBar.Value);
        };
        Find<Button>("CloseButton").Click += (_, _) => window.Close();
        Find<Button>("CompactCloseButton").Click += (_, _) => window.Close();
        Find<Button>("TaskbarMinimizeButton").Click += (_, _) => window.WindowState = WindowState.Minimized;
        Find<Button>("CompactTaskbarMinimizeButton").Click += (_, _) => window.WindowState = WindowState.Minimized;
        Find<Button>("MinimizeButton").Click += (_, _) => SetCompact(true);
        Find<Button>("ExpandButton").Click += (_, _) => SetCompact(false);
        if (preferences is null)
        {
            // Synthetic previews do not access any real settings.
            Find<Button>("SettingsFooterButton").IsHitTestVisible = false;
            Find<Button>("SettingsFooterButton").Focusable = false;
        }
        else ConfigureDisplaySettings();
        if (options.Scene == "active")
        {
            samples = LegacySamples(options.Language);
            compactSelection = samples[0].Id;
        }
        else if (options.Scene == "claude-synthetic")
        {
            claudeScenario = new SyntheticClaudeScenario();
            UpdateSamples(claudeScenario.Snapshot(options.Language));
        }
        else if (options.Scene != "empty")
        {
            scenario = new SyntheticProviderScenarios(options.Scene);
            UpdateSamples(scenario.Snapshot().Select(state => ProviderPresentation.Map(state, options.Language)).ToList());
        }
        Render();
        if (options.Compact) SetCompact(true);
    }

    private T Find<T>(string name) where T : class => window.FindName(name) as T
        ?? throw new InvalidOperationException($"Published layout is missing {name}.");

    private static List<SampleTask> LegacySamples(string language)
    {
        string DemoText(string ru, string en) => language == "en" ? en : ru;
        static SampleTask Task(string id, string name, string title, string activity, int progress, int active, string[] steps)
        {
            var result = steps.Select((text, index) => new SampleStep(text,
                index < active - 1 ? "done" : index == active - 1 ? "active" : "pending")).ToArray();
            return new SampleTask(id, id, name, title, activity, "active", progress, result, true, "18:09",
                DateTimeOffset.MinValue, id, DateTimeOffset.MinValue);
        }
        return
        [
            Task("codex", "Codex", DemoText("Создать индикатор прогресса задач", "Create a task progress indicator"),
                DemoText("Проверяю карточки планов, переключение источников и прокрутку этапов перед публикацией новой версии, светлую тему и поведение длинных описаний", "Checking plan cards, source filters, scrolling, the light theme and long descriptions before release"),
                50, 5,
                [DemoText("Синхронизировать список задач", "Synchronize the task list"), DemoText("Восстановить карточки планов", "Restore plan cards"), DemoText("Исправить прокрутку этапов", "Fix step scrolling"), DemoText("Применить системный акцент", "Apply the system accent"), DemoText("Проверить скругления и фокус", "Check corners and focus"), DemoText("Снять тёмный и светлый экран", "Capture dark and light screens"), DemoText("Провести финальную проверку", "Run final checks"), DemoText("Опубликовать исходники", "Publish the source")]),
            Task("claude", "Claude Code", DemoText("Задача Claude Code", "Claude Code task"), DemoText("Запускаю визуальную проверку", "Running visual checks"), 33, 3,
                [DemoText("Проверить локальное окружение", "Check the local environment"), DemoText("Подготовить тестовые данные", "Prepare test data"), DemoText("Запустить визуальную проверку", "Run visual checks"), DemoText("Проверить светлую тему", "Check the light theme"), DemoText("Зафиксировать результат", "Record the result"), DemoText("Очистить временные данные", "Clear temporary data")])
        ];
    }

    private void UpdateSamples(List<SampleTask> next)
    {
        var previous = samples.ToDictionary(task => task.Id, StringComparer.Ordinal);
        var present = next.Select(task => task.Id).ToHashSet(StringComparer.Ordinal);
        var activated = new List<SampleTask>();
        foreach (var task in next)
        {
            if (!taskPriority.ContainsKey(task.Id)) taskPriority[task.Id] = 0;
            previous.TryGetValue(task.Id, out SampleTask? old);
            bool newTurn = !string.IsNullOrEmpty(task.StartKey) && task.StartKey != old?.StartKey;
            bool recentPending = !task.Active && (task.Status is "unknown" or "waiting") &&
                !string.IsNullOrEmpty(task.StartKey) && task.Started != DateTimeOffset.MinValue;
            if (!task.Active && !recentPending) continue;
            bool becameActive = old is not null && !old.Active && (string.IsNullOrEmpty(task.StartKey) || string.IsNullOrEmpty(old.StartKey));
            if (old is null || newTurn || (task.Active && becameActive)) activated.Add(task);
        }
        foreach (string id in taskPriority.Keys.Where(id => !present.Contains(id)).ToArray()) taskPriority.Remove(id);
        foreach (SampleTask task in activated.OrderBy(task => task.Started).ThenBy(task => task.Id, StringComparer.Ordinal))
        {
            taskPriority[task.Id] = ++taskPriorityCounter;
            compactSelection = task.Id;
        }
        samples = next.OrderByDescending(task => taskPriority[task.Id]).ThenByDescending(task => task.Active)
            .ThenByDescending(task => task.Updated).ToList();
        if (!samples.Any(task => task.Id == compactSelection)) compactSelection = samples.FirstOrDefault()?.Id ?? "";
    }

    // Test-only input: the default application never creates a release service
    // or opens a download. The supplied callback belongs to a fake test handler.
    internal void ApplySyntheticUpdate(UpdateInfo update, Action download)
    {
        if (!window.Dispatcher.CheckAccess()) throw new InvalidOperationException("UI updates must run on the window dispatcher.");
        ArgumentNullException.ThrowIfNull(update);
        ArgumentNullException.ThrowIfNull(download);
        if (string.IsNullOrWhiteSpace(update.Version)) throw new ArgumentException("A synthetic version is required.", nameof(update));
        syntheticUpdate = update;
        syntheticDownload = download;
        ShowSyntheticPendingUpdate();
    }

    private void ShowSyntheticPendingUpdate()
    {
        var overlay = Find<Grid>("UpdateOverlay");
        if (compact || syntheticUpdate is null || syntheticUpdate.Version == dismissedSyntheticVersion)
        {
            overlay.Visibility = Visibility.Collapsed;
            return;
        }
        Find<TextBlock>("UpdateVersionText").Text = options.Language == "en"
            ? $"Version {syntheticUpdate.Version} is available to download"
            : $"Версия {syntheticUpdate.Version} доступна для скачивания";
        Find<TextBlock>("UpdateOpenError").Visibility = Visibility.Collapsed;
        overlay.Visibility = Visibility.Visible;
        Find<Button>("UpdateLaterButton").Focus();
    }

    private void DismissSyntheticUpdate()
    {
        if (syntheticUpdate is not null) dismissedSyntheticVersion = syntheticUpdate.Version;
        Find<Grid>("UpdateOverlay").Visibility = Visibility.Collapsed;
        Keyboard.ClearFocus();
    }

    internal string SelectedTaskId => compactSelection;
    internal string SelectedProvider => selectedProvider;
    internal IReadOnlyList<SampleTask> CurrentTasks => samples;

    // Warning state is supplied by a future controller, not read by the view.
    internal void ApplyLoopWarnings(IReadOnlyDictionary<string, LoopWarningView> warnings, Func<string, bool> dismiss)
    {
        if (!window.Dispatcher.CheckAccess()) throw new InvalidOperationException("UI updates must run on the window dispatcher.");
        ArgumentNullException.ThrowIfNull(warnings);
        ArgumentNullException.ThrowIfNull(dismiss);
        if (warnings.Any(item => item.Value is null || item.Value.Threshold is < 3 or > 10 || item.Value.WindowMinutes is < 1 or > 30))
            throw new ArgumentException("Invalid loop warning settings.", nameof(warnings));
        loopWarnings = new Dictionary<string, LoopWarningView>(warnings, StringComparer.Ordinal);
        dismissLoopWarning = dismiss;
        Render();
    }

    private LoopWarningView? WarningFor(SampleTask task) =>
        task.Active && loopWarnings.TryGetValue(task.Id, out LoopWarningView? warning) ? warning : null;

    // The caller must supply a snapshot on the WPF dispatcher. Other providers
    // already visible in the window are retained when the Claude source polls.
    internal void ApplyClaudeSource(ClaudeSourceSnapshot snapshot)
    {
        if (!window.Dispatcher.CheckAccess()) throw new InvalidOperationException("UI updates must run on the window dispatcher.");
        ArgumentNullException.ThrowIfNull(snapshot);
        latestClaude = snapshot;
        claudeSourceObserved = true;
        claudeSourceUnavailable = snapshot.Unavailable;
        var combined = samples.Where(task => task.Provider != "claude").ToList();
        combined.AddRange(snapshot.Tasks.Select(task => ClaudePresentation.Map(task, options.Language)));
        UpdateSamples(combined);
        Render();
    }

    // Cloud and local Codex share a visible provider tab, not a source state.
    internal void ApplyCloudSource(CloudSnapshot snapshot)
    {
        if (!window.Dispatcher.CheckAccess()) throw new InvalidOperationException("UI updates must run on the window dispatcher.");
        ArgumentNullException.ThrowIfNull(snapshot);
        cloudEnabled = snapshot.Enabled;
        cloudScanned = snapshot.Scanned;
        cloudUnavailable = snapshot.Unavailable;

        var other = samples.Where(task => !cloudTaskIds.Contains(task.Id)).ToList();
        var mapped = snapshot.Tasks.Select(task => MapCloudTask(task, options.Language)).ToList();
        var nextIds = mapped.Select(task => task.Id).ToHashSet(StringComparer.Ordinal);
        if (other.Any(task => nextIds.Contains(task.Id)))
        {
            // An ID collision cannot replace an unrelated task.
            cloudUnavailable = true;
            Render();
            return;
        }
        latestCloud = snapshot;
        cloudTaskIds.Clear();
        foreach (SampleTask task in mapped) cloudTaskIds.Add(task.Id);
        other.AddRange(mapped);
        UpdateSamples(other);
        Render();
    }

    private static SampleTask MapCloudTask(CloudTask task, string language)
    {
        bool english = language == "en";
        string title = string.IsNullOrWhiteSpace(task.Title)
            ? english ? "Codex task" : "Задача Codex"
            : task.Title;
        DateTimeOffset updated = task.UpdatedAt ?? DateTimeOffset.MinValue;
        return new SampleTask(task.Id, "codex", "Codex",
            (english ? "Cloud: " : "Облако: ") + title,
            english ? "Status unconfirmed" : "Статус не подтверждён",
            "unknown", null, [], false,
            updated == DateTimeOffset.MinValue ? "" : updated.LocalDateTime.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture),
            updated, "", DateTimeOffset.MinValue);
    }

    internal void AdvanceMultiForTest()
    {
        if (scenario is null) throw new InvalidOperationException("A synthetic scenario is required.");
        scenario.AdvanceMulti();
        var retainedCloud = samples.Where(task => cloudTaskIds.Contains(task.Id)).ToArray();
        UpdateSamples(scenario.Snapshot().Select(state => ProviderPresentation.Map(state, options.Language)).Concat(retainedCloud).ToList());
        Render();
    }

    internal void AdvanceClaudeForTest()
    {
        if (claudeScenario is null) throw new InvalidOperationException("A synthetic Claude scenario is required.");
        claudeScenario.Advance();
        var retainedCloud = samples.Where(task => cloudTaskIds.Contains(task.Id)).ToArray();
        UpdateSamples(claudeScenario.Snapshot(options.Language).Concat(retainedCloud).ToList());
        Render();
    }

    private static readonly IReadOnlyDictionary<string, string> DarkPalette = new Dictionary<string, string>
    {
        ["Surface"]="#202020", ["Raised"]="#282828", ["TooltipSurface"]="#171717", ["TooltipBorder"]="#3D3D3D",
        ["Border"]="#414141", ["Primary"]="#F1F1F1", ["Secondary"]="#ACACAC", ["Muted"]="#989898",
        ["Hover"]="#333333", ["Pressed"]="#3B3B3B", ["Divider"]="#343434", ["Track"]="#3A3A3A",
        ["Scroll"]="#555555", ["ScrollHover"]="#747474", ["CardBorder"]="#474747", ["Activity"]="#989898",
        ["Done"]="#989898", ["Pending"]="#B8B8B8"
    };
    private static readonly IReadOnlyDictionary<string, string> LightPalette = new Dictionary<string, string>
    {
        ["Surface"]="#F6F6F6", ["Raised"]="#FFFFFF", ["TooltipSurface"]="#ECECEC", ["TooltipBorder"]="#CDCDCD",
        ["Border"]="#D7D7D7", ["Primary"]="#1F1F1F", ["Secondary"]="#575757", ["Muted"]="#707070",
        ["Hover"]="#EAEAEA", ["Pressed"]="#DFDFDF", ["Divider"]="#E2E2E2", ["Track"]="#D8D8D8",
        ["Scroll"]="#B3B3B3", ["ScrollHover"]="#8F8F8F", ["CardBorder"]="#DADADA", ["Activity"]="#707070",
        ["Done"]="#707070", ["Pending"]="#4F4F4F"
    };

    private static Brush Brush(string color) => (Brush)new BrushConverter().ConvertFromString(color)!;
    private Brush ColorFor(string key) => Brush(palette[key]);
    private Brush AccentBrush => new SolidColorBrush(accent);
    private Brush AccentText => Brush((0.299 * accent.R + 0.587 * accent.G + 0.114 * accent.B) > 155 ? "#161616" : "#FFFFFF");

    private void ApplyPalette()
    {
        var keys = new Dictionary<string, string>
        {
            ["Surface"]="Surface", ["SurfaceRaised"]="Raised", ["TooltipSurface"]="TooltipSurface",
            ["TooltipBorder"]="TooltipBorder", ["Border"]="Border", ["TextPrimary"]="Primary",
            ["TextSecondary"]="Secondary", ["TextMuted"]="Muted", ["SurfaceHover"]="Hover",
            ["SurfacePressed"]="Pressed", ["Divider"]="Divider", ["Track"]="Track",
            ["ScrollThumbBrush"]="Scroll", ["ScrollThumbHoverBrush"]="ScrollHover"
        };
        foreach (var item in keys) window.Resources[item.Key] = ColorFor(item.Value);
        window.Resources["Accent"] = AccentBrush;
    }

    private void ApplyIcon()
    {
        var uri = new Uri("pack://application:,,,/AI%20Task%20Monitor;component/Assets/app-icon.ico", UriKind.Absolute);
        using Stream icon = Application.GetResourceStream(uri).Stream;
        var decoder = BitmapDecoder.Create(icon, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        window.Icon = decoder.Frames.First(frame => frame.PixelWidth == 32);
        foreach (string name in new[] { "ExpandedTitleIcon", "CompactTitleIcon" })
        {
            var image = Find<Image>(name);
            image.Source = window.Icon;
            image.Visibility = Visibility.Visible;
        }
    }

    private void CaptureStaticTranslations(DependencyObject root)
    {
        if (root is TextBlock text && DisplayText.English.ContainsKey(text.Text)) staticText[text] = text.Text;
        if (root is Button button && button.Content is string label && DisplayText.English.ContainsKey(label))
            staticButtons[button] = label;
        string name = AutomationProperties.GetName(root);
        if (!string.IsNullOrEmpty(name) && DisplayText.English.ContainsKey(name)) staticNames[root] = name;
        foreach (object child in LogicalTreeHelper.GetChildren(root))
            if (child is DependencyObject element) CaptureStaticTranslations(element);
    }

    private void ApplyStaticTranslations()
    {
        bool english = options.Language == "en";
        foreach (var pair in staticText) pair.Key.Text = english ? DisplayText.English[pair.Value] : pair.Value;
        foreach (var pair in staticButtons) pair.Key.Content = english ? DisplayText.English[pair.Value] : pair.Value;
        foreach (var pair in staticNames) AutomationProperties.SetName(pair.Key, english ? DisplayText.English[pair.Value] : pair.Value);
        window.Language = System.Windows.Markup.XmlLanguage.GetLanguage(english ? "en-US" : "ru-RU");
    }

    private static bool? WindowsUsesLightTheme()
    {
        try
        {
            using Microsoft.Win32.RegistryKey? key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", false);
            return key?.GetValue("AppsUseLightTheme") is int value ? value != 0 : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        { return null; }
    }

    private void ConfigureDisplaySettings()
    {
        Grid settings = Find<Grid>("SettingsView");
        var enabled = new HashSet<Button>
        {
            Find<Button>("SettingsBackButton"), Find<Button>("SettingsTaskbarMinimizeButton"), Find<Button>("SettingsCloseButton"),
            Find<Button>("SystemThemeButton"), Find<Button>("DarkThemeButton"), Find<Button>("LightThemeButton"),
            Find<Button>("SystemLanguageButton"), Find<Button>("RussianLanguageButton"), Find<Button>("EnglishLanguageButton")
        };
        void DisableUnconnected(DependencyObject root)
        {
            if (root is Button button && !enabled.Contains(button)) button.IsEnabled = false;
            if (root is ComboBox combo) combo.IsEnabled = false;
            if (root is Hyperlink link) link.IsEnabled = false;
            foreach (object child in LogicalTreeHelper.GetChildren(root))
                if (child is DependencyObject element) DisableUnconnected(element);
        }
        DisableUnconnected(settings);
        Find<Button>("SettingsFooterButton").Click += (_, _) => ShowSettings(true);
        Find<Button>("SettingsBackButton").Click += (_, _) => ShowSettings(false);
        Find<Button>("SettingsTaskbarMinimizeButton").Click += (_, _) => window.WindowState = WindowState.Minimized;
        Find<Button>("SettingsCloseButton").Click += (_, _) => window.Close();
        Find<Button>("SystemThemeButton").Click += (_, _) => SelectDisplayMode(true, "system");
        Find<Button>("DarkThemeButton").Click += (_, _) => SelectDisplayMode(true, "dark");
        Find<Button>("LightThemeButton").Click += (_, _) => SelectDisplayMode(true, "light");
        Find<Button>("SystemLanguageButton").Click += (_, _) => SelectDisplayMode(false, "system");
        Find<Button>("RussianLanguageButton").Click += (_, _) => SelectDisplayMode(false, "ru");
        Find<Button>("EnglishLanguageButton").Click += (_, _) => SelectDisplayMode(false, "en");
        var scroll = Find<ScrollViewer>("SettingsScroll");
        var bar = Find<ScrollBar>("SettingsScrollBar");
        scroll.ScrollChanged += (_, _) =>
        {
            bar.Maximum = scroll.ScrollableHeight;
            bar.ViewportSize = scroll.ViewportHeight;
            bar.Value = scroll.VerticalOffset;
            bar.Visibility = scroll.ScrollableHeight > 0 ? Visibility.Visible : Visibility.Hidden;
        };
        bar.ValueChanged += (_, _) =>
        {
            if (Math.Abs(scroll.VerticalOffset - bar.Value) > 0.5) scroll.ScrollToVerticalOffset(bar.Value);
        };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) => { if (themeMode == "system") ApplyDisplayModes(); };
        window.Closed += (_, _) => timer.Stop();
        timer.Start();
        UpdateDisplayControls();
    }

    private void ShowSettings(bool show)
    {
        expanded.Visibility = show ? Visibility.Collapsed : Visibility.Visible;
        Find<Grid>("SettingsView").Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (show) Find<Button>("SettingsBackButton").Focus();
        else Find<Button>("SettingsFooterButton").Focus();
    }

    private void SelectDisplayMode(bool theme, string mode)
    {
        if (preferences is null) return;
        PreferenceStatus saved = theme ? preferences.SaveTheme(mode) : preferences.SaveLanguage(mode);
        if (saved != PreferenceStatus.Success)
        {
            preferenceError = "save";
            UpdateDisplayControls();
            return;
        }
        PreferenceLoad loaded = preferences.Load();
        if (loaded.Status == PreferenceStatus.Success && loaded.Modes is not null)
        {
            themeMode = loaded.Modes.Theme;
            languageMode = loaded.Modes.Language;
            preferenceError = "";
        }
        else
        {
            if (theme) themeMode = mode; else languageMode = mode;
            preferenceError = "load";
        }
        ApplyDisplayModes();
    }

    private void ApplyDisplayModes()
    {
        string nextTheme = themeMode is null ? options.Theme : DisplayPreferenceDocument.ResolveTheme(themeMode, windowsUsesLightTheme());
        string nextLanguage = languageMode is null ? options.Language : DisplayPreferenceDocument.ResolveLanguage(languageMode, systemLanguage());
        bool changedTheme = nextTheme != options.Theme, changedLanguage = nextLanguage != options.Language;
        options = options with { Theme = nextTheme, Language = nextLanguage };
        if (changedTheme)
        {
            palette = nextTheme == "light" ? LightPalette : DarkPalette;
            ApplyPalette();
        }
        if (changedLanguage)
        {
            ApplyStaticTranslations();
            RelocalizeSamples();
        }
        if (changedTheme || changedLanguage) Render();
        UpdateDisplayControls();
    }

    private void UpdateDisplayControls()
    {
        foreach (var item in new[] { ("SystemThemeButton", "system"), ("DarkThemeButton", "dark"), ("LightThemeButton", "light") })
            Find<Button>(item.Item1).Background = themeMode == item.Item2 ? ColorFor("Pressed") : Brushes.Transparent;
        foreach (var item in new[] { ("SystemLanguageButton", "system"), ("RussianLanguageButton", "ru"), ("EnglishLanguageButton", "en") })
            Find<Button>(item.Item1).Background = languageMode == item.Item2 ? ColorFor("Pressed") : Brushes.Transparent;
        TextBlock error = Find<TextBlock>("LanguageSettingsError");
        bool english = options.Language == "en";
        error.Text = preferenceError == "save"
            ? english ? "Could not save display settings" : "Не удалось сохранить настройки оформления"
            : english ? "Could not read display settings" : "Не удалось прочитать настройки оформления";
        error.Visibility = preferenceError.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RelocalizeSamples()
    {
        List<SampleTask> next = options.Scene == "active" ? LegacySamples(options.Language)
            : scenario is not null ? scenario.Snapshot().Select(state => ProviderPresentation.Map(state, options.Language)).ToList()
            : claudeScenario is not null ? claudeScenario.Snapshot(options.Language) : samples.ToList();
        if (latestClaude is not null)
        {
            next.RemoveAll(task => task.Provider == "claude");
            next.AddRange(latestClaude.Tasks.Select(task => ClaudePresentation.Map(task, options.Language)));
        }
        if (latestCloud is not null)
        {
            next.RemoveAll(task => cloudTaskIds.Contains(task.Id));
            next.AddRange(latestCloud.Tasks.Select(task => MapCloudTask(task, options.Language)));
        }
        UpdateSamples(next);
    }

    private void UpdateShapes()
    {
        if (frame.ActualWidth > 0 && frame.ActualHeight > 0)
        {
            frame.Clip = Squircle.Create(frame.ActualWidth, frame.ActualHeight, 16);
            outline.Data = Squircle.Create(frame.ActualWidth, frame.ActualHeight, 16, 0.5);
        }
        if (tabsHost.ActualWidth > 0 && tabsHost.ActualHeight > 0)
        {
            tabsShape.Data = TabContour.Create(tabsHost.ActualWidth, tabsHost.ActualHeight, 14);
            tabsHost.Clip = TabContour.Create(tabsHost.ActualWidth, tabsHost.ActualHeight, 14);
        }
    }

    private void SetCompact(bool value)
    {
        if (compact == value) return;
        bool restoreToggleFocus = Find<Button>(value ? "MinimizeButton" : "ExpandButton").IsKeyboardFocusWithin;
        compact = value;
        expanded.Visibility = value ? Visibility.Collapsed : Visibility.Visible;
        compactView.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        if (value)
        {
            window.ResizeMode = ResizeMode.NoResize;
            window.MinWidth = window.MinHeight = 0;
            window.Width = 390;
            window.Height = CompactHeight();
            frame.Margin = new Thickness(16);
        }
        else
        {
            window.ResizeMode = ResizeMode.CanResize;
            window.MinWidth = window.MinHeight = 500;
            window.Width = 590;
            window.Height = 760;
            frame.Margin = new Thickness(28);
        }
        Render();
        if (restoreToggleFocus) Find<Button>(value ? "ExpandButton" : "MinimizeButton").Focus();
        ShowSyntheticPendingUpdate();
    }

    private TextBlock Text(string value, double size, string color, bool semiBold = false) => new()
    {
        Text = value, FontFamily = new FontFamily("Segoe UI Variable Text"), FontSize = size,
        Foreground = ColorFor(color), FontWeight = semiBold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap, LineHeight = size * 1.35
    };

    private string Progress(SampleTask task)
    {
        if (task.Steps.Length == 0 || !task.PlanConfirmed || task.Status == "unknown") return "";
        int[] active = task.Steps.Select((step, index) => (step, index)).Where(item => item.step.Status == "active").Select(item => item.index + 1).ToArray();
        if (active.Length == 1) return options.Language == "en" ? $"Step {active[0]} of {task.Steps.Length}" : $"Этап {active[0]} из {task.Steps.Length}";
        int done = task.Steps.Count(step => step.Status == "done");
        return options.Language == "en" ? $"Done {done} of {task.Steps.Length}" : $"Готово {done} из {task.Steps.Length}";
    }

    private string PlanNote(SampleTask task)
    {
        if (task.Provider == "claude" && task.RetainedPlanIncomplete)
            return options.Language == "en" ? "Plan unconfirmed; retained plan is incomplete" : "План не подтверждён, сохранён не полностью";
        if (task.Steps.Length == 0) return "";
        if (!task.PlanConfirmed || (task.Provider == "claude" && task.Status == "unknown"))
            return options.Language == "en" ? "Plan unconfirmed" : "План не подтверждён";
        return task.Provider == "claude"
            ? options.Language == "en" ? "Based on observed steps; may be inaccurate" : "По известным этапам, возможна неточность"
            : "";
    }

    private static readonly (string Id, string Name)[] ProviderOrder =
    [ ("codex", "Codex"), ("claude", "Claude Code"), ("kimi", "Kimi Code"),
      ("deepseek", "DeepSeek Harness"), ("hermes", "Hermes Agent"), ("opencode", "OpenCode") ];

    private void Render()
    {
        double oldTabOffset = tabsScroll.HorizontalOffset;
        double oldTaskOffset = tasksScroll.VerticalOffset;
        string? focusedTab = tabs.Children.OfType<Button>().FirstOrDefault(button => button.IsKeyboardFocusWithin)?.Tag as string;
        Button[] oldWarnings = WarningButtons().ToArray();
        string[] oldWarningOrder = oldWarnings.Select(button => ((WarningFocusKey)button.Tag).TaskId).ToArray();
        string? focusedWarning = oldWarnings.FirstOrDefault(button => button.IsKeyboardFocusWithin)?.Tag is WarningFocusKey key ? key.TaskId : null;
        tasks.Children.Clear(); tabs.Children.Clear(); compactTasks.Children.Clear(); dots.Children.Clear();
        bool english = options.Language == "en";
        var warnings = new List<string>();
        if (claudeSourceUnavailable) warnings.Add(english ? "No data from Claude Code" : "Нет данных от Claude Code");
        if (cloudEnabled && cloudUnavailable) warnings.Add(english ? "No data from Codex Cloud" : "Нет данных от Codex Cloud");
        string warningText = string.Join(Environment.NewLine, warnings);
        if (warningText.Length != 0)
        {
            var warning = Text(warningText, 14, "Secondary");
            warning.Margin = new Thickness(4, 0, 0, 12);
            tasks.Children.Add(warning);
        }
        var providers = samples.Select(task => task.Provider).Distinct(StringComparer.Ordinal).ToHashSet(StringComparer.Ordinal);
        showProviderLabels = providers.Count >= 2;
        equalProviderWidths = providers.Count == 2;
        tabsHost.Visibility = showProviderLabels ? Visibility.Visible : Visibility.Collapsed;
        if (!showProviderLabels) selectedProvider = "all";
        if (selectedProvider != "all" && !providers.Contains(selectedProvider)) selectedProvider = "all";
        if (samples.Count == 0)
        {
            string text = cloudEnabled
                ? cloudScanned
                    ? english ? "Cloud task status unconfirmed" : "Статус облачных задач не подтверждён"
                    : english ? "Checking Codex Cloud" : "Проверка Codex Cloud"
                : claudeSourceObserved
                    ? english ? "Task status unconfirmed" : "Статус задач не подтверждён"
                    : options.Scene == "empty"
                        ? english ? "No sources connected" : "Источники не подключены"
                        : english ? "No active tasks" : "Активных задач сейчас нет";
            if (warningText.Length == 0) { var empty = Text(text, 14, "Secondary"); empty.Margin = new Thickness(4, 24, 0, 0); tasks.Children.Add(empty); }
            var compactEmpty = Text(warningText.Length != 0 ? warningText : text, 12.5, "Activity"); compactEmpty.Margin = new Thickness(0, 5, 0, 5); compactTasks.Children.Add(compactEmpty);
            dots.Visibility = Visibility.Collapsed;
            compactMore.Visibility = Visibility.Collapsed;
            if (compact) window.Height = CompactHeight();
            if (focusedWarning is not null) RestoreWarningFocus(focusedWarning, oldTaskOffset, oldWarningOrder);
            return;
        }
        if (showProviderLabels)
        {
            AddTab("all", options.Language == "en" ? "All" : "Все", samples.Count);
            foreach (var provider in ProviderOrder.Where(provider => providers.Contains(provider.Id)))
                AddTab(provider.Id, provider.Name, samples.Count(task => task.Provider == provider.Id));
            tabs.Children[^1].SetValue(FrameworkElement.MarginProperty, new Thickness(0));
            SizeTabs();
            tabsHost.UpdateLayout();
            tabsScroll.ScrollToHorizontalOffset(oldTabOffset);
            if (lastRenderedProvider != selectedProvider)
                tabs.Children.OfType<Button>().FirstOrDefault(button => (string)button.Tag == selectedProvider)?.BringIntoView();
            if (focusedTab is not null)
                tabs.Children.OfType<Button>().FirstOrDefault(button => (string)button.Tag == focusedTab)?.Focus();
            lastRenderedProvider = selectedProvider;
            UpdateShapes();
        }
        foreach (SampleTask task in samples.Where(t => selectedProvider == "all" || t.Provider == selectedProvider)) AddCard(task);
        SampleTask[] visible = samples.Take(3).ToArray();
        if (!visible.Any(task => task.Id == compactSelection)) compactSelection = visible[0].Id;
        AddCompactTask(visible.First(task => task.Id == compactSelection));
        if (warningText.Length != 0)
        {
            var warning = Text(warningText, 11.5, "Muted");
            warning.Margin = new Thickness(12, 0, 0, 6);
            compactTasks.Children.Add(warning);
        }
        dots.Visibility = visible.Length > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (visible.Length > 1) for (int i = 0; i < visible.Length; i++) AddDot(i, visible[i]);
        int remaining = Math.Max(0, samples.Count - 3);
        compactMore.Visibility = remaining > 0 ? Visibility.Visible : Visibility.Collapsed;
        compactMore.Text = CompactMoreText(remaining, options.Language);
        if (compact) window.Height = CompactHeight();
        if (focusedWarning is not null) RestoreWarningFocus(focusedWarning, oldTaskOffset, oldWarningOrder);
    }

    private static string CompactMoreText(int count, string language)
    {
        if (count <= 0) return "";
        if (language == "en") return $"{count} more {(count == 1 ? "task" : "tasks")}";
        int lastTwo = count % 100, last = count % 10;
        string word = lastTwo is >= 11 and <= 14 ? "задач"
            : last == 1 ? "задача" : last is >= 2 and <= 4 ? "задачи" : "задач";
        return $"Ещё {count} {word}";
    }

    private static IEnumerable<Button> DescendantButtons(DependencyObject root)
    {
        if (root is Button button) yield return button;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (Button child in DescendantButtons(VisualTreeHelper.GetChild(root, i))) yield return child;
    }

    private IEnumerable<Button> WarningButtons() => DescendantButtons(compact ? compactTasks : tasks)
        .Where(button => button.Tag is WarningFocusKey && button.IsVisible && button.IsEnabled);

    private void RestoreWarningFocus(string taskId, double previousOffset, IReadOnlyList<string> oldOrder)
    {
        Button[] remaining = WarningButtons().ToArray();
        Button? target = remaining.FirstOrDefault(button => ((WarningFocusKey)button.Tag).TaskId == taskId);
        bool movedToAnotherAction = target is null;
        if (target is null && remaining.Length > 0)
        {
            int oldIndex = oldOrder.ToList().IndexOf(taskId);
            if (oldIndex >= 0)
            {
                IEnumerable<string> neighbors = oldOrder.Skip(oldIndex + 1).Concat(oldOrder.Take(oldIndex).Reverse());
                foreach (string neighbor in neighbors)
                {
                    target = remaining.FirstOrDefault(button => ((WarningFocusKey)button.Tag).TaskId == neighbor);
                    if (target is not null) break;
                }
            }
            int removedIndex = samples.FindIndex(task => task.Id == taskId);
            target ??= remaining.OrderBy(button =>
            {
                int index = samples.FindIndex(task => task.Id == ((WarningFocusKey)button.Tag).TaskId);
                return index >= removedIndex ? index - removedIndex : samples.Count + removedIndex - index;
            }).First();
        }
        if (target is null && compact && dots.Visibility == Visibility.Visible)
        {
            int selected = samples.Take(3).ToList().FindIndex(task => task.Id == compactSelection);
            if (selected >= 0 && selected < dots.Children.Count) target = dots.Children[selected] as Button;
        }
        target ??= tabs.Children.OfType<Button>().FirstOrDefault(button => button.IsVisible && (string)button.Tag == selectedProvider);
        Button settings = Find<Button>("SettingsFooterButton");
        if (target is null && settings.IsVisible && settings.IsEnabled && settings.Focusable) target = settings;
        target ??= Find<Button>(compact ? "ExpandButton" : "MinimizeButton");
        target.Focus();
        if (movedToAnotherAction) target.BringIntoView();
        else if (!compact) tasksScroll.ScrollToVerticalOffset(previousOffset);
    }

    private void SizeTabs()
    {
        if (!equalProviderWidths || tabs.Children.Count != 3 || tabsHost.ActualWidth <= 0) return;
        double width = Math.Max(0, tabsHost.ActualWidth - 8 - 8) / 3;
        foreach (Button button in tabs.Children) button.Width = width;
    }

    private double CompactHeight()
    {
        int warningCount = (claudeSourceUnavailable ? 1 : 0) + (cloudEnabled && cloudUnavailable ? 1 : 0);
        if (samples.Count == 0) return 132 + Math.Max(0, warningCount - 1) * 20;
        var selected = samples.FirstOrDefault(task => task.Id == compactSelection);
        return 162 + (samples.Count > 1 ? 18 : 0) + (samples.Count > 3 ? 20 : 0) +
            (samples.Select(task => task.Provider).Distinct(StringComparer.Ordinal).Skip(1).Any() ? 18 : 0) +
            (selected is not null && PlanNote(selected).Length > 0 ? 20 : 0) + warningCount * 20 +
            (selected is not null && WarningFor(selected) is not null ? 72 : 0);
    }

    private void AddTab(string id, string label, int count)
    {
        var button = new Button { Style = (Style)window.Resources["ProviderTabStyle"], Tag = id };
        bool selected = selectedProvider == id;
        Brush foreground = ColorFor("Primary");
        var surface = new Grid();
        var shape = new ShapePath { Fill = selected ? ColorFor("Surface") : Brushes.Transparent, IsHitTestVisible = false };
        surface.Children.Add(shape);
        var content = new Grid { HorizontalAlignment = HorizontalAlignment.Center };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Text(label, 13, "Secondary", true); title.Foreground = foreground; title.VerticalAlignment = VerticalAlignment.Center; title.TextWrapping = TextWrapping.NoWrap;
        var number = Text(count.ToString(), 11.5, "Secondary", true); number.Foreground = foreground; number.Margin = new Thickness(3, -5, 0, 0); number.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(number, 1); content.Children.Add(title); content.Children.Add(number);
        surface.Children.Add(new Border { Padding = new Thickness(13, 0, 13, 0), Child = content });
        button.Content = surface;
        button.SizeChanged += (_, _) => shape.Data = TabContour.Create(button.ActualWidth, button.ActualHeight, 10);
        button.GotKeyboardFocus += (_, _) => button.BringIntoView();
        button.MouseEnter += (_, _) => { if (selectedProvider != id) shape.Fill = ColorFor("Hover"); };
        button.MouseLeave += (_, _) => { if (selectedProvider != id) shape.Fill = Brushes.Transparent; };
        AutomationProperties.SetAutomationId(button, "SampleProvider-" + id);
        AutomationProperties.SetName(button, options.Language == "en" ? $"Show tasks: {label}, {count}" : $"Показать задачи: {label}, {count}");
        button.Click += (_, _) => { selectedProvider = id; Render(); tabsHost.UpdateLayout(); UpdateShapes(); };
        tabs.Children.Add(button);
    }

    private FrameworkElement Indicator(bool active)
    {
        var track = new Canvas { Width = 16, Height = 4, ClipToBounds = true, IsHitTestVisible = false,
            Margin = new Thickness(0, 7, 6, 0), VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left };
        track.Children.Add(new ShapePath { Width = 16, Height = 4, Stretch = Stretch.None,
            Data = new RectangleGeometry(new Rect(0, 0, 4, 4), 2, 2), Fill = active ? AccentBrush : ColorFor("Muted") });
        return track;
    }

    private Grid ActivityRow(SampleTask task, bool isCompact)
    {
        var row = new Grid { Margin = isCompact ? new Thickness(12, 2, 0, 0) : new Thickness(0, 5, 14, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (!string.IsNullOrEmpty(task.Activity)) row.Children.Add(Indicator(task.Active));
        var activity = Text(task.Activity, isCompact ? 11.5 : 12, "Activity");
        activity.TextTrimming = TextTrimming.CharacterEllipsis;
        if (isCompact) activity.TextWrapping = TextWrapping.NoWrap;
        else { activity.MaxWidth = 390; activity.HorizontalAlignment = HorizontalAlignment.Left; activity.Height = activity.MaxHeight = 34; }
        Grid.SetColumn(activity, 1); row.Children.Add(activity);
        return row;
    }

    private void AddCard(SampleTask task)
    {
        var card = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        if (task.Steps.Length > 0) card.Height = (showProviderLabels ? 278 : 258) + (WarningFor(task) is null ? 0 : 64);
        var shape = new ShapePath { Fill = ColorFor("Raised"), Stroke = ColorFor(task.Active ? "CardBorder" : "Border"), StrokeThickness = 1, IsHitTestVisible = false };
        card.SizeChanged += (_, _) => shape.Data = Squircle.Create(card.ActualWidth, card.ActualHeight, 12, 0.5);
        card.Children.Add(shape);
        var stack = new StackPanel();
        if (showProviderLabels)
        {
            var provider = Text(task.ProviderName, 11.5, "Primary", true); provider.Foreground = AccentBrush; provider.Margin = new Thickness(0, 0, 0, 3); stack.Children.Add(provider);
        }
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titleStack = new StackPanel();
        var title = Text(task.Title, 16, "Primary", true); title.Margin = new Thickness(0, 0, 14, 0); title.Height = 22; title.MaxWidth = 390; title.HorizontalAlignment = HorizontalAlignment.Left; title.TextWrapping = TextWrapping.NoWrap; title.TextTrimming = TextTrimming.CharacterEllipsis;
        titleStack.Children.Add(title); titleStack.Children.Add(ActivityRow(task, false));
        var progress = Text(Progress(task), 16, "Primary", true); progress.Height = 22; progress.VerticalAlignment = VerticalAlignment.Top; Grid.SetColumn(progress, 1);
        header.Children.Add(titleStack); header.Children.Add(progress); stack.Children.Add(header);
        AddLoopWarning(stack, task, false);
        if (task.Progress.HasValue && (task.Provider != "claude" || (task.PlanConfirmed && task.Status != "unknown")))
            stack.Children.Add(new ProgressBar { Maximum = 100, Value = task.Progress.Value, Margin = new Thickness(0, 14, 0, 0) });
        if (task.Steps.Length > 0)
        {
            AddSteps(stack, task);
            string label = PlanNote(task);
            if (label.Length == 0) label = options.Language == "en" ? "Task plan" : "План задачи";
            string meta = $"{label} · {task.Steps.Length} {StepCountWord(options.Language, task.Steps.Length)}";
            if (!string.IsNullOrEmpty(task.UpdatedText)) meta += " · " + task.UpdatedText;
            var footer = Text(meta, 11.5, "Muted"); footer.Margin = new Thickness(0, 11, 0, 0); stack.Children.Add(footer);
        }
        card.Children.Add(new Border { Padding = new Thickness(16, 15, 16, 14), Child = stack });
        tasks.Children.Add(card);
    }

    private void AddLoopWarning(Panel container, SampleTask task, bool compactLayout)
    {
        LoopWarningView? warning = WarningFor(task);
        if (warning is null) return;
        var row = new Grid { Margin = compactLayout ? new Thickness(12, 6, 0, 0) : new Thickness(0, 8, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        string message = options.Language == "en"
            ? $"Possible loop: one command failed with the same code at least {warning.Threshold} times in {warning.WindowMinutes} min."
            : $"Возможный цикл: одна команда завершилась с одинаковым кодом ошибки не менее {warning.Threshold} раз за {warning.WindowMinutes} мин.";
        var label = Text(message, compactLayout ? 11.5 : 12, "Secondary");
        label.TextWrapping = TextWrapping.Wrap;
        label.Margin = new Thickness(0, 0, 8, 0);
        AutomationProperties.SetName(label, message);
        var dismiss = new Button { Content = options.Language == "en" ? "Hide" : "Скрыть", Tag = new WarningFocusKey(task.Id), Style = (Style)window.Resources["SourceActionStyle"],
            FontSize = 11.5, VerticalAlignment = VerticalAlignment.Top, FocusVisualStyle = (Style)window.Resources["KeyboardFocusStyle"] };
        AutomationProperties.SetName(dismiss, (options.Language == "en" ? "Hide possible loop warning for task: " : "Скрыть предупреждение о возможном цикле для задачи: ") + task.Title);
        dismiss.Click += (_, _) =>
        {
            bool dismissed;
            try { dismissed = dismissLoopWarning is not null && dismissLoopWarning(task.Id); }
            catch (Exception) { dismissed = false; }
            if (dismissed) { loopWarnings.Remove(task.Id); Render(); }
        };
        Grid.SetColumn(dismiss, 1);
        row.Children.Add(label); row.Children.Add(dismiss); container.Children.Add(row);
    }

    internal static string StepCountWord(string language, int count)
    {
        if (language == "en") return count == 1 ? "step" : "steps";
        int lastHundred = Math.Abs(count % 100), lastDigit = Math.Abs(count % 10);
        if (lastHundred is >= 11 and <= 14) return "этапов";
        return lastDigit == 1 ? "этап" : lastDigit is >= 2 and <= 4 ? "этапа" : "этапов";
    }

    private void AddSteps(Panel container, SampleTask task)
    {
        var scroll = new ScrollViewer { Height = 110, Margin = new Thickness(0, 11, 0, 0), VerticalScrollBarVisibility = task.Steps.Length > 5 ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var rail = new StackPanel();
        for (int i = 0; i < task.Steps.Length; i++)
        {
            var row = new Grid { Height = 22 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var marker = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(7), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
            bool showStatus = task.Provider != "claude" || (task.PlanConfirmed && task.Status != "unknown");
            bool done = showStatus && task.Steps[i].Status == "done", current = showStatus && task.Steps[i].Status == "active";
            if (done)
            {
                marker.Background = ColorFor("Raised");
                marker.Child = new ShapePath { Data = Geometry.Parse("M 2,7 L 5.2,10 L 11.5,3.5"), Width = 11, Height = 9, Stretch = Stretch.Uniform, Stroke = AccentBrush, StrokeThickness = 1.5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            }
            else if (current) marker.Background = AccentBrush;
            else { marker.Background = ColorFor("Surface"); marker.BorderBrush = ColorFor("Muted"); marker.BorderThickness = new Thickness(1); }
            var label = Text(task.Steps[i].Title, 13, current ? "Primary" : done ? "Done" : "Pending", current);
            label.Margin = new Thickness(4, 0, 0, 0); label.TextWrapping = TextWrapping.NoWrap; label.TextTrimming = TextTrimming.CharacterEllipsis; label.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(label, 1); row.Children.Add(marker); row.Children.Add(label); rail.Children.Add(row);
        }
        scroll.Content = rail;
        int focus = Array.FindIndex(task.Steps, step => step.Status == "active");
        if (focus < 0) focus = Array.FindIndex(task.Steps, step => step.Status == "pending");
        if (focus < 0) focus = Math.Max(0, task.Steps.Length - 2);
        scroll.Loaded += (_, _) => scroll.ScrollToVerticalOffset(focus * 22);
        container.Children.Add(scroll);
    }

    private void AddCompactTask(SampleTask task)
    {
        if (showProviderLabels)
        {
            var provider = Text(task.ProviderName, 10.5, "Primary", true); provider.Foreground = AccentBrush; provider.Margin = new Thickness(12, 0, 0, 2); compactTasks.Children.Add(provider);
        }
        var container = new Grid { Margin = new Thickness(0, 0, 0, 10) };
        for (int i = 0; i < 4; i++) container.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = new Grid(); header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) }); header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Text(task.Title, 16, "Primary", true); title.TextWrapping = TextWrapping.NoWrap; title.TextTrimming = TextTrimming.CharacterEllipsis; title.Margin = new Thickness(0, 0, 10, 0); Grid.SetColumn(title, 1);
        var progress = Text(Progress(task), 16, "Primary", true); progress.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(progress, 2);
        header.Children.Add(title); header.Children.Add(progress); container.Children.Add(header);
        var row = ActivityRow(task, true); Grid.SetRow(row, 1); container.Children.Add(row);
        string planNote = PlanNote(task);
        if (planNote.Length > 0 || WarningFor(task) is not null)
        {
            var notes = new StackPanel();
            if (planNote.Length > 0)
            {
                var note = Text(planNote, 11.5, "Muted");
                note.Margin = new Thickness(12, 4, 0, 0); notes.Children.Add(note);
            }
            AddLoopWarning(notes, task, true);
            Grid.SetRow(notes, 2); container.Children.Add(notes);
        }
        if (task.Progress.HasValue && (task.Provider != "claude" || (task.PlanConfirmed && task.Status != "unknown")))
        {
            var bar = new ProgressBar { Maximum = 100, Value = task.Progress.Value, Height = 2, Margin = new Thickness(12, 7, 0, 0) }; Grid.SetRow(bar, 3); container.Children.Add(bar);
        }
        compactTasks.Children.Add(container);
    }

    private void AddDot(int index, SampleTask task)
    {
        var dot = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = task.Id == compactSelection ? AccentBrush : ColorFor("Scroll") };
        var button = new Button { Style = (Style)window.Resources["CompactDotStyle"], Content = dot };
        AutomationProperties.SetAutomationId(button, "SampleTask-" + index);
        AutomationProperties.SetName(button, (options.Language == "en" ? "Show task: " : "Показать задачу: ") + task.Title);
        button.Click += (_, _) => { compactSelection = task.Id; Render(); };
        dots.Children.Add(button);
    }
}

