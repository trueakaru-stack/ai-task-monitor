using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ShapePath = System.Windows.Shapes.Path;

namespace AITaskMonitor.Prototype;

// This isolated preview uses synthetic data and the published WPF layout only.
internal sealed class PrototypeWindow
{
    private readonly Window window;
    private readonly Options options;
    private readonly Border frame;
    private readonly ShapePath outline;
    private readonly Grid expanded;
    private readonly Grid compactView;
    private readonly Grid tabsHost;
    private readonly ShapePath tabsShape;
    private readonly StackPanel tabs;
    private readonly StackPanel tasks;
    private readonly StackPanel compactTasks;
    private readonly StackPanel dots;
    private readonly TextBlock compactMore;
    private readonly ScrollViewer tasksScroll;
    private readonly ScrollBar tasksScrollBar;
    private readonly IReadOnlyDictionary<string, string> palette;
    private readonly Color accent = SystemParameters.WindowGlassColor;
    private string selectedProvider = "all";
    private string compactSelection = "";
    private bool compact;
    private readonly SyntheticProviderScenarios? scenario;
    private List<SampleTask> samples = [];
    private readonly Dictionary<string, long> taskPriority = new(StringComparer.Ordinal);
    private long taskPriorityCounter;
    private bool showProviderLabels;

    public PrototypeWindow(Window window, Options options)
    {
        this.window = window;
        this.options = options;
        frame = Find<Border>("WindowFrame");
        outline = Find<ShapePath>("WindowOutline");
        expanded = Find<Grid>("ExpandedView");
        compactView = Find<Grid>("CompactView");
        tabsHost = Find<Grid>("ProviderTabsHost");
        tabsShape = Find<ShapePath>("ProviderTabsShape");
        tabs = Find<StackPanel>("ProviderTabsPanel");
        tasks = Find<StackPanel>("TasksPanel");
        compactTasks = Find<StackPanel>("CompactTasksPanel");
        dots = Find<StackPanel>("CompactDotsPanel");
        compactMore = Find<TextBlock>("CompactMoreText");
        tasksScroll = Find<ScrollViewer>("TasksScroll");
        tasksScrollBar = Find<ScrollBar>("TasksScrollBar");

        palette = options.Theme == "light" ? LightPalette : DarkPalette;
        ApplyPalette();
        ApplyIcon();
        if (options.Language == "en") TranslateVisibleStaticText(window);

        frame.SizeChanged += (_, _) => UpdateShapes();
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
        // Settings, integrations and other application features are not part of this prototype.
        Find<Button>("SettingsFooterButton").IsHitTestVisible = false;
        Find<Button>("SettingsFooterButton").Focusable = false;
        if (options.Scene == "active")
        {
            samples = LegacySamples();
            compactSelection = samples[0].Id;
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

    private static List<SampleTask> LegacySamples()
    {
        static SampleTask Task(string id, string name, string title, string activity, int progress, int active, string[] steps)
        {
            var result = steps.Select((text, index) => new SampleStep(text,
                index < active - 1 ? "done" : index == active - 1 ? "active" : "pending")).ToArray();
            return new SampleTask(id, id, name, title, activity, "active", progress, result, true, "18:09",
                DateTimeOffset.MinValue, id, DateTimeOffset.MinValue);
        }
        return
        [
            Task("codex", "Codex", "Создать индикатор прогресса задач",
                "Проверяю карточки планов, переключение источников и прокрутку этапов перед публикацией новой версии, светлую тему и поведение длинных описаний",
                50, 5,
                ["Синхронизировать список задач", "Восстановить карточки планов", "Исправить прокрутку этапов", "Применить системный акцент", "Проверить скругления и фокус", "Снять тёмный и светлый экран", "Провести финальную проверку", "Опубликовать исходники"]),
            Task("claude", "Claude Code", "Задача Claude Code", "Запускаю визуальную проверку", 33, 3,
                ["Проверить локальное окружение", "Подготовить тестовые данные", "Запустить визуальную проверку", "Проверить светлую тему", "Зафиксировать результат", "Очистить временные данные"])
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

    internal string SelectedTaskId => compactSelection;
    internal string SelectedProvider => selectedProvider;
    internal IReadOnlyList<SampleTask> CurrentTasks => samples;

    internal void AdvanceMultiForTest()
    {
        if (scenario is null) throw new InvalidOperationException("A synthetic scenario is required.");
        scenario.AdvanceMulti();
        UpdateSamples(scenario.Snapshot().Select(state => ProviderPresentation.Map(state, options.Language)).ToList());
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

    private static void TranslateVisibleStaticText(DependencyObject root)
    {
        if (root is TextBlock text)
        {
            if (text.Text == "Ход выполнения") text.Text = "Progress";
            else if (text.Text == "Настройки") text.Text = "Settings";
        }
        string name = AutomationProperties.GetName(root);
        string translated = name switch
        {
            "Свернуть в панель задач" => "Minimize to taskbar", "Компактный режим" => "Compact view",
            "Закрыть" => "Close", "Открыть настройки" => "Open settings", "Развернуть" => "Expand", _ => name
        };
        if (translated != name) AutomationProperties.SetName(root, translated);
        foreach (object child in LogicalTreeHelper.GetChildren(root))
            if (child is DependencyObject element) TranslateVisibleStaticText(element);
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
            tabsShape.Data = Squircle.Create(tabsHost.ActualWidth, tabsHost.ActualHeight, 12);
            tabsHost.Clip = Squircle.Create(tabsHost.ActualWidth, tabsHost.ActualHeight, 12);
        }
    }

    private void SetCompact(bool value)
    {
        if (compact == value) return;
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
    }

    private TextBlock Text(string value, double size, string color, bool semiBold = false) => new()
    {
        Text = value, FontFamily = new FontFamily("Segoe UI Variable Text"), FontSize = size,
        Foreground = ColorFor(color), FontWeight = semiBold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap, LineHeight = size * 1.35
    };

    private string Title(SampleTask task) => options.Language == "en" && task.Provider == "claude" ? "Claude Code task" : task.Title;
    private string Progress(SampleTask task)
    {
        if (task.Steps.Length == 0 || !task.PlanConfirmed || task.Status == "unknown") return "";
        int[] active = task.Steps.Select((step, index) => (step, index)).Where(item => item.step.Status == "active").Select(item => item.index + 1).ToArray();
        if (active.Length == 1) return options.Language == "en" ? $"Step {active[0]} of {task.Steps.Length}" : $"Этап {active[0]} из {task.Steps.Length}";
        int done = task.Steps.Count(step => step.Status == "done");
        return options.Language == "en" ? $"Done {done} of {task.Steps.Length}" : $"Готово {done} из {task.Steps.Length}";
    }

    private static readonly (string Id, string Name)[] ProviderOrder =
    [ ("codex", "Codex"), ("claude", "Claude Code"), ("kimi", "Kimi Code"),
      ("deepseek", "DeepSeek Harness"), ("hermes", "Hermes Agent"), ("opencode", "OpenCode") ];

    private void Render()
    {
        tasks.Children.Clear(); tabs.Children.Clear(); compactTasks.Children.Clear(); dots.Children.Clear();
        var providers = samples.Select(task => task.Provider).Distinct(StringComparer.Ordinal).ToHashSet(StringComparer.Ordinal);
        showProviderLabels = providers.Count >= 2;
        tabsHost.Visibility = showProviderLabels ? Visibility.Visible : Visibility.Collapsed;
        if (selectedProvider != "all" && !providers.Contains(selectedProvider)) selectedProvider = "all";
        if (samples.Count == 0)
        {
            string text = options.Language == "en" ? "No active tasks" : "Активных задач сейчас нет";
            var empty = Text(text, 14, "Secondary"); empty.Margin = new Thickness(4, 24, 0, 0); tasks.Children.Add(empty);
            var compactEmpty = Text(text, 12.5, "Activity"); compactEmpty.Margin = new Thickness(0, 5, 0, 5); compactTasks.Children.Add(compactEmpty);
            dots.Visibility = Visibility.Collapsed;
            compactMore.Visibility = Visibility.Collapsed;
            if (compact) window.Height = CompactHeight();
            return;
        }
        if (showProviderLabels)
        {
            AddTab("all", options.Language == "en" ? "All" : "Все", samples.Count(task => task.Active));
            foreach (var provider in ProviderOrder.Where(provider => providers.Contains(provider.Id)))
                AddTab(provider.Id, provider.Name, samples.Count(task => task.Active && task.Provider == provider.Id));
            tabs.Children[^1].SetValue(FrameworkElement.MarginProperty, new Thickness(0));
        }
        foreach (SampleTask task in samples.Where(t => selectedProvider == "all" || t.Provider == selectedProvider)) AddCard(task);
        SampleTask[] visible = samples.Take(3).ToArray();
        if (!visible.Any(task => task.Id == compactSelection)) compactSelection = visible[0].Id;
        AddCompactTask(visible.First(task => task.Id == compactSelection));
        dots.Visibility = visible.Length > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (visible.Length > 1) for (int i = 0; i < visible.Length; i++) AddDot(i, visible[i]);
        int remaining = Math.Max(0, samples.Count - 3);
        compactMore.Visibility = remaining > 0 ? Visibility.Visible : Visibility.Collapsed;
        compactMore.Text = remaining > 0 ? (options.Language == "en" ? $"{remaining} more tasks" : $"Ещё {remaining} задач") : "";
        if (compact) window.Height = CompactHeight();
    }

    private double CompactHeight()
    {
        if (samples.Count == 0) return 132;
        var selected = samples.FirstOrDefault(task => task.Id == compactSelection);
        return 162 + (samples.Count > 1 ? 18 : 0) + (samples.Count > 3 ? 20 : 0) +
            (samples.Select(task => task.Provider).Distinct(StringComparer.Ordinal).Skip(1).Any() ? 18 : 0) +
            (selected is not null && selected.Steps.Length > 0 && !selected.PlanConfirmed ? 20 : 0);
    }

    private void AddTab(string id, string label, int count)
    {
        var button = new Button { Style = (Style)window.Resources["ProviderTabStyle"], Tag = id };
        bool selected = selectedProvider == id;
        Brush foreground = selected ? AccentText : ColorFor("Secondary");
        var surface = new Grid();
        var shape = new ShapePath { Fill = selected ? AccentBrush : Brushes.Transparent, IsHitTestVisible = false };
        surface.Children.Add(shape);
        var content = new Grid();
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = Text(label, 13, "Secondary", true); title.Foreground = foreground; title.VerticalAlignment = VerticalAlignment.Center; title.TextWrapping = TextWrapping.NoWrap;
        var number = Text(count.ToString(), 11.5, "Secondary", true); number.Foreground = foreground; number.Margin = new Thickness(3, -5, 0, 0); number.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(number, 1); content.Children.Add(title); content.Children.Add(number);
        surface.Children.Add(new Border { Padding = new Thickness(13, 0, 13, 0), Child = content });
        button.Content = surface;
        button.SizeChanged += (_, _) => shape.Data = Squircle.Create(button.ActualWidth, button.ActualHeight, 9);
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
        if (task.Steps.Length > 0) card.Height = showProviderLabels ? 278 : 258;
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
        var title = Text(Title(task), 16, "Primary", true); title.Margin = new Thickness(0, 0, 14, 0); title.Height = 22; title.MaxWidth = 390; title.HorizontalAlignment = HorizontalAlignment.Left; title.TextWrapping = TextWrapping.NoWrap; title.TextTrimming = TextTrimming.CharacterEllipsis;
        titleStack.Children.Add(title); titleStack.Children.Add(ActivityRow(task, false));
        var progress = Text(Progress(task), 16, "Primary", true); progress.Height = 22; progress.VerticalAlignment = VerticalAlignment.Top; Grid.SetColumn(progress, 1);
        header.Children.Add(titleStack); header.Children.Add(progress); stack.Children.Add(header);
        if (task.Progress.HasValue) stack.Children.Add(new ProgressBar { Maximum = 100, Value = task.Progress.Value, Margin = new Thickness(0, 14, 0, 0) });
        if (task.Steps.Length > 0)
        {
            AddSteps(stack, task);
            string label = options.Language == "en" ? (task.PlanConfirmed ? "Task plan" : "Plan unconfirmed") : (task.PlanConfirmed ? "План задачи" : "План не подтверждён");
            string meta = options.Language == "en" ? $"{label} · {task.Steps.Length} steps" : $"{label} · {task.Steps.Length} этапов";
            if (!string.IsNullOrEmpty(task.UpdatedText)) meta += " · " + task.UpdatedText;
            var footer = Text(meta, 11.5, "Muted"); footer.Margin = new Thickness(0, 11, 0, 0); stack.Children.Add(footer);
        }
        card.Children.Add(new Border { Padding = new Thickness(16, 15, 16, 14), Child = stack });
        tasks.Children.Add(card);
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
            bool done = task.Steps[i].Status == "done", current = task.Steps[i].Status == "active";
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
        var title = Text(Title(task), 16, "Primary", true); title.TextWrapping = TextWrapping.NoWrap; title.TextTrimming = TextTrimming.CharacterEllipsis; title.Margin = new Thickness(0, 0, 10, 0); Grid.SetColumn(title, 1);
        var progress = Text(Progress(task), 16, "Primary", true); progress.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(progress, 2);
        header.Children.Add(title); header.Children.Add(progress); container.Children.Add(header);
        var row = ActivityRow(task, true); Grid.SetRow(row, 1); container.Children.Add(row);
        if (task.Steps.Length > 0 && !task.PlanConfirmed)
        {
            var note = Text(options.Language == "en" ? "Plan unconfirmed" : "План не подтверждён", 11.5, "Muted");
            note.Margin = new Thickness(12, 4, 0, 0); Grid.SetRow(note, 2); container.Children.Add(note);
        }
        if (task.Progress.HasValue)
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
        AutomationProperties.SetName(button, (options.Language == "en" ? "Show task: " : "Показать задачу: ") + Title(task));
        button.Click += (_, _) => { compactSelection = task.Id; Render(); };
        dots.Children.Add(button);
    }
}
