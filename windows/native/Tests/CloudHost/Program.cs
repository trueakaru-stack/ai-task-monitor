using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using AITaskMonitor.CodexCloud;
using AITaskMonitor.CodexCloudCommand;
using AITaskMonitor.Prototype;

internal static class Program
{
    private static int checks;
    private static string fixture = "";
    private static string root = "";

    private sealed class CheckFailure(string message) : Exception(message) { }

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new CheckFailure(message);
    }

    private static void RequireHosted(string[] args)
    {
        Check(OperatingSystem.IsWindows() &&
              string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase) &&
              string.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase) &&
              string.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"), "github-hosted", StringComparison.OrdinalIgnoreCase) &&
              string.Equals(Environment.GetEnvironmentVariable("RUNNER_OS"), "Windows", StringComparison.OrdinalIgnoreCase) &&
              Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0",
              "disposable hosted Windows required");
        Check(args.Length == 1 && Path.IsPathFullyQualified(args[0]), "absolute synthetic root required");
        string temp = Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "";
        Check(Path.IsPathFullyQualified(temp), "absolute runner temp required");
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[0]));
        string parent = Path.TrimEndingDirectorySeparator(Path.GetFullPath(temp));
        Check(string.Equals(Directory.GetParent(root)?.FullName, parent, StringComparison.OrdinalIgnoreCase) &&
              Regex.IsMatch(Path.GetFileName(root), "^aitm-cloud-host-[0-9a-f]{32}$", RegexOptions.CultureInvariant) &&
              Directory.Exists(root), "unique runner-temp root required");
        CheckDirectoryPath(root, null);

        string assembly = Path.Combine(root, "artifacts", "bin", "CloudHost.Tests", "release",
            "AITaskMonitor.Prototype.Tests.dll");
        Check(string.Equals(Path.GetFullPath(Assembly.GetExecutingAssembly().Location), assembly,
            StringComparison.OrdinalIgnoreCase), "isolated test assembly required");
        fixture = Path.Combine(root, "artifacts", "bin", "CloudHost.Fixture", "release",
            "AITaskMonitor.CloudHost.Fixture.exe");
        Check(File.Exists(fixture) && (File.GetAttributes(fixture) & FileAttributes.ReparsePoint) == 0,
            "synthetic fixture required");
        CheckDirectoryPath(Path.GetDirectoryName(fixture)!, root);
    }

    private static void CheckDirectoryPath(string path, string? stop)
    {
        for (DirectoryInfo? directory = new(path); directory is not null; directory = directory.Parent)
        {
            Check((directory.Attributes & FileAttributes.ReparsePoint) == 0, "reparse path rejected");
            if (stop is not null && string.Equals(directory.FullName, stop, StringComparison.OrdinalIgnoreCase))
                return;
        }
        Check(stop is null, "fixture must remain under synthetic root");
    }

    private static (Window Window, PrototypeWindow View) Open(string scene, string language, string theme)
    {
        using Stream layout = typeof(PrototypeWindow).Assembly.GetManifestResourceStream(
            "AITaskMonitor.Prototype.PublishedWindow.xaml")!;
        var window = (Window)XamlReader.Load(layout);
        var view = new PrototypeWindow(window, new Options(theme, language, scene, false, true, null, null, false));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000;
        window.Top = -10000;
        window.ShowActivated = false;
        window.ShowInTaskbar = false;
        window.Show();
        window.UpdateLayout();
        return (window, view);
    }

    private static Task<CommandResult> RunFixture(string? cursor, TimeSpan timeout, CancellationToken token) =>
        CloudCommand.RunAsync(fixture, cursor, timeout, token);

    private static void Mode(string value) => Environment.SetEnvironmentVariable("AITM_CLOUDHOST_MODE", value);

    private static void WaitUntil(Func<bool> condition, string message, int seconds = 20)
    {
        if (condition()) return;
        var frame = new DispatcherFrame();
        long started = Stopwatch.GetTimestamp();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
        timer.Tick += (_, _) =>
        {
            if (condition() || Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(seconds))
                frame.Continue = false;
        };
        timer.Start();
        try { Dispatcher.PushFrame(frame); }
        finally { timer.Stop(); }
        Check(condition(), message);
    }

    private static IEnumerable<T> Visible<T>(DependencyObject parent) where T : FrameworkElement
    {
        if (parent is FrameworkElement element && !element.IsVisible) yield break;
        if (parent is T match) yield return match;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            foreach (T child in Visible<T>(VisualTreeHelper.GetChild(parent, i))) yield return child;
    }

    private static bool HasText(Window window, string text) =>
        Visible<TextBlock>(window).Any(item => item.Text == text);

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

    private static void CheckTabs(Window window, string language, int all, int codex, int claude)
    {
        var tabs = ((StackPanel)window.FindName("ProviderTabsPanel")).Children.OfType<Button>()
            .ToDictionary(item => (string)item.Tag, StringComparer.Ordinal);
        string prefix = language == "en" ? "Show tasks: " : "Показать задачи: ";
        foreach (var entry in new[]
        {
            (Id: "all", Label: language == "en" ? "All" : "Все", Count: all),
            (Id: "codex", Label: "Codex", Count: codex),
            (Id: "claude", Label: "Claude Code", Count: claude)
        })
        {
            Check(tabs.TryGetValue(entry.Id, out Button? button), "provider tab exists");
            Check(AutomationProperties.GetName(button!) == $"{prefix}{entry.Label}, {entry.Count}", "accessible provider count");
            Check(Visible<TextBlock>(button!).Any(text => text.Text == entry.Count.ToString()), "visible provider count");
        }
    }

    private static void Flow(string language, string theme)
    {
        Mode("pages");
        var (window, view) = Open("active", language, theme);
        using var host = new CloudSourcePump(window.Dispatcher, view.ApplyCloudSource, RunFixture,
            pollInterval: TimeSpan.FromMinutes(1));
        try
        {
            host.SetEnabled(true);
            WaitUntil(() => !host.InFlight && view.CurrentTasks.Count == 4, "two pages reach WPF");
            var cloud = view.CurrentTasks.Where(task => task.Id.StartsWith("codex-cloud:", StringComparison.Ordinal)).ToArray();
            Check(cloud.Length == 2 && cloud.All(task => task.Provider == "codex" && task.Status == "unknown" &&
                !task.Active && task.Progress is null && !task.PlanConfirmed && task.Steps.Length == 0),
                "cloud tasks remain unconfirmed");
            Check(view.CurrentTasks.Count(task => task.Provider == "codex" && task.Active) == 1 &&
                  view.CurrentTasks.Count(task => task.Provider == "claude") == 1, "local and Claude tasks remain");
            window.UpdateLayout();
            CheckTabs(window, language, 4, 3, 1);
            string activity = language == "en" ? "Status unconfirmed" : "Статус не подтверждён";
            Check(HasText(window, activity), "cloud task uncertainty visible");
            Capture(window, "cloud-" + language + "-" + theme + "-expanded.png");

            Button codex = ((StackPanel)window.FindName("ProviderTabsPanel")).Children.OfType<Button>()
                .Single(button => (string)button.Tag == "codex");
            codex.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();
            Check(view.SelectedProvider == "codex" && !HasText(window, language == "en" ? "Claude Code task" : "Задача Claude Code"),
                "Codex filter keeps cloud and local together");
            var taskScroll = (ScrollViewer)window.FindName("TasksScroll");
            taskScroll.ScrollToEnd();
            window.UpdateLayout();
            Check(taskScroll.ScrollableHeight > 0 && taskScroll.VerticalOffset > 0, "expanded cloud cards are scrolled into view");
            Capture(window, "cloud-" + language + "-" + theme + "-expanded-cloud.png");
            ((Button)window.FindName("MinimizeButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();
            var dots = ((StackPanel)window.FindName("CompactDotsPanel")).Children.OfType<Button>();
            Button cloudDot = dots.First(button => AutomationProperties.GetName(button).Contains("Fixture first", StringComparison.Ordinal) ||
                                                   AutomationProperties.GetName(button).Contains("Fixture second", StringComparison.Ordinal));
            cloudDot.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.UpdateLayout();
            Check(HasText(window, activity), "compact cloud status unconfirmed");
            Capture(window, "cloud-" + language + "-" + theme + "-compact.png");
            ((Button)window.FindName("ExpandButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

            Mode("error");
            host.RequestRefresh();
            WaitUntil(() => !host.InFlight && HasText(window, language == "en" ? "No data from Codex Cloud" : "Нет данных от Codex Cloud"),
                "failure reaches WPF");
            Check(view.CurrentTasks.Count == 4 && view.CurrentTasks.Count(task => task.Id.StartsWith("codex-cloud:", StringComparison.Ordinal)) == 2,
                "failure retains cloud and other sources");

            Mode("partial");
            host.RequestRefresh();
            WaitUntil(() => !host.InFlight && view.CurrentTasks.Count == 9, "partial response merges retained cards");
            window.UpdateLayout();
            Check(view.CurrentTasks.Count(task => task.Provider == "codex") == 8 &&
                  view.CurrentTasks.Count(task => task.Provider == "claude") == 1,
                  "partial cloud does not erase unrelated cards");
            Check(HasText(window, activity), "partial cloud tasks remain unconfirmed");
            CheckTabs(window, language, 9, 8, 1);

            host.SetEnabled(false);
            Check(view.CurrentTasks.Count == 2 && view.CurrentTasks.Any(task => task.Provider == "codex") &&
                  view.CurrentTasks.Any(task => task.Provider == "claude"), "disconnect clears cloud only");
        }
        finally { window.Close(); }
    }

    private static void EmptyCoverage()
    {
        Mode("empty");
        var (window, view) = Open("empty", "en", "dark");
        var snapshots = new List<CloudSnapshot>();
        using var host = new CloudSourcePump(window.Dispatcher, snapshot =>
        {
            snapshots.Add(snapshot);
            view.ApplyCloudSource(snapshot);
        }, RunFixture, pollInterval: TimeSpan.FromMinutes(1));
        try
        {
            host.SetEnabled(true);
            WaitUntil(() => !host.InFlight && snapshots.Any(snapshot => snapshot.Scanned), "empty response completes");
            Check(view.CurrentTasks.Count == 0 && HasText(window, "Cloud task status unconfirmed") &&
                  !HasText(window, "No active tasks"), "empty CLI response does not prove all cloud tasks absent");
            host.SetEnabled(false);
            Check(HasText(window, "No active tasks"), "disabled cloud restores normal empty state");
        }
        finally { window.Close(); }
    }

    private static void CloudAndClaudeIsolation()
    {
        Mode("pages");
        var (window, view) = Open("active", "en", "dark");
        using var host = new CloudSourcePump(window.Dispatcher, view.ApplyCloudSource, RunFixture,
            pollInterval: TimeSpan.FromMinutes(1));
        try
        {
            host.SetEnabled(true);
            WaitUntil(() => !host.InFlight && view.CurrentTasks.Count == 4, "cloud scan completes before Claude update");
            view.ApplyClaudeSource(new AITaskMonitor.Claude.ClaudeSourceSnapshot([], true));
            Check(view.CurrentTasks.Count == 3 && view.CurrentTasks.Count(task => task.Provider == "codex") == 3 &&
                  HasText(window, "No data from Claude Code"), "Claude loss retains local and cloud Codex tasks");
            host.RequestRefresh();
            WaitUntil(() => !host.InFlight, "cloud refresh completes after Claude loss");
            Check(view.CurrentTasks.Count == 3 && HasText(window, "No data from Claude Code"),
                "cloud refresh does not clear Claude source warning");
            view.ApplyClaudeSource(new AITaskMonitor.Claude.ClaudeSourceSnapshot([], false));
            Check(view.CurrentTasks.Count == 3 && !HasText(window, "No data from Claude Code"),
                "Claude recovery keeps both Codex sources");
        }
        finally { window.Close(); }
    }

    private static CloudSnapshot CloudTasks(int count)
    {
        var source = new CodexCloudSource();
        source.SetEnabled(true);
        CloudPageRequest request = source.BeginScan()!;
        int firstCount = Math.Min(count, 20);
        var first = Enumerable.Range(0, firstCount)
            .Select(index => new { id = "compact-" + index, title = "Fixture " + index, status = "pending" }).ToArray();
        CloudPageResult result = source.AcceptPage(request,
            JsonSerializer.SerializeToUtf8Bytes(new { tasks = first, cursor = count > 20 ? "next" : null }));
        if (count > 20)
        {
            Check(result.Disposition == CloudPageDisposition.NextPage && result.NextRequest is not null,
                "compact-count fixture requests another page");
            var second = Enumerable.Range(20, count - 20)
                .Select(index => new { id = "compact-" + index, title = "Fixture " + index, status = "pending" }).ToArray();
            result = source.AcceptPage(result.NextRequest!, JsonSerializer.SerializeToUtf8Bytes(new { tasks = second, cursor = (string?)null }));
        }
        Check(result.Disposition == CloudPageDisposition.Complete && source.GetSnapshot().Tasks.Count == count,
            "compact-count fixture produces requested tasks");
        return source.GetSnapshot();
    }

    private static void CompactCountGrammar()
    {
        var cases = new (int Count, string Russian)[]
        {
            (1, "задача"), (2, "задачи"), (3, "задачи"), (4, "задачи"), (5, "задач"),
            (11, "задач"), (12, "задач"), (13, "задач"), (14, "задач"),
            (21, "задача"), (22, "задачи"), (25, "задач")
        };
        foreach (string language in new[] { "ru", "en" })
        {
            var (window, view) = Open("active", language, "dark");
            try
            {
                ((Button)window.FindName("MinimizeButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                foreach (var item in cases)
                {
                    // Two local cards plus count + 1 cloud cards leave count past the first three.
                    view.ApplyCloudSource(CloudTasks(item.Count + 1));
                    window.UpdateLayout();
                    var more = (TextBlock)window.FindName("CompactMoreText");
                    string expected = language == "en"
                        ? $"{item.Count} more {(item.Count == 1 ? "task" : "tasks")}"
                        : $"Ещё {item.Count} {item.Russian}";
                    Check(more.IsVisible && more.Text == expected, "compact task-count grammar");
                    if (item.Count is 1 or 21)
                        Capture(window, $"compact-count-{language}-{item.Count}.png");
                }
            }
            finally { window.Close(); }
        }
    }

    private static void LateAfterReconnect()
    {
        Mode("pages");
        var (window, view) = Open("active", "en", "dark");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int calls = 0;
        var delivered = new List<int>();
        async Task<CommandResult> Runner(string? cursor, TimeSpan timeout, CancellationToken token)
        {
            int call = Interlocked.Increment(ref calls);
            CommandResult result = await RunFixture(cursor, timeout, token).ConfigureAwait(false);
            if (call == 1) { entered.TrySetResult(); await release.Task.ConfigureAwait(false); }
            return result;
        }
        using var host = new CloudSourcePump(window.Dispatcher, snapshot =>
        {
            delivered.Add(snapshot.Tasks.Count);
            view.ApplyCloudSource(snapshot);
        }, Runner, scanLimit: TimeSpan.FromSeconds(20), pollInterval: TimeSpan.FromMinutes(1));
        try
        {
            host.SetEnabled(true);
            WaitUntil(() => entered.Task.IsCompleted, "first response held");
            host.SetEnabled(false);
            host.SetEnabled(true);
            Check(host.InFlight && calls == 1 && view.CurrentTasks.Count == 2, "reconnect cannot overlap the old scan");
            release.TrySetResult();
            WaitUntil(() => !host.InFlight && view.CurrentTasks.Count == 4, "new generation completes");
            Check(calls == 3 && delivered.All(count => count is 0 or 2), "late page never publishes or starts extra work");
        }
        finally { release.TrySetResult(); window.Close(); }
    }

    private static void DeadlineAndSlot()
    {
        Mode("pages");
        var (window, view) = Open("empty", "en", "dark");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int calls = 0;
        async Task<CommandResult> Runner(string? cursor, TimeSpan timeout, CancellationToken token)
        {
            int call = Interlocked.Increment(ref calls);
            CommandResult result = await RunFixture(cursor, timeout, token).ConfigureAwait(false);
            if (call == 1) { entered.TrySetResult(); await release.Task.ConfigureAwait(false); }
            return result;
        }
        using var host = new CloudSourcePump(window.Dispatcher, view.ApplyCloudSource, Runner,
            scanLimit: TimeSpan.FromSeconds(6), pageLimit: TimeSpan.FromSeconds(6), pollInterval: TimeSpan.FromMinutes(1));
        try
        {
            host.SetEnabled(true);
            WaitUntil(() => entered.Task.IsCompleted, "deadline fixture response held");
            WaitUntil(() => host.InFlight && HasText(window, "No data from Codex Cloud"), "deadline marks source unavailable");
            Check(calls == 1 && view.CurrentTasks.Count == 0, "deadline does not launch another worker");
            release.TrySetResult();
            WaitUntil(() => !host.InFlight, "late worker completes");
            Check(view.CurrentTasks.Count == 0 && HasText(window, "No data from Codex Cloud"), "late response remains hidden");
            host.RequestRefresh();
            WaitUntil(() => !host.InFlight && view.CurrentTasks.Count == 2, "subsequent scan can recover");
        }
        finally { release.TrySetResult(); window.Close(); }
    }

    private static void AnotherOwnerCannotOverlap()
    {
        Mode("pages");
        var (firstWindow, firstView) = Open("empty", "en", "dark");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int firstPresentations = 0, secondCalls = 0;
        async Task<CommandResult> HeldRunner(string? cursor, TimeSpan timeout, CancellationToken token)
        {
            CommandResult result = await RunFixture(cursor, timeout, token).ConfigureAwait(false);
            entered.TrySetResult();
            await release.Task.ConfigureAwait(false);
            return result;
        }
        Task<CommandResult> SecondRunner(string? cursor, TimeSpan timeout, CancellationToken token)
        {
            Interlocked.Increment(ref secondCalls);
            return RunFixture(cursor, timeout, token);
        }
        using var first = new CloudSourcePump(firstWindow.Dispatcher, snapshot =>
        {
            firstPresentations++;
            firstView.ApplyCloudSource(snapshot);
        }, HeldRunner, scanLimit: TimeSpan.FromSeconds(20), pollInterval: TimeSpan.FromMinutes(1));
        Window? secondWindow = null;
        CloudSourcePump? second = null;
        try
        {
            first.SetEnabled(true);
            WaitUntil(() => entered.Task.IsCompleted, "first owner holds its scan");
            first.Dispose();
            int presentationsAtDispose = firstPresentations;
            var opened = Open("empty", "en", "dark");
            secondWindow = opened.Window;
            second = new CloudSourcePump(secondWindow.Dispatcher, opened.View.ApplyCloudSource, SecondRunner,
                pollInterval: TimeSpan.FromMinutes(1));
            second.SetEnabled(true);
            Check(secondCalls == 0 && !second.InFlight && HasText(secondWindow, "No data from Codex Cloud"),
                "second owner cannot overlap disposed in-flight owner");
            release.TrySetResult();
            WaitUntil(() => !first.InFlight, "disposed owner completes");
            Check(firstPresentations == presentationsAtDispose, "disposed owner does not present late results");
            second.RequestRefresh();
            WaitUntil(() => !second.InFlight && opened.View.CurrentTasks.Count == 2, "second owner can start after clean exit");
        }
        finally
        {
            release.TrySetResult();
            second?.Dispose();
            secondWindow?.Close();
            firstWindow.Close();
        }
    }

    private static bool MutexAvailable(Mutex mutex, TimeSpan timeout)
    {
        try
        {
            if (!mutex.WaitOne(timeout)) return false;
            mutex.ReleaseMutex();
            return true;
        }
        catch (AbandonedMutexException)
        {
            mutex.ReleaseMutex();
            return true;
        }
    }

    private static void CancelRunningChild()
    {
        string id = Guid.NewGuid().ToString("N");
        Environment.SetEnvironmentVariable("AITM_CLOUDHOST_SIGNAL", id);
        Mode("hold");
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, "Local\\AITM.CloudHost.Ready." + id, out bool created);
        Check(created, "fixture signal unique");
        var (window, view) = Open("active", "en", "dark");
        var delivered = new List<int>();
        using var host = new CloudSourcePump(window.Dispatcher, snapshot =>
        {
            delivered.Add(snapshot.Tasks.Count);
            view.ApplyCloudSource(snapshot);
        }, RunFixture, pollInterval: TimeSpan.FromMinutes(1));
        try
        {
            host.SetEnabled(true);
            WaitUntil(() => ready.WaitOne(0), "running child signals readiness");
            using Mutex lifetime = Mutex.OpenExisting("Local\\AITM.CloudHost.Lifetime." + id);
            Check(!MutexAvailable(lifetime, TimeSpan.Zero), "synthetic child is alive before cancellation");
            host.SetEnabled(false);
            Check(view.CurrentTasks.Count == 2, "disconnect while running clears cloud only");
            WaitUntil(() => !host.InFlight, "cancelled child worker exits");
            Check(MutexAvailable(lifetime, TimeSpan.FromSeconds(2)), "cancelled synthetic child really exited");
            Check(delivered.All(count => count == 0), "cancelled child does not publish");
        }
        finally { window.Close(); }
    }

    private static void UnconfirmedExitBlocksNewScans()
    {
        // Construct an explicitly synthetic result without starting a process.
        // The command component's actual kill behavior has separate process tests.
        ConstructorInfo? constructor = typeof(CommandResult).GetConstructor(
            BindingFlags.Instance | BindingFlags.NonPublic, null,
            [typeof(CommandOutcome), typeof(bool), typeof(bool), typeof(byte[])], null);
        Check(constructor is not null, "synthetic command-result constructor exists");
        int firstCalls = 0, secondCalls = 0;
        Task<CommandResult> UnknownExit(string? cursor, TimeSpan timeout, CancellationToken cancellation)
        {
            Interlocked.Increment(ref firstCalls);
            var result = (CommandResult)constructor!.Invoke([CommandOutcome.TerminationUnconfirmed, true, false, null]);
            return Task.FromResult(result);
        }
        Task<CommandResult> SecondRunner(string? cursor, TimeSpan timeout, CancellationToken cancellation)
        {
            Interlocked.Increment(ref secondCalls);
            return RunFixture(cursor, timeout, cancellation);
        }

        var (firstWindow, firstView) = Open("empty", "en", "dark");
        var (secondWindow, secondView) = Open("empty", "en", "dark");
        using var first = new CloudSourcePump(firstWindow.Dispatcher, firstView.ApplyCloudSource, UnknownExit,
            pollInterval: TimeSpan.FromMinutes(1));
        using var second = new CloudSourcePump(secondWindow.Dispatcher, secondView.ApplyCloudSource, SecondRunner,
            pollInterval: TimeSpan.FromMinutes(1));
        try
        {
            first.SetEnabled(true);
            WaitUntil(() => !first.InFlight && HasText(firstWindow, "No data from Codex Cloud"),
                "unconfirmed exit reports unavailable");
            first.RequestRefresh();
            Check(firstCalls == 1 && !first.InFlight, "unconfirmed exit blocks retry in same owner");
            second.SetEnabled(true);
            Check(secondCalls == 0 && !second.InFlight && HasText(secondWindow, "No data from Codex Cloud"),
                "unconfirmed exit blocks a new owner");
        }
        finally
        {
            firstWindow.Close();
            secondWindow.Close();
        }
    }

    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr state);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr state);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public UIntPtr DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int PriorityBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string Executable;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static IntPtr FindOwnedWindow(int processId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((handle, state) =>
        {
            _ = GetWindowThreadProcessId(handle, out uint owner);
            if (owner != (uint)processId || !IsWindowVisible(handle)) return true;
            var title = new StringBuilder(128);
            _ = GetWindowText(handle, title, title.Capacity);
            if (title.ToString() != "AI task monitor") return true;
            found = handle;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    private static void CheckNoPowerShellDescendants(int processId)
    {
        IntPtr snapshot = CreateToolhelp32Snapshot(0x00000002, 0);
        Check(snapshot != new IntPtr(-1), "synthetic process snapshot available");
        try
        {
            var all = new List<(uint Id, uint Parent, string Name)>();
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>(), Executable = "" };
            if (Process32First(snapshot, ref entry))
            {
                do { all.Add((entry.ProcessId, entry.ParentProcessId, entry.Executable)); }
                while (Process32Next(snapshot, ref entry));
            }
            else throw new CheckFailure("synthetic process snapshot readable");
            var queue = new Queue<uint>();
            var seen = new HashSet<uint> { (uint)processId };
            queue.Enqueue((uint)processId);
            while (queue.Count > 0)
            {
                uint parent = queue.Dequeue();
                foreach (var child in all.Where(item => item.Parent == parent && seen.Add(item.Id)))
                {
                    Check(!string.Equals(child.Name, "powershell.exe", StringComparison.OrdinalIgnoreCase) &&
                          !string.Equals(child.Name, "pwsh.exe", StringComparison.OrdinalIgnoreCase),
                          "no PowerShell descendant observed");
                    queue.Enqueue(child.Id);
                }
            }
        }
        finally { _ = CloseHandle(snapshot); }
    }

    private static bool HasAutomationText(IntPtr handle, string value)
    {
        AutomationElement element = AutomationElement.FromHandle(handle);
        return element.FindFirst(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.NameProperty, value)) is not null;
    }

    private static void DefaultEntrypointSmoke()
    {
        string executable = Path.Combine(root, "artifacts", "bin", "Prototype", "release", "AI Task Monitor.exe");
        Check(File.Exists(executable) && (File.GetAttributes(executable) & FileAttributes.ReparsePoint) == 0,
            "isolated product entrypoint exists");
        CheckDirectoryPath(Path.GetDirectoryName(executable)!, root);
        string ready = Path.Combine(root, "default-ready.txt");
        string screenshot = Path.Combine(root, "default-empty.png");
        Check(!File.Exists(ready) && !File.Exists(screenshot), "default output paths are new");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = root
        };
        foreach (string argument in new[] { "--offscreen", "--ready-file", ready, "--snapshot", screenshot })
            start.ArgumentList.Add(argument);
        start.Environment["DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"] = "0";
        using var process = new Process { StartInfo = start };
        bool started = false;
        try
        {
            started = process.Start();
            Check(started, "product entrypoint starts");
            WaitUntil(() => File.Exists(ready) || process.HasExited, "product entrypoint signals readiness");
            Check(!process.HasExited && File.Exists(ready) && File.Exists(screenshot), "product window remains open");
            IntPtr handle = IntPtr.Zero;
            WaitUntil(() => (handle = FindOwnedWindow(process.Id)) != IntPtr.Zero, "product window is owned by executable");
            Check(GetWindowThreadProcessId(handle, out uint owner) != 0 && owner == (uint)process.Id, "window owner matches process");
            WaitUntil(() => HasAutomationText(handle, "Активных задач сейчас нет"), "default empty text is visible");
            Check(!HasAutomationText(handle, "Создать индикатор прогресса задач") &&
                  !HasAutomationText(handle, "Задача Claude Code"), "default window has no demonstration cards");
            Check(!process.Modules.Cast<ProcessModule>().Any(module =>
                string.Equals(module.ModuleName, "System.Management.Automation.dll", StringComparison.OrdinalIgnoreCase)),
                "PowerShell engine not loaded");
            for (int i = 0; i < 3; i++)
            {
                CheckNoPowerShellDescendants(process.Id);
                Thread.Sleep(100);
            }
            Check(PostMessage(handle, 0x0010, IntPtr.Zero, IntPtr.Zero), "close request delivered");
            Check(process.WaitForExit(5000) && process.ExitCode == 0, "product entrypoint closes cleanly");
        }
        finally
        {
            if (started && !process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); _ = process.WaitForExit(5000); }
                catch (InvalidOperationException) { }
            }
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            RequireHosted(args);
            Check(Options.TryParse([], out Options? defaults) && defaults!.Scene == "empty", "default entrypoint has no demo");
            Check(Options.TryParse(["--scene", "active"], out Options? preview) && preview!.Scene == "active",
                "explicit preview scene remains available");
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            DefaultEntrypointSmoke();
            foreach (string language in new[] { "ru", "en" })
                foreach (string theme in new[] { "dark", "light" })
                    Flow(language, theme);
            EmptyCoverage();
            CloudAndClaudeIsolation();
            CompactCountGrammar();
            LateAfterReconnect();
            DeadlineAndSlot();
            AnotherOwnerCannotOverlap();
            CancelRunningChild();
            UnconfirmedExitBlocksNewScans();
            app.Shutdown();
            Console.WriteLine("Synthetic cloud-to-WPF checks passed: " + checks);
            return 0;
        }
        catch (CheckFailure failure)
        {
            Console.Error.WriteLine("Synthetic cloud-host check failed: " + failure.Message);
            return 1;
        }
        catch (Exception)
        {
            Console.Error.WriteLine("Synthetic cloud-host checks failed.");
            return 1;
        }
    }
}

