using System.Security.Cryptography;
using AITaskMonitor.CodexHookTransport;

// Synthetic executable: nothing installs or registers it with Codex.
// There is intentionally no stdout/stderr and every expected failure returns 0.
if (!OperatingSystem.IsWindows() || args.Length != 1 || !HookWire.IsValidPipeName(args[0]))
    return 0;

Task worker = Task.Run(async () =>
{
    byte[] buffer = GC.AllocateUninitializedArray<byte>(HookWire.MaximumInputBytes + 1);
    try
    {
        using Stream input = Console.OpenStandardInput();
        int count = 0;
        while (count < buffer.Length)
        {
            int read = await input.ReadAsync(buffer.AsMemory(count)).ConfigureAwait(false);
            if (read == 0) break;
            count += read;
        }
        if (count > 0 && count <= HookWire.MaximumInputBytes)
            _ = await HookWire.SendAsync(args[0], buffer.AsMemory(0, count)).ConfigureAwait(false);
    }
    catch (Exception) { }
    finally { CryptographicOperations.ZeroMemory(buffer); }
});

try { _ = worker.Wait(HookWire.HelperDeadlineMilliseconds); }
catch (AggregateException) { }
// A pending input read runs on background threads, so returning terminates the
// helper even if the writer never closes stdin. A real async hook must also
// have its own Codex-side timeout; process startup itself is outside this bound.
return 0;
