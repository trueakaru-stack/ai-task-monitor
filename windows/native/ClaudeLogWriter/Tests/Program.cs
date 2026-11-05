using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using AITaskMonitor.ClaudeHook;
using AITaskMonitor.ClaudeLogWriter;
using Writer = AITaskMonitor.ClaudeLogWriter.ClaudeLogWriter;

if (args.Length > 0 && args[0] == "worker") return Fixtures.Worker(args);
if (args.Length != 3) throw new ArgumentException("Expected copied hook, synthetic root and Windows PowerShell.");
return Fixtures.Run(args[0], args[1], args[2]);

static class Fixtures
{
    private const long Limit = 1_000_000;
    private static readonly UTF8Encoding Utf8 = new(false);
    private static readonly Regex SyntheticMutex = new(@"\ALocal\\AITM\.Test\.Writer\.[0-9a-f]{32}\z", RegexOptions.CultureInvariant);
    private static int checks;
    private static string fixtureRoot = "";
    private static string legacyHook = "";
    private static string powerShell = "";

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }

    public static int Run(string hook, string root, string shell)
    {
        fixtureRoot = ValidateRoot(root);
        legacyHook = Path.GetFullPath(hook);
        powerShell = Path.GetFullPath(shell);
        Check(File.Exists(legacyHook) && File.Exists(powerShell), "A synthetic dependency is missing.");
        Check(!File.Exists(Path.Combine(Path.GetDirectoryName(legacyHook)!, "store-channel.marker")), "The copied hook is not isolated.");

        string ordinary = FixtureDirectory("basic");
        string mutex = NewMutex();
        ClaudeEventRecord record = Record("synthetic-basic") with { TaskSubject = "Пример 🌿\r\nстрока" };
        Check(Writer.Write(ordinary, mutex, Limit, record) == ClaudeLogWriteResult.Written, "The synthetic record was not written.");
        string log = Path.Combine(ordinary, Writer.EventFileName);
        byte[] bytes = File.ReadAllBytes(log);
        Check(bytes.Length > 2 && bytes[0] != 0xEF && bytes[^2] == 13 && bytes[^1] == 10, "The log is not UTF-8 without BOM and CRLF.");
        string[] lines = File.ReadAllLines(log, Utf8);
        Check(lines.Length == 1, "Escaped content was split across log lines.");
        using (JsonDocument parsed = JsonDocument.Parse(lines[0]))
        {
            Check(parsed.RootElement.EnumerateObject().Count() == 10, "The serialized record changed its field count.");
            Check(parsed.RootElement.GetProperty("task_subject").GetString() == record.TaskSubject, "Unicode or escaped newlines changed.");
        }
        File.WriteAllText(Path.Combine(ordinary, "settings.json"), "{synthetic invalid settings", Utf8);
        Check(Writer.Write(ordinary, mutex, Limit, Record("no-settings-read")) == ClaudeLogWriteResult.Written,
            "Explicit limits unexpectedly depended on settings.");
        Check(File.ReadAllText(Path.Combine(ordinary, "settings.json")) == "{synthetic invalid settings", "The writer modified settings.");
        Expect<ArgumentException>(() => Writer.Write("relative", mutex, Limit, record), "A relative path was accepted.");
        Expect<ArgumentException>(() => Writer.Write(@"\\localhost\synthetic", mutex, Limit, record), "A network path was accepted.");
        Expect<ArgumentException>(() => Writer.Write(ordinary, "Global\\synthetic", Limit, record), "A nonlocal mutex was accepted.");
        foreach (long invalid in new long[] { -1, 1, 999_999, 1_000_001, 101_000_000 })
            Expect<ArgumentOutOfRangeException>(() => Writer.Write(ordinary, mutex, invalid, record), "An unsupported limit was accepted.");
        Expect<ArgumentException>(() => Writer.Write(ordinary, mutex, Limit, record with { Provider = "other" }), "A non-Claude record was accepted.");
        Expect<IOException>(() => Writer.Write(Path.Combine(fixtureRoot, "missing"), mutex, Limit, record), "A missing directory was created.");
        Check(Writer.Write(ordinary, mutex, 100_000_000, Record("maximum-setting")) == ClaudeLogWriteResult.Written,
            "The highest supported limit was rejected.");

        string seed = SeedLines(16, 70_000);
        CompareLegacy("default", seed, null, 10_000_000, expectedRotate: false, writes: 1);
        CompareLegacy("rotation", seed, "{\"claudeMaximumMB\":1}", Limit, expectedRotate: true, writes: 1);
        string exactPrefix = "{\"synthetic\":\"";
        const string exactSuffix = "\"}\r\n";
        string exactSeed = exactPrefix + new string('x', (int)Limit - exactPrefix.Length - exactSuffix.Length) + exactSuffix;
        Check(Utf8.GetByteCount(exactSeed) == Limit, "The exact-size fixture is invalid.");
        CompareLegacy("at-limit", exactSeed, "{\"claudeMaximumMB\":1}", Limit, expectedRotate: false, writes: 1);
        CompareLegacy("over-on-next", exactSeed, "{\"claudeMaximumMB\":1}", Limit, expectedRotate: true, writes: 2);
        CompareLegacy("disabled", seed, "{bad", 0, expectedRotate: false, writes: 1);
        CompareLegacyNoNewline();

        VerifyBusyAndAbandoned();
        VerifyLockedFile();
        VerifyParallelRotation(seed);
        VerifyMixedLegacyAndNative();
        VerifyLinks();

        Console.WriteLine($"Claude log writer: {checks} synthetic assertions passed; legacy comparisons, parallel processes and rotation verified.");
        return 0;
    }

    public static int Worker(string[] args)
    {
        if (args.Length != 5) throw new ArgumentException("Invalid synthetic worker arguments.");
        fixtureRoot = ValidateRoot(Environment.GetEnvironmentVariable("AITM_LOG_TEST_ROOT") ?? "");
        string directory = Path.GetFullPath(args[1]);
        RequireFixturePath(directory);
        RequireSyntheticMutex(args[2]);
        if (!Regex.IsMatch(args[3], @"\Aworker-[0-9]+\z", RegexOptions.CultureInvariant) ||
            !int.TryParse(args[4], out int count) || count < 1 || count > 100)
            throw new ArgumentException("Invalid synthetic worker identity.");
        for (int i = 0; i < count; i++)
        {
            if (i == 0) { Console.WriteLine("synthetic-worker-ready"); Console.Out.Flush(); }
            if (Writer.Write(directory, args[2], Limit, Record(args[3] + "-" + i)) != ClaudeLogWriteResult.Written)
                throw new InvalidOperationException("A synthetic worker was busy.");
        }
        return 0;
    }

    private static void CompareLegacy(string name, string seed, string? settings, long maximumBytes, bool expectedRotate, int writes)
    {
        string local = FixtureDirectory(name + "-legacy-local");
        string legacyDir = Path.Combine(local, "CodexTaskProgress");
        Directory.CreateDirectory(legacyDir);
        string nativeDir = FixtureDirectory(name + "-native");
        string oldPath = Path.Combine(legacyDir, Writer.EventFileName), newPath = Path.Combine(nativeDir, Writer.EventFileName);
        File.WriteAllText(oldPath, seed, Utf8);
        File.WriteAllText(newPath, seed, Utf8);
        if (settings is not null) File.WriteAllText(Path.Combine(legacyDir, "settings.json"), settings, Utf8);
        File.WriteAllText(Path.Combine(legacyDir, "claude-events.jsonl"), "synthetic legacy sentinel", Utf8);
        File.WriteAllText(Path.Combine(nativeDir, "claude-events.jsonl"), "synthetic legacy sentinel", Utf8);
        string mutex = NewMutex();
        const string input = "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"synthetic_compare\",\"task_subject\":\"\\u041f\\u0440\\u0438\\u043c\\u0435\\u0440 \\ud83c\\udf3f\",\"prompt\":\"SYNTHETIC_PRIVATE_PROMPT\",\"cwd\":\"SYNTHETIC_PRIVATE_PATH\"}";
        Check(ClaudeHookTranslator.TryTranslate(input, DateTimeOffset.UnixEpoch, out ClaudeEventRecord? translated), "The synthetic input was not translated.");
        for (int i = 0; i < writes; i++)
        {
            using Process old = StartLegacy(local, mutex, input);
            WaitSuccess(old, "Legacy hook");
            Check(Writer.Write(nativeDir, mutex, maximumBytes, translated!) == ClaudeLogWriteResult.Written, name + ": native write failed.");
        }
        string[] legacyLines = File.ReadAllLines(oldPath, Utf8), nativeLines = File.ReadAllLines(newPath, Utf8);
        Check(legacyLines.Length == nativeLines.Length && legacyLines.Length >= writes, name + ": line counts differ.");
        Check(PrefixBeforeLastLines(File.ReadAllText(oldPath, Utf8), writes) == PrefixBeforeLastLines(File.ReadAllText(newPath, Utf8), writes),
            name + ": retained bytes differ from legacy.");
        for (int i = 1; i <= writes; i++) CompareEvents(legacyLines[^i], nativeLines[^i], name);
        Check(!File.ReadAllText(newPath).Contains("SYNTHETIC_PRIVATE_", StringComparison.Ordinal), name + ": raw input leaked.");
        Check(File.ReadAllText(Path.Combine(legacyDir, "claude-events.jsonl")) == "synthetic legacy sentinel" &&
            File.ReadAllText(Path.Combine(nativeDir, "claude-events.jsonl")) == "synthetic legacy sentinel", name + ": unrelated log changed.");
        bool rotated = !File.ReadAllText(newPath, Utf8).StartsWith(seed, StringComparison.Ordinal);
        Check(rotated == expectedRotate, name + ": unexpected pre-append rotation.");
    }

    private static void CompareLegacyNoNewline()
    {
        string local = FixtureDirectory("no-newline-legacy-local"), oldDir = Path.Combine(local, "CodexTaskProgress");
        Directory.CreateDirectory(oldDir);
        string nativeDir = FixtureDirectory("no-newline-native"), mutex = NewMutex();
        string oldPath = Path.Combine(oldDir, Writer.EventFileName), newPath = Path.Combine(nativeDir, Writer.EventFileName);
        string seed = new('x', (int)Limit + 100);
        File.WriteAllText(oldPath, seed, Utf8); File.WriteAllText(newPath, seed, Utf8);
        File.WriteAllText(Path.Combine(oldDir, "settings.json"), "{\"claudeMaximumMB\":1}", Utf8);
        const string input = "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"synthetic\"}";
        using (Process old = StartLegacy(local, mutex, input)) WaitSuccess(old, "No-newline legacy hook");
        Check(ClaudeHookTranslator.TryTranslate(input, DateTimeOffset.UnixEpoch, out ClaudeEventRecord? translated), "No-newline fixture translation failed.");
        Check(Writer.Write(nativeDir, mutex, Limit, translated!) == ClaudeLogWriteResult.Written, "No-newline native write failed.");
        string a = File.ReadAllText(oldPath, Utf8), b = File.ReadAllText(newPath, Utf8);
        int firstA = a.IndexOf('{'), firstB = b.IndexOf('{');
        Check(firstA == 900_000 && firstB == firstA && a[..firstA] == b[..firstB],
            "A no-newline retained tail differed from legacy.");
        CompareEvents(a[firstA..].TrimEnd('\r', '\n'), b[firstB..].TrimEnd('\r', '\n'), "no-newline");
    }

    private static void CompareEvents(string legacy, string native, string name)
    {
        using JsonDocument a = JsonDocument.Parse(legacy), b = JsonDocument.Parse(native);
        Check(a.RootElement.EnumerateObject().Count() == 10 && b.RootElement.EnumerateObject().Count() == 10, name + ": event shape differs.");
        foreach (JsonProperty property in a.RootElement.EnumerateObject())
        {
            if (property.Name == "timestamp") continue;
            Check(b.RootElement.TryGetProperty(property.Name, out JsonElement value) &&
                JsonElement.DeepEquals(property.Value, value), name + ": event field differs: " + property.Name);
        }
    }

    private static void VerifyBusyAndAbandoned()
    {
        string directory = FixtureDirectory("busy"), name = NewMutex();
        using (var owner = new Mutex(false, name))
        {
            Check(owner.WaitOne(0), "The synthetic mutex could not be acquired.");
            try
            {
                var watch = Stopwatch.StartNew();
                ClaudeLogWriteResult result = Task.Run(() => Writer.Write(directory, name, Limit, Record("busy"))).GetAwaiter().GetResult();
                watch.Stop();
                Check(result == ClaudeLogWriteResult.Busy && watch.ElapsedMilliseconds >= 1800 && watch.ElapsedMilliseconds < 7000,
                    "The busy mutex did not respect the two-second bound.");
                Check(!File.Exists(Path.Combine(directory, Writer.EventFileName)), "A busy write created an event.");
            }
            finally { owner.ReleaseMutex(); }
        }

        string abandoned = NewMutex();
        using var keeper = new Mutex(false, abandoned);
        var thread = new Thread(() => { using var owner = new Mutex(false, abandoned); owner.WaitOne(); });
        thread.Start();
        Check(thread.Join(5000), "The synthetic abandoned mutex fixture did not finish.");
        Expect<AbandonedMutexException>(() => Writer.Write(directory, abandoned, Limit, Record("abandoned")), "An abandoned mutex was ignored.");
        Check(!File.Exists(Path.Combine(directory, Writer.EventFileName)), "An abandoned mutex wrote an event.");
        Check(keeper.WaitOne(0), "The abandoned mutex was not released after failure.");
        keeper.ReleaseMutex();
    }

    private static void VerifyLockedFile()
    {
        string directory = FixtureDirectory("sharing"), path = Path.Combine(directory, Writer.EventFileName), mutex = NewMutex();
        File.WriteAllText(path, "synthetic intact\r\n", Utf8);
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            Expect<IOException>(() => Writer.Write(directory, mutex, Limit, Record("locked")), "An exclusively held file was changed.");
        Check(File.ReadAllText(path, Utf8) == "synthetic intact\r\n", "An access failure changed the existing file.");
    }

    private static void VerifyParallelRotation(string seed)
    {
        string directory = FixtureDirectory("parallel-rotation"), path = Path.Combine(directory, Writer.EventFileName), mutex = NewMutex();
        File.WriteAllText(path, seed, Utf8);
        var workers = new List<Process>();
        try
        {
            for (int worker = 0; worker < 8; worker++) workers.Add(StartWorker(directory, mutex, "worker-" + worker, 30));
            foreach (Process child in workers) WaitSuccess(child, "Parallel native worker");
        }
        finally { StopProcesses(workers); }
        string[] lines = File.ReadAllLines(path, Utf8);
        var ids = new List<string>();
        foreach (string line in lines)
        {
            using JsonDocument json = JsonDocument.Parse(line);
            ids.Add(json.RootElement.GetProperty("session_id").GetString()!);
        }
        string[] expected = Enumerable.Range(0, 8).SelectMany(w => Enumerable.Range(0, 30).Select(i => "worker-" + w + "-" + i)).ToArray();
        Check(expected.All(id => ids.Count(value => value == id) == 1), "Parallel writes lost or duplicated events.");
        Check(!ids.Contains("seed-0"), "Parallel writes did not rotate the oversized seed.");
        Check(File.ReadAllBytes(path)[^1] == 10, "Parallel writes left an incomplete line.");
        Check(!Directory.EnumerateFiles(directory, ".aitm-hook-retention-*.tmp").Any(), "Rotation left a temporary file.");
    }

    private static void VerifyMixedLegacyAndNative()
    {
        string local = FixtureDirectory("mixed-local"), directory = Path.Combine(local, "CodexTaskProgress");
        Directory.CreateDirectory(directory);
        string mutex = NewMutex();
        string path = Path.Combine(directory, Writer.EventFileName);
        using (var owner = new Mutex(false, mutex))
        {
            Check(owner.WaitOne(0), "The shared synthetic mutex could not be acquired.");
            try
            {
                var watch = Stopwatch.StartNew();
                using (Process old = StartLegacy(local, mutex, "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"legacy_blocked\"}"))
                    WaitSuccess(old, "Blocked legacy hook");
                watch.Stop();
                Check(watch.ElapsedMilliseconds >= 1500 && !File.Exists(path), "The legacy hook ignored the shared mutex.");
                using Process blocked = StartWorker(directory, mutex, "worker-99", 1);
                try
                {
                    string? ready = blocked.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult();
                    Check(ready == "synthetic-worker-ready", "The synthetic worker did not start.");
                    Thread.Sleep(150);
                    Check(!File.Exists(path) && !blocked.HasExited, "The native worker ignored the shared mutex.");
                    owner.ReleaseMutex();
                    WaitSuccess(blocked, "Released native worker");
                    Check(File.ReadAllLines(path, Utf8).Length == 1, "The released native worker did not append one event.");
                }
                finally { if (!blocked.HasExited) blocked.Kill(true); }
            }
            finally { try { owner.ReleaseMutex(); } catch (ApplicationException) { } }
        }
        File.Delete(path);
        var processes = new List<Process>();
        try
        {
            for (int i = 0; i < 4; i++)
                processes.Add(StartLegacy(local, mutex, "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"legacy_" + i + "\"}"));
            for (int i = 0; i < 4; i++) processes.Add(StartWorker(directory, mutex, "worker-" + i, 10));
            foreach (Process child in processes) WaitSuccess(child, "Mixed legacy/native worker");
        }
        finally { StopProcesses(processes); }
        string[] lines = File.ReadAllLines(Path.Combine(directory, Writer.EventFileName), Utf8);
        var ids = new List<string>();
        foreach (string line in lines) { using JsonDocument json = JsonDocument.Parse(line); ids.Add(json.RootElement.GetProperty("session_id").GetString()!); }
        Check(ids.Count == 44 && ids.Distinct(StringComparer.Ordinal).Count() == 44, "Concurrent legacy/native writes were lost or duplicated.");
        Check(Enumerable.Range(0, 4).All(i => ids.Contains("legacy_" + i)), "A legacy synthetic event was lost.");
        Check(Enumerable.Range(0, 4).SelectMany(w => Enumerable.Range(0, 10).Select(i => "worker-" + w + "-" + i)).All(ids.Contains),
            "A native synthetic event was lost.");
    }

    private static void VerifyLinks()
    {
        string directory = FixtureDirectory("link-file"), target = Path.Combine(fixtureRoot, "synthetic-link-target.txt");
        string link = Path.Combine(directory, Writer.EventFileName), mutex = NewMutex();
        File.WriteAllText(target, "synthetic protected content", Utf8);
        try { File.CreateSymbolicLink(link, target); }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
        {
            Console.WriteLine("Symbolic-link fixture skipped: " + e.GetType().Name + ".");
            return;
        }
        Expect<IOException>(() => Writer.Write(directory, mutex, Limit, Record("link")), "A symbolic-link event file was accepted.");
        Check(File.ReadAllText(target, Utf8) == "synthetic protected content", "A link target was modified.");
        File.Delete(target);
        Expect<IOException>(() => Writer.Write(directory, mutex, Limit, Record("dangling")), "A dangling symbolic link was accepted.");
        Check(!File.Exists(target), "A dangling link target was created.");

        string real = FixtureDirectory("link-directory-target"), linked = Path.Combine(fixtureRoot, "link-directory");
        try { Directory.CreateSymbolicLink(linked, real); }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or PlatformNotSupportedException)
        {
            Console.WriteLine("Directory symbolic-link fixture skipped: " + e.GetType().Name + ".");
            return;
        }
        Expect<IOException>(() => Writer.Write(linked, mutex, Limit, Record("directory-link")), "A symbolic-link directory was accepted.");
        Check(!File.Exists(Path.Combine(real, Writer.EventFileName)), "A linked directory was modified.");
        Directory.CreateDirectory(Path.Combine(real, "nested"));
        Expect<IOException>(() => Writer.Write(Path.Combine(linked, "nested"), mutex, Limit, Record("ancestor-link")), "A symbolic-link ancestor was accepted.");
        Check(!File.Exists(Path.Combine(real, "nested", Writer.EventFileName)), "A linked ancestor was modified.");
        Console.WriteLine("Synthetic file, dangling and directory symbolic links were rejected.");
    }

    private static Process StartLegacy(string local, string mutex, string json)
    {
        RequireFixturePath(local);
        RequireSyntheticMutex(mutex);
        string home = FixtureDirectory("legacy-home-" + Guid.NewGuid().ToString("N"));
        string temp = Path.Combine(home, "temp"), appdata = Path.Combine(home, "appdata");
        Directory.CreateDirectory(temp); Directory.CreateDirectory(appdata);
        var start = StartInfo(powerShell);
        foreach (string arg in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", legacyHook,
            "-LoopTestPipe", "AITM.Test." + Guid.NewGuid().ToString("N"), "-LogTestMutex", mutex[6..] }) start.ArgumentList.Add(arg);
        start.RedirectStandardInput = true;
        start.WorkingDirectory = home;
        start.Environment["USERPROFILE"] = home; start.Environment["HOME"] = home;
        start.Environment["LOCALAPPDATA"] = local; start.Environment["APPDATA"] = appdata;
        start.Environment["TEMP"] = temp; start.Environment["TMP"] = temp;
        start.Environment["PSModuleAnalysisCachePath"] = Path.Combine(temp, "ModuleAnalysisCache");
        start.Environment["AI_TASK_MONITOR_AUDIT"] = "1";
        Process process = Process.Start(start) ?? throw new InvalidOperationException("The copied hook did not start.");
        process.StandardInput.Write(json);
        process.StandardInput.Close();
        return process;
    }

    private static Process StartWorker(string directory, string mutex, string id, int count)
    {
        RequireFixturePath(directory); RequireSyntheticMutex(mutex);
        string dotnet = Environment.ProcessPath ?? throw new InvalidOperationException("The SDK host is missing.");
        var start = StartInfo(dotnet);
        foreach (string arg in new[] { Assembly.GetExecutingAssembly().Location, "worker", directory, mutex, id, count.ToString() })
            start.ArgumentList.Add(arg);
        return Process.Start(start) ?? throw new InvalidOperationException("The synthetic worker did not start.");
    }

    private static ProcessStartInfo StartInfo(string executable)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = fixtureRoot };
        start.Environment.Clear();
        foreach (string key in new[] { "SystemRoot", "windir", "PATH", "DOTNET_ROOT", "DOTNET_MULTILEVEL_LOOKUP", "DOTNET_CLI_HOME",
            "DOTNET_CLI_TELEMETRY_OPTOUT", "DOTNET_NOLOGO", "DOTNET_GENERATE_ASPNET_CERTIFICATE", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE",
            "DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE", "NUGET_PACKAGES", "USERPROFILE", "HOME", "CODEX_HOME", "APPDATA",
            "LOCALAPPDATA", "TEMP", "TMP", "PSModuleAnalysisCachePath", "AITM_LOG_TEST_ROOT", "ProgramFiles", "ProgramFiles(x86)",
            "ProgramW6432", "ProgramData", "ALLUSERSPROFILE", "SystemDrive", "ComSpec" })
            if (Environment.GetEnvironmentVariable(key) is string value) start.Environment[key] = value;
        return start;
    }

    private static void WaitSuccess(Process process, string description)
    {
        Task<string> stdout = process.StandardOutput.ReadToEndAsync(), stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(30_000)) { process.Kill(true); throw new TimeoutException(description + " timed out."); }
        if (process.ExitCode != 0) throw new InvalidOperationException(description + " failed: " + stdout.Result + stderr.Result);
    }

    private static void StopProcesses(IEnumerable<Process> processes)
    {
        foreach (Process process in processes)
        {
            try { if (!process.HasExited) process.Kill(true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            finally { process.Dispose(); }
        }
    }

    private static string ValidateRoot(string root)
    {
        string expected = Environment.GetEnvironmentVariable("AITM_LOG_TEST_ROOT") ?? throw new InvalidOperationException("Synthetic root missing.");
        string full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        if (!string.Equals(full, Path.GetFullPath(expected).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) || !Directory.Exists(full))
            throw new InvalidOperationException("The synthetic root does not match the test runner.");
        return full;
    }
    private static void RequireFixturePath(string path)
    {
        string full = Path.GetFullPath(path);
        if (!full.StartsWith(fixtureRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The synthetic path is outside the fixture root.");
    }
    private static string FixtureDirectory(string name)
    {
        string path = Path.Combine(fixtureRoot, name); RequireFixturePath(path); Directory.CreateDirectory(path); return path;
    }
    private static string NewMutex() => "Local\\AITM.Test.Writer." + Guid.NewGuid().ToString("N");
    private static void RequireSyntheticMutex(string value)
    {
        if (!SyntheticMutex.IsMatch(value)) throw new InvalidOperationException("A non-synthetic mutex was requested.");
    }
    private static ClaudeEventRecord Record(string id) => new("2026-11-05T12:00:00.0000000Z", "claude", id,
        "UserPromptSubmit", true, "New request", "", "", "", "");
    private static string SeedLines(int count, int size)
    {
        var builder = new StringBuilder();
        for (int i = 0; i < count; i++) builder.Append("{\"session_id\":\"seed-").Append(i).Append("\",\"data\":\"").Append('x', size).Append("\"}\r\n");
        return builder.ToString();
    }
    private static string PrefixBeforeLastLines(string text, int count)
    {
        int end = text.Length;
        for (int i = 0; i < count; i++)
        {
            if (end == 0 || text[end - 1] != '\n') throw new InvalidOperationException("An event line has no final LF.");
            end = text.LastIndexOf('\n', end - 2) + 1;
        }
        return text[..end];
    }
    private static void Expect<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { checks++; return; }
        throw new InvalidOperationException(message);
    }
}
