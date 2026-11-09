using System.Windows.Threading;
using AITaskMonitor.Claude;

namespace AITaskMonitor.Prototype;

// Polls away from the UI thread. Explicit refreshes invalidate an older
// in-flight result so a disconnect cannot resurrect an outdated snapshot.
internal sealed class ClaudeSourcePump : IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly DispatcherTimer timer;
    private readonly ClaudeFileSource source;
    private readonly Func<ClaudeConnection> connection;
    private readonly Func<DateTime> utcNow;
    private readonly Action<ClaudeSourceSnapshot> apply;
    private bool inFlight, rerun, disposed;
    private long revision;

    public ClaudeSourcePump(Dispatcher dispatcher, ClaudeFileSource source, Func<ClaudeConnection> connection,
        Action<ClaudeSourceSnapshot> apply, Func<DateTime>? utcNow = null, TimeSpan? interval = null)
    {
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        this.source = source ?? throw new ArgumentNullException(nameof(source));
        this.connection = connection ?? throw new ArgumentNullException(nameof(connection));
        this.apply = apply ?? throw new ArgumentNullException(nameof(apply));
        this.utcNow = utcNow ?? (() => DateTime.UtcNow);
        dispatcher.VerifyAccess();
        timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = interval ?? TimeSpan.FromSeconds(2) };
        timer.Tick += OnTick;
    }

    public void Start()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        timer.Start();
        RequestRefresh();
    }

    public void RequestRefresh()
    {
        dispatcher.VerifyAccess();
        ObjectDisposedException.ThrowIf(disposed, this);
        revision++;
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
        long started = revision;
        _ = System.Threading.Tasks.Task.Run(() =>
        {
            try { return source.Poll(connection(), utcNow()); }
            catch (Exception) { return source.ReportUnavailable(); }
        }).ContinueWith(result =>
        {
            if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished) return;
            dispatcher.BeginInvoke(() =>
            {
                if (disposed) return;
                inFlight = false;
                if (started == revision) apply(result.Result);
                if (rerun)
                {
                    rerun = false;
                    StartPoll();
                }
            });
        }, System.Threading.Tasks.TaskScheduler.Default);
    }

    public void Dispose()
    {
        dispatcher.VerifyAccess();
        if (disposed) return;
        disposed = true;
        revision++;
        timer.Stop();
        timer.Tick -= OnTick;
    }
}
