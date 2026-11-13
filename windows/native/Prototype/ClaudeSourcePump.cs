using System;
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
    private ClaudeSourceSnapshot lastPresented = new([], false);
    private ClaudeConnection connection;
    private bool started, inFlight, rerun, disposed;
    private object revision = new();

    public ClaudeSourcePump(Dispatcher dispatcher, ClaudeFileSource source, ClaudeConnection initialConnection,
        Action<ClaudeSourceSnapshot> apply, Func<DateTime>? utcNow = null, TimeSpan? interval = null,
        Action<ClaudeSourceSnapshot>? afterPoll = null, Action? afterCompletion = null)
    {
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        this.source = source ?? throw new ArgumentNullException(nameof(source));
        this.apply = apply ?? throw new ArgumentNullException(nameof(apply));
        this.utcNow = utcNow ?? (() => DateTime.UtcNow);
        this.afterPoll = afterPoll; // Synchronization seam for synthetic tests.
        this.afterCompletion = afterCompletion; // Synthetic tests observe dispatcher completion.
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
        bool changed = connection != next;
        connection = next;
        revision = new object();
        if (!started) return;
        if (inFlight) rerun = true;
        else StartPoll();
        if (!changed) return;
        if (next == ClaudeConnection.Disconnected) Present(new ClaudeSourceSnapshot([], false));
        else if (next == ClaudeConnection.Partial) Present(lastPresented, true);
    }

    public void RequestRefresh()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!started) throw new InvalidOperationException("Start the source pump before requesting a refresh.");
        revision = new object();
        if (inFlight) { rerun = true; return; }
        StartPoll();
    }

    private void OnTick(object? sender, EventArgs args)
    {
        if (!disposed && !inFlight) StartPoll();
    }

    private void StartPoll()
    {
        inFlight = true;
        object pollRevision = revision;
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

    private void CompletePoll(System.Threading.Tasks.Task<ClaudeSourceSnapshot> result, object pollRevision)
    {
        dispatcher.VerifyAccess();
        if (disposed) return;
        inFlight = false;
        try
        {
            if (result.IsFaulted) _ = result.Exception;
            if (ReferenceEquals(pollRevision, revision))
            {
                if (result.Status == System.Threading.Tasks.TaskStatus.RanToCompletion && source.IsCurrent(result.Result))
                    Present(result.Result);
                else if (result.Status != System.Threading.Tasks.TaskStatus.RanToCompletion)
                    Present(connection == ClaudeConnection.Disconnected ? new ClaudeSourceSnapshot([], false) : lastPresented,
                        connection != ClaudeConnection.Disconnected);
            }
        }
        finally
        {
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
        timer.Stop();
        timer.Tick -= OnTick;
    }
}
