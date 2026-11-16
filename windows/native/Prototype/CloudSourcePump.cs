using System.Diagnostics;
using System.Windows.Threading;
using AITaskMonitor.CodexCloud;
using AITaskMonitor.CodexCloudCommand;

namespace AITaskMonitor.Prototype;

// This owner has no executable discovery. The normal entry point supplies no
// runner; only a hosted synthetic test supplies one.
internal sealed class CloudSourcePump : IDisposable
{
    private static int processLease; // 0 = free, 1 = scan owns it, 2 = termination unconfirmed
    private readonly object gate = new();
    private readonly Dispatcher dispatcher;
    private readonly CodexCloudSource source = new();
    private readonly Action<CloudSnapshot> present;
    private readonly Func<string?, TimeSpan, CancellationToken, Task<CommandResult>>? runner;
    private readonly DispatcherTimer pollTimer;
    private readonly DispatcherTimer deadlineTimer;
    private readonly TimeSpan scanLimit;
    private readonly TimeSpan pageLimit;
    private bool enabled, disposed, inFlight, workerFinished, rerun, publishingLeaseFailure;
    private object generation = new();
    private CancellationLifetime? cancellation;
    private CloudPageRequest? firstRequest;
    private long startedAt;

    internal CloudSourcePump(Dispatcher dispatcher, Action<CloudSnapshot> present,
        Func<string?, TimeSpan, CancellationToken, Task<CommandResult>>? runner,
        TimeSpan? scanLimit = null, TimeSpan? pageLimit = null, TimeSpan? pollInterval = null)
    {
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        this.present = present ?? throw new ArgumentNullException(nameof(present));
        this.runner = runner;
        this.scanLimit = scanLimit ?? TimeSpan.FromSeconds(30);
        this.pageLimit = pageLimit ?? TimeSpan.FromSeconds(12);
        TimeSpan interval = pollInterval ?? TimeSpan.FromSeconds(30);
        if (this.scanLimit < TimeSpan.FromMilliseconds(1) || this.scanLimit > TimeSpan.FromMinutes(2) ||
            this.pageLimit < TimeSpan.FromMilliseconds(1) || this.pageLimit > TimeSpan.FromMinutes(2) ||
            interval < TimeSpan.FromMilliseconds(1) || interval > TimeSpan.FromHours(1))
            throw new ArgumentOutOfRangeException(nameof(scanLimit));
        dispatcher.VerifyAccess();
        pollTimer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = interval };
        deadlineTimer = new DispatcherTimer(DispatcherPriority.Normal, dispatcher) { Interval = this.scanLimit };
        pollTimer.Tick += OnPoll;
        deadlineTimer.Tick += OnDeadline;
    }

    internal bool InFlight { get { dispatcher.VerifyAccess(); return inFlight; } }

    internal void SetEnabled(bool value)
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (value && runner is null) throw new InvalidOperationException("No cloud runner is configured.");
        CancellationLifetime? toCancel;
        CloudSnapshot snapshot;
        lock (gate)
        {
            if (enabled == value) return;
            enabled = value;
            generation = new object();
            source.SetEnabled(value);
            snapshot = source.GetSnapshot();
            toCancel = value ? null : cancellation;
            rerun = value && inFlight;
        }

        if (value) pollTimer.Start();
        else
        {
            pollTimer.Stop();
            deadlineTimer.Stop();
            RequestCancellation(toCancel);
        }
        present(snapshot);
        if (value && !inFlight) StartScan();
    }

    internal void RequestRefresh()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!enabled) return;
        if (inFlight) { rerun = true; return; }
        StartScan();
    }

    private void OnPoll(object? sender, EventArgs e)
    {
        if (!disposed && enabled && !inFlight) StartScan();
    }

    private void StartScan()
    {
        dispatcher.VerifyAccess();
        if (disposed || !enabled || inFlight || runner is null || publishingLeaseFailure) return;
        CloudPageRequest? request;
        object currentGeneration;
        lock (gate)
        {
            request = source.BeginScan();
            currentGeneration = generation;
        }
        if (request is null) return;
        if (Interlocked.CompareExchange(ref processLease, 1, 0) != 0)
        {
            lock (gate) { source.ReportFailure(request); }
            // A view callback may synchronously ask to refresh; retrying here
            // would recursively report the same busy lease without progress.
            publishingLeaseFailure = true;
            try { present(source.GetSnapshot()); }
            finally { publishingLeaseFailure = false; }
            return;
        }

        var ownedCancellation = new CancellationLifetime();
        cancellation = ownedCancellation;
        firstRequest = request;
        startedAt = Stopwatch.GetTimestamp();
        lock (gate) { workerFinished = false; }
        inFlight = true;
        deadlineTimer.Stop();
        deadlineTimer.Start();
        long started = startedAt;
        Task<CloudSnapshot?> work;
        try
        {
            work = Task.Run(() => ScanAsync(request, currentGeneration, started, ownedCancellation));
        }
        catch
        {
            Interlocked.CompareExchange(ref processLease, 0, 1);
            lock (gate) { source.ReportFailure(request); workerFinished = true; }
            inFlight = false;
            deadlineTimer.Stop();
            ownedCancellation.CompleteWorker();
            cancellation = null;
            firstRequest = null;
            present(source.GetSnapshot());
            throw;
        }
        _ = work.ContinueWith(completed =>
        {
            if (completed.IsFaulted) _ = completed.Exception;
            if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished)
            {
                ownedCancellation.CompleteWorker();
                return;
            }
            try { dispatcher.BeginInvoke(() => CompleteScan(completed, currentGeneration, ownedCancellation)); }
            catch (InvalidOperationException) { ownedCancellation.CompleteWorker(); }
        }, TaskScheduler.Default);
    }

    private async Task<CloudSnapshot?> ScanAsync(CloudPageRequest initial, object currentGeneration,
        long started, CancellationLifetime lifetime)
    {
        CloudPageRequest request = initial;
        CancellationToken token = lifetime.Token;
        bool releaseLease = true;
        try
        {
            while (true)
            {
                if (token.IsCancellationRequested) return null;
                TimeSpan remaining = scanLimit - Stopwatch.GetElapsedTime(started);
                if (remaining <= TimeSpan.Zero)
                {
                    lock (gate)
                    {
                        if (!disposed && enabled && ReferenceEquals(generation, currentGeneration))
                        {
                            source.ReportFailure(request);
                            workerFinished = true;
                            return source.GetSnapshot();
                        }
                        return null;
                    }
                }
                TimeSpan timeout = remaining < pageLimit ? remaining : pageLimit;
                using CommandResult response = await runner!(request.Cursor, timeout, token).ConfigureAwait(false);
                if (response.Started && !response.ExitObserved) releaseLease = false;
                lock (gate)
                {
                    if (disposed || !enabled || !ReferenceEquals(generation, currentGeneration)) return null;
                    // The response must arrive before the scan deadline. The
                    // bounded in-memory parse and UI delivery may finish later.
                    if (Stopwatch.GetElapsedTime(started) >= scanLimit ||
                        response.Outcome != CommandOutcome.Success || !response.Started || !response.ExitObserved)
                    {
                        source.ReportFailure(request);
                        workerFinished = true;
                        return source.GetSnapshot();
                    }
                    CloudPageResult page = source.AcceptPage(request, response.Output);
                    if (page.Disposition == CloudPageDisposition.NextPage && page.NextRequest is not null)
                    {
                        request = page.NextRequest;
                        continue;
                    }
                    workerFinished = true;
                    return source.GetSnapshot();
                }
            }
        }
        catch
        {
            // An unexpected exception does not prove that a child never started.
            releaseLease = false;
            lock (gate)
            {
                if (!disposed && enabled && ReferenceEquals(generation, currentGeneration))
                    source.ReportFailure(request);
                workerFinished = true;
            }
            throw;
        }
        finally
        {
            if (!releaseLease) lifetime.MarkUncertain();
            lock (gate) { workerFinished = true; }
        }
    }

    private void OnDeadline(object? sender, EventArgs e)
    {
        dispatcher.VerifyAccess();
        deadlineTimer.Stop();
        CloudSnapshot? snapshot = null;
        CancellationLifetime? toCancel = null;
        lock (gate)
        {
            if (!disposed && enabled && inFlight && !workerFinished && firstRequest is not null)
            {
                generation = new object();
                source.CancelScan(firstRequest);
                snapshot = source.GetSnapshot();
                toCancel = cancellation;
            }
        }
        RequestCancellation(toCancel);
        if (snapshot is not null) present(snapshot);
    }

    private void CompleteScan(Task<CloudSnapshot?> result, object currentGeneration,
        CancellationLifetime ownedCancellation)
    {
        dispatcher.VerifyAccess();
        deadlineTimer.Stop();
        CloudSnapshot? snapshot = null;
        bool startAgain;
        lock (gate)
        {
            if (!disposed && enabled && ReferenceEquals(generation, currentGeneration))
            {
                if (result.Status == TaskStatus.RanToCompletion)
                    snapshot = result.Result;
                else
                    snapshot = source.GetSnapshot();
            }
            inFlight = false;
            firstRequest = null;
            if (ReferenceEquals(cancellation, ownedCancellation)) cancellation = null;
            startAgain = !disposed && enabled && rerun;
            rerun = false;
        }
        ownedCancellation.CompleteWorker();
        if (snapshot is not null) present(snapshot);
        if (startAgain) StartScan();
    }

    private static void RequestCancellation(CancellationLifetime? target)
    {
        if (target is null) return;
        target.Request();
    }

    public void Dispose()
    {
        dispatcher.VerifyAccess();
        CancellationLifetime? toCancel;
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            enabled = false;
            generation = new object();
            source.SetEnabled(false);
            rerun = false;
            toCancel = cancellation;
        }
        pollTimer.Stop();
        deadlineTimer.Stop();
        pollTimer.Tick -= OnPoll;
        deadlineTimer.Tick -= OnDeadline;
        RequestCancellation(toCancel);
    }

    // The worker can finish while CancelAsync callbacks still run. Keep the
    // token source alive until both have completed, without waiting on WPF.
    private sealed class CancellationLifetime
    {
        private readonly object sync = new();
        private readonly CancellationTokenSource source = new();
        private int pending;
        private bool workerComplete;

        internal CancellationLifetime() => Token = source.Token;
        internal CancellationToken Token { get; }

        internal void MarkUncertain() => Interlocked.Exchange(ref processLease, 2);

        internal void Request()
        {
            lock (sync)
            {
                if (workerComplete) return;
                pending++;
            }
            Task work;
            try { work = source.CancelAsync(); }
            catch { CompleteCancellation(); throw; }
            _ = work.ContinueWith(completed =>
            {
                if (completed.IsFaulted) _ = completed.Exception;
                CompleteCancellation();
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }

        internal void CompleteWorker()
        {
            bool dispose;
            lock (sync)
            {
                if (workerComplete) return;
                workerComplete = true;
                dispose = pending == 0;
            }
            if (dispose) Release();
        }

        private void CompleteCancellation()
        {
            bool dispose;
            lock (sync)
            {
                pending--;
                dispose = workerComplete && pending == 0;
            }
            if (dispose) Release();
        }

        private void Release()
        {
            source.Dispose();
            // A pending cancellation callback keeps the process-wide lease held.
            // Never release an explicitly unconfirmed process termination.
            Interlocked.CompareExchange(ref processLease, 0, 1);
        }
    }
}

