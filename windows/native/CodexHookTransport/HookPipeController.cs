using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Cryptography;
using AITaskMonitor.CodexHookEvidence;

namespace AITaskMonitor.CodexHookTransport;

// A synthetic owner only. No endpoint discovery or registration is provided.
public sealed class HookPipeController : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly HookEvidenceCollector collector = new();
    private readonly HookConnection connection;
    private readonly CancellationTokenSource stopping = new();
    private readonly NamedPipeServerStream server;
    private readonly Task loop;
    private Task? stopTask;

    private HookPipeController(string name, NamedPipeServerStream server)
    {
        PipeName = name;
        this.server = server;
        connection = collector.Connect();
        loop = ListenAsync();
    }

    public string PipeName { get; }
    public HookEvidenceSnapshot Snapshot() => collector.Snapshot();

    public static HookPipeController Start() => Start(HookWire.NewPipeName());

    // An explicit name is useful for a synthetic collision check. A real
    // discovery mechanism and identity policy are deliberately absent.
    public static HookPipeController Start(string pipeName)
    {
        NamedPipeServerStream server = LocalPipe.Create(pipeName);
        try { return new HookPipeController(pipeName, server); }
        catch { server.Dispose(); throw; }
    }

    public Task StopAsync()
    {
        lock (gate) return stopTask ??= StopCoreAsync();
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    private async Task StopCoreAsync()
    {
        // This invalidates in-flight callbacks before disposal is observable.
        collector.Disconnect(connection);
        stopping.Cancel();
        server.Dispose();
        try { await loop.ConfigureAwait(false); }
        finally { stopping.Dispose(); }
    }

    private async Task ListenAsync()
    {
        try
        {
            while (!stopping.IsCancellationRequested)
            {
                try { await server.WaitForConnectionAsync(stopping.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
                catch (ObjectDisposedException) when (stopping.IsCancellationRequested) { break; }
                catch (Exception error) when (error is IOException or InvalidOperationException or UnauthorizedAccessException)
                {
                    collector.NotifyLoss(connection);
                    break;
                }

                bool reusable = true;
                try
                {
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token);
                    deadline.CancelAfter(HookWire.IoTimeoutMilliseconds);
                    await ReceiveAsync(deadline.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
                catch (ObjectDisposedException) when (stopping.IsCancellationRequested) { break; }
                catch (Exception error) when (error is IOException or InvalidDataException or OperationCanceledException or
                    InvalidOperationException or ArgumentException)
                {
                    collector.NotifyLoss(connection);
                }
                finally
                {
                    // A peer closing early can put the stream in Broken state,
                    // where IsConnected is false but Disconnect is still needed.
                    try { server.Disconnect(); }
                    catch (Exception error) when (error is IOException or InvalidOperationException)
                    {
                        reusable = false;
                        if (!stopping.IsCancellationRequested) collector.NotifyLoss(connection);
                    }
                }
                if (!reusable) break;
            }
        }
        finally { collector.Disconnect(connection); }
    }

    private async Task ReceiveAsync(CancellationToken cancellationToken)
    {
        byte[] lengthBytes = new byte[4];
        await server.ReadExactlyAsync(lengthBytes, cancellationToken).ConfigureAwait(false);
        int length = BinaryPrimitives.ReadInt32LittleEndian(lengthBytes);
        if (length <= 0 || length > HookWire.MaximumFrameBytes)
            throw new InvalidDataException("Invalid frame length.");
        byte[] payload = GC.AllocateUninitializedArray<byte>(length);
        try
        {
            await server.ReadExactlyAsync(payload, cancellationToken).ConfigureAwait(false);
            if (!HookWire.ContainsOnlyRoutingFields(payload))
            {
                collector.NotifyLoss(connection);
                return;
            }
            _ = collector.Accept(connection, payload);
        }
        finally { CryptographicOperations.ZeroMemory(payload); }
    }
}
