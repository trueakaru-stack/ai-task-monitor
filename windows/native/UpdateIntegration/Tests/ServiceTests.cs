using System;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using AITaskMonitor.NativeUpdateController;
using AITaskMonitor.NativeUpdateIntegration;

internal static class ServiceTests
{
    private const string Version = "0.2.0";
    private const string Endpoint = "https://api.github.com/repos/trueakaru-stack/ai-task-monitor/releases?per_page=100";
    private const string Url = "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0/AI-Task-Monitor-Setup.exe";
    private const string Release = """
        [{"tag_name":"v0.3.0","draft":false,"assets":[{"name":"AI-Task-Monitor-Setup.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0/AI-Task-Monitor-Setup.exe"}]}]
        """;
    private static int checks;

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task Until(Func<bool> condition, string message)
    {
        var watch = Stopwatch.StartNew();
        while (!condition())
        {
            if (watch.Elapsed > TimeSpan.FromSeconds(8)) throw new TimeoutException(message);
            await Task.Delay(5);
        }
    }

    private sealed class Clock
    {
        private long now;
        internal long Tick() => Interlocked.Read(ref now);
        internal void Set(long value) => Interlocked.Exchange(ref now, value);
        internal DateTimeOffset Utc() => new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    }

    private sealed class FakeHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> reply,
        Action? disposingAction = null) : HttpMessageHandler
    {
        private int requests, disposals;
        internal int Requests => Volatile.Read(ref requests);
        internal int Disposals => Volatile.Read(ref disposals);
        internal string? RequestUri { get; private set; }
        internal string? Method { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            RequestUri = request.RequestUri?.AbsoluteUri;
            Method = request.Method.Method;
            Interlocked.Increment(ref requests);
            return reply(request, cancellationToken);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                Interlocked.Increment(ref disposals);
                disposingAction?.Invoke();
            }
            base.Dispose(disposing);
        }
    }

    private static HttpResponseMessage Response(HttpStatusCode status, string body) => new(status)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json")
    };

    private static WindowsUpdateService Make(FakeHandler handler, Clock clock,
        string version = Version, TimeSpan? timeout = null) =>
        WindowsUpdateService.Create(WindowsUpdateChannel.Standalone, version, clock.Tick,
            clock.Utc, 1, timeout ?? TimeSpan.FromSeconds(5), () => handler);

    private static async Task<CoordinatorSnapshot> RunOnce(WindowsUpdateService service)
    {
        Check(await service.StartIfDueAsync(), "A service check did not start.");
        await Until(() => service.Snapshot() is { Busy: false }, "A service check did not finish.");
        return service.Snapshot()!;
    }

    internal static async Task RunAsync()
    {
        var clock = new Clock();
        var handler = new FakeHandler((_, _) => Task.FromResult(Response(HttpStatusCode.OK, Release)));
        await using (WindowsUpdateService service = Make(handler, clock))
        {
            Check(service.IsExternalUpdaterConfigured && handler.Requests == 0, "Construction unexpectedly performed a request.");
            CoordinatorSnapshot result = await RunOnce(service);
            Check(result is { Failures: 0, HasSchedule: true, Available.Version: "0.3.0" }
                && result.Available.Url == Url, "The service did not publish the trusted release.");
            Check(handler.Requests == 1 && handler.Method == "GET" && handler.RequestUri == Endpoint,
                "The service did not use the bounded release endpoint.");
            Check(!await service.StartIfDueAsync() && handler.Requests == 1,
                "The service bypassed the successful-check schedule.");
        }
        Check(handler.Disposals == 1, "The transport was not disposed exactly once.");

        handler = new FakeHandler((_, _) => Task.FromResult(Response(HttpStatusCode.OK, Release)));
        await using (WindowsUpdateService service = Make(handler, new Clock(), "0.3.0"))
        {
            CoordinatorSnapshot result = await RunOnce(service);
            Check(result is { Failures: 0, HasSchedule: true, Available: null },
                "An already installed version was reported as an update.");
        }

        string unsafeRelease = Release.Replace("github.com/trueakaru-stack", "github.com.attacker.example/trueakaru-stack", StringComparison.Ordinal);
        handler = new FakeHandler((_, _) => Task.FromResult(Response(HttpStatusCode.OK, unsafeRelease)));
        await using (WindowsUpdateService service = Make(handler, new Clock()))
        {
            CoordinatorSnapshot result = await RunOnce(service);
            Check(result is { Failures: 0, Available: null }, "An untrusted URL was published.");
        }

        handler = new FakeHandler((_, _) => Task.FromResult(Response(HttpStatusCode.OK, "{invalid")));
        await using (WindowsUpdateService service = Make(handler, new Clock()))
        {
            CoordinatorSnapshot result = await RunOnce(service);
            Check(result is { Failures: 1, HasSchedule: true, Available: null }, "Invalid metadata did not schedule a retry.");
        }

        Check(WindowsUpdateIntegration.Select("[]", Version) is { Valid: true, Update: null },
            "The partial-response fixture is not a valid empty release list.");
        clock = new Clock();
        int partialAttempts = 0;
        handler = new FakeHandler((_, _) =>
        {
            bool partial = Interlocked.Increment(ref partialAttempts) == 1;
            HttpResponseMessage response = Response(partial ? HttpStatusCode.PartialContent : HttpStatusCode.OK, "[]");
            if (partial)
            {
                response.Content!.Headers.ContentRange = new System.Net.Http.Headers.ContentRangeHeaderValue(0, 1, 20);
                response.Headers.TryAddWithoutValidation("Retry-After", "7200");
            }
            return Task.FromResult(response);
        });
        await using (WindowsUpdateService service = Make(handler, clock))
        {
            CoordinatorSnapshot partial = await RunOnce(service);
            Check(partial is { Failures: 1, HasSchedule: true, Available: null } && handler.Requests == 1,
                "A 206 response containing valid JSON was accepted as a complete release list.");
            clock.Set(7199);
            Check(!await service.StartIfDueAsync() && handler.Requests == 1,
                "The 206 response lost its Retry-After delay.");
            clock.Set(7200);
            CoordinatorSnapshot complete = await RunOnce(service);
            Check(complete is { Failures: 0, HasSchedule: true, Available: null } && handler.Requests == 2,
                "A complete 200 response containing the same JSON was not accepted on retry.");
            clock.Set(93599);
            Check(!await service.StartIfDueAsync() && handler.Requests == 2,
                "The successful 200 response did not restore the daily schedule.");
            clock.Set(93600);
            CoordinatorSnapshot nextDay = await RunOnce(service);
            Check(nextDay is { Failures: 0, HasSchedule: true, Available: null } && handler.Requests == 3,
                "The successful 200 response was not rechecked after one day.");
        }

        handler = new FakeHandler((_, _) =>
        {
            HttpResponseMessage response = Response(HttpStatusCode.PartialContent, Release);
            int bytes = Encoding.UTF8.GetByteCount(Release);
            response.Content!.Headers.ContentRange = new System.Net.Http.Headers.ContentRangeHeaderValue(0, bytes - 1, bytes + 20);
            return Task.FromResult(response);
        });
        await using (WindowsUpdateService service = Make(handler, new Clock()))
        {
            CoordinatorSnapshot result = await RunOnce(service);
            Check(result is { Failures: 1, HasSchedule: true, Available: null },
                "A partial response published a plausible but incomplete release list.");
        }

        string oversizedRelease = Release.Replace("\"draft\":false,",
            "\"description\":\"" + new string('\u00e9', 530_000) + "\",\"draft\":false,", StringComparison.Ordinal);
        Check(Encoding.UTF8.GetByteCount(oversizedRelease) > 1_048_576 &&
            WindowsUpdateIntegration.Select(oversizedRelease, Version) is { Valid: true, Update.Version: "0.3.0" },
            "The oversized-response fixture did not isolate the byte limit.");
        handler = new FakeHandler((_, _) => Task.FromResult(Response(HttpStatusCode.OK, oversizedRelease)));
        await using (WindowsUpdateService service = Make(handler, new Clock()))
        {
            CoordinatorSnapshot result = await RunOnce(service);
            Check(result is { Failures: 1, HasSchedule: true, Available: null }, "An oversized HTTP body was accepted.");
        }

        clock = new Clock();
        int attempts = 0;
        handler = new FakeHandler((_, _) =>
        {
            if (Interlocked.Increment(ref attempts) == 1)
            {
                HttpResponseMessage failed = Response(HttpStatusCode.TooManyRequests, "[]");
                failed.Headers.TryAddWithoutValidation("Retry-After", "7200");
                return Task.FromResult(failed);
            }
            return Task.FromResult(Response(HttpStatusCode.OK, Release));
        });
        await using (WindowsUpdateService service = Make(handler, clock))
        {
            CoordinatorSnapshot failed = await RunOnce(service);
            Check(failed is { Failures: 1, HasSchedule: true, Available: null }, "HTTP failure did not schedule a retry.");
            clock.Set(7199);
            Check(!await service.StartIfDueAsync() && handler.Requests == 1, "The server retry delay was shortened.");
            clock.Set(7200);
            CoordinatorSnapshot retry = await RunOnce(service);
            Check(retry is { Failures: 0, Available.Version: "0.3.0" } && handler.Requests == 2,
                "The due retry did not publish the trusted release.");
        }

        handler = new FakeHandler((_, _) => Task.FromException<HttpResponseMessage>(new HttpRequestException("Synthetic failure")));
        await using (WindowsUpdateService service = Make(handler, new Clock()))
        {
            CoordinatorSnapshot result = await RunOnce(service);
            Check(result is { Failures: 1, HasSchedule: true, Available: null }, "A transport exception was accepted.");
        }

        var timeoutCancelled = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        handler = new FakeHandler(async (_, token) =>
        {
            using CancellationTokenRegistration registration = token.Register(() => timeoutCancelled.TrySetResult(true));
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return Response(HttpStatusCode.OK, Release);
        });
        await using (WindowsUpdateService service = Make(handler, new Clock(), timeout: TimeSpan.FromSeconds(2)))
        {
            Check(await service.StartIfDueAsync(), "The timeout fixture did not start.");
            await timeoutCancelled.Task.WaitAsync(TimeSpan.FromSeconds(8));
            await Until(() => service.Snapshot() is { Busy: false }, "The timed-out request did not finish.");
            Check(service.Snapshot() is { Failures: 1, HasSchedule: true, Available: null },
                "A cancelled timeout was treated as success.");
        }

        var entered = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        handler = new FakeHandler(async (_, token) =>
        {
            using CancellationTokenRegistration registration = token.Register(() => cancelled.TrySetResult(true));
            entered.TrySetResult(true);
            return await release.Task;
        });
        await using (WindowsUpdateService service = Make(handler, new Clock()))
        {
            Task<bool> first = service.StartIfDueAsync();
            Task<bool> second = service.StartIfDueAsync();
            bool[] admissions = await Task.WhenAll(first, second);
            Check(admissions[0] != admissions[1], "Concurrent checks were both accepted or both rejected.");
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(8));
            Task stopping = service.StopAsync();
            Check(ReferenceEquals(stopping, service.StopAsync()), "Repeated stops created new disposal work.");
            await stopping.WaitAsync(TimeSpan.FromSeconds(8));
            await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(8));
            Check(!await service.StartIfDueAsync() && handler.Requests == 1 && handler.Disposals == 1,
                "A stopped service restarted or did not dispose its handler.");
            release.SetResult(Response(HttpStatusCode.OK, Release));
            await Until(() => service.Snapshot() is { Busy: false }, "The late response did not finish.");
            Check(service.Snapshot() is { Stopped: true, Available: null }, "A stopped service published a late update.");
        }
        Check(handler.Disposals == 1, "Async disposal repeated transport disposal.");

        using var disposalGate = new ManualResetEventSlim();
        var disposalEntered = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        handler = new FakeHandler((_, _) => throw new InvalidOperationException("Unexpected request."), () =>
        {
            disposalEntered.TrySetResult(true);
            if (!disposalGate.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The disposal fixture was not released.");
        });
        WindowsUpdateService disposingService = Make(handler, new Clock());
        Task<Task> caller = Task.Factory.StartNew(() => disposingService.StopAsync(), CancellationToken.None,
            TaskCreationOptions.None, TaskScheduler.Default);
        Task? disposal = null;
        try
        {
            await disposalEntered.Task.WaitAsync(TimeSpan.FromSeconds(8));
            disposal = await caller.WaitAsync(TimeSpan.FromSeconds(3));
            Check(!disposal.IsCompleted, "Blocking handler disposal unexpectedly completed.");
        }
        finally { disposalGate.Set(); }
        await disposal!.WaitAsync(TimeSpan.FromSeconds(8));
        await disposingService.DisposeAsync();
        Check(handler.Disposals == 1, "The handler was not disposed once after release.");

        int factories = 0, clockCalls = 0;
        await using (WindowsUpdateService store = WindowsUpdateService.Create(WindowsUpdateChannel.Store, "invalid",
            () => { clockCalls++; throw new InvalidOperationException(); },
            () => { clockCalls++; throw new InvalidOperationException(); }, -1, TimeSpan.Zero,
            () => { factories++; throw new InvalidOperationException(); }))
        {
            Check(!store.IsExternalUpdaterConfigured && store.Snapshot() is null && !await store.StartIfDueAsync(),
                "Store created or started an external updater.");
            await store.StopAsync();
            Check(!await store.StartIfDueAsync() && factories == 0 && clockCalls == 0,
                "Store invoked an updater dependency.");
        }

        foreach (WindowsUpdateChannel channel in new[] { (WindowsUpdateChannel)0, (WindowsUpdateChannel)42 })
        {
            try
            {
                _ = WindowsUpdateService.Create(channel, Version, new Clock().Tick,
                    new Clock().Utc, 1, TimeSpan.FromSeconds(5),
                    () => { factories++; throw new InvalidOperationException(); });
                throw new InvalidOperationException("An unsupported channel created a service.");
            }
            catch (ArgumentOutOfRangeException) { Check(factories == 0, "An unknown channel created a handler."); }
        }

        try
        {
            _ = WindowsUpdateService.Create(WindowsUpdateChannel.Standalone, Version, new Clock().Tick,
                new Clock().Utc, 1, TimeSpan.FromSeconds(5), () => null!);
            throw new ArgumentException("A null test handler created a service.");
        }
        catch (InvalidOperationException) { checks++; }

        handler = new FakeHandler((_, _) => throw new InvalidOperationException("Unexpected request."));
        try
        {
            _ = Make(handler, new Clock(), "invalid");
            throw new InvalidOperationException("An invalid version created a service.");
        }
        catch (ArgumentException) { Check(handler.Requests == 0 && handler.Disposals == 1, "Failed construction leaked its handler."); }

        Console.WriteLine($"Update service: {checks} synthetic assertions passed.");
    }
}
