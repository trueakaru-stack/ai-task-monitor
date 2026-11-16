using System.Reflection;
using System.ComponentModel;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Security.AccessControl;
using System.Security.Principal;
using AITaskMonitor.CodexCloud;
using AITaskMonitor.CodexCloudCommand;

internal static class Program
{
    private const string DangerousCursor = "--leading \"quoted\" & %PATH% \\trailing\\";
    private const string Page = "{\"tasks\":[],\"cursor\":null}";
    private static int checks;

    private sealed class CheckFailure(string message) : Exception(message) { }

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new CheckFailure(message);
    }

    private static string RequireFixture(string[] args)
    {
        Check(OperatingSystem.IsWindows(), "Windows runner required");
        Check(string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase) &&
              string.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase) &&
              string.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"), "github-hosted", StringComparison.OrdinalIgnoreCase) &&
              string.Equals(Environment.GetEnvironmentVariable("RUNNER_OS"), "Windows", StringComparison.OrdinalIgnoreCase) &&
              Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0",
              "disposable hosted runner required");
        Check(args.Length == 1 && Path.IsPathFullyQualified(args[0]), "fixture root must be absolute");
        string temp = Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "";
        Check(Path.IsPathFullyQualified(temp), "runner temp must be absolute");
        string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[0]));
        string tempRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(temp));
        Check(string.Equals(Directory.GetParent(root)?.FullName, tempRoot, StringComparison.OrdinalIgnoreCase),
            "fixture root must be a direct runner-temp child");
        Check(Regex.IsMatch(Path.GetFileName(root), "^aitm-cloud-command-[0-9a-f]{32}$",
            RegexOptions.CultureInvariant), "fixture root name");
        Check(Directory.Exists(root), "fixture root exists");
        for (DirectoryInfo? directory = new(root); directory is not null; directory = directory.Parent)
            Check((directory.Attributes & FileAttributes.ReparsePoint) == 0, "fixture ancestry has no reparse point");

        string isolatedTemp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath()));
        Check(string.Equals(isolatedTemp, Path.Combine(root, "isolated", "temp"), StringComparison.OrdinalIgnoreCase),
            "isolated temporary directory required");
        for (DirectoryInfo? item = new(isolatedTemp); item is not null; item = item.Parent)
            Check((item.Attributes & FileAttributes.ReparsePoint) == 0, "isolated temp has no reparse ancestor");

        string expectedTest = Path.Combine(root, "artifacts", "bin", "CodexCloudCommand.Tests", "release",
            "AITaskMonitor.CodexCloudCommand.Tests.dll");
        Check(string.Equals(Path.GetFullPath(Assembly.GetExecutingAssembly().Location), expectedTest,
            StringComparison.OrdinalIgnoreCase), "test assembly belongs to isolated build");
        string fixture = Path.Combine(root, "artifacts", "bin", "CodexCloudCommand.Fixture", "release",
            "AITaskMonitor.CodexCloudCommand.Fixture.exe");
        Check(File.Exists(fixture) && (File.GetAttributes(fixture) & FileAttributes.ReparsePoint) == 0,
            "synthetic fixture exists");
        string? fixtureDirectory = Path.GetDirectoryName(fixture);
        for (DirectoryInfo? directory = new(fixtureDirectory!);
             directory is not null && !string.Equals(directory.FullName, root, StringComparison.OrdinalIgnoreCase);
             directory = directory.Parent)
            Check((directory.Attributes & FileAttributes.ReparsePoint) == 0, "fixture path has no reparse point");
        return fixture;
    }

    private static async Task Basic(string fixture, string root)
    {
        using (CommandResult result = await CloudCommand.RunAsync(fixture, null, TimeSpan.FromSeconds(15)))
        {
            Check(result.Outcome == CommandOutcome.Success && result.Started && result.ExitObserved,
                "single page process succeeds");
            Check(Encoding.UTF8.GetString(result.Output.Span) == Page, "stdout transferred intact");
            Check(!JsonSerializer.Serialize(result).Contains("tasks", StringComparison.Ordinal) &&
                  !result.ToString().Contains("tasks", StringComparison.Ordinal), "stdout excluded from diagnostics");
        }

        using (CommandResult result = await CloudCommand.RunAsync(fixture, DangerousCursor, TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.Success && Encoding.UTF8.GetString(result.Output.Span) == Page,
                "quoted cursor reaches fixture as one unchanged argument");

        using (CommandResult result = await CloudCommand.RunAsync(fixture, "stdin-eof", TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.Success, "child stdin is closed");

        using (CommandResult result = await CloudCommand.RunAsync(fixture, "bad-utf8", TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.InvalidUtf8 && result.Output.IsEmpty && result.ExitObserved,
                "invalid UTF-8 is not published");

        using (CommandResult result = await CloudCommand.RunAsync(fixture, "nonzero", TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.ExitFailed && result.Output.IsEmpty &&
                  !JsonSerializer.Serialize(result).Contains("synthetic-private", StringComparison.Ordinal) &&
                  !result.ToString().Contains("synthetic-private", StringComparison.Ordinal),
                  "nonzero exit discards process output");

        using (CommandResult result = await CloudCommand.RunAsync(fixture, "bad\ncursor", TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.InvalidArguments && !result.Started, "control cursor rejected before start");
        using (CommandResult result = await CloudCommand.RunAsync(fixture, new string('я', 513), TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.InvalidArguments && !result.Started, "oversized UTF-8 cursor rejected");
        using (CommandResult result = await CloudCommand.RunAsync("relative.exe", null, TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.InvalidArguments && !result.Started, "relative executable rejected");
        using (CommandResult result = await CloudCommand.RunAsync(Path.Combine(root, "fixture.cmd"), null, TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.InvalidArguments && !result.Started, "script executable rejected");
        using (CommandResult result = await CloudCommand.RunAsync(fixture, null, TimeSpan.Zero))
            Check(result.Outcome == CommandOutcome.InvalidArguments && !result.Started, "invalid timeout rejected");
        using (CommandResult result = await CloudCommand.RunAsync(fixture, null, TimeSpan.FromSeconds(15), new CancellationToken(true)))
            Check(result.Outcome == CommandOutcome.Cancelled && !result.Started, "pre-cancelled request does not launch");
        string missing = Path.Combine(root, "does-not-exist.exe");
        Check(!File.Exists(missing), "synthetic missing executable");
        using (CommandResult result = await CloudCommand.RunAsync(missing, null, TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.StartFailed && !result.Started, "start failure is safe");
    }

    private static async Task Bounds(string fixture)
    {
        CommandResult exact = await CloudCommand.RunAsync(fixture, "both-exact", TimeSpan.FromSeconds(20));
        ReadOnlyMemory<byte> borrow = exact.Output;
        Check(exact.Outcome == CommandOutcome.Success && borrow.Length == CloudCommand.MaximumOutputBytes,
            "simultaneous stdout and stderr exact limits succeed");
        Check(borrow.Span[0] == (byte)'A' && borrow.Span[^1] == (byte)'A', "boundary output preserved");
        exact.Dispose();
        Check(borrow.Span[0] == 0 && exact.Output.IsEmpty, "owned output is cleared on dispose");

        using (CommandResult result = await CloudCommand.RunAsync(fixture, "stdout-over", TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.OutputTooLarge && result.ExitObserved && result.Output.IsEmpty,
                "oversized stdout stops child and discards data");
        using (CommandResult result = await CloudCommand.RunAsync(fixture, "stderr-over", TimeSpan.FromSeconds(15)))
            Check(result.Outcome == CommandOutcome.ErrorOutputTooLarge && result.ExitObserved && result.Output.IsEmpty,
                "oversized stderr stops child and discards data");
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

    private static async Task StopCase(string fixture, bool cancel)
    {
        string id = Guid.NewGuid().ToString("N");
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, "Local\\AITM.Cloud.Ready." + id, out bool created);
        Check(created, "synthetic signal is unique");
        using var cancellation = new CancellationTokenSource();
        Task<CommandResult> pending = CloudCommand.RunAsync(fixture, "wait-" + id,
            TimeSpan.FromSeconds(cancel ? 20 : 12), cancellation.Token);
        try
        {
            bool signalled = await Task.Run(() => ready.WaitOne(TimeSpan.FromSeconds(8)));
            Check(signalled, "synthetic child signalled it started");
            using Mutex lifetime = Mutex.OpenExisting("Local\\AITM.Cloud.Lifetime." + id);
            Check(!MutexAvailable(lifetime, TimeSpan.Zero), "synthetic child is alive before stop");
            string temp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath()));
            string[] held = Directory.GetDirectories(temp, "aitm-cloud-*");
            Check(held.Length == 1, "live child has exactly one protected workspace");
            bool moved = false;
            try { Directory.Move(held[0], held[0] + "-moved"); moved = true; }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            Check(!moved && Directory.Exists(held[0]), "live workspace cannot be renamed");
            if (cancel) cancellation.Cancel();
            using CommandResult result = await pending;
            Check(result.Outcome == (cancel ? CommandOutcome.Cancelled : CommandOutcome.TimedOut) &&
                  result.Started && result.ExitObserved && result.Output.IsEmpty,
                  "stop reports expected result");
            Check(MutexAvailable(lifetime, TimeSpan.FromSeconds(2)), "synthetic child really exited");
        }
        finally
        {
            cancellation.Cancel();
            if (await Task.WhenAny(pending, Task.Delay(TimeSpan.FromSeconds(5))) == pending)
                (await pending).Dispose();
        }
    }

    private static async Task StopFailures()
    {
        bool exited = false;
        int treeAttempts = 0, directAttempts = 0, waits = 0;
        bool observed = await CloudCommand.StopAsync(() => exited, entireTree =>
        {
            if (entireTree)
            {
                treeAttempts++;
                throw new AggregateException(new AggregateException(new Win32Exception(5)));
            }
            directAttempts++;
            exited = true;
        }, _ => { waits++; return Task.CompletedTask; });
        Check(observed && treeAttempts == 1 && directAttempts == 1 && waits == 1,
            "aggregate tree failure retries and observes the explicitly launched process");

        treeAttempts = 0; directAttempts = 0; waits = 0;
        bool stopped = await CloudCommand.StopAsync(() => false, entireTree =>
        {
            if (entireTree)
            {
                treeAttempts++;
                throw new AggregateException(new Win32Exception(5));
            }
            directAttempts++;
            throw new Win32Exception(5);
        }, async cancellation =>
        {
            waits++;
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellation);
        }).WaitAsync(TimeSpan.FromSeconds(6));
        Check(!stopped && treeAttempts == 1 && directAttempts == 1 && waits == 1,
            "unobserved termination remains unconfirmed after cleanup deadline");

        exited = false; treeAttempts = 0; directAttempts = 0;
        observed = await CloudCommand.StopAsync(() => exited, entireTree =>
        {
            if (entireTree)
            {
                treeAttempts++;
                exited = true;
                throw new AggregateException(new Win32Exception(5));
            }
            directAttempts++;
        }, _ => Task.CompletedTask);
        Check(observed && treeAttempts == 1 && directAttempts == 0,
            "already exited parent is not killed again after aggregate failure");

        var unexpected = new AggregateException(new OutOfMemoryException("Synthetic exception."));
        bool propagated = false;
        try
        {
            _ = await CloudCommand.StopAsync(() => false, _ => throw unexpected, _ => Task.CompletedTask);
        }
        catch (AggregateException error) when (ReferenceEquals(error, unexpected)) { propagated = true; }
        Check(propagated, "unexpected aggregate failure is not hidden");
    }

    private static async Task DirtyWorkspace(string fixture, string root)
    {
        string temp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath()));
        Check(string.Equals(temp, Path.Combine(root, "isolated", "temp"), StringComparison.OrdinalIgnoreCase),
            "dirty workspace requires the isolated temp");
        for (DirectoryInfo? item = new(temp); item is not null; item = item.Parent)
            Check((item.Attributes & FileAttributes.ReparsePoint) == 0, "dirty workspace ancestry is plain");
        CloudWorkingDirectory owned = CloudWorkingDirectory.Create();
        string path = owned.Path;
        bool validated = false;
        FileStream? payload = null;
        try
        {
            Check(string.Equals(Directory.GetParent(path)?.FullName, temp, StringComparison.OrdinalIgnoreCase) &&
                  Regex.IsMatch(Path.GetFileName(path), "^aitm-cloud-[0-9a-f]{32}$", RegexOptions.CultureInvariant) &&
                  (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0,
                  "dirty workspace remains in the synthetic temp");
            validated = true;
            SecurityIdentifier user = WindowsIdentity.GetCurrent().User
                ?? throw new CheckFailure("synthetic identity unavailable");
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(user);
            security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
                InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(path).SetAccessControl(security);
            payload = new FileStream(Path.Combine(path, "owned-synthetic-payload.txt"), FileMode.CreateNew,
                FileAccess.ReadWrite, FileShare.Read | FileShare.Delete, 4096, FileOptions.DeleteOnClose);
            payload.WriteByte(42);
            payload.Flush();
            owned.Dispose();
            payload.Position = 0;
            Check(payload.ReadByte() == 42, "cleanup did not remove unexpected contents");
            using CommandResult blocked = await CloudCommand.RunAsync(fixture, null, TimeSpan.FromSeconds(15));
            Check(blocked.Outcome == CommandOutcome.StartFailed && !blocked.Started,
                "cleanup failure blocks further launches");
        }
        finally
        {
            owned.Dispose();
            payload?.Dispose();
            if (validated && Directory.Exists(path)) Directory.Delete(path);
        }
        Check(!Directory.Exists(path), "owned synthetic dirty workspace removed after check");
    }

    private static async Task<int> Main(string[] args)
    {
        try
        {
            bool dirtyCase = args.Length == 2 && args[1] == "--dirty-workspace";
            string fixture = RequireFixture(dirtyCase ? new[] { args[0] } : args);
            if (dirtyCase)
            {
                await DirtyWorkspace(fixture, Path.GetFullPath(args[0]));
                Console.WriteLine("Dirty workspace synthetic checks passed: " + checks);
                return 0;
            }
            string root = Path.GetFullPath(args[0]);
            string original = Path.Combine(root, "original-cwd");
            Directory.CreateDirectory(original);
            string sentinel = Path.Combine(original, "error.log");
            File.WriteAllText(sentinel, "original-synthetic-sentinel");
            Directory.SetCurrentDirectory(original);
            string temp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath()));
            Check(!Directory.EnumerateDirectories(temp, "aitm-cloud-*").Any(), "workspace test starts empty");
            using (CloudWorkingDirectory held = CloudWorkingDirectory.Create())
            {
                using CommandResult busy = await CloudCommand.RunAsync(fixture, null, TimeSpan.FromSeconds(15));
                Check(busy.Outcome == CommandOutcome.StartFailed && !busy.Started,
                    "busy workspace blocks a second process");
            }
            Check(!Directory.EnumerateDirectories(temp, "aitm-cloud-*").Any(), "idle workspace is removed");
            await Basic(fixture, root);
            await Bounds(fixture);
            await StopCase(fixture, true);
            await StopCase(fixture, false);
            await StopFailures();
            Check(File.ReadAllText(sentinel) == "original-synthetic-sentinel", "original cwd was not modified");
            Check(!Directory.EnumerateDirectories(temp, "aitm-cloud-*").Any(), "completed workspaces were removed");
            string? priorTemp = Environment.GetEnvironmentVariable("TEMP");
            string? priorTmp = Environment.GetEnvironmentVariable("TMP");
            string missing = Path.Combine(root, "missing-temp");
            Check(!Directory.Exists(missing), "invalid temp fixture is absent");
            try
            {
                Environment.SetEnvironmentVariable("TEMP", missing);
                Environment.SetEnvironmentVariable("TMP", missing);
                using CommandResult failed = await CloudCommand.RunAsync(fixture, null, TimeSpan.FromSeconds(15));
                Check(failed.Outcome == CommandOutcome.StartFailed && !failed.Started,
                    "unavailable temp prevents process launch");
            }
            finally
            {
                Environment.SetEnvironmentVariable("TEMP", priorTemp);
                Environment.SetEnvironmentVariable("TMP", priorTmp);
            }
            Check(File.ReadAllText(sentinel) == "original-synthetic-sentinel", "failed setup left original cwd intact");
            string link = Path.Combine(root, "redirected-temp");
            Check(!Directory.Exists(link), "redirect fixture is absent");
            Directory.CreateSymbolicLink(link, temp);
            try
            {
                Check((File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0, "redirect fixture is a reparse point");
                Environment.SetEnvironmentVariable("TEMP", link);
                Environment.SetEnvironmentVariable("TMP", link);
                using CommandResult redirected = await CloudCommand.RunAsync(fixture, null, TimeSpan.FromSeconds(15));
                Check(redirected.Outcome == CommandOutcome.StartFailed && !redirected.Started,
                    "redirected temp prevents process launch");
            }
            finally
            {
                Environment.SetEnvironmentVariable("TEMP", priorTemp);
                Environment.SetEnvironmentVariable("TMP", priorTmp);
                Directory.Delete(link);
            }
            Check(File.ReadAllText(sentinel) == "original-synthetic-sentinel", "redirect rejection left original cwd intact");
            using (CloudWorkingDirectory uncertain = CloudWorkingDirectory.Create())
                uncertain.PreventFurtherRuns();
            using (CommandResult blocked = await CloudCommand.RunAsync(fixture, null, TimeSpan.FromSeconds(15)))
                Check(blocked.Outcome == CommandOutcome.StartFailed && !blocked.Started,
                    "unconfirmed child termination blocks further launches");
            Check(!Directory.EnumerateDirectories(temp, "aitm-cloud-*").Any(),
                "unconfirmed termination test removed its empty workspace");
            Console.WriteLine("Codex Cloud command synthetic checks passed: " + checks);
            return 0;
        }
        catch (CheckFailure failure)
        {
            // Check descriptions are fixed strings and contain no fixture data.
            Console.Error.WriteLine("Synthetic check failed: " + failure.Message);
            return 1;
        }
        catch (Exception error)
        {
            // Report only exception type and a source line, never fixture values or child output.
            string line = Regex.Match(error.StackTrace ?? "", @"line \d+", RegexOptions.CultureInvariant).Value;
            Console.Error.WriteLine("Codex Cloud command synthetic checks failed: " + error.GetType().Name + " " + line);
            return 1;
        }
    }
}

