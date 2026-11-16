using System.Windows.Threading;
using AITaskMonitor.NativeUpdateController;
using AITaskMonitor.NativeUpdateIntegration;

namespace AITaskMonitor.Prototype;

// An injected service only. The application does not create this pump until
// distribution, version and installer identity have verified contracts.
internal sealed class UpdateSourcePump
{
    private readonly Dispatcher dispatcher;
    private readonly WindowsUpdateService service;
    private readonly Action<UpdateInfo> present;
    private readonly DispatcherTimer timer;
    private UpdateInfo? lastPublished;
    private bool stopped;
    private Task? stopTask;

    internal UpdateSourcePump(Dispatcher dispatcher, WindowsUpdateService service,
        Action<UpdateInfo> present, TimeSpan interval)
    {
        this.dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        this.service = service ?? throw new ArgumentNullException(nameof(service));
        this.present = present ?? throw new ArgumentNullException(nameof(present));
        if (!dispatcher.CheckAccess()) throw new InvalidOperationException("The update pump belongs to the window dispatcher.");
        if (interval < TimeSpan.FromMilliseconds(10) || interval > TimeSpan.FromMinutes(5))
            throw new ArgumentOutOfRangeException(nameof(interval));
        timer = new DispatcherTimer(DispatcherPriority.Background, dispatcher) { Interval = interval };
        timer.Tick += OnTick;
    }

    internal void Start()
    {
        VerifyAccess();
        if (stopped) return;
        timer.Start();
        Poll();
    }

    internal void Poll()
    {
        VerifyAccess();
        if (stopped) return;
        Task<bool> pending = service.StartIfDueAsync();
        _ = pending.ContinueWith(done => { _ = done.Exception; }, CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
        CoordinatorSnapshot? snapshot = service.Snapshot();
        if (snapshot is { Stopped: false, Available: not null } &&
            snapshot.Available != lastPublished)
        {
            lastPublished = snapshot.Available;
            present(snapshot.Available);
        }
    }

    private void OnTick(object? sender, EventArgs e) => Poll();

    internal Task StopAsync()
    {
        VerifyAccess();
        if (stopTask is not null) return stopTask;
        stopped = true;
        timer.Stop();
        timer.Tick -= OnTick;
        stopTask = service.StopAsync();
        return stopTask;
    }

    private void VerifyAccess()
    {
        if (!dispatcher.CheckAccess()) throw new InvalidOperationException("The update pump belongs to the window dispatcher.");
    }
}
