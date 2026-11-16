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
using AITaskMonitor.Prototype.Settings;

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
        string systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? throw new InvalidOperationException();
        string programFiles = Environment.GetEnvironmentVariable("ProgramFiles") ?? throw new InvalidOperationException();
        start.Environment["PSModulePath"] =
            Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "Modules") + ";" +
            Path.Combine(programFiles, "WindowsPowerShell", "Modules");
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

    private enum NameObservation { Found, ProcessExited, NoWindow, NoRoot, Missing, ElementUnavailable, InvalidOperation }

    // Require two consecutive positive observations, without extending the
    // original 20-second deadline. A transient False restarts the sequence.
    private static void WaitUntilStable(Func<NameObservation> condition, string description, TextWriter evidence, int timeoutMs = 20000)
    {
        var frame = new DispatcherFrame();
        var watch = Stopwatch.StartNew();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(30) };
        var counts = new Dictionary<NameObservation, int>();
        var recent = new Queue<NameObservation>();
        int consecutive = 0, polls = 0;
        bool stable = false, deadlineHit = false;
        timer.Tick += (_, _) =>
        {
            NameObservation sample = condition();
            polls++;
            counts[sample] = counts.TryGetValue(sample, out int count) ? count + 1 : 1;
            recent.Enqueue(sample); if (recent.Count > 6) recent.Dequeue();
            consecutive = sample == NameObservation.Found ? consecutive + 1 : 0;
            if (watch.ElapsedMilliseconds >= timeoutMs) deadlineHit = true;
            else if (consecutive >= 2) stable = true;
            if (stable || deadlineHit) frame.Continue = false;
        };
        timer.Start();
        try { Dispatcher.PushFrame(frame); }
        finally { timer.Stop(); }
        evidence.WriteLine("Synthetic stable wait: stable=" + stable + " deadline=" + deadlineHit +
            " polls=" + polls + " elapsedMs=" + watch.ElapsedMilliseconds +
            " counts=" + String.Join(",", counts.OrderBy(x => x.Key).Select(x => x.Key + ":" + x.Value)) +
            " recent=" + String.Join(",", recent));
        Check(stable, description);
    }

    private static void CheckStableWait()
    {
        var sequence = new[] { NameObservation.Found, NameObservation.Missing, NameObservation.Found, NameObservation.Found };
        int index = 0;
        using (var evidence = new StringWriter())
        {
            WaitUntilStable(() => sequence[Math.Min(index++, sequence.Length - 1)],
                "A temporary missing observation did not recover.", evidence, 1000);
            Check(index == 4 && evidence.ToString().Contains("Found,Missing,Found,Found", StringComparison.Ordinal),
                "Stable wait must reset after a transient missing result.");
        }
        int alternating = 0;
        bool rejectedAlternating = false;
        using (var evidence = new StringWriter())
        {
            try
            {
                WaitUntilStable(() => Interlocked.Increment(ref alternating) % 2 == 1
                    ? NameObservation.Found : NameObservation.Missing,
                    "Synthetic alternating observations.", evidence, 240);
            }
            catch (InvalidOperationException) { rejectedAlternating = true; }
            Check(rejectedAlternating && evidence.ToString().Contains("deadline=True", StringComparison.Ordinal),
                "Alternating results must not pass without two consecutive observations.");
        }
        bool rejectedMissing = false;
        using (var evidence = new StringWriter())
        {
            try { WaitUntilStable(() => NameObservation.Missing, "Synthetic missing observation.", evidence, 180); }
            catch (InvalidOperationException) { rejectedMissing = true; }
            Check(rejectedMissing && evidence.ToString().Contains("deadline=True", StringComparison.Ordinal),
                "A consistently missing observation must fail at the deadline.");
        }
    }

    private static Window NewWindow(string language, string theme, bool compact, out PrototypeWindow controller,
        DisplayPreferenceService? preferences = null)
    {
        using Stream resource = typeof(PrototypeWindow).Assembly.GetManifestResourceStream(
            "AITaskMonitor.Prototype.PublishedWindow.xaml") ?? throw new InvalidOperationException();
        var window = (Window)XamlReader.Load(resource);
        controller = new PrototypeWindow(window, new Options(theme, language, "empty", compact, true, null, null, false), preferences);
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000; window.Top = -10000; window.ShowActivated = false; window.ShowInTaskbar = false;
        window.Show(); window.UpdateLayout();
        return window;
    }

    private static void CheckRepeatedRenderRecreatesEmptyNode()
    {
        Window window = NewWindow("ru", "dark", false, out PrototypeWindow controller);
        try
        {
            var empty = new ClaudeSourceSnapshot([], false);
            controller.ApplyClaudeSource(empty);
            var panel = (StackPanel)window.FindName("TasksPanel");
            TextBlock first = panel.Children.OfType<TextBlock>().Single(item => item.Text == "Статус задач не подтверждён");
            controller.ApplyClaudeSource(empty);
            TextBlock second = panel.Children.OfType<TextBlock>().Single(item => item.Text == "Статус задач не подтверждён");
            Check(!ReferenceEquals(first, second) && !panel.Children.Contains(first),
                "Repeated synthetic Claude rendering did not replace its empty-state node.");
            Console.WriteLine("Synthetic identical Claude render replaced the empty-state UI element.");
        }
        finally { window.Close(); }
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

    private static NameObservation ObserveName(Process host, string text)
    {
        try
        {
            host.Refresh();
            if (host.HasExited) return NameObservation.ProcessExited;
            if (host.MainWindowHandle == IntPtr.Zero) return NameObservation.NoWindow;
            AutomationElement? root = AutomationElement.FromHandle(host.MainWindowHandle);
            if (root is null) return NameObservation.NoRoot;
            return root.FindFirst(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.NameProperty, text)) is null
                ? NameObservation.Missing : NameObservation.Found;
        }
        catch (ElementNotAvailableException) { return NameObservation.ElementUnavailable; }
        catch (InvalidOperationException) { return NameObservation.InvalidOperation; }
    }

    private static bool HasName(Process host, string text) => ObserveName(host, text) == NameObservation.Found;

    private static AutomationElement? FindById(Process host, string id)
    {
        try
        {
            host.Refresh();
            if (host.HasExited || host.MainWindowHandle == IntPtr.Zero) return null;
            AutomationElement? root = AutomationElement.FromHandle(host.MainWindowHandle);
            return root?.FindFirst(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.AutomationIdProperty, id));
        }
        catch (ElementNotAvailableException) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    private static void InvokeControl(Process host, string id)
    {
        WaitUntil(() => { AutomationElement? element = FindById(host, id); return element is not null && element.Current.IsEnabled; },
            "Synthetic control unavailable: " + id);
        AutomationElement element = FindById(host, id) ?? throw new InvalidOperationException(id);
        ((InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
    }

    private static void HoldWithoutCard(Process host, int milliseconds)
    {
        DateTime until = DateTime.UtcNow.AddMilliseconds(milliseconds);
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        bool observed = false;
        timer.Tick += (_, _) =>
        {
            observed |= HasName(host, "Задача Claude Code");
            if (observed || DateTime.UtcNow >= until) frame.Continue = false;
        };
        timer.Start(); Dispatcher.PushFrame(frame); timer.Stop();
        Check(!observed && !host.HasExited, "A pre-start event must not be presented as a current task.");
    }

    private static void ObserveEmptyState(Process host, int milliseconds)
    {
        var counts = new Dictionary<NameObservation, int>();
        int immediateRecovery = 0, otherEmptyState = 0, progressVisible = 0;
        DateTime until = DateTime.UtcNow.AddMilliseconds(milliseconds);
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        timer.Tick += (_, _) =>
        {
            NameObservation sample = ObserveName(host, "Статус задач не подтверждён");
            counts[sample] = counts.TryGetValue(sample, out int count) ? count + 1 : 1;
            if (sample != NameObservation.Found)
            {
                if (HasName(host, "Статус задач не подтверждён")) immediateRecovery++;
                if (HasName(host, "Источники не подключены") || HasName(host, "Нет данных от Claude Code")) otherEmptyState++;
                if (HasName(host, "Ход выполнения")) progressVisible++;
            }
            if (DateTime.UtcNow >= until) frame.Continue = false;
        };
        timer.Start();
        try { Dispatcher.PushFrame(frame); }
        finally { timer.Stop(); }
        Console.WriteLine("Synthetic UIA hold: counts=" +
            String.Join(",", counts.OrderBy(x => x.Key).Select(x => x.Key + ":" + x.Value)) +
            " immediateRecovery=" + immediateRecovery + " otherEmptyState=" + otherEmptyState +
            " progressVisibleAfterMiss=" + progressVisible);
    }

    private static void CheckPreviewDoesNotReadProfile(string root, ClaudeRegisteredHookPaths paths)
    {
        string exe = Path.Combine(root, "artifacts", "bin", "Prototype", "release", "AI Task Monitor.exe");
        string directory = Path.GetDirectoryName(paths.CurrentJournal)!;
        string legacy = Path.Combine(directory, "settings.json");
        string display = Path.Combine(directory, "display-preferences.json");
        string lockFile = display + ".lock";
        string ready = Path.Combine(root, "preview-ready.txt");
        byte[] original = Encoding.UTF8.GetBytes("{\"theme\":\"dark\",\"language\":\"en\"}");
        File.WriteAllBytes(legacy, original);
        Check(!File.Exists(display) && !File.Exists(lockFile), "Preview preferences must start absent.");
        var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = root };
        start.ArgumentList.Add("--ready-file");
        start.ArgumentList.Add(ready);
        ApplySyntheticEnvironment(start);
        using Process host = Process.Start(start) ?? throw new InvalidOperationException("The synthetic preview did not start.");
        try
        {
            WaitUntil(() => File.Exists(ready) && HasName(host, "Источники не подключены"),
                "The preview read the synthetic profile or did not start.");
            Emit(paths.Hook, new { hook_event_name = "UserPromptSubmit", session_id = "preview-fixture" }, root);
            HoldWithoutCard(host, 2500);
            Check(!HasName(host, "Claude Code task") && !File.Exists(display) && !File.Exists(lockFile) &&
                File.ReadAllBytes(legacy).AsSpan().SequenceEqual(original),
                "The preview used or modified synthetic profile data.");
            Check(host.CloseMainWindow() && host.WaitForExit(8000), "The synthetic preview did not close gracefully.");
        }
        finally { if (!host.HasExited) { host.Kill(true); host.WaitForExit(5000); } }
    }

    private static void ReportEntryPointFailure(Process host, ClaudeRegisteredHookPaths paths, string legacy, byte[] original, TextWriter output)
    {
        try
        {
            host.Refresh();
            bool exited = host.HasExited;
            output.WriteLine("Synthetic child exited=" + exited +
                (exited ? " exitCode=" + host.ExitCode : " hasMainWindow=" + (host.MainWindowHandle != IntPtr.Zero)));
        }
        catch (Exception error) { output.WriteLine("Synthetic child state error=" + error.GetType().Name); }
        try
        {
            output.WriteLine("Synthetic global registration=" + ClaudeRegisteredHookOwner.Inspect(paths) +
                ", legacyUnchanged=" + (File.Exists(legacy) && File.ReadAllBytes(legacy).AsSpan().SequenceEqual(original)));
        }
        catch (Exception error) { output.WriteLine("Synthetic fixture inspection error=" + error.GetType().Name); }
        try
        {
            host.Refresh();
            if (host.HasExited || host.MainWindowHandle == IntPtr.Zero)
            {
                output.WriteLine("Synthetic UIA root unavailable (no running window)");
                return;
            }
            AutomationElement? root = AutomationElement.FromHandle(host.MainWindowHandle);
            output.WriteLine("Synthetic UIA root=" + (root is not null));
            if (root is null) return;
            foreach (string name in new[] { "Статус задач не подтверждён", "Task status unconfirmed",
                "Нет данных от Claude Code", "No data from Claude Code", "Источники не подключены",
                "No sources connected", "Задача Claude Code", "Claude Code task", "Ход выполнения", "Progress",
                "__aitm_synthetic_missing_label__" })
            {
                try
                {
                    bool present = root.FindFirst(TreeScope.Descendants,
                        new PropertyCondition(AutomationElement.NameProperty, name)) is not null;
                    output.WriteLine("Synthetic UIA label [" + name + "]=" + present);
                }
                catch (Exception error) { output.WriteLine("Synthetic UIA label error=" + error.GetType().Name); }
            }
        }
        catch (Exception error) { output.WriteLine("Synthetic UIA root error=" + error.GetType().Name); }
    }

    private static void CheckActualEntryPoint(string root, ClaudeRegisteredHookPaths paths)
    {
        string exe = Path.Combine(root, "artifacts", "bin", "Prototype", "release", "AI Task Monitor.exe");
        Check(File.Exists(exe), "The synthetic WPF executable is missing.");
        string directory = Path.GetDirectoryName(paths.CurrentJournal)!;
        string legacy = Path.Combine(directory, "settings.json");
        string display = Path.Combine(directory, "display-preferences.json");
        byte[] original = Encoding.UTF8.GetBytes("{\"theme\":\"dark\",\"language\":\"ru\",\"unrelated\":\"preserve\"}");
        File.WriteAllBytes(legacy, original);
        Check(!File.Exists(display), "The synthetic display preferences already exist.");
        // The existing prompt predates the monitor. It cannot prove activity now.
        Emit(paths.Hook, new { hook_event_name = "UserPromptSubmit", session_id = "host-fixture" }, root);
        System.Threading.Thread.Sleep(250);
        var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = root };
        ApplySyntheticEnvironment(start);
        using Process host = Process.Start(start) ?? throw new InvalidOperationException("The synthetic host did not start.");
        try
        {
            try
            {
                WaitUntilStable(() => ObserveName(host, "Статус задач не подтверждён"),
                    "The normal entry point did not show the expected empty state.", Console.Out);
            }
            catch
            {
                ReportEntryPointFailure(host, paths, legacy, original, Console.Error);
                throw;
            }
            // Verify the diagnostic itself reports one known present and one
            // known absent label. Allow brief UIA gaps without accepting False.
            bool diagnosticVerified = false;
            string lastDiagnostic = "";
            for (int attempt = 0; attempt < 5 && !diagnosticVerified; attempt++)
            {
                using var diagnostic = new StringWriter();
                ReportEntryPointFailure(host, paths, legacy, original, diagnostic);
                lastDiagnostic = diagnostic.ToString();
                diagnosticVerified = lastDiagnostic.Contains("Synthetic child exited=False hasMainWindow=True", StringComparison.Ordinal) &&
                    lastDiagnostic.Contains("Synthetic global registration=Registered, legacyUnchanged=True", StringComparison.Ordinal) &&
                    lastDiagnostic.Contains("Synthetic UIA root=True", StringComparison.Ordinal) &&
                    lastDiagnostic.Contains("Synthetic UIA label [Статус задач не подтверждён]=True", StringComparison.Ordinal) &&
                    lastDiagnostic.Contains("Synthetic UIA label [__aitm_synthetic_missing_label__]=False", StringComparison.Ordinal);
                if (!diagnosticVerified && attempt < 4) Thread.Sleep(50);
            }
            Check(diagnosticVerified, "Synthetic entry-point diagnostics did not report known fixture state. " + lastDiagnostic);
            // Preserve the original negative interval; additional UIA tracing
            // runs separately so it cannot reduce the card-absence probes.
            HoldWithoutCard(host, 2500);
            ObserveEmptyState(host, 2500);
            Check(!HasName(host, "Источники не подключены") && !HasName(host, "Активных задач сейчас нет"),
                "A missing pre-start card was presented as a definitive absence.");
            // A later active event from the same session can make its prior context visible.
            Emit(paths.Hook, new { hook_event_name = "PreToolUse", session_id = "host-fixture", tool_name = "Read" }, root);
            WaitUntil(() => HasName(host, "Задача Claude Code") && HasName(host, "Статус не подтверждён"),
                "The normal entry point did not render later same-session activity as unconfirmed.");
            InvokeControl(host, "SettingsFooterButton");
            WaitUntil(() => HasName(host, "Настройки") && HasName(host, "Статус не подтверждён"),
                "The loaded Russian preferences or Claude registration status was not shown.");
            InvokeControl(host, "EnglishLanguageButton");
            WaitUntil(() => HasName(host, "Settings") && HasName(host, "Status unconfirmed"),
                "The real entry point did not preserve the Claude status through language selection.");
            WaitUntil(() => File.Exists(display), "The real entry point did not save synthetic display preferences.");
            using (JsonDocument saved = JsonDocument.Parse(File.ReadAllBytes(display)))
                Check(saved.RootElement.GetProperty("language").GetString() == "en", "The selected language was not saved.");
            Check(File.ReadAllBytes(legacy).AsSpan().SequenceEqual(original), "The old synthetic settings were changed.");
            InvokeControl(host, "SettingsBackButton");
            Emit(paths.Hook, new { hook_event_name = "Stop", session_id = "host-fixture",
                background_tasks = Array.Empty<object>(), session_crons = Array.Empty<object>() }, root);
            WaitUntil(() => !HasName(host, "Claude Code task") && HasName(host, "Task status unconfirmed"),
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
            CheckStableWait();
            CheckRepeatedRenderRecreatesEmptyNode();
            string preferenceRoot = Path.Combine(root, "owner-preferences");
            Directory.CreateDirectory(preferenceRoot);
            string oldPreferences = Path.Combine(preferenceRoot, "old.json");
            File.WriteAllText(oldPreferences, "{\"theme\":\"dark\",\"language\":\"ru\"}", new UTF8Encoding(false));
            var preferences = new PreferenceFiles(oldPreferences, Path.Combine(preferenceRoot, "display.json"));
            Window window = NewWindow("ru", "dark", false, out PrototypeWindow controller, preferences.Service);
            Check(!((Button)window.FindName("ClaudeSourceAction")).IsEnabled &&
                !((Button)window.FindName("AboutSettingsButton")).IsEnabled,
                "Unfinished connection or About actions must remain disabled.");
            File.WriteAllText(paths.Settings, "{\"hooks\":{}}", new UTF8Encoding(false));
            ClaudeSourceSnapshot? latest = null;
            ClaudeRegistration? registration = null;
            int presentations = 0;
            using var inspectionEntered = new ManualResetEventSlim();
            using var inspectionRelease = new ManualResetEventSlim();
            int blockInspection = 0;
            var owner = new ClaudeRegisteredHookOwner(window.Dispatcher, paths, snapshot =>
            {
                latest = snapshot;
                presentations++;
                controller.ApplyClaudeSource(snapshot);
            }, inspect: () =>
            {
                if (Interlocked.Exchange(ref blockInspection, 0) == 1)
                {
                    inspectionEntered.Set();
                    if (!inspectionRelease.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("Synthetic inspection was not released.");
                }
                return ClaudeRegisteredHookOwner.Inspect(paths);
            }, interval: TimeSpan.FromHours(1), reportRegistration: value =>
            {
                registration = value;
                controller.ApplyClaudeRegistration(value);
            });
            try
            {
                owner.Start();
                WaitUntil(() => registration == ClaudeRegistration.Absent, "The absent global hook was not inspected.");
                Check(((TextBlock)window.FindName("ClaudeSourceStatus")).Text == "Статус не подтверждён",
                    "Absence in one file was presented as all Claude integrations disconnected.");
                Check(((StackPanel)window.FindName("TasksPanel")).Children.OfType<TextBlock>()
                    .Any(text => text.Text == "Статус задач не подтверждён"),
                    "An absent global hook was presented as absence of all sources.");
                File.WriteAllText(paths.Settings, "{", new UTF8Encoding(false));
                owner.RequestInspection();
                WaitUntil(() => registration == ClaudeRegistration.Unavailable, "Invalid settings were not reported unavailable.");
                Check(((TextBlock)window.FindName("ClaudeSourceStatus")).Text == "Нет данных",
                    "Invalid settings must not produce a registration conclusion.");
                File.WriteAllText(paths.Settings, complete, new UTF8Encoding(false));
                owner.RequestInspection();
                WaitUntil(() => registration == ClaudeRegistration.Registered && latest is { Unavailable: false },
                    "The synthetic registration was not polled.");
                Check(controller.CurrentTasks.Count == 0 && latest is { Unavailable: false }, "The empty source state is wrong.");
                Check(((TextBlock)window.FindName("ClaudeSourceStatus")).Text == "Статус не подтверждён",
                    "A known global hook must not imply all registrations or delivery are confirmed.");
                ((Button)window.FindName("EnglishLanguageButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(((TextBlock)window.FindName("ClaudeSourceStatus")).Text == "Status unconfirmed",
                    "The source status did not switch to English.");
                ((Button)window.FindName("RussianLanguageButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(((TextBlock)window.FindName("ClaudeSourceStatus")).Text == "Статус не подтверждён",
                    "The source status did not switch back to Russian.");
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
                string heldSettings = paths.Settings + ".fixture-held";
                File.Move(paths.Settings, heldSettings);
                try
                {
                    owner.RequestInspection();
                    WaitUntil(() => registration == ClaudeRegistration.Absent && latest is { Unavailable: true },
                        "A temporarily missing settings file was not reported as uncertain.");
                    Check(controller.CurrentTasks.Single(task => task.Provider == "claude").Status == "unknown",
                        "A temporarily missing settings file cleared a known card.");
                }
                finally { File.Move(heldSettings, paths.Settings); }
                owner.RequestInspection();
                WaitUntil(() => registration == ClaudeRegistration.Registered,
                    "Returning settings were not inspected.");
                Check(controller.CurrentTasks.Single(task => task.Provider == "claude").Status == "unknown",
                    "Returning settings silently cleared a retained card.");

                string heldHook = paths.Hook + ".fixture-held";
                File.Move(paths.Hook, heldHook);
                try
                {
                    owner.RequestInspection();
                    WaitUntil(() => registration == ClaudeRegistration.Unavailable && latest is { Unavailable: true },
                        "A temporarily missing hook was not reported unavailable.");
                    Check(((TextBlock)window.FindName("ClaudeSourceStatus")).Text == "Нет данных" &&
                        controller.CurrentTasks.Single(task => task.Provider == "claude").Status == "unknown",
                        "A missing hook cleared a card or asserted a registration.");
                }
                finally { File.Move(heldHook, paths.Hook); }
                owner.RequestInspection();
                WaitUntil(() => registration == ClaudeRegistration.Registered,
                    "Returning hook was not inspected.");

                File.WriteAllText(paths.Settings, partial, new UTF8Encoding(false));
                owner.RequestInspection();
                WaitUntil(() => latest is { Unavailable: true } && registration == ClaudeRegistration.Partial, "Partial registration did not make the source unavailable.");
                Check(((TextBlock)window.FindName("ClaudeSourceStatus")).Text == "Статус не подтверждён",
                    "Partial registration did not retain an unconfirmed source status.");
                Check(controller.CurrentTasks.Single(task => task.Provider == "claude").Status == "unknown",
                    "A partial source retained a confirmed card.");
                int beforeDelayedStop = presentations;
                Emit(paths.Hook, new { hook_event_name = "Stop", session_id = "synthetic-second",
                    background_tasks = Array.Empty<object>(), session_crons = Array.Empty<object>() }, root);
                WaitUntil(() => presentations >= beforeDelayedStop + 2 &&
                    controller.CurrentTasks.Any(task => task.Provider == "claude") && latest is { Unavailable: true },
                    "Connection loss must retain the known unconfirmed card.");
                File.WriteAllText(paths.Settings, "{\"hooks\":{}}", new UTF8Encoding(false));
                owner.RequestInspection();
                WaitUntil(() => registration == ClaudeRegistration.Absent && latest is { Unavailable: true }
                    && controller.CurrentTasks.Any(task => task.Provider == "claude"),
                    "Removing one known hook must retain the last unconfirmed card.");
                Check(((TextBlock)window.FindName("ClaudeSourceStatus")).Text == "Статус не подтверждён",
                    "Removing one global hook was presented as absence of all integrations.");
                File.WriteAllText(paths.Settings, complete, new UTF8Encoding(false));
                int beforeReconnect = presentations;
                owner.RequestInspection();
                WaitUntil(() => registration == ClaudeRegistration.Registered && presentations > beforeReconnect,
                    "Returning registration did not report a snapshot.");
                Check(controller.CurrentTasks.Any(task => task.Provider == "claude") && latest is { Unavailable: true },
                    "A late stop after lost registration erased the unconfirmed card.");
                Emit(paths.Hook, new { hook_event_name = "UserPromptSubmit", session_id = "after-reconnect" }, root);
                WaitUntil(() => controller.CurrentTasks.Count(task => task.Provider == "claude") >= 2,
                    "A new event after registration returned was not shown.");
                Interlocked.Exchange(ref blockInspection, 1);
                owner.RequestInspection();
                WaitUntil(() => inspectionEntered.IsSet, "The delayed inspection did not reach its gate.");
                owner.Disconnect();
                Check(controller.CurrentTasks.All(task => task.Provider != "claude"), "Explicit disconnect did not clear cards.");
                inspectionRelease.Set();
                WaitUntil(() => !owner.InspectionPending, "The delayed inspection did not finish.");
                Check(controller.CurrentTasks.All(task => task.Provider != "claude"),
                    "A stale inspection reconnected after explicit disconnect.");
            }
            finally { inspectionRelease.Set(); owner.Dispose(); window.Close(); }

            File.WriteAllText(paths.Settings, complete, new UTF8Encoding(false));
            CheckPreviewDoesNotReadProfile(root, paths);
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
