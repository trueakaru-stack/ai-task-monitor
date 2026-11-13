using System.Buffers;
using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using System.Text;
using System.Text.Json.Serialization;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("AITaskMonitor.CodexCloudCommand.Tests")]

namespace AITaskMonitor.CodexCloudCommand;

public enum CommandOutcome
{
    Success,
    InvalidArguments,
    Cancelled,
    TimedOut,
    StartFailed,
    ExitFailed,
    OutputTooLarge,
    ErrorOutputTooLarge,
    InvalidUtf8,
    ReadFailed,
    TerminationUnconfirmed
}

public sealed class CommandResult : IDisposable
{
    private byte[]? output;

    internal CommandResult(CommandOutcome outcome, bool started, bool exitObserved, byte[]? bytes = null)
    {
        Outcome = outcome;
        Started = started;
        ExitObserved = exitObserved;
        output = bytes;
    }

    public CommandOutcome Outcome { get; }
    public bool Started { get; }
    // Only the launched process is observed. Descendant termination is not proven.
    public bool ExitObserved { get; }

    [JsonIgnore]
    public ReadOnlyMemory<byte> Output => output is { } value ? new ReadOnlyMemory<byte>(value) : ReadOnlyMemory<byte>.Empty;

    public void Dispose()
    {
        byte[]? previous = Interlocked.Exchange(ref output, null);
        if (previous is not null) Array.Clear(previous);
    }

    public override string ToString() => "Codex Cloud command result";
}

public static class CloudCommand
{
    public const int MaximumOutputBytes = 1_048_576;
    public const int MaximumErrorBytes = 65_536;
    private static readonly TimeSpan CleanupLimit = TimeSpan.FromSeconds(2);
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static async Task<CommandResult> RunAsync(
        string executable,
        string? cursor,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
            return new(CommandOutcome.Cancelled, false, false);
        if (!ValidInput(executable, cursor, timeout))
            return new(CommandOutcome.InvalidArguments, false, false);

        using var timeoutSource = new CancellationTokenSource(timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);
        using var process = new Process();
        var failure = new TaskCompletionSource<CommandOutcome>(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<ReadResult>? stdoutTask = null;
        Task<ReadResult>? stderrTask = null;
        Task? allTasks = null;
        CommandOutcome outcome = CommandOutcome.StartFailed;
        byte[]? output = null;
        bool started = false;
        bool exitObserved = false;

        try
        {
            var start = new ProcessStartInfo(executable)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            foreach (string argument in new[] { "cloud", "list", "--json", "--limit", "20" })
                start.ArgumentList.Add(argument);
            if (cursor is not null) start.ArgumentList.Add("--cursor=" + cursor);
            process.StartInfo = start;

            if (linked.IsCancellationRequested)
                outcome = CancellationOutcome(cancellationToken);
            else
            {
                started = process.Start();
                if (started)
                {
                    process.StandardInput.Close();
                    stdoutTask = ReadStreamAsync(process.StandardOutput.BaseStream, MaximumOutputBytes,
                        true, CommandOutcome.OutputTooLarge, failure, linked.Token);
                    stderrTask = ReadStreamAsync(process.StandardError.BaseStream, MaximumErrorBytes,
                        false, CommandOutcome.ErrorOutputTooLarge, failure, linked.Token);
                    Task exited = process.WaitForExitAsync();
                    allTasks = Task.WhenAll(exited, stdoutTask, stderrTask);
                    Task cancelled = Task.Delay(Timeout.InfiniteTimeSpan, linked.Token);
                    Task finished = await Task.WhenAny(allTasks, failure.Task, cancelled).ConfigureAwait(false);

                    // Do not suppress unexpected reader faults such as genuine memory exhaustion.
                    if (failure.Task.IsFaulted) _ = await failure.Task.ConfigureAwait(false);
                    if (linked.IsCancellationRequested)
                        outcome = CancellationOutcome(cancellationToken);
                    else if (failure.Task.IsCompleted)
                        outcome = await failure.Task.ConfigureAwait(false);
                    else if (finished == allTasks)
                    {
                        await allTasks.ConfigureAwait(false);
                        ReadResult stdout = await stdoutTask.ConfigureAwait(false);
                        ReadResult stderr = await stderrTask.ConfigureAwait(false);
                        if (!stdout.Ok || !stderr.Ok)
                            outcome = CommandOutcome.ReadFailed;
                        else if (process.ExitCode != 0)
                            outcome = CommandOutcome.ExitFailed;
                        else if (stdout.Data is null)
                            outcome = CommandOutcome.ReadFailed;
                        else
                        {
                            try
                            {
                                _ = StrictUtf8.GetCharCount(stdout.Data);
                                if (linked.IsCancellationRequested)
                                    outcome = CancellationOutcome(cancellationToken);
                                else
                                {
                                    output = stdout.Data;
                                    outcome = CommandOutcome.Success;
                                }
                            }
                            catch (DecoderFallbackException)
                            {
                                outcome = CommandOutcome.InvalidUtf8;
                            }
                        }
                    }
                    else
                        outcome = CommandOutcome.ReadFailed;
                }
            }
        }
        catch (Exception error) when (Expected(error))
        {
            outcome = started ? CommandOutcome.ReadFailed : CommandOutcome.StartFailed;
        }
        finally
        {
            // Cancellation wakes stream readers; termination can include the launched process tree.
            linked.Cancel();
            if (started && outcome != CommandOutcome.Success)
            {
                exitObserved = await StopAsync(process).ConfigureAwait(false);
                CloseQuietly(() => process.StandardOutput.BaseStream);
                CloseQuietly(() => process.StandardError.BaseStream);
            }
            else if (started)
                exitObserved = true;

            if (outcome != CommandOutcome.Success)
                ObserveAndClear(stdoutTask);
            Observe(stderrTask);
            Observe(allTasks);
            Observe(failure.Task);
        }

        if (started && !exitObserved) outcome = CommandOutcome.TerminationUnconfirmed;
        return new(outcome, started, exitObserved, output);
    }

    private static bool ValidInput(string executable, string? cursor, TimeSpan timeout)
    {
        try
        {
            if (!OperatingSystem.IsWindows() || string.IsNullOrEmpty(executable) ||
                !Path.IsPathFullyQualified(executable) ||
                !string.Equals(Path.GetExtension(executable), ".exe", StringComparison.OrdinalIgnoreCase) ||
                timeout <= TimeSpan.Zero || timeout > TimeSpan.FromSeconds(120))
                return false;
            if (cursor is null) return true;
            if (cursor.Length == 0 || StrictUtf8.GetByteCount(cursor) > 1024) return false;
            foreach (char character in cursor)
                if (character < 0x20 || character == 0x7f) return false;
            return true;
        }
        catch (Exception error) when (Expected(error))
        {
            return false;
        }
    }

    private static CommandOutcome CancellationOutcome(CancellationToken external) =>
        external.IsCancellationRequested ? CommandOutcome.Cancelled : CommandOutcome.TimedOut;

    private sealed class ReadResult(bool ok, byte[]? data)
    {
        internal bool Ok { get; } = ok;
        internal byte[]? Data { get; } = data;
    }

    private static async Task<ReadResult> ReadStreamAsync(Stream input, int limit, bool keep,
        CommandOutcome tooLarge, TaskCompletionSource<CommandOutcome> failure, CancellationToken cancellation)
    {
        byte[]? scratch = null;
        MemoryStream? destination = null;
        try
        {
            scratch = ArrayPool<byte>.Shared.Rent(8192);
            if (keep) destination = new MemoryStream();
            int total = 0;
            while (true)
            {
                int count = await input.ReadAsync(scratch.AsMemory(), cancellation).ConfigureAwait(false);
                if (count == 0) break;
                if (count > limit - total)
                {
                    failure.TrySetResult(tooLarge);
                    return new(false, null);
                }
                total += count;
                destination?.Write(scratch, 0, count);
            }
            return new(true, destination?.ToArray());
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            return new(false, null);
        }
        catch (Exception error) when (Expected(error))
        {
            failure.TrySetResult(CommandOutcome.ReadFailed);
            return new(false, null);
        }
        catch (Exception error)
        {
            failure.TrySetException(error);
            throw;
        }
        finally
        {
            if (destination is not null)
            {
                if (destination.TryGetBuffer(out ArraySegment<byte> segment) && segment.Array is not null)
                    Array.Clear(segment.Array, segment.Offset, segment.Count);
                destination.Dispose();
            }
            if (scratch is not null) ArrayPool<byte>.Shared.Return(scratch, clearArray: true);
        }
    }

    private static Task<bool> StopAsync(Process process) => StopAsync(
        () => process.HasExited,
        entireTree => process.Kill(entireTree),
        cancellation => process.WaitForExitAsync(cancellation));

    // Injectable operations exercise termination failures without touching a process.
    internal static async Task<bool> StopAsync(Func<bool> hasExited, Action<bool> kill,
        Func<CancellationToken, Task> waitForExit)
    {
        using var cleanup = new CancellationTokenSource(CleanupLimit);
        try
        {
            try { if (!hasExited()) kill(true); }
            catch (Exception error) when (ExpectedStopFailure(error))
            {
                try { if (!hasExited()) kill(false); }
                catch (Exception fallback) when (ExpectedStopFailure(fallback)) { }
            }
            await waitForExit(cleanup.Token).ConfigureAwait(false);
            return hasExited();
        }
        catch (OperationCanceledException) when (cleanup.IsCancellationRequested)
        {
            try { return hasExited(); }
            catch (Exception error) when (ExpectedStopFailure(error)) { return false; }
        }
        catch (Exception error) when (ExpectedStopFailure(error))
        {
            return false;
        }
    }

    private static void CloseQuietly(Func<Stream> getStream)
    {
        try { getStream().Dispose(); }
        catch (Exception error) when (Expected(error)) { }
    }

    private static bool Expected(Exception error) =>
        error is IOException or InvalidOperationException or ArgumentException or
        UnauthorizedAccessException or SecurityException or NotSupportedException or
        Win32Exception or BadImageFormatException;

    private static bool ExpectedStopFailure(Exception error) => error is AggregateException aggregate
        ? aggregate.InnerExceptions.Count > 0 && aggregate.InnerExceptions.All(ExpectedStopFailure)
        : Expected(error);

    private static void ObserveAndClear(Task<ReadResult>? task)
    {
        if (task is null) return;
        _ = task.ContinueWith(completed =>
        {
            if (completed.Status == TaskStatus.RanToCompletion && completed.Result.Data is { } data)
                Array.Clear(data);
            else if (completed.IsFaulted) _ = completed.Exception;
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    private static void Observe(Task? task)
    {
        if (task is null) return;
        _ = task.ContinueWith(completed => { if (completed.IsFaulted) _ = completed.Exception; },
            CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }
}

