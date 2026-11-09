using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AITaskMonitor.Prototype;

internal static class Program
{
    private static int checks;
    [STAThread]
    private static int Main()
    {
        try
        {
            string work = Directory.CreateTempSubdirectory("aitm-loop-ui-").FullName;
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            foreach (string language in new[] { "ru", "en" })
                foreach (string theme in new[] { "dark", "light" }) Verify(work, language, theme);
            VerifyScrollFocus(work);
            app.Shutdown();
            Console.WriteLine($"Loop warning WPF: {checks} synthetic checks passed.");
            Console.WriteLine($"Synthetic frames: {work}");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static void VerifyScrollFocus(string work)
    {
        using Stream layout = typeof(PrototypeWindow).Assembly.GetManifestResourceStream("AITaskMonitor.Prototype.PublishedWindow.xaml")!;
        var window = (Window)XamlReader.Load(layout);
        var controller = new PrototypeWindow(window, new Options("dark", "ru", "active", false, true, null, null, false));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        try
        {
            SampleTask seed = controller.CurrentTasks.Single(task => task.Provider == "codex");
            List<SampleTask> many = Enumerable.Range(0, 6).Select(i => seed with { Id = "task-" + i, Title = "Synthetic task " + i }).ToList();
            SetTasks(controller, many);
            controller.ApplyLoopWarnings(many.ToDictionary(task => task.Id, _ => new LoopWarningView(5, 10)), _ => true);
            Button fourth = Visible<Button>(window).Where(button => Equals(button.Content, "Скрыть")).ElementAt(3);
            fourth.BringIntoView();
            Check(fourth.Focus(), "Scrolled warning could not receive focus");
            Capture(window, Path.Combine(work, "scroll-focus-before.png"));
            var viewport = (ScrollViewer)window.FindName("TasksScroll");
            viewport.ScrollToVerticalOffset(0);
            Capture(window, Path.Combine(work, "scroll-manual-before-refresh.png"));
            controller.ApplyLoopWarnings(many.ToDictionary(task => task.Id, _ => new LoopWarningView(5, 10)), _ => true);
            Capture(window, Path.Combine(work, "scroll-manual-after-refresh.png"));
            Check(viewport.VerticalOffset == 0, "Refreshing the same warning changed the user's scroll position");
            fourth = Visible<Button>(window).Single(button => Equals(button.Content, "Скрыть") && button.IsKeyboardFocused);
            fourth.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Capture(window, Path.Combine(work, "scroll-focus-after.png"));
            Button focused = Visible<Button>(window).Single(button => Equals(button.Content, "Скрыть") && button.IsKeyboardFocused);
            Point top = focused.TransformToAncestor(viewport).Transform(new Point(0, 0));
            Console.WriteLine($"Synthetic scroll focus: y={top.Y:F1}, height={focused.ActualHeight:F1}, viewport={viewport.ViewportHeight:F1}, offset={viewport.VerticalOffset:F1}");
            Check(viewport.VerticalOffset > 0 && top.Y >= 0 && top.Y + focused.ActualHeight <= viewport.ViewportHeight,
                "Focused neighboring warning was not brought into the viewport");

            List<SampleTask> eight = Enumerable.Range(0, 8).Select(i => seed with { Id = "new-" + i, Title = "New synthetic task " + i }).ToList();
            SetTasks(controller, eight);
            controller.ApplyLoopWarnings(eight.ToDictionary(task => task.Id, _ => new LoopWarningView(5, 10)), _ => true);
            Button[] beforeRemoval = Visible<Button>(window).Where(button => Equals(button.Content, "Скрыть")).ToArray();
            string removedId = ((WarningFocusKey)beforeRemoval[4].Tag).TaskId;
            string nextId = ((WarningFocusKey)beforeRemoval[5].Tag).TaskId;
            beforeRemoval[4].BringIntoView();
            Check(beforeRemoval[4].Focus(), "Removal target could not receive focus");
            Capture(window, Path.Combine(work, "remove-focused-before.png"));
            SetTasks(controller, controller.CurrentTasks.Where(task => task.Id != removedId).ToList());
            Capture(window, Path.Combine(work, "remove-focused-after.png"));
            Button afterRemoval = Visible<Button>(window).Single(button => Equals(button.Content, "Скрыть") && button.IsKeyboardFocused);
            Check(((WarningFocusKey)afterRemoval.Tag).TaskId == nextId && viewport.VerticalOffset > 300,
                "Removing the focused task did not focus its previous neighbor");
        }
        finally { window.Close(); }
    }

    private static void Verify(string work, string language, string theme)
    {
        using Stream layout = typeof(PrototypeWindow).Assembly.GetManifestResourceStream("AITaskMonitor.Prototype.PublishedWindow.xaml")!;
        var window = (Window)XamlReader.Load(layout);
        var controller = new PrototypeWindow(window, new Options(theme, language, "active", false, true, null, null, false));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        try
        {
            SampleTask codex = controller.CurrentTasks.Single(task => task.Provider == "codex");
            SetTasks(controller, [codex]);
            int dismissed = 0;
            string? dismissedId = null;
            var warnings = new Dictionary<string, LoopWarningView> { [codex.Id] = new(5, 10) };
            controller.ApplyLoopWarnings(warnings, id => { dismissed++; dismissedId = id; return true; });
            window.UpdateLayout();
            string message = language == "en" ? "Possible loop: one command failed with the same code at least 5 times in 10 min."
                : "Возможный цикл: одна команда завершилась с одинаковым кодом ошибки не менее 5 раз за 10 мин.";
            string action = language == "en" ? "Hide" : "Скрыть";
            Check(Visible<TextBlock>(window).Any(text => text.Text == message), "Warning message missing");
            Button button = Visible<Button>(window).Single(item => Equals(item.Content, action));
            Check(AutomationProperties.GetName(button).Contains(codex.Title, StringComparison.Ordinal), "Warning action lacks task identity");
            Capture(window, Path.Combine(work, $"{theme}-{language}-expanded.png"));
            Button collapse = (Button)window.FindName("MinimizeButton");
            Check(collapse.Focus(), "Compact toggle could not receive focus");
            collapse.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(((Button)window.FindName("ExpandButton")).IsKeyboardFocused, "Compact toggle lost focus");
            window.UpdateLayout();
            Check(Visible<TextBlock>(window).Any(text => text.Text == message), "Compact warning missing");
            Capture(window, Path.Combine(work, $"{theme}-{language}-compact.png"));
            Button compactWarning = Visible<Button>(window).Single(item => Equals(item.Content, action));
            Check(compactWarning.Focus(), "Compact warning could not receive focus");
            controller.ApplyLoopWarnings(warnings, id => { dismissed++; dismissedId = id; return true; });
            compactWarning = Visible<Button>(window).Single(item => Equals(item.Content, action));
            Check(compactWarning.IsKeyboardFocused, "A refresh lost compact warning focus");
            Capture(window, Path.Combine(work, $"{theme}-{language}-focus-compact.png"));
            compactWarning.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();
            Check(dismissed == 1 && dismissedId == codex.Id && !Visible<TextBlock>(window).Any(text => text.Text == message), "Warning dismissal failed");
            Check(((Button)window.FindName("ExpandButton")).IsKeyboardFocused, "Compact dismissal lost focus");
            controller.ApplyLoopWarnings(warnings, _ => false);
            window.UpdateLayout();
            Visible<Button>(window).Single(item => Equals(item.Content, action)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(Visible<TextBlock>(window).Any(text => text.Text == message), "Failed dismissal hid a warning");
            controller.ApplyLoopWarnings(warnings, _ => throw new InvalidOperationException("Synthetic dismissal error"));
            Visible<Button>(window).Single(item => Equals(item.Content, action)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(Visible<TextBlock>(window).Any(text => text.Text == message), "Dismissal error hid a warning");
            try
            {
                controller.ApplyLoopWarnings(new Dictionary<string, LoopWarningView> { [codex.Id] = new(0, 31) }, _ => true);
                throw new InvalidOperationException("Invalid warning settings were accepted");
            }
            catch (ArgumentException) { checks++; }
            Check(Visible<TextBlock>(window).Any(text => text.Text == message), "Invalid settings replaced a valid warning");
            Button expand = (Button)window.FindName("ExpandButton");
            Check(expand.Focus(), "Expand toggle could not receive focus");
            expand.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(((Button)window.FindName("MinimizeButton")).IsKeyboardFocused, "Expand toggle lost focus");
            SetTasks(controller, [codex with { Status = "unknown" }]);
            Check(!Visible<TextBlock>(window).Any(text => text.Text == message), "Unconfirmed task showed a live warning");

            SampleTask claude = controller.CurrentTasks.First() with
            {
                Id = "claude-session", Provider = "claude", ProviderName = "Claude Code", Title = "Claude synthetic task",
                Status = "active", PlanConfirmed = false
            };
            SetTasks(controller, [codex, claude]);
            var twoWarnings = new Dictionary<string, LoopWarningView> { [codex.Id] = new(5, 10), [claude.Id] = new(5, 10) };
            controller.ApplyLoopWarnings(twoWarnings, id => { dismissedId = id; return true; });
            Check(Visible<TextBlock>(window).Count(text => text.Text == message) == 2, "Neighbor or Claude warning missing");
            Button claudeButton = Visible<Button>(window).Single(item => Equals(item.Content, action) &&
                AutomationProperties.GetName(item).Contains(claude.Title, StringComparison.Ordinal));
            Check(claudeButton.Focus(), "Claude warning could not receive focus");
            controller.ApplyLoopWarnings(twoWarnings, id => { dismissedId = id; return true; });
            claudeButton = Visible<Button>(window).Single(item => Equals(item.Content, action) &&
                AutomationProperties.GetName(item).Contains(claude.Title, StringComparison.Ordinal));
            Check(claudeButton.IsKeyboardFocused, "A refresh lost Claude warning focus");
            claudeButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(dismissedId == claude.Id && Visible<TextBlock>(window).Count(text => text.Text == message) == 1,
                "Dismissing Claude warning affected its neighbor");
            Check(Visible<Button>(window).Single(item => Equals(item.Content, action)).IsKeyboardFocused,
                "Focus did not move to the remaining warning");
            Capture(window, Path.Combine(work, $"{theme}-{language}-focus-neighbor-expanded.png"));
            SetTasks(controller, [claude]);
            controller.ApplyLoopWarnings(new Dictionary<string, LoopWarningView> { [claude.Id] = new(5, 10) }, _ => true);
            Capture(window, Path.Combine(work, $"{theme}-{language}-claude-expanded.png"));
            ((Button)window.FindName("MinimizeButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Capture(window, Path.Combine(work, $"{theme}-{language}-claude-compact.png"));
            Button lastWarning = Visible<Button>(window).Single(item => Equals(item.Content, action));
            Check(lastWarning.Focus(), "Last warning could not receive focus");
            SetTasks(controller, []);
            Check(((Button)window.FindName("ExpandButton")).IsKeyboardFocused, "Removing all tasks lost focus");
        }
        finally { window.Close(); }
    }

    private static void SetTasks(PrototypeWindow controller, List<SampleTask> tasks)
    {
        typeof(PrototypeWindow).GetMethod("UpdateSamples", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(controller, [tasks]);
        typeof(PrototypeWindow).GetMethod("Render", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(controller, null);
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
        var frame = new DispatcherFrame();
        window.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        encoder.Save(stream);
    }

    private static void Check(bool value, string message) { checks++; if (!value) throw new InvalidOperationException(message); }
}
