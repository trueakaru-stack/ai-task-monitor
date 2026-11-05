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
