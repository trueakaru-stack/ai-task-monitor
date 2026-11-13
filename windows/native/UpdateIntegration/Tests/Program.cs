using System.Diagnostics;
using AITaskMonitor.NativeUpdateController;
using AITaskMonitor.NativeUpdateIntegration;

const string Version = "0.2.0";
const string Download = "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0/AI-Task-Monitor-Setup.exe";
const string Valid = """
    [{"tag_name":"v0.3.0","draft":false,"assets":[{"name":"AI-Task-Monitor-Setup.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0/AI-Task-Monitor-Setup.exe"}]}]
    """;
const string Unsafe = """
    [{"tag_name":"v0.3.0","draft":false,"assets":[{"name":"AI-Task-Monitor-Setup.exe","browser_download_url":"https://github.com.attacker.example/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0/AI-Task-Monitor-Setup.exe"}]}]
    """;

int checks = 0;
void Check(bool condition, string message)
{
    checks++;
    if (!condition) throw new InvalidOperationException(message);
}

async Task Until(Func<bool> condition, string description)
{
    var watch = Stopwatch.StartNew();
    while (!condition())
    {
        if (watch.Elapsed > TimeSpan.FromSeconds(5)) throw new TimeoutException(description);
        await Task.Delay(5);
    }
}

DateTimeOffset Now() => new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
long clock = 0;
long Tick() => Interlocked.Read(ref clock);
UpdateCoordinator Make(Func<Action<ProbeHeaders>, CancellationToken, Task<ProbeResult>> fetch) =>
    WindowsUpdateIntegration.Create(Version, fetch, Tick, Now, 1, TimeSpan.FromSeconds(3));

Selection selected = WindowsUpdateIntegration.Select(Valid, Version);
Check(selected is { Valid: true, Update.Version: "0.3.0" } && selected.Update.Url == Download,
    "The trusted Windows release was not selected.");
Check(WindowsUpdateIntegration.Select("[]", Version) is { Valid: true, Update: null },
    "A valid response without an update was not distinguished.");
Check(WindowsUpdateIntegration.Select("{invalid", Version) is { Valid: false, Update: null },
    "Invalid metadata was accepted.");
Check(WindowsUpdateIntegration.Select(Unsafe, Version) is { Valid: true, Update: null },
    "An untrusted download URL produced an update.");
foreach (string url in new[]
{
    Download.Replace("https://", "http://", StringComparison.Ordinal),
    Download + "?download=1",
    Download.Replace("/v0.3.0/", "/v0.4.0/", StringComparison.Ordinal),
    Download.Replace(".exe", ".zip", StringComparison.Ordinal),
    Download.Replace("github.com/", "github.com@attacker.example/", StringComparison.Ordinal),
})
{
    string metadata = Valid.Replace(Download, url, StringComparison.Ordinal);
    Check(WindowsUpdateIntegration.Select(metadata, Version) is { Valid: true, Update: null },
        "A malformed or untrusted release URL produced an update.");
}
Check(WindowsUpdateIntegration.Select(Valid, "0.3.0") is { Valid: true, Update: null },
    "A current release was incorrectly presented as newer.");
Check(WindowsUpdateIntegration.Select(Valid, "invalid") is { Valid: false, Update: null },
    "An invalid installed version was accepted by the selector.");
try
{
    _ = WindowsUpdateIntegration.Create("invalid", (_, _) => Task.FromResult(new ProbeResult(true, Valid)),
        Tick, Now, 1, TimeSpan.FromSeconds(3));
    throw new InvalidOperationException("An invalid installed version constructed a coordinator.");
}
catch (ArgumentException) { checks++; }

async Task<CoordinatorSnapshot> RunOnce(ProbeResult result)
{
    var controller = Make((_, _) => Task.FromResult(result));
    Check(await controller.StartIfDueAsync(), "The synthetic update check did not start.");
    await Until(() => !controller.Snapshot().Busy, "The synthetic update check did not finish.");
    CoordinatorSnapshot snapshot = controller.Snapshot();
    controller.Stop();
    return snapshot;
}

CoordinatorSnapshot update = await RunOnce(new ProbeResult(true, Valid));
Check(update is { HasSchedule: true, Failures: 0, Available.Version: "0.3.0" }
    && update.Available.Url == Download, "A validated release was not published by the coordinator.");
CoordinatorSnapshot empty = await RunOnce(new ProbeResult(true, "[]"));
Check(empty is { HasSchedule: true, Failures: 0, Available: null }, "No-update response was treated as a failure.");
CoordinatorSnapshot malformed = await RunOnce(new ProbeResult(true, "{invalid"));
Check(malformed is { HasSchedule: true, Failures: 1, Available: null }, "Invalid metadata was treated as successful.");
CoordinatorSnapshot unsafeUrl = await RunOnce(new ProbeResult(true, Unsafe));
Check(unsafeUrl is { HasSchedule: true, Failures: 0, Available: null }, "An unsafe URL was published.");
CoordinatorSnapshot transportFailure = await RunOnce(new ProbeResult(false, Valid));
Check(transportFailure is { HasSchedule: true, Failures: 1, Available: null }, "A failed fetch was accepted.");

Interlocked.Exchange(ref clock, 0);
int retainedAttempts = 0;
var retained = Make((_, _) => Task.FromResult(Interlocked.Increment(ref retainedAttempts) switch
{
    1 => new ProbeResult(true, Valid),
    2 => new ProbeResult(false, null),
    3 => new ProbeResult(true, "{invalid"),
    4 => new ProbeResult(true, "[]"),
    _ => throw new InvalidOperationException("Unexpected retained-update request.")
}));
Check(await retained.StartIfDueAsync(), "The retained-update fixture did not start.");
await Until(() => !retained.Snapshot().Busy, "The initial retained-update check did not finish.");
Check(retained.Snapshot() is { HasSchedule: true, Failures: 0, Available.Version: "0.3.0" },
    "The initial update was not retained.");
Interlocked.Exchange(ref clock, 86399);
Check(!await retained.StartIfDueAsync(), "The successful check was repeated before its daily schedule.");
Interlocked.Exchange(ref clock, 86400);
Check(await retained.StartIfDueAsync(), "The scheduled transport-failure check did not start.");
await Until(() => !retained.Snapshot().Busy, "The retained transport-failure check did not finish.");
Check(retained.Snapshot() is { HasSchedule: true, Failures: 1, Available.Version: "0.3.0" },
    "A transport failure erased the existing update or failure schedule.");
Interlocked.Exchange(ref clock, 89999);
Check(!await retained.StartIfDueAsync(), "The first failure retry started too early.");
Interlocked.Exchange(ref clock, 90000);
Check(await retained.StartIfDueAsync(), "The invalid-response retry did not start.");
await Until(() => !retained.Snapshot().Busy, "The invalid-response retry did not finish.");
Check(retained.Snapshot() is { HasSchedule: true, Failures: 2, Available.Version: "0.3.0" },
    "Invalid metadata erased the existing update or failure streak.");
Interlocked.Exchange(ref clock, 97199);
Check(!await retained.StartIfDueAsync(), "The second failure retry started too early.");
Interlocked.Exchange(ref clock, 97200);
Check(await retained.StartIfDueAsync(), "The empty-response retry did not start.");
await Until(() => !retained.Snapshot().Busy, "The empty-response retry did not finish.");
CoordinatorSnapshot retainedSnapshot = retained.Snapshot();
Check(retainedSnapshot is { HasSchedule: true, Failures: 0, Available.Version: "0.3.0" }
    && retainedSnapshot.Available.Url == Download, "An empty success erased the existing update or failed to reset retries.");
Interlocked.Exchange(ref clock, 183599);
Check(!await retained.StartIfDueAsync(), "The empty success did not restore the daily schedule.");
Check(retainedAttempts == 4, "The retained-update fixture issued an unexpected request.");
retained.Stop();

Interlocked.Exchange(ref clock, 0);
int attempts = 0;
var retry = Make((report, _) =>
{
    if (Interlocked.Increment(ref attempts) == 1)
    {
        report(new ProbeHeaders(RetryAfter: ["7200"]));
        return Task.FromResult(new ProbeResult(false, null));
    }
    return Task.FromResult(new ProbeResult(true, Valid));
});
Check(await retry.StartIfDueAsync(), "The synthetic retry check did not start.");
await Until(() => !retry.Snapshot().Busy, "The first retry attempt did not finish.");
Check(retry.Snapshot().Failures == 1, "The initial failure was not recorded.");
Interlocked.Exchange(ref clock, 7199);
Check(!await retry.StartIfDueAsync(), "The server retry delay was shortened.");
Interlocked.Exchange(ref clock, 7200);
Check(await retry.StartIfDueAsync(), "The retry did not start when due.");
await Until(() => !retry.Snapshot().Busy, "The retry did not finish.");
Check(retry.Snapshot() is { Failures: 0, Available.Version: "0.3.0" }, "The successful retry was not published.");
retry.Stop();

var started = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
var reply = new TaskCompletionSource<ProbeResult>(TaskCreationOptions.RunContinuationsAsynchronously);
var stopped = Make((_, _) => { started.TrySetResult(true); return reply.Task; });
Check(await stopped.StartIfDueAsync(), "The delayed check did not start.");
await started.Task.WaitAsync(TimeSpan.FromSeconds(3));
stopped.Stop();
reply.SetResult(new ProbeResult(true, Valid));
await Until(() => !stopped.Snapshot().Busy, "The stopped check did not finish.");
Check(stopped.Snapshot() is { Stopped: true, Available: null }, "A stopped check published a late result.");

await ServiceTests.RunAsync();
Console.WriteLine($"Update integration: {checks} synthetic assertions passed.");
