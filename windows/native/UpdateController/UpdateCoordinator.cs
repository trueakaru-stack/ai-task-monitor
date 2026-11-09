using System.Diagnostics;
using AITaskMonitor.NativeUpdateRetry;

namespace AITaskMonitor.NativeUpdateController;

// This coordinator uses supplied transport/selector functions; it performs no I/O itself.
public sealed record ProbeResult(bool Success, string? Json);
public sealed record ProbeHeaders(string?[]? RetryAfter = null,
    string?[]? RateReset = null, string?[]? ServerDate = null);
public sealed record UpdateInfo(string Version, string Url);
public sealed record Selection(bool Valid, UpdateInfo? Update);
public sealed record CoordinatorSnapshot(bool Stopped, bool Faulted, bool Busy, bool HasSchedule, int Failures, UpdateInfo? Available);

public sealed class UpdateCoordinator
{
    private readonly object gate = new();
    private readonly Func<Action<ProbeHeaders>, CancellationToken, Task<ProbeResult>> fetch;
    private readonly Func<string, Selection> select;
    private readonly Func<long> timestamp;
    private readonly Func<DateTimeOffset> utcNow;
    private readonly long frequency;
    private readonly TimeSpan timeout;
    private UpdateRetrySchedule schedule = new();
    private bool stopped, faulted, starting, busy;
    private long generation;
    private CancellationTokenSource? cancellation;
    private Task? cancellationCompletion;
    private readonly TaskCompletionSource<bool> stopSignal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private UpdateInfo? available;

    public UpdateCoordinator(Func<Action<ProbeHeaders>, CancellationToken, Task<ProbeResult>> fetch, Func<string, Selection> select,
        Func<long> timestamp, Func<DateTimeOffset> utcNow, long frequency, TimeSpan timeout)
    {
        this.fetch = fetch ?? throw new ArgumentNullException(nameof(fetch));
        this.select = select ?? throw new ArgumentNullException(nameof(select));
        this.timestamp = timestamp ?? throw new ArgumentNullException(nameof(timestamp));
        this.utcNow = utcNow ?? throw new ArgumentNullException(nameof(utcNow));
        if (frequency <= 0) throw new ArgumentOutOfRangeException(nameof(frequency));
        if (timeout < TimeSpan.FromMilliseconds(1) || timeout > TimeSpan.FromMinutes(2))
            throw new ArgumentOutOfRangeException(nameof(timeout));
        this.frequency = frequency;
        this.timeout = timeout;
    }

    // The caller may await this without running injected clock code on the UI thread.
    public Task<bool> StartIfDueAsync()
    {
        lock (gate)
        {
            if (stopped || faulted || starting || busy) return Task.FromResult(false);
            starting = true;
        }
        try { return Task.Run(StartIfDue); }
        catch (Exception) { lock (gate) { starting = false; if (!stopped) faulted = true; } return Task.FromResult(false); }
    }

    private bool StartIfDue()
    {
        lock (gate) { if (stopped || faulted) { starting = false; return false; } }
        long startedAt;
        try { startedAt = timestamp(); }
        catch (Exception) { lock (gate) { starting = false; if (!stopped) faulted = true; } return false; }
        lock (gate)
        {
            starting = false;
            if (stopped || faulted || busy) return false;
            try { if (!schedule.Due(startedAt)) return false; }
            catch (Exception) { faulted = true; return false; }
            busy = true;
            long current = ++generation;
            var cts = new CancellationTokenSource();
            cancellation = cts;
            cancellationCompletion = null;
            var elapsed = Stopwatch.StartNew();
            Task deadline = Task.Delay(timeout);
            var context = new AttemptContext();
            Task<Attempt> attempt = Task.Run(() => Execute(cts.Token, context));
            _ = Task.Run(() => Observe(attempt, deadline, cts, elapsed, current, startedAt, context));
            return true;
        }
    }

    public CoordinatorSnapshot Snapshot()
    {
        lock (gate) return new CoordinatorSnapshot(stopped, faulted, starting || busy, schedule.HasSchedule, schedule.Failures, available);
    }

    // Prevent publication immediately; cancellation callbacks run off the caller's thread.
    public void Stop()
    {
        lock (gate)
        {
            if (stopped) return;
            stopped = true;
            generation++;
            stopSignal.TrySetResult(true);
            if (cancellation is not null) RequestCancelLocked(cancellation);
        }
    }

    // Caller holds gate. CancelAsync sets the token immediately, but runs callbacks asynchronously.
    private void RequestCancelLocked(CancellationTokenSource cts)
    {
        if (cancellationCompletion is not null) return;
        try { cancellationCompletion = cts.CancelAsync(); }
        catch (ObjectDisposedException) { cancellationCompletion = Task.CompletedTask; }
    }

    private sealed record Attempt(bool Valid, UpdateInfo? Update);
    private sealed class AttemptContext
    {
        private readonly object sync = new();
        private ProbeHeaders? hints;
        private bool reported, invalid, sealedContext;
        public void Store(ProbeHeaders result)
        {
            lock (sync)
            {
                if (sealedContext) return;
                if (reported || result is null) { invalid = true; return; }
                reported = true;
                if ((result.RetryAfter?.Length ?? 0) > 256 || (result.RateReset?.Length ?? 0) > 256 ||
                    (result.ServerDate?.Length ?? 0) > 256) { invalid = true; return; }
                hints = new ProbeHeaders(result.RetryAfter?.ToArray(), result.RateReset?.ToArray(), result.ServerDate?.ToArray());
            }
        }
        public (ProbeHeaders? Hints, bool Invalid) Seal()
        {
            lock (sync) { sealedContext = true; return (hints, invalid); }
        }
    }

    private async Task<Attempt> Execute(CancellationToken token, AttemptContext context)
    {
        try
        {
            token.ThrowIfCancellationRequested();
            ProbeResult response = await fetch(context.Store, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            if (!response.Success || response.Json is null) return new Attempt(false, null);
            Selection selection = select(response.Json);
            token.ThrowIfCancellationRequested();
            return new Attempt(selection.Valid, selection.Update);
        }
        catch (Exception) { return new Attempt(false, null); }
    }

    private async Task Observe(Task<Attempt> attempt, Task deadline, CancellationTokenSource cts, Stopwatch elapsed, long expected, long startedAt, AttemptContext context)
    {
        Task winner = await Task.WhenAny(attempt, deadline, stopSignal.Task).ConfigureAwait(false);
        if (winner != attempt) { lock (gate) RequestCancelLocked(cts); }
        Attempt result = winner == attempt ? await attempt.ConfigureAwait(false) : new Attempt(false, null);
        (ProbeHeaders? hints, bool invalidHeaders) = context.Seal();

        long completedAt = 0;
        DateTimeOffset wallNow = default;
        bool clockReady = false;
        if (!stopSignal.Task.IsCompleted)
        {
            try { wallNow = utcNow(); completedAt = timestamp(); clockReady = true; }
            catch (Exception) { lock (gate) { if (!stopped) faulted = true; } }
        }
        try
        {
            lock (gate)
            {
                if (winner != attempt || cts.IsCancellationRequested || elapsed.Elapsed >= timeout)
                {
                    RequestCancelLocked(cts);
                    result = new Attempt(false, null);
                }
                if (!stopped && generation == expected && clockReady)
                {
                    if (invalidHeaders) { faulted = true; }
                    else
                    {
                        // The previous deadline had expired at admission. Preserve
                        // the failure streak when the counter resets in flight.
                        if (completedAt < startedAt) schedule = new UpdateRetrySchedule(schedule.Failures);
                        bool recorded = schedule.Record(result.Valid, completedAt, frequency, wallNow,
                            hints?.RetryAfter, hints?.RateReset, hints?.ServerDate);
                        if (recorded && result.Valid && result.Update is not null) available = result.Update;
                    }
                }
            }
        }
        catch (Exception) { lock (gate) faulted = true; }
        // An uncooperative fetch/selector keeps the one slot occupied until it actually ends.
        try { await attempt.ConfigureAwait(false); } catch (Exception) { }
        Task? callbacks;
        lock (gate)
        {
            callbacks = cancellationCompletion;
            if (callbacks is null)
            {
                if (ReferenceEquals(cancellation, cts)) { cancellation = null; busy = false; }
                cts.Dispose();
                return;
            }
        }
        try { await callbacks.ConfigureAwait(false); } catch (Exception) { }
        lock (gate)
        {
            if (ReferenceEquals(cancellation, cts)) { cancellation = null; busy = false; }
            cts.Dispose();
        }
    }
}
