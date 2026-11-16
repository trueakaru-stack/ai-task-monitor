using System.Diagnostics;
using System.IO;
using System.Reflection;
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
using AITaskMonitor.Claude;
using AITaskMonitor.Prototype;

internal static class Program
{
    private static int checks;
    private static readonly string[] HookEvents = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "TaskCreated", "TaskCompleted",
        "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"];

    private static void Check(bool value, string description)
    {
        checks++;
        if (!value) throw new InvalidOperationException(description);
    }

    private static string RequireIsolatedRunner()
    {
        Check(OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("CI") == "true" &&
              Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
              Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted" &&
              Environment.GetEnvironmentVariable("RUNNER_OS") == "Windows" &&
              Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0",
              "Disposable hosted Windows is required.");
        string runner = Path.TrimEndingDirectorySeparator(Path.GetFullPath(
            Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? ""));
        string temp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath()));
        DirectoryInfo? rootInfo = new DirectoryInfo(temp).Parent?.Parent;
        Check(rootInfo is not null &&
              string.Equals(rootInfo.Parent?.FullName, runner, StringComparison.OrdinalIgnoreCase) &&
              Regex.IsMatch(rootInfo.Name, "^aitm-claude-anchor-[0-9a-f]{32}$", RegexOptions.CultureInvariant) &&
              string.Equals(temp, Path.Combine(rootInfo.FullName, "isolated", "temp"), StringComparison.OrdinalIgnoreCase),
              "Synthetic temporary directory is required.");
        string root = rootInfo!.FullName;
        foreach (string name in new[] { "USERPROFILE", "APPDATA", "LOCALAPPDATA" })
        {
            string suffix = name == "USERPROFILE" ? "profile" : name == "APPDATA" ? "appdata" : "localappdata";
            Check(string.Equals(Path.GetFullPath(Environment.GetEnvironmentVariable(name) ?? ""),
                Path.Combine(root, "isolated", suffix), StringComparison.OrdinalIgnoreCase),
                "A synthetic profile environment is required.");
        }
        string expected = Path.Combine(root, "artifacts", "bin", "ClaudeRuntimeHost.Tests", "release",
            "AITaskMonitor.Prototype.Tests.dll");
        Check(string.Equals(Path.GetFullPath(Assembly.GetExecutingAssembly().Location), expected, StringComparison.OrdinalIgnoreCase),
            "A synthetic test assembly is required.");
        for (DirectoryInfo? item = new(root); item is not null; item = item.Parent)
            Check((item.Attributes & FileAttributes.ReparsePoint) == 0, "Synthetic root has a redirected ancestor.");
        return root;
    }

    private static string Settings(string hook, bool complete)
    {
        string script = "& '" + hook.Replace("'", "''", StringComparison.Ordinal) + "'";
        string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        var groups = new Dictionary<string, object>();
        foreach (string name in HookEvents)
        {
            if (!complete && name == "StopFailure") continue;
            groups[name] = new object[] { new { hooks = new object[] {
                new { type = "command", command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand " + encoded, timeout = 10 }
            } } };
        }
        return JsonSerializer.Serialize(new { hooks = groups });
    }

    private static void ApplySyntheticEnvironment(ProcessStartInfo start)
    {
        start.Environment.Clear();
        foreach (string name in new[] { "SystemRoot", "windir", "PATH", "DOTNET_ROOT", "DOTNET_CLI_HOME",
            "DOTNET_CLI_TELEMETRY_OPTOUT", "DOTNET_GENERATE_ASPNET_CERTIFICATE", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE",
            "DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP",
            "CI", "GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS", "RUNNER_TEMP", "ProgramFiles", "ProgramW6432",
            "ProgramData", "ALLUSERSPROFILE", "SystemDrive", "ComSpec" })
        {
            string? value = Environment.GetEnvironmentVariable(name);
            if (value is not null) start.Environment[name] = value;
        }
        start.Environment["DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"] = "0";
    }

    private static void Emit(string hook, object payload, string work)
    {
        string system = Environment.GetEnvironmentVariable("SystemRoot") ?? throw new InvalidOperationException();
        var start = new ProcessStartInfo(Path.Combine(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = work,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        ApplySyntheticEnvironment(start);
        start.Environment["AI_TASK_MONITOR_AUDIT"] = "1";
        foreach (string item in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", hook })
            start.ArgumentList.Add(item);
        using Process child = Process.Start(start) ?? throw new InvalidOperationException("Synthetic hook did not start.");
        Task<string> output = child.StandardOutput.ReadToEndAsync();
        Task<string> errors = child.StandardError.ReadToEndAsync();
        child.StandardInput.Write(JsonSerializer.Serialize(payload));
        child.StandardInput.Close();
        if (!child.WaitForExit(15000)) { child.Kill(true); throw new TimeoutException("Synthetic hook timed out."); }
        Check(child.ExitCode == 0 && output.GetAwaiter().GetResult().Length == 0 &&
            errors.GetAwaiter().GetResult().Length == 0, "Released hook failed for a synthetic input.");
    }

    private static void WaitUntil(Func<bool> condition, string description, int seconds = 20)
    {
        var frame = new DispatcherFrame();
        DateTime deadline = DateTime.UtcNow.AddSeconds(seconds);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(30) };
        timer.Tick += (_, _) => { if (condition() || DateTime.UtcNow >= deadline) frame.Continue = false; };
        timer.Start();
        Dispatcher.PushFrame(frame);
        timer.Stop();
        Check(condition(), description);
    }

    private static Window NewWindow(string language, string theme, bool compact, out PrototypeWindow controller)
    {
        using Stream resource = typeof(PrototypeWindow).Assembly.GetManifestResourceStream(
            "AITaskMonitor.Prototype.PublishedWindow.xaml") ?? throw new InvalidOperationException();
        var window = (Window)XamlReader.Load(resource);
        controller = new PrototypeWindow(window, new Options(theme, language, "empty", compact, true, null, null, false));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        return window;
    }

    private static void CaptureVariants(ClaudeSourceSnapshot snapshot, string root)
    {
        string output = Path.Combine(root, "visuals");
        Directory.CreateDirectory(output);
        foreach (string language in new[] { "ru", "en" })
        foreach (string theme in new[] { "light", "dark" })
        foreach (bool compact in new[] { false, true })
        {
            Window window = NewWindow(language, theme, compact, out PrototypeWindow controller);
            try
            {
                controller.ApplyClaudeSource(snapshot);
                window.UpdateLayout();
                var image = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),
                    (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
                image.Render(window);
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(image));
                using var file = new FileStream(Path.Combine(output,
                    language + "-" + theme + "-" + (compact ? "compact" : "full") + ".png"), FileMode.CreateNew, FileAccess.Write);
                encoder.Save(file);
                Check(controller.CurrentTasks.Count == 1 && controller.CurrentTasks[0].Status == "unknown",
                    "A rendered variant lost the unconfirmed task.");
            }
            finally { window.Close(); }
        }
    }

    private static bool HasName(Process host, string text)
    {
        try
        {
            host.Refresh();
            if (host.HasExited || host.MainWindowHandle == IntPtr.Zero) return false;
            AutomationElement? root = AutomationElement.FromHandle(host.MainWindowHandle);
            if (root is null) return false;
            return root.FindFirst(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.NameProperty, text)) is not null;
        }
        catch (ElementNotAvailableException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    private static void CheckActualEntryPoint(string root, ClaudeRegisteredHookPaths paths)
    {
        string exe = Path.Combine(root, "artifacts", "bin", "Prototype", "release", "AI Task Monitor.exe");
        Check(File.Exists(exe), "The synthetic WPF executable is missing.");
        var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = root };
        ApplySyntheticEnvironment(start);
        using Process host = Process.Start(start) ?? throw new InvalidOperationException("The synthetic host did not start.");
        try
        {
            WaitUntil(() => HasName(host, "Статус задач не подтверждён"), "The normal entry point did not discover the synthetic registration.");
            Emit(paths.Hook, new { hook_event_name = "UserPromptSubmit", session_id = "host-fixture" }, root);
            WaitUntil(() => HasName(host, "Задача Claude Code") && HasName(host, "Статус не подтверждён"),
                "The normal entry point did not render the released hook event as unconfirmed.");
            Emit(paths.Hook, new { hook_event_name = "Stop", session_id = "host-fixture",
                background_tasks = Array.Empty<object>(), session_crons = Array.Empty<object>() }, root);
            WaitUntil(() => !HasName(host, "Задача Claude Code") && HasName(host, "Статус задач не подтверждён"),
                "The normal entry point did not update after the synthetic stop.");
            Check(host.CloseMainWindow() && host.WaitForExit(8000), "The synthetic host did not close gracefully.");
        }
        finally { if (!host.HasExited) { host.Kill(true); host.WaitForExit(5000); } }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 0) throw new ArgumentException("The test accepts no external input.");
            string root = RequireIsolatedRunner();
            Check(ClaudeRegisteredHookPaths.TryFromEnvironment(out ClaudeRegisteredHookPaths? value) && value is not null,
                "Synthetic default paths could not be discovered.");
            ClaudeRegisteredHookPaths paths = value!;
            Check(File.Exists(paths.Hook) && File.Exists(Path.Combine(Path.GetDirectoryName(paths.Hook)!, "ClaudeStageObservation.dll")),
                "The copied released hook and helper are missing.");
            Check(ClaudeRegisteredHookOwner.Inspect(paths) == ClaudeRegistration.Absent, "Missing synthetic settings must not enable a source.");
            Directory.CreateDirectory(Path.GetDirectoryName(paths.Settings)!);
            Directory.CreateDirectory(Path.GetDirectoryName(paths.CurrentJournal)!);
            string complete = Settings(paths.Hook, true), partial = Settings(paths.Hook, false);
            File.WriteAllText(paths.Settings, partial, new UTF8Encoding(false));
            Check(ClaudeRegisteredHookOwner.Inspect(paths) == ClaudeRegistration.Partial, "Partial synthetic registration was not recognized.");
            File.WriteAllText(paths.Settings, complete, new UTF8Encoding(false));
            Check(ClaudeRegisteredHookOwner.Inspect(paths) == ClaudeRegistration.Registered, "Complete synthetic registration was not recognized.");
            string link = Path.Combine(Path.GetDirectoryName(paths.Settings)!, "synthetic-link.json");
            File.CreateSymbolicLink(link, paths.Settings);
            Check(ClaudeRegisteredHookOwner.Inspect(paths with { Settings = link }) == ClaudeRegistration.Unavailable,
                "A redirected settings file must not be treated as verified.");

            var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            Window window = NewWindow("ru", "dark", false, out PrototypeWindow controller);
            ClaudeSourceSnapshot? latest = null;
            int presentations = 0;
            var owner = new ClaudeRegisteredHookOwner(window.Dispatcher, paths, snapshot =>
            {
                latest = snapshot;
                presentations++;
                controller.ApplyClaudeSource(snapshot);
            }, interval: TimeSpan.FromHours(1));
            try
            {
                owner.Start();
                WaitUntil(() => presentations > 0, "The synthetic registration was not polled.");
                Check(controller.CurrentTasks.Count == 0 && latest is { Unavailable: false }, "The empty source state is wrong.");
                Emit(paths.Hook, new { hook_event_name = "UserPromptSubmit", session_id = "synthetic-session" }, root);
                Emit(paths.Hook, new { hook_event_name = "TaskCreated", session_id = "synthetic-session",
                    task_id = "step-1", task_subject = "Synthetic step" }, root);
                WaitUntil(() => controller.CurrentTasks.Any(task => task.Provider == "claude"), "The hook event did not reach WPF.");
                SampleTask first = controller.CurrentTasks.Single(task => task.Provider == "claude");
                Check(first.Status == "unknown" && !first.PlanConfirmed && first.Progress is null,
                    "The real hook evidence must remain unconfirmed.");
                WaitUntil(() => controller.CurrentTasks.Single(task => task.Provider == "claude").Steps.Any(step => step.Title == "Synthetic step"),
                    "The released hook step was not displayed.");
                CaptureVariants(latest!, root);
                Emit(paths.Hook, new { hook_event_name = "Stop", session_id = "synthetic-session",
                    background_tasks = Array.Empty<object>(), session_crons = Array.Empty<object>() }, root);
                WaitUntil(() => controller.CurrentTasks.All(task => task.Provider != "claude"), "A clear synthetic stop was not observed.");
                Emit(paths.Hook, new { hook_event_name = "UserPromptSubmit", session_id = "synthetic-second" }, root);
                WaitUntil(() => controller.CurrentTasks.Any(task => task.Provider == "claude"), "A subsequent synthetic task was not shown.");
                File.WriteAllText(paths.Settings, partial, new UTF8Encoding(false));
                owner.RequestInspection();
                WaitUntil(() => latest is { Unavailable: true }, "Partial registration did not make the source unavailable.");
                Check(controller.CurrentTasks.Single(task => task.Provider == "claude").Status == "unknown",
                    "A partial source retained a confirmed card.");
                int beforeDelayedStop = presentations;
                Emit(paths.Hook, new { hook_event_name = "Stop", session_id = "synthetic-second",
                    background_tasks = Array.Empty<object>(), session_crons = Array.Empty<object>() }, root);
                WaitUntil(() => presentations > beforeDelayedStop &&
                    controller.CurrentTasks.Any(task => task.Provider == "claude") && latest is { Unavailable: true },
                    "Connection loss must retain the known unconfirmed card.");
            }
            finally { owner.Dispose(); window.Close(); }

            File.WriteAllText(paths.Settings, complete, new UTF8Encoding(false));
            CheckActualEntryPoint(root, paths);
            application.Shutdown();
            Console.WriteLine("Claude registered-hook-to-WPF: " + checks + " synthetic checks passed.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Claude synthetic host check failed: " + error);
            return 1;
        }
    }
}
