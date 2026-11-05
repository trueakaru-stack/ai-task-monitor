using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using AITaskMonitor.Prototype;

internal static class Program
{
    private static int checks;

    [STAThread]
    private static int Main()
    {
        try
        {
            var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            foreach (string language in new[] { "ru", "en" })
                foreach (string theme in new[] { "dark", "light" })
                    foreach (string scene in SyntheticProviderScenarios.Names)
                        CheckScenario(scene, language, theme);
            CheckSelection();
            CheckLegacyDemoLanguage();
            CheckExternalTaskText();
            string? configuredContourReference = Environment.GetEnvironmentVariable("AITM_MAC_CONTOUR_REFERENCE");
            string contourReference = string.IsNullOrEmpty(configuredContourReference)
                ? Path.Combine(AppContext.BaseDirectory, "Fixtures", "macos-tab-paths.json")
                : configuredContourReference;
            ContourChecks.Run(contourReference);
            string? captureDirectory = Environment.GetEnvironmentVariable("AITM_TAB_CAPTURE_DIRECTORY");
            if (!string.IsNullOrEmpty(captureDirectory)) CaptureTabStates(captureDirectory);
            application.Shutdown();
            Console.WriteLine($"Synthetic event-to-state-to-WPF checks passed: {checks} assertions.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static void CheckScenario(string scene, string language, string theme)
    {
        bool english = language == "en";
        var fixture = new SyntheticProviderScenarios(scene);
        var snapshot = fixture.Snapshot();
        if (scene == "state-end") Check(snapshot.Length == 0, "Completed DeepSeek task remained visible.");
        else if (scene == "state-multi")
        {
            Check(snapshot.Length == 3, "Synthetic sessions collided.");
            Check(snapshot.Count(state => state.Session == "shared") == 2, "Different providers with the same session id collided.");
        }
        else
        {
            Check(snapshot.Length == 1, scene + ": expected one task.");
            string expected = scene switch
            {
                "state-kimi" or "state-unknown" or "state-gap" or "state-hermes-unknown" => "unknown",
                "state-wait" or "state-hermes-wait" => "waiting",
                _ => "active"
            };
            Check(snapshot[0].Status == expected, scene + ": unexpected state.");
            SampleTask mapped = ProviderPresentation.Map(snapshot[0], language);
            Check(mapped.Status == expected, scene + ": mapper changed the state.");
            if (scene == "state-kimi") Check(mapped.Progress is null && mapped.Steps.Length == 0, "Kimi acquired invented progress.");
            if (scene is "state-plan" or "state-wait" or "state-unknown" or "state-gap" or "state-old-plan")
            {
                Check(mapped.Progress == 50 && mapped.Steps.Length == 8, scene + ": plan progress changed.");
                Check(mapped.PlanConfirmed == (scene is not ("state-gap" or "state-old-plan")), scene + ": plan confirmation changed.");
            }
        }

        var (window, controller) = Open(scene, language, theme);
        try
        {
            var texts = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            if (scene == "state-end") Check(texts.Contains(english ? "No active tasks" : "Активных задач сейчас нет"), "Empty state text missing.");
            else if (scene == "state-multi")
                Check(controller.CurrentTasks.Select(task => task.Id).Distinct().Count() == 3, "Rendered task identities collided.");
            else
            {
                string? expectedText = scene switch
                {
                    "state-kimi" or "state-unknown" or "state-gap" or "state-hermes-unknown" => english ? "Status unconfirmed" : "Статус не подтверждён",
                    "state-wait" or "state-hermes-wait" => english ? "Waiting for confirmation" : "Ожидает подтверждения",
                    _ => english ? "Working" : "Выполняется"
                };
                Check(texts.Contains(expectedText), scene + ": expected state text not rendered.");
                string progress = english ? "Step 5 of 8" : "Этап 5 из 8";
                if (scene is "state-plan" or "state-wait") Check(texts.Contains(progress), scene + ": confirmed progress not rendered.");
                if (scene is "state-unknown" or "state-gap" or "state-old-plan") Check(!texts.Contains(progress), scene + ": unconfirmed progress was labelled as current.");
                if (scene is "state-gap" or "state-old-plan")
                {
                    Check(texts.Any(text => text.StartsWith(english ? "Plan unconfirmed · 8 steps" : "План не подтверждён · 8 этапов", StringComparison.Ordinal)), "Unconfirmed plan label missing.");
                    Check(Visible<ProgressBar>(window).Any(bar => bar.Value == 50), "The published retained-plan bar changed.");
                }
                if (scene == "state-kimi") Check(!Visible<ProgressBar>(window).Any(), "Kimi acquired a progress bar.");
            }
        }
        finally { window.Close(); }
    }

    private static void CheckSelection()
    {
        var (window, controller) = Open("state-multi", "en", "dark");
        try
        {
            Click((Button)window.FindName("MinimizeButton"));
            var dots = (StackPanel)window.FindName("CompactDotsPanel");
            Check(dots.Children.Count == 3, "Three independent compact tasks were not rendered.");
            Click((Button)dots.Children[2]);
            Check(controller.SelectedTaskId == "deepseek:shared", "The requested compact task was not selected.");
            controller.AdvanceMultiForTest();
            Check(controller.SelectedTaskId == "deepseek:shared", "An unrelated tool event changed the selection.");
            Click((Button)window.FindName("ExpandButton"));
            var tabs = (StackPanel)window.FindName("ProviderTabsPanel");
            Click(tabs.Children.OfType<Button>().Single(button => (string)button.Tag == "opencode"));
            Check(controller.SelectedProvider == "opencode", "The provider filter did not change.");
            Click((Button)window.FindName("MinimizeButton"));
            controller.AdvanceMultiForTest();
            Check(controller.SelectedTaskId == "deepseek:shared", "Removing another task changed the selection.");
            Check(controller.SelectedProvider == "all", "A removed provider left a stale filter.");
            controller.AdvanceMultiForTest();
            Check(controller.SelectedTaskId == "opencode:new", "A newly started task did not receive the published priority.");
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(text => text.Text == "OpenCode task"), "The newly selected task is not rendered.");
        }
        finally { window.Close(); }
    }

    private static void CheckLegacyDemoLanguage()
    {
        SampleTask[]? russian = null;
        foreach (string language in new[] { "ru", "en" })
        {
            var (window, controller) = Open("active", language, "light");
            try
            {
                var tasks = controller.CurrentTasks.ToArray();
                Check(tasks.Length == 2, "The demo must contain two tasks.");
                SampleTask codex = tasks.Single(task => task.Provider == "codex");
                SampleTask claude = tasks.Single(task => task.Provider == "claude");
                if (language == "ru")
                {
                    Check(codex.Title == "Создать индикатор прогресса задач" && claude.Title == "Задача Claude Code", "The Russian demo changed.");
                    russian = tasks;
                }
                else
                {
                    Check(codex.Title == "Create a task progress indicator" && claude.Title == "Claude Code task", "English demo titles were not translated.");
                    Check(codex.Activity.StartsWith("Checking plan cards", StringComparison.Ordinal) && claude.Activity == "Running visual checks", "English demo activity was not translated.");
                    Check(codex.Steps[0].Title == "Synchronize the task list" && claude.Steps[0].Title == "Check the local environment", "English demo steps were not translated.");
                    var texts = tasks.SelectMany(task => new[] { task.Title, task.Activity }.Concat(task.Steps.Select(step => step.Title)));
                    Check(!texts.Any(text => text.Any(ch => ch >= '\u0400' && ch <= '\u052f')), "English demo contains untranslated task text.");
                    Check(russian is not null && russian.Zip(tasks).All(pair => pair.First.Progress == pair.Second.Progress &&
                        pair.First.Status == pair.Second.Status && pair.First.Steps.Select(step => step.Status).SequenceEqual(pair.Second.Steps.Select(step => step.Status))),
                        "Translating demo text changed its state or progress.");
                    var rendered = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
                    Check(rendered.Contains(codex.Title) && rendered.Contains(claude.Title), "English demo titles were not rendered.");
                }
            }
            finally { window.Close(); }
        }
    }

    private static void CheckExternalTaskText()
    {
        var (window, controller) = Open("active", "en", "dark");
        try
        {
            const string title = "Мой настоящий заголовок";
            const string activity = "Моё собственное описание";
            var tasks = controller.CurrentTasks.Select(task => task.Provider == "claude"
                ? task with { Title = title, Activity = activity, Steps = [new SampleStep("Мой этап", "active")] }
                : task).ToList();
            Type type = typeof(PrototypeWindow);
            type.GetField("samples", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(controller, tasks);
            type.GetMethod("Render", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(controller, null);
            window.UpdateLayout();
            var rendered = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            Check(rendered.Contains(title) && rendered.Contains(activity) && rendered.Contains("Мой этап"), "Source task text was changed in the English expanded view.");
            Click((Button)window.FindName("MinimizeButton"));
            var dots = (StackPanel)window.FindName("CompactDotsPanel");
            Button claudeDot = (Button)dots.Children[1];
            Check(System.Windows.Automation.AutomationProperties.GetName(claudeDot) == "Show task: " + title, "Accessible task name was changed.");
            Click(claudeDot);
            window.UpdateLayout();
            rendered = Visible<TextBlock>(window).Select(text => text.Text).ToArray();
            Check(rendered.Contains(title) && rendered.Contains(activity), "Source task text was changed in the English compact view.");
        }
        finally { window.Close(); }
    }

    private static void CaptureTabStates(string directory)
    {
        foreach (string language in new[] { "ru", "en" })
        foreach (string theme in new[] { "light", "dark" })
        {
            var (window, controller) = Open("active", language, theme);
            try
            {
                window.Width = 616; window.Height = 756;
                window.UpdateLayout();
                var host = (Grid)window.FindName("ProviderTabsHost");
                var tabs = (StackPanel)window.FindName("ProviderTabsPanel");
                Check(tabs.Children.Count == 3, "Expected three tabs for the two-provider case.");
                Check(tabs.Children.OfType<Button>().Select(button => button.Width).Distinct().Count() == 1,
                    "The two-provider tabs are not equally wide.");
                Check(Math.Abs(host.ActualHeight - 42) < 1e-8, "Unexpected tab track height.");
                SaveCapture(window, Path.Combine(directory, $"{theme}-{language}-all.png"));
                Click(tabs.Children.OfType<Button>().Single(button => (string)button.Tag == "claude"));
                window.UpdateLayout();
                Check(controller.SelectedProvider == "claude", "Claude filter was not selected.");
                SaveCapture(window, Path.Combine(directory, $"{theme}-{language}-claude.png"));
                var definitions = new (string Id, string Name)[] { ("codex", "Codex"), ("claude", "Claude Code"),
                    ("kimi", "Kimi Code"), ("deepseek", "DeepSeek Harness"), ("hermes", "Hermes Agent"), ("opencode", "OpenCode") };
                SampleTask template = controller.CurrentTasks[0];
                var synthetic = definitions.Select(provider => template with
                {
                    Id = "test-" + provider.Id, Provider = provider.Id, ProviderName = provider.Name,
                    Title = provider.Name + " task"
                }).ToList();
                Type controllerType = typeof(PrototypeWindow);
                controllerType.GetField("samples", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(controller, synthetic);
                controllerType.GetField("selectedProvider", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(controller, "all");
                controllerType.GetMethod("Render", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(controller, null);
                window.UpdateLayout();
                var scroll = (ScrollViewer)window.FindName("ProviderTabsScroll");
                Check(tabs.Children.Count == 7 && scroll.ScrollableWidth > 0, "Six providers did not produce scrollable tabs.");
                SaveCapture(window, Path.Combine(directory, $"{theme}-{language}-six-start.png"));
                scroll.ScrollToEnd();
                window.UpdateLayout();
                Click(tabs.Children.OfType<Button>().Single(button => (string)button.Tag == "opencode"));
                window.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, new Action(() => { }));
                window.UpdateLayout();
                Check(controller.SelectedProvider == "opencode", "Scrolling changed the selected provider.");
                Check(scroll.HorizontalOffset > 0, "Scrolling to the final provider did not persist.");
                SaveCapture(window, Path.Combine(directory, $"{theme}-{language}-six-end.png"));
            }
            finally { window.Close(); }
        }
    }

    private static void SaveCapture(Window window, string path)
    {
        window.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, new Action(() => { }));
        window.UpdateLayout();
        var image = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),
            (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        image.Render(window);
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        encoder.Save(output);
    }

    private static (Window Window, PrototypeWindow Controller) Open(string scene, string language, string theme)
    {
        Assembly assembly = typeof(PrototypeWindow).Assembly;
        using Stream layout = assembly.GetManifestResourceStream("AITaskMonitor.Prototype.PublishedWindow.xaml")
            ?? throw new InvalidOperationException("Published WPF layout is missing.");
        var window = (Window)XamlReader.Load(layout);
        var options = new Options(theme, language, scene, false, true, null, null, false);
        var controller = new PrototypeWindow(window, options);
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        return (window, controller);
    }

    private static IEnumerable<T> Visible<T>(DependencyObject root) where T : FrameworkElement
    {
        if (root is FrameworkElement element && !element.IsVisible) yield break;
        if (root is T match) yield return match;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (T child in Visible<T>(VisualTreeHelper.GetChild(root, i))) yield return child;
    }

    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }
}
