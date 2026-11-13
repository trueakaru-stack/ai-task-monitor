using System;
using System.Net.Http;
using System.Threading.Tasks;
using AITaskMonitor.NativeUpdateController;
using AITaskMonitor.NativeUpdateHttp;

namespace AITaskMonitor.NativeUpdateIntegration;

public enum WindowsUpdateChannel { Standalone = 1, Store = 2 }

/// <summary>
/// Owns the standalone update transport and coordinator. Callers drive checks
/// and await shutdown; this service does not create a timer or open a UI.
/// The Store channel never constructs an external updater.
/// </summary>
public sealed class WindowsUpdateService : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly UpdateHttpTransport? transport;
    private readonly UpdateCoordinator? coordinator;
    private Task? stopTask;

    private WindowsUpdateService(UpdateHttpTransport? transport, UpdateCoordinator? coordinator) =>
        (this.transport, this.coordinator) = (transport, coordinator);

    // The handler factory is a test seam. Its handler is owned and disposed by
    // the transport; omit it for the restricted production HTTP handler.
    public static WindowsUpdateService Create(
        WindowsUpdateChannel channel,
        string currentVersion,
        Func<long> timestamp,
        Func<DateTimeOffset> utcNow,
        long frequency,
        TimeSpan timeout,
        Func<HttpMessageHandler>? handlerFactory = null)
    {
        if (channel == WindowsUpdateChannel.Store) return new WindowsUpdateService(null, null);
        if (channel != WindowsUpdateChannel.Standalone) throw new ArgumentOutOfRangeException(nameof(channel));

        HttpMessageHandler? handler = null;
        UpdateHttpTransport? transport = null;
        try
        {
            if (handlerFactory is not null)
                handler = handlerFactory() ?? throw new InvalidOperationException("The handler factory returned null.");
            transport = new UpdateHttpTransport(handler);
            UpdateCoordinator coordinator = WindowsUpdateIntegration.Create(
                currentVersion, transport.Fetch, timestamp, utcNow, frequency, timeout);
            return new WindowsUpdateService(transport, coordinator);
        }
        catch
        {
            if (transport is not null) transport.Dispose();
            else handler?.Dispose();
            throw;
        }
    }

    public bool IsExternalUpdaterConfigured => coordinator is not null;

    // Store has no coordinator and hence no external-update snapshot.
    public CoordinatorSnapshot? Snapshot() => coordinator?.Snapshot();

    public Task<bool> StartIfDueAsync()
    {
        lock (gate)
        {
            if (stopTask is not null || coordinator is null) return Task.FromResult(false);
            return coordinator.StartIfDueAsync();
        }
    }

    // Stopping immediately prevents publication. Transport disposal is moved
    // off the caller thread because cancellation callbacks may block.
    // An uncooperative handler can still keep an attempt in flight.
    public Task StopAsync()
    {
        lock (gate)
        {
            if (stopTask is not null) return stopTask;
            coordinator?.Stop();
            stopTask = transport is null ? Task.CompletedTask : Task.Run(transport.Dispose);
            return stopTask;
        }
    }

    public ValueTask DisposeAsync() => new(StopAsync());
}
