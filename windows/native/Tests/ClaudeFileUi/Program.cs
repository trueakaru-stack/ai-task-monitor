using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AITaskMonitor.Claude;
using AITaskMonitor.Prototype;

internal static class Program
{
    private static int checks;
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 0) throw new ArgumentException("This test accepts no external input.");
            string work = Directory.CreateTempSubdirectory("aitm-claude-file-ui-").FullName;
            string fixture = Path.Combine(AppContext.BaseDirectory, "status-retention.synthetic.json");
            using JsonDocument json = JsonDocument.Parse(File.ReadAllText(fixture));
            string events = json.RootElement.GetProperty("complete").GetString()!;
            string suffix = json.RootElement.GetProperty("suffix").GetString()!;
            DateTime now = DateTime.Parse(json.RootElement.GetProperty("now").GetString()!, null, System.Globalization.DateTimeStyles.AdjustToUniversal);
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            CheckPump(work, events, now);
            Console.WriteLine($"Background pump checks passed: {checks}.");
            foreach (string language in new[] { "ru", "en" })
                foreach (string theme in new[] { "dark", "light" })
                {
                    CheckFlow(work, events, suffix, now, language, theme);
                    CheckEmptyWarning(work, language, theme);
                }
            app.Shutdown();
            Console.WriteLine($"Claude file-to-WPF flow: {checks} synthetic checks passed.");
            Console.WriteLine($"Synthetic output: {work}");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static void CheckEmptyWarning(string work, string language, string theme)
    {
        using Stream layout = typeof(PrototypeWindow).Assembly.GetManifestResourceStream("AITaskMonitor.Prototype.PublishedWindow.xaml")!;
        var window = (Window)XamlReader.Load(layout);
        var controller = new PrototypeWindow(window, new Options(theme, language, "empty", false, true, null, null, false));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        try
        {
            controller.ApplyClaudeSource(new ClaudeSourceSnapshot([], true));
            window.UpdateLayout();
            string warning = language == "en" ? "No data from Claude Code" : "Нет данных от Claude Code";
            string empty = language == "en" ? "No active tasks" : "Активных задач сейчас нет";
            Check(Visible<TextBlock>(window).Any(x => x.Text == warning) && !Visible<TextBlock>(window).Any(x => x.Text == empty), "Empty source failure must not look like a clean empty state");
            Capture(window, Path.Combine(work, $"{language}-{theme}-empty-warning-expanded.png"));
            ((Button)window.FindName("MinimizeButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(x => x.Text == warning), "Compact empty source warning missing");
            Capture(window, Path.Combine(work, $"{language}-{theme}-empty-warning-compact.png"));
        }
        finally { window.Close(); }
    }

    private static void CheckPump(string work, string events, DateTime now)
    {
        string eventPath = Path.Combine(work, "pump.jsonl");
        File.WriteAllText(eventPath, events, new UTF8Encoding(false));
        var source = new ClaudeFileSource(eventPath, null, DateTime.MinValue.ToUniversalTime());
        using var entered = new ManualResetEventSlim(false);
        using var release = new ManualResetEventSlim(false);
        int reads = 0, applied = 0;
        ClaudeSourceSnapshot? last = null;
        Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
        using Stream layout = typeof(PrototypeWindow).Assembly.GetManifestResourceStream("AITaskMonitor.Prototype.PublishedWindow.xaml")!;
        var window = (Window)XamlReader.Load(layout);
        var controller = new PrototypeWindow(window, new Options("dark", "ru", "active", false, true, null, null, false));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        try
        {
        using var pump = new ClaudeSourcePump(dispatcher, source, ClaudeConnection.Connected,
            snapshot => { Check(dispatcher.CheckAccess(), "Snapshot applied off UI dispatcher"); controller.ApplyClaudeSource(snapshot); last = snapshot; applied++; }, () =>
        {
            if (Interlocked.Increment(ref reads) == 1)
            {
                entered.Set();
                if (!release.Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException("Synthetic reader did not resume.");
            }
            return now;
        }, TimeSpan.FromSeconds(30));
        pump.Start();
        WaitUntil(() => entered.IsSet, "Background read did not start");
        pump.NotifyConnection(ClaudeConnection.Disconnected);
        Check(applied == 1 && last is { Unavailable: false } && last.Tasks.Count == 0,
            "Disconnect did not immediately hide the stale Claude snapshot");
        release.Set();
        WaitUntil(() => applied >= 2, "Refreshed snapshot did not arrive");
        Check(last is { Unavailable: false } && last.Tasks.Count == 0,
            "An outdated connected snapshot appeared after disconnect");
        Check(reads >= 2, "Explicit refresh did not trigger a new read");
        Check(controller.CurrentTasks.Count == 1 && controller.CurrentTasks.Single().Provider == "codex", "Disconnect must retain only the unrelated task");
        pump.NotifyConnection(ClaudeConnection.Connected);
        WaitUntil(() => applied >= 3, "Connected file snapshot did not reach the window");
        Check(controller.CurrentTasks.Count == 2 && controller.CurrentTasks.Single(x => x.Provider == "claude") is { Status: "unknown", PlanConfirmed: false } &&
            controller.CurrentTasks.Single(x => x.Provider == "claude").Steps.Length == 2,
            "Reconnected Claude steps must remain unconfirmed");
        pump.Dispose();
        bool rejected = false;
        try { pump.RequestRefresh(); } catch (ObjectDisposedException) { rejected = true; }
        Check(rejected, "Disposed pump accepted a refresh");
        }
        finally { window.Close(); }
    }

    private static void WaitUntil(Func<bool> condition, string message)
    {
        var frame = new DispatcherFrame();
        DateTime deadline = DateTime.UtcNow.AddSeconds(5);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
        timer.Tick += (_, _) => { if (condition() || DateTime.UtcNow >= deadline) frame.Continue = false; };
        timer.Start();
        Dispatcher.PushFrame(frame);
        timer.Stop();
        if (!condition()) throw new InvalidOperationException(message);
    }

    private static void CheckFlow(string work, string events, string suffix, DateTime now, string language, string theme)
    {
        string prefix = $"{language}-{theme}";
        string eventPath = Path.Combine(work, prefix + ".jsonl");
        File.WriteAllText(eventPath, events, new UTF8Encoding(false));
        var source = new ClaudeFileSource(eventPath, null, DateTime.MinValue.ToUniversalTime());
        Assembly assembly = typeof(PrototypeWindow).Assembly;
        using Stream layout = assembly.GetManifestResourceStream("AITaskMonitor.Prototype.PublishedWindow.xaml")!;
        var window = (Window)XamlReader.Load(layout);
        var controller = new PrototypeWindow(window, new Options(theme, language, "active", false, true, null, null, false));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        try
        {
            controller.ApplyClaudeSource(source.Poll(ClaudeConnection.Connected, now));
            window.UpdateLayout();
            Check(controller.CurrentTasks.Count == 2 && controller.CurrentTasks.Any(x => x.Provider == "codex"), "Neighboring Codex task lost");
            SampleTask claude = controller.CurrentTasks.Single(x => x.Provider == "claude");
            Check(claude.Steps.Length == 2 && claude.PlanConfirmed && claude.Progress == 50, "Known steps not displayed");
            string note = language == "en" ? "Based on observed steps; may be inaccurate" : "По известным этапам, возможна неточность";
            Check(Visible<TextBlock>(window).Any(x => x.Text.StartsWith(note, StringComparison.Ordinal)), "Known-step qualification missing");
            Capture(window, Path.Combine(work, prefix + "-confirmed-expanded.png"));

            File.Delete(eventPath);
            controller.ApplyClaudeSource(source.Poll(ClaudeConnection.Connected, now));
            window.UpdateLayout();
            claude = controller.CurrentTasks.Single(x => x.Provider == "claude");
            Check(claude.Status == "unknown" && !claude.PlanConfirmed && claude.Progress is null && claude.Steps.Length == 2, "Source loss must keep names without confirmed progress");
            CheckTabCounts(window, language, 2, 1, 1);
            string warning = language == "en" ? "No data from Claude Code" : "Нет данных от Claude Code";
            Check(Visible<TextBlock>(window).Any(x => x.Text == warning), "Source warning missing");
            Check(Visible<ProgressBar>(window).Count() == 1, "Only the unaffected Codex bar should remain");
            Capture(window, Path.Combine(work, prefix + "-loss-expanded.png"));
            ((Button)window.FindName("MinimizeButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(x => x.Text == warning), "Compact source warning missing");
            Capture(window, Path.Combine(work, prefix + "-loss-compact.png"));

            File.WriteAllText(eventPath, "", new UTF8Encoding(false));
            controller.ApplyClaudeSource(source.Poll(ClaudeConnection.Connected, now));
            claude = controller.CurrentTasks.Single(x => x.Provider == "claude");
            Check(claude.Status == "unknown" && !claude.PlanConfirmed && claude.Steps.Length == 2, "Empty recovered source lost names");
            Check(controller.CurrentTasks.Any(x => x.Provider == "codex" && x.Active), "Recovery affected neighboring task");

            File.WriteAllText(eventPath, suffix, new UTF8Encoding(false));
            controller.ApplyClaudeSource(source.Poll(ClaudeConnection.Connected, now.AddSeconds(2)));
            claude = controller.CurrentTasks.Single(x => x.Provider == "claude");
            Check(claude.Status == "unknown" && !claude.PlanConfirmed && claude.Progress is null &&
                  claude.Steps.Select(x => x.Title).SequenceEqual(new[] { "First step", "Second step", "Third step" }) &&
                  claude.Steps.All(x => x.Status == "unknown"), "New prompt after loss must retain known names without confirmed progress");
            window.UpdateLayout();
            string unconfirmedNote = language == "en" ? "Plan unconfirmed" : "План не подтверждён";
            Check(Visible<TextBlock>(window).Any(x => x.Text == unconfirmedNote), "Compact retained-plan note missing after a new prompt");
            Capture(window, Path.Combine(work, prefix + "-new-prompt-compact.png"));
            ((Button)window.FindName("ExpandButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();
            var visibleNames = Visible<TextBlock>(window).Select(x => x.Text).ToHashSet(StringComparer.Ordinal);
            Check(new[] { "First step", "Second step", "Third step" }.All(visibleNames.Contains) &&
                  visibleNames.Any(x => x.StartsWith(unconfirmedNote, StringComparison.Ordinal)), "Expanded view lost known names or the unconfirmed-plan note");
            Check(Visible<ProgressBar>(window).Count() == 1, "Unconfirmed Claude plan displayed a progress bar after a new prompt");
            CheckTabCounts(window, language, 2, 1, 1);
            Capture(window, Path.Combine(work, prefix + "-new-prompt-expanded.png"));
            ((Button)window.FindName("MinimizeButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();

            string boundedPath = Path.Combine(work, prefix + "-bounded.jsonl");
            var many = new StringBuilder();
            many.Append(JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "bounded", ["timestamp"] = now.AddMinutes(-1).ToString("O"), ["event"] = "UserPromptSubmit", ["active"] = true })).Append('\n');
            for (int i = 0; i < 129; i++)
                many.Append(JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "bounded", ["timestamp"] = now.AddSeconds(-30).AddMilliseconds(i).ToString("O"), ["event"] = "TaskCreated", ["active"] = true, ["task_id"] = i.ToString(), ["task_subject"] = "Synthetic " + i })).Append('\n');
            File.WriteAllText(boundedPath, many.ToString(), new UTF8Encoding(false));
            var boundedSource = new ClaudeFileSource(boundedPath, null, DateTime.MinValue.ToUniversalTime());
            _ = boundedSource.Poll(ClaudeConnection.Connected, now);
            File.Delete(boundedPath);
            _ = boundedSource.Poll(ClaudeConnection.Connected, now);
            File.WriteAllText(boundedPath, "", new UTF8Encoding(false));
            var boundedSnapshot = boundedSource.Poll(ClaudeConnection.Connected, now);
            Check(boundedSnapshot.Tasks.Single().RetainedPlanIncomplete && boundedSnapshot.Tasks.Single().Steps.Length == 128, "Bounded source did not report its truncated history");
            controller.ApplyClaudeSource(boundedSnapshot);
            window.UpdateLayout();
            string boundedNote = language == "en" ? "Plan unconfirmed; retained plan is incomplete" : "План не подтверждён, сохранён не полностью";
            Check(Visible<TextBlock>(window).Any(x => x.Text == boundedNote), "Compact retained-plan limit must be disclosed");
            Capture(window, Path.Combine(work, prefix + "-bounded-compact.png"));
            ((Button)window.FindName("ExpandButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(x => x.Text.StartsWith(boundedNote, StringComparison.Ordinal)), "Expanded retained-plan limit must be disclosed");
            Capture(window, Path.Combine(work, prefix + "-bounded-expanded.png"));
        }
        finally { window.Close(); }
    }

    private static void CheckTabCounts(Window window, string language, int total, int codex, int claude)
    {
        var tabs = ((StackPanel)window.FindName("ProviderTabsPanel")).Children.OfType<Button>()
            .ToDictionary(button => (string)button.Tag, StringComparer.Ordinal);
        string lead = language == "en" ? "Show tasks: " : "Показать задачи: ";
        string all = language == "en" ? "All" : "Все";
        foreach (var item in new[] { (Id: "all", Label: all, Count: total), (Id: "codex", Label: "Codex", Count: codex), (Id: "claude", Label: "Claude Code", Count: claude) })
        {
            Check(tabs.TryGetValue(item.Id, out Button? button), "A provider tab is missing");
            Check(AutomationProperties.GetName(button!) == $"{lead}{item.Label}, {item.Count}", "The accessible tab count differs from visible cards");
            Check(Visible<TextBlock>(button!).Any(text => text.Text == item.Count.ToString()), "The displayed tab count differs from visible cards");
        }
    }

    private static IEnumerable<T> Visible<T>(DependencyObject root) where T : FrameworkElement
    {
        if (root is FrameworkElement element && !element.IsVisible) yield break;
        if (root is T match) yield return match;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (T child in Visible<T>(VisualTreeHelper.GetChild(root, i))) yield return child;
    }

    private static void Capture(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        encoder.Save(stream);
    }

    private static void Check(bool condition, string message) { checks++; if (!condition) throw new InvalidOperationException(message); }
}
