using System.Reflection;
using System.ComponentModel;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
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

    private static async Task<int> Main(string[] args)
    {
        try
        {
            string fixture = RequireFixture(args);
            string root = Path.GetFullPath(args[0]);
            await Basic(fixture, root);
            await Bounds(fixture);
            await StopCase(fixture, true);
            await StopCase(fixture, false);
            await StopFailures();
            Console.WriteLine("Codex Cloud command synthetic checks passed: " + checks);
            return 0;
        }
        catch (CheckFailure failure)
        {
            // Check descriptions are fixed strings and contain no fixture data.
            Console.Error.WriteLine("Synthetic check failed: " + failure.Message);
            return 1;
        }
        catch (Exception)
        {
            // Never print argument values, paths, cursors, or child output.
            Console.Error.WriteLine("Codex Cloud command synthetic checks failed.");
            return 1;
        }
    }
}

