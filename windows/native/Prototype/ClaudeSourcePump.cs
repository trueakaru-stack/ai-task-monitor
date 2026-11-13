using System;
using System.Diagnostics;
using System.Linq;
using System.Windows.Threading;
using AITaskMonitor.Claude;
using ClaudeTask = AITaskMonitor.Claude.Task;

namespace AITaskMonitor.Prototype;

// The owner must report connection changes through this pump on the dispatcher.
// Polling runs off that thread; verification and presentation stay ordered with
// connection notifications on it. The application entry point does not start it.
internal sealed class ClaudeSourcePump : IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly DispatcherTimer timer;
    private readonly ClaudeFileSource source;
    private readonly Func<DateTime> utcNow;
    private readonly Action<ClaudeSourceSnapshot> apply;
    private readonly Action<ClaudeSourceSnapshot>? afterPoll;
    private readonly Action? afterCompletion;
    private readonly TimeSpan timeout;
    private DispatcherTimer? deadline;
    private ClaudeSourceSnapshot lastPresented = new([], false);
    private ClaudeSourceSnapshot? lastSourceSnapshot;
    private ClaudeConnection connection;
    private bool started, inFlight, rerun, disposed, timedOut, refreshInvalidatedSinceDelivery;
    private long pollStarted;
    private object revision = new();

    public ClaudeSourcePump(Dispatcher dispatcher, ClaudeFileSource source, ClaudeConnection initialConnection,
        Action<ClaudeSourceSnapshot> apply, Func<DateTime>? utcNow = null, TimeSpan? interval = null,
        Action<ClaudeSourceSnapshot>? afterPoll = null, Action? afterCompletion = null, TimeSpan? timeout = null)
    {
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        this.source = source ?? throw new ArgumentNullException(nameof(source));
        this.apply = apply ?? throw new ArgumentNullException(nameof(apply));
        this.utcNow = utcNow ?? (() => DateTime.UtcNow);
        this.afterPoll = afterPoll; // Synchronization seam for synthetic tests.
        this.afterCompletion = afterCompletion; // Synthetic tests observe dispatcher completion.
        this.timeout = timeout ?? TimeSpan.FromSeconds(10);
        if (this.timeout < TimeSpan.FromMilliseconds(1) || this.timeout > TimeSpan.FromMinutes(2))
            throw new ArgumentOutOfRangeException(nameof(timeout));
        dispatcher.VerifyAccess();
        source.NotifyConnection(initialConnection);
        connection = initialConnection;
        timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = interval ?? TimeSpan.FromSeconds(2) };
        timer.Tick += OnTick;
    }

    public void Start()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (started) return;
        started = true;
        timer.Start();
        RequestRefresh();
    }

    // This is the only connection-change entry point for the pump's owner.
    // Do not call source.NotifyConnection concurrently outside the dispatcher.
    public void NotifyConnection(ClaudeConnection next)
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        source.NotifyConnection(next);
        if (connection == next) return;
        connection = next;
        revision = new object();
        refreshInvalidatedSinceDelivery = true;
        if (!started) return;
        if (inFlight) rerun = true;
        else StartPoll();
        if (next == ClaudeConnection.Disconnected) Present(new ClaudeSourceSnapshot([], false));
        else if (next == ClaudeConnection.Partial) Present(lastPresented, true);
    }

    public void RequestRefresh()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!started) throw new InvalidOperationException("Start the source pump before requesting a refresh.");
        if (inFlight)
        {
            // Invalidate at most one read between presentations. Further
            // requests still schedule a follow-up, but cannot starve it.
            if (!refreshInvalidatedSinceDelivery)
            {
                revision = new object();
                refreshInvalidatedSinceDelivery = true;
            }
            rerun = true;
            return;
        }
        revision = new object();
        StartPoll();
    }

    private void OnTick(object? sender, EventArgs args)
    {
        if (!disposed && !inFlight) StartPoll();
    }

    private void StartPoll()
    {
        inFlight = true;
        timedOut = false;
        pollStarted = Stopwatch.GetTimestamp();
        object pollRevision = revision;
        var pollDeadline = new DispatcherTimer(DispatcherPriority.Normal, dispatcher) { Interval = timeout };
        deadline = pollDeadline;
        pollDeadline.Tick += (_, _) => OnDeadline(pollDeadline);
        pollDeadline.Start();
        _ = System.Threading.Tasks.Task.Run(() =>
        {
            try
            {
                ClaudeSourceSnapshot snapshot = source.Poll(utcNow());
                afterPoll?.Invoke(snapshot);
                return snapshot;
            }
            catch (Exception) { return source.ReportUnavailable(); }
        }).ContinueWith(result =>
        {
            if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished) return;
            try { dispatcher.BeginInvoke(() =>
            {
                try { CompletePoll(result, pollRevision); }
                finally { afterCompletion?.Invoke(); }
            }); }
            catch (InvalidOperationException) { }
        }, System.Threading.Tasks.TaskScheduler.Default);
    }

    private void OnDeadline(DispatcherTimer pollDeadline)
    {
        pollDeadline.Stop();
        if (disposed || !inFlight || timedOut || !ReferenceEquals(deadline, pollDeadline)) return;
        deadline = null;
        timedOut = true;
        revision = new object();
        refreshInvalidatedSinceDelivery = true;
        rerun = true;
        // Only the lightweight signal runs on the dispatcher; it does not wait
        // for the potentially blocked file-read lock or create another worker.
        source.NotifyUnavailable(lastSourceSnapshot);
        if (connection != ClaudeConnection.Disconnected) Present(lastPresented, true);
    }

    private void CompletePoll(System.Threading.Tasks.Task<ClaudeSourceSnapshot> result, object pollRevision)
    {
        dispatcher.VerifyAccess();
        if (disposed) return;
        // A congested dispatcher can deliver a completed result before its
        // overdue timer callback. Check elapsed time before presenting it.
        if (!timedOut && deadline is not null && Stopwatch.GetElapsedTime(pollStarted) >= timeout)
        {
            OnDeadline(deadline);
            if (disposed) return;
        }
        deadline?.Stop();
        deadline = null;
        try
        {
            if (result.IsFaulted) _ = result.Exception;
            if (ReferenceEquals(pollRevision, revision))
            {
                if (result.Status == System.Threading.Tasks.TaskStatus.RanToCompletion && source.IsCurrent(result.Result))
                {
                    lastSourceSnapshot = result.Result;
                    refreshInvalidatedSinceDelivery = false;
                    Present(result.Result);
                }
                else if (result.Status != System.Threading.Tasks.TaskStatus.RanToCompletion)
                {
                    refreshInvalidatedSinceDelivery = false;
                    Present(connection == ClaudeConnection.Disconnected ? new ClaudeSourceSnapshot([], false) : lastPresented,
                        connection != ClaudeConnection.Disconnected);
                }
            }
        }
        finally
        {
            // Presentation can synchronously request another refresh. Keep the
            // current poll reserved through that callback, then coalesce all
            // requests into a single subsequent worker.
            inFlight = false;
            if (!disposed && rerun) { rerun = false; StartPoll(); }
        }
    }

    private void Present(ClaudeSourceSnapshot snapshot, bool unconfirmed = false)
    {
        lastPresented = Copy(snapshot, unconfirmed);
        apply(Copy(lastPresented, false));
    }

    private static ClaudeSourceSnapshot Copy(ClaudeSourceSnapshot snapshot, bool unconfirmed)
    {
        ClaudeTask[] tasks = snapshot.Tasks.Select(item =>
        {
            Step[] steps = item.Steps.Select(step => new Step { id = step.id, title = step.title,
                generated = step.generated, status = unconfirmed ? "unknown" : step.status }).ToArray();
            return new ClaudeTask { Id = item.Id, Activity = unconfirmed ? "" : item.Activity,
                Updated = item.Updated, Started = item.Started, StartKey = item.StartKey, Steps = steps,
                Unconfirmed = unconfirmed || item.Unconfirmed, PlanConfirmed = !unconfirmed && item.PlanConfirmed,
                KnownStepCount = unconfirmed ? 0 : item.KnownStepCount,
                KnownDoneCount = unconfirmed ? 0 : item.KnownDoneCount,
                UnknownStepCount = unconfirmed ? steps.Length : item.UnknownStepCount,
                SessionEvidenceUncertain = item.SessionEvidenceUncertain, PlanEvidenceUncertain = item.PlanEvidenceUncertain,
                RetainedPlanIncomplete = item.RetainedPlanIncomplete };
        }).ToArray();
        return new ClaudeSourceSnapshot(tasks, unconfirmed || snapshot.Unavailable);
    }

    public void Dispose()
    {
        dispatcher.VerifyAccess();
        if (disposed) return;
        disposed = true;
        revision = new object();
        lastSourceSnapshot = null;
        lastPresented = new ClaudeSourceSnapshot([], false);
        deadline?.Stop();
        deadline = null;
        timer.Stop();
        timer.Tick -= OnTick;
    }
}
