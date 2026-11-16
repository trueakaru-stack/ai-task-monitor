using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AITaskMonitor.NativeUpdateController;
using AITaskMonitor.NativeUpdateIntegration;
using AITaskMonitor.Prototype;
using ShapePath = System.Windows.Shapes.Path;

internal static class Program
{
    private const string Payload = """
        [{"tag_name":"v0.3.8-alpha","draft":false,"assets":[{"name":"AITaskMonitor-macOS-0.3.8-alpha.dmg","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.8-alpha/AITaskMonitor-macOS-0.3.8-alpha.dmg"}]},
         {"tag_name":"v0.2.7-alpha","draft":false,"assets":[{"name":"AITaskMonitorSetup-0.2.7-alpha.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.2.7-alpha/AITaskMonitorSetup-0.2.7-alpha.exe"}]}]
        """;
    private const string Url = "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.2.7-alpha/AITaskMonitorSetup-0.2.7-alpha.exe";
    private static string root = "";
    private static int checks;

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void RequireHosted(string[] args)
    {
        Check(OperatingSystem.IsWindows() &&
              Environment.GetEnvironmentVariable("CI") == "true" &&
              Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
              Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted" &&
              Environment.GetEnvironmentVariable("RUNNER_OS") == "Windows" &&
              Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0",
              "A disposable hosted Windows runner with the PATH opt-out is required.");
        Check(args.Length == 1 && Path.IsPathFullyQualified(args[0]), "An absolute synthetic root is required.");
        string temp = Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "";
        Check(Path.IsPathFullyQualified(temp), "Runner temp must be absolute.");
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[0]));
        string parent = Path.TrimEndingDirectorySeparator(Path.GetFullPath(temp));
        Check(string.Equals(Directory.GetParent(root)?.FullName, parent, StringComparison.OrdinalIgnoreCase) &&
              Regex.IsMatch(Path.GetFileName(root), "^aitm-update-host-[0-9a-f]{32}$", RegexOptions.CultureInvariant) &&
              Directory.Exists(root), "A unique runner-temp root is required.");
        for (DirectoryInfo? directory = new(root); directory is not null; directory = directory.Parent)
            Check((directory.Attributes & FileAttributes.ReparsePoint) == 0, "Redirected test paths are rejected.");
        string expected = Path.Combine(root, "artifacts", "bin", "UpdateHost.Tests", "release",
            "AITaskMonitor.Prototype.Tests.dll");
        Check(string.Equals(Path.GetFullPath(Assembly.GetExecutingAssembly().Location), expected,
            StringComparison.OrdinalIgnoreCase), "The test assembly must be in the synthetic output directory.");
    }

    private sealed class ImmediateHandler : HttpMessageHandler
    {
        private int calls;
        internal int Calls => Volatile.Read(ref calls);
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Interlocked.Increment(ref calls);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Payload, Encoding.UTF8, "application/json")
            });
        }
    }

    private sealed class BlockingDisposeHandler : HttpMessageHandler
    {
        internal readonly TaskCompletionSource<bool> Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<HttpResponseMessage> Response = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly ManualResetEventSlim Disposing = new(false);
        internal readonly ManualResetEventSlim Release = new(false);

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Started.TrySetResult(true);
            return Response.Task; // Synthetic uncooperative transport; no network request is made.
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                Disposing.Set();
                _ = Release.Wait(TimeSpan.FromSeconds(8));
            }
            base.Dispose(disposing);
        }
    }

    private static WindowsUpdateService Service(WindowsUpdateChannel channel, Func<HttpMessageHandler> handler) =>
        WindowsUpdateService.Create(channel, "0.2.6-alpha", Stopwatch.GetTimestamp,
            () => DateTimeOffset.UtcNow, Stopwatch.Frequency, TimeSpan.FromSeconds(5), handler);

    private static (Window Window, PrototypeWindow View) Open(string language, string theme, bool compact)
    {
        using Stream layout = typeof(PrototypeWindow).Assembly.GetManifestResourceStream(
            "AITaskMonitor.Prototype.PublishedWindow.xaml") ?? throw new InvalidOperationException("Published layout missing.");
        var window = (Window)XamlReader.Load(layout);
        var view = new PrototypeWindow(window, new Options(theme, language, "active", compact, true, null, null, false));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000;
        window.Top = -10000;
        window.ShowActivated = false;
        window.ShowInTaskbar = false;
        window.Show();
        window.UpdateLayout();
        return (window, view);
    }

    private static T Find<T>(Window window, string name) where T : class =>
        window.FindName(name) as T ?? throw new InvalidOperationException("Expected control missing: " + name);

    private static void Click(Window window, string name) =>
        Find<Button>(window, name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    private static void WaitUntil(Func<bool> condition, string label, int seconds = 20)
    {
        if (condition()) return;
        var frame = new DispatcherFrame();
        long started = Stopwatch.GetTimestamp();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
        timer.Tick += (_, _) =>
        {
            if (condition() || Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(seconds)) frame.Continue = false;
        };
        timer.Start();
        try { Dispatcher.PushFrame(frame); }
        finally { timer.Stop(); }
        Check(condition(), label);
    }

    private static IEnumerable<T> Visible<T>(DependencyObject parent) where T : FrameworkElement
    {
        if (parent is FrameworkElement element && !element.IsVisible) yield break;
        if (parent is T match) yield return match;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            foreach (T child in Visible<T>(VisualTreeHelper.GetChild(parent, i))) yield return child;
    }

    private static void Capture(Window window, string name)
    {
        window.UpdateLayout();
        var image = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),
            (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        image.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var output = new FileStream(Path.Combine(root, name), FileMode.CreateNew, FileAccess.Write, FileShare.None);
        encoder.Save(output);
    }

    private static void Finish(UpdateSourcePump pump)
    {
        Task task = pump.StopAsync();
        WaitUntil(() => task.IsCompleted, "Synthetic service shutdown did not finish.");
        task.GetAwaiter().GetResult();
    }

    private static void Flow(string language, string theme, bool compact)
    {
        var (window, view) = Open(language, theme, compact);
        var handler = new ImmediateHandler();
        WindowsUpdateService service = Service(WindowsUpdateChannel.Standalone, () => handler);
        int displayed = 0, fakeDownloads = 0;
        var pump = new UpdateSourcePump(window.Dispatcher, service, update =>
        {
            displayed++;
            view.ApplySyntheticUpdate(update, () => fakeDownloads++);
        }, TimeSpan.FromMilliseconds(25));
        try
        {
            Check(Find<Grid>(window, "UpdateOverlay").Visibility == Visibility.Collapsed,
                "Default preview unexpectedly displays an update.");
            pump.Start();
            WaitUntil(() => displayed == 1, "The fake update did not reach the WPF controller.");
            Check(handler.Calls == 1 && service.Snapshot()?.Available is { Version: "0.2.7-alpha", Url: Url },
                "The service did not select the synthetic Windows release.");
            var overlay = Find<Grid>(window, "UpdateOverlay");
            if (compact)
            {
                Check(overlay.Visibility == Visibility.Collapsed, "A compact window displayed a modal update.");
                Capture(window, $"compact-{language}-{theme}.png");
                Click(window, "ExpandButton");
            }
            WaitUntil(() => overlay.Visibility == Visibility.Visible, "The update dialog was not shown after expansion.");
            window.UpdateLayout();
            Check(Find<TextBlock>(window, "UpdateVersionText").Text ==
                  (language == "en" ? "Version 0.2.7-alpha is available to download" : "Версия 0.2.7-alpha доступна для скачивания"),
                  "The update version text is incorrect.");
            Check(Visible<TextBlock>(window).Any(item => item.Text ==
                  (language == "en" ? "A new version is available" : "Доступна новая версия")),
                  "The approved update title is missing.");
            Check((string)Find<Button>(window, "UpdateLaterButton").Content == (language == "en" ? "Later" : "Позже") &&
                  (string)Find<Button>(window, "UpdateDownloadButton").Content == (language == "en" ? "Download" : "Скачать"),
                  "The approved update actions are missing.");
            Check(AutomationProperties.GetName(Find<Button>(window, "UpdateLaterButton")) ==
                  (language == "en" ? "Remind me next time" : "Напомнить при следующем запуске"),
                  "The later action is not localized for accessibility.");
            Check(Find<ShapePath>(window, "UpdateDialogShape").Data is not null &&
                  Math.Abs(Find<Grid>(window, "UpdateDialog").ActualWidth - 368) < 0.1,
                  "The existing dialog contour was not applied.");
            if (!compact)
            {
                Capture(window, $"full-{language}-{theme}.png");
                Button download = Find<Button>(window, "UpdateDownloadButton");
                Check(download.Focus() && download.IsKeyboardFocused, "The download button did not receive keyboard focus.");
                window.UpdateLayout();
                Capture(window, $"focus-{language}-{theme}.png");
            }

            Click(window, "UpdateLaterButton");
            Check(overlay.Visibility == Visibility.Collapsed && fakeDownloads == 0, "Later did not dismiss the update.");
            pump.Poll();
            view.ApplySyntheticUpdate(new UpdateInfo("0.2.7-alpha", Url), () => fakeDownloads++);
            Check(overlay.Visibility == Visibility.Collapsed, "The dismissed update returned during the session.");
            view.ApplySyntheticUpdate(new UpdateInfo("0.2.8-alpha", Url), () => fakeDownloads++);
            Check(overlay.Visibility == Visibility.Visible, "A different synthetic version remained dismissed.");
            Click(window, "UpdateDownloadButton");
            Check(fakeDownloads == 1 && overlay.Visibility == Visibility.Collapsed,
                "The synthetic download callback did not run exactly once.");
        }
        finally { Finish(pump); window.Close(); }
    }

    private static void Store()
    {
        var (window, view) = Open("en", "dark", false);
        int factories = 0, presented = 0;
        WindowsUpdateService service = Service(WindowsUpdateChannel.Store, () => { factories++; return new ImmediateHandler(); });
        var pump = new UpdateSourcePump(window.Dispatcher, service,
            update => { presented++; view.ApplySyntheticUpdate(update, () => { }); }, TimeSpan.FromMilliseconds(25));
        try
        {
            pump.Start();
            bool clockTick = false;
            window.Dispatcher.BeginInvoke(new Action(() => clockTick = true));
            WaitUntil(() => clockTick, "The Store dispatcher did not run.");
            Check(factories == 0 && presented == 0 && !service.IsExternalUpdaterConfigured &&
                  service.Snapshot() is null && Find<Grid>(window, "UpdateOverlay").Visibility == Visibility.Collapsed,
                  "Store created an external updater or an update dialog.");
            bool rejected = false;
            try { _ = Service((WindowsUpdateChannel)0, () => { factories++; return new ImmediateHandler(); }); }
            catch (ArgumentOutOfRangeException) { rejected = true; }
            Check(rejected && factories == 0, "An unknown distribution channel created an updater.");
        }
        finally { Finish(pump); window.Close(); }
    }

    private static void NonBlockingStop()
    {
        var (window, view) = Open("en", "dark", false);
        using var handler = new BlockingDisposeHandler();
        WindowsUpdateService service = Service(WindowsUpdateChannel.Standalone, () => handler);
        int presented = 0;
        var pump = new UpdateSourcePump(window.Dispatcher, service,
            update => { presented++; view.ApplySyntheticUpdate(update, () => { }); }, TimeSpan.FromMilliseconds(25));
        Task? stop = null;
        try
        {
            pump.Start();
            WaitUntil(() => handler.Started.Task.IsCompleted, "The synthetic request did not start.");
            var watch = Stopwatch.StartNew();
            stop = pump.StopAsync();
            Check(watch.Elapsed < TimeSpan.FromSeconds(1), "Stopping blocked the UI dispatcher.");
            WaitUntil(() => handler.Disposing.IsSet, "Asynchronous transport disposal did not start.");
            Check(!stop.IsCompleted, "The blocking synthetic disposal unexpectedly finished.");
            bool uiTick = false;
            window.Dispatcher.BeginInvoke(new Action(() => uiTick = true));
            WaitUntil(() => uiTick, "The dispatcher could not run during disposal.");
            handler.Response.TrySetResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(Payload, Encoding.UTF8, "application/json")
            });
            pump.Poll();
            Check(presented == 0 && service.Snapshot() is { Stopped: true, Available: null },
                "A stopped pump published a late result.");
        }
        finally
        {
            handler.Release.Set();
            stop ??= pump.StopAsync();
            WaitUntil(() => stop.IsCompleted, "Synthetic disposal remained blocked.");
            stop.GetAwaiter().GetResult();
            window.Close();
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        RequireHosted(args);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        try
        {
            foreach (string language in new[] { "ru", "en" })
                foreach (string theme in new[] { "light", "dark" })
                    foreach (bool compact in new[] { false, true })
                        Flow(language, theme, compact);
            Store();
            NonBlockingStop();
            Console.WriteLine($"Synthetic update host: {checks} checks passed; 12 screenshots written.");
            return 0;
        }
        finally { app.Shutdown(); }
    }
}
