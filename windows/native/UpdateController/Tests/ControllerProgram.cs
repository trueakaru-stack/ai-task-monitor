using System.Diagnostics;
using AITaskMonitor.NativeUpdateController;

ThreadPool.SetMinThreads(16, 16);
int checks = 0;
void Check(bool value, string message) { checks++; if (!value) throw new InvalidOperationException(message); }
async Task Until(Func<bool> predicate, string message)
{
    var sw = Stopwatch.StartNew();
    while (!predicate()) { if (sw.Elapsed > TimeSpan.FromSeconds(4)) throw new TimeoutException(message); await Task.Delay(5); }
}
long clock = 0;
long Tick() => Interlocked.Read(ref clock);
DateTimeOffset Now() => new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
Selection Select(string json) => json switch
{
    "valid" => new(true, new("1.2.3", "https://example.invalid/synthetic")),
    "empty" => new(true, null),
    _ => new(false, null)
};

int calls = 0;
using var firstRelease = new ManualResetEventSlim(false);
using var firstStarted = new ManualResetEventSlim(false);
Task<ProbeResult> First(Action<ProbeHeaders> headers, CancellationToken token)
{
    int call = Interlocked.Increment(ref calls);
    firstStarted.Set();
    firstRelease.Wait();
    return Task.FromResult(call == 2 ? new ProbeResult(false, null) : new ProbeResult(true, call == 1 ? "valid" : "empty"));
}
var normal = new UpdateCoordinator(First, Select, Tick, Now, 10, TimeSpan.FromSeconds(3));
var startWatch = Stopwatch.StartNew();
Check(await normal.StartIfDueAsync(), "First check did not start.");
Check(startWatch.Elapsed < TimeSpan.FromMilliseconds(500), "Start waited for the fetch.");
Check(firstStarted.Wait(2000), "Synthetic fetch did not start.");
bool[] concurrent = await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => normal.StartIfDueAsync()));
Check(concurrent.All(value => !value), "Concurrent check was started.");
firstRelease.Set();
await Until(() => !normal.Snapshot().Busy, "First check did not finish.");
Check(normal.Snapshot() is { HasSchedule: true, Failures: 0, Available.Version: "1.2.3" }, "Valid result was not saved.");
Check(!await normal.StartIfDueAsync(), "A successful check did not wait 24 hours.");
Check(calls == 1, "Unexpected extra fetch.");
Interlocked.Exchange(ref clock, 864000);
Check(await normal.StartIfDueAsync(), "Failure after the success interval did not start.");
await Until(() => !normal.Snapshot().Busy, "Failure after success did not finish.");
Check(normal.Snapshot() is { Failures: 1, Available.Version: "1.2.3" }, "Failure erased the existing update.");
Interlocked.Exchange(ref clock, 900000);
Check(await normal.StartIfDueAsync(), "Retry after failure did not start.");
await Until(() => !normal.Snapshot().Busy, "Empty success did not finish.");
Check(normal.Snapshot() is { Failures: 0, Available.Version: "1.2.3" }, "Empty success erased the existing update.");
normal.Stop();

Interlocked.Exchange(ref clock, 0);
int retryCalls = 0;
Task<ProbeResult> Retry(Action<ProbeHeaders> headers, CancellationToken token)
{
    int call = Interlocked.Increment(ref retryCalls);
    if (call == 1) headers(new ProbeHeaders(new string?[] { "7200" }));
    return Task.FromResult(call == 1 ? new ProbeResult(false, null) : new ProbeResult(true, "empty"));
}
var retry = new UpdateCoordinator(Retry, Select, Tick, Now, 10, TimeSpan.FromSeconds(3));
Check(await retry.StartIfDueAsync(), "Failure fixture did not start.");
await Until(() => !retry.Snapshot().Busy, "Failure fixture did not finish.");
Check(retry.Snapshot().Failures == 1, "Failure was not scheduled.");
Interlocked.Exchange(ref clock, 71999);
Check(!await retry.StartIfDueAsync(), "Server delay was shortened.");
Interlocked.Exchange(ref clock, 72000);
Check(await retry.StartIfDueAsync(), "Retry at deadline was not allowed.");
await Until(() => !retry.Snapshot().Busy, "Retry did not finish.");
Check(retry.Snapshot() is { Failures: 0, HasSchedule: true }, "Success did not reset failures.");
retry.Stop();

Interlocked.Exchange(ref clock, 0);
int resetCalls = 0;
var pendingReset = new TaskCompletionSource<ProbeResult>(TaskCreationOptions.RunContinuationsAsynchronously);
async Task<ProbeResult> ResetFetch(Action<ProbeHeaders> headers, CancellationToken token)
{
    if (Interlocked.Increment(ref resetCalls) == 1) return new ProbeResult(true, "empty");
    ProbeResult result = await pendingReset.Task;
    headers(new ProbeHeaders(new string?[] { "172800" }));
    return result;
}
var counterReset = new UpdateCoordinator(ResetFetch, Select, Tick, Now, 10, TimeSpan.FromSeconds(3));
Check(await counterReset.StartIfDueAsync(), "Counter-reset fixture did not start.");
await Until(() => !counterReset.Snapshot().Busy, "First counter-reset result did not finish.");
Interlocked.Exchange(ref clock, 864000);
Check(await counterReset.StartIfDueAsync(), "The due check before counter reset did not start.");
await Until(() => Volatile.Read(ref resetCalls) >= 2, "The second counter-reset fetch did not start.");
Interlocked.Exchange(ref clock, 0);
pendingReset.SetResult(new ProbeResult(false, null));
await Until(() => !counterReset.Snapshot().Busy, "Counter-reset failure did not finish.");
Check(counterReset.Snapshot().Failures == 1, "Counter reset discarded the failure.");
Interlocked.Exchange(ref clock, 864000);
Check(!await counterReset.StartIfDueAsync(), "Counter reset shortened the new server delay.");
Interlocked.Exchange(ref clock, 1728000);
Check(await counterReset.StartIfDueAsync(), "The new server delay did not expire.");
await Until(() => !counterReset.Snapshot().Busy, "Final counter-reset check did not finish.");
counterReset.Stop();

Interlocked.Exchange(ref clock, 0);
int streakCalls = 0;
var pendingStreak = new TaskCompletionSource<ProbeResult>(TaskCreationOptions.RunContinuationsAsynchronously);
Task<ProbeResult> StreakFetch(Action<ProbeHeaders> headers, CancellationToken token) => Interlocked.Increment(ref streakCalls) == 7
    ? pendingStreak.Task : Task.FromResult(new ProbeResult(false, null));
var streak = new UpdateCoordinator(StreakFetch, Select, Tick, Now, 10, TimeSpan.FromSeconds(3));
Check(await streak.StartIfDueAsync(), "Failure-streak fixture did not start.");
await Until(() => !streak.Snapshot().Busy, "First streak failure did not finish.");
long streakClock = 0;
foreach (int hours in new[] { 1, 2, 4, 8, 16 })
{
    streakClock += hours * 36000L;
    Interlocked.Exchange(ref clock, streakClock);
    Check(await streak.StartIfDueAsync(), "A streak retry was not due.");
    await Until(() => !streak.Snapshot().Busy, "A streak failure did not finish.");
}
Check(streak.Snapshot().Failures == 6, "Failure streak did not reach the cap.");
streakClock += 24 * 36000L;
Interlocked.Exchange(ref clock, streakClock);
Check(await streak.StartIfDueAsync(), "Capped streak retry did not start.");
await Until(() => Volatile.Read(ref streakCalls) >= 7, "Capped retry fetch did not start.");
Interlocked.Exchange(ref clock, 0);
pendingStreak.SetResult(new ProbeResult(false, null));
await Until(() => !streak.Snapshot().Busy, "Counter-reset streak failure did not finish.");
Check(streak.Snapshot().Failures == 6, "Counter reset lost the previous failure streak.");
Interlocked.Exchange(ref clock, 36000);
Check(!await streak.StartIfDueAsync(), "Counter reset shortened a capped backoff.");
Interlocked.Exchange(ref clock, 864000);
Check(await streak.StartIfDueAsync(), "The capped backoff did not expire.");
await Until(() => !streak.Snapshot().Busy, "Post-reset streak retry did not finish.");
streak.Stop();

Interlocked.Exchange(ref clock, 0);
int streamingCalls = 0;
var stalledBody = new TaskCompletionSource<ProbeResult>(TaskCreationOptions.RunContinuationsAsynchronously);
using var headersSeen = new ManualResetEventSlim(false);
Action<ProbeHeaders>? delayedHeaders = null;
Task<ProbeResult> StreamingFetch(Action<ProbeHeaders> headers, CancellationToken token)
{
    if (Interlocked.Increment(ref streamingCalls) != 1) return Task.FromResult(new ProbeResult(true, "empty"));
    delayedHeaders = headers;
    headers(new ProbeHeaders(new string?[] { "172800" }));
    headersSeen.Set();
    return stalledBody.Task;
}
var streaming = new UpdateCoordinator(StreamingFetch, Select, Tick, Now, 10, TimeSpan.FromMilliseconds(100));
Check(await streaming.StartIfDueAsync() && headersSeen.Wait(2000), "Streaming-header fixture did not start.");
await Until(() => streaming.Snapshot().HasSchedule, "Stalled body did not time out.");
Check(streaming.Snapshot() is { Busy: true, Failures: 1, Available: null }, "Stalled body published a false result.");
for (int i = 0; i < 1000; i++) delayedHeaders!(new ProbeHeaders(new string?[] { "864000" }));
stalledBody.SetResult(new ProbeResult(true, "valid"));
await Until(() => !streaming.Snapshot().Busy, "Stalled-body slot did not release.");
Check(!streaming.Snapshot().Faulted, "Late header callbacks changed sealed state.");
Interlocked.Exchange(ref clock, 864000);
Check(!await streaming.StartIfDueAsync(), "A timeout lost already received response headers.");
Interlocked.Exchange(ref clock, 1728000);
Check(await streaming.StartIfDueAsync(), "The streaming server delay did not expire.");
await Until(() => !streaming.Snapshot().Busy, "Final streaming check did not finish.");
streaming.Stop();

Interlocked.Exchange(ref clock, 0);
var oneHeader = new ProbeHeaders(new string?[] { "1" });
var repeatedHeaders = new UpdateCoordinator((headers, _) =>
{
    for (int i = 0; i < 200000; i++) headers(oneHeader);
    return Task.FromResult(new ProbeResult(true, "valid"));
}, Select, Tick, Now, 10, TimeSpan.FromSeconds(3));
Check(await repeatedHeaders.StartIfDueAsync(), "Repeated-header fixture did not start.");
await Until(() => !repeatedHeaders.Snapshot().Busy, "Repeated-header fixture did not finish.");
Check(repeatedHeaders.Snapshot() is { Faulted: true, HasSchedule: false, Available: null }, "Repeated headers did not stop automatic checks.");
repeatedHeaders.Stop();

var excessiveHeaders = new UpdateCoordinator((headers, _) =>
{
    headers(new ProbeHeaders(Enumerable.Repeat<string?>("1", 257).ToArray()));
    return Task.FromResult(new ProbeResult(true, "valid"));
}, Select, Tick, Now, 10, TimeSpan.FromSeconds(3));
Check(await excessiveHeaders.StartIfDueAsync(), "Oversized-header fixture did not start.");
await Until(() => !excessiveHeaders.Snapshot().Busy, "Oversized-header fixture did not finish.");
Check(excessiveHeaders.Snapshot() is { Faulted: true, HasSchedule: false }, "Excessive header count did not stop checks.");
excessiveHeaders.Stop();

Interlocked.Exchange(ref clock, 0);
DateTimeOffset PausedWallClock()
{
    Interlocked.Exchange(ref clock, 36000);
    return Now();
}
var clockOrder = new UpdateCoordinator((headers, _) =>
{
    headers(new ProbeHeaders(new string?[] { "Sat, 03 Jan 2026 00:00:00 GMT" }));
    return Task.FromResult(new ProbeResult(false, null));
}, Select, Tick, PausedWallClock, 10, TimeSpan.FromSeconds(3));
Check(await clockOrder.StartIfDueAsync(), "Clock-order fixture did not start.");
await Until(() => !clockOrder.Snapshot().Busy, "Clock-order fixture did not finish.");
Interlocked.Exchange(ref clock, 1728000);
Check(!await clockOrder.StartIfDueAsync(), "Reading the clocks shortened an absolute retry hint.");
Interlocked.Exchange(ref clock, 1764000);
Check(await clockOrder.StartIfDueAsync(), "Absolute retry hint did not expire.");
await Until(() => !clockOrder.Snapshot().Busy, "Clock-order retry did not finish.");
clockOrder.Stop();

Interlocked.Exchange(ref clock, 0);
using var parseStarted = new ManualResetEventSlim(false);
using var unblockParse = new ManualResetEventSlim(false);
Selection SlowParse(string json) { parseStarted.Set(); unblockParse.Wait(); return Select(json); }
var slow = new UpdateCoordinator((headers, _) => { headers(new ProbeHeaders(new string?[] { "86400" })); return Task.FromResult(new ProbeResult(true, "valid")); },
    SlowParse, Tick, Now, 10, TimeSpan.FromMilliseconds(100));
Check(await slow.StartIfDueAsync(), "Slow parser fixture did not start.");
Check(parseStarted.Wait(2000), "Slow parser did not start.");
await Until(() => slow.Snapshot().HasSchedule, "Timeout was not scheduled.");
Check(slow.Snapshot() is { Busy: true, Failures: 1, Available: null }, "A timed-out parser published a result or freed its slot.");
Interlocked.Exchange(ref clock, 828000);
Check(!await slow.StartIfDueAsync(), "A second check started while the old parser still ran.");
unblockParse.Set();
await Until(() => !slow.Snapshot().Busy, "Parser slot was not released.");
Check(slow.Snapshot().Available is null && !await slow.StartIfDueAsync(), "Late result or early retry ignored the server hint.");
slow.Stop();

Interlocked.Exchange(ref clock, 0);
using var timeoutStarted = new ManualResetEventSlim(false);
using var timeoutFetchRelease = new ManualResetEventSlim(false);
using var timeoutCallbackStarted = new ManualResetEventSlim(false);
using var timeoutCallbackRelease = new ManualResetEventSlim(false);
Task<ProbeResult> BlockingTimeout(Action<ProbeHeaders> headers, CancellationToken token)
{
    token.Register(() => { timeoutCallbackStarted.Set(); timeoutCallbackRelease.Wait(); });
    timeoutStarted.Set();
    timeoutFetchRelease.Wait();
    return Task.FromResult(new ProbeResult(true, "valid"));
}
var timeoutCase = new UpdateCoordinator(BlockingTimeout, Select, Tick, Now, 10, TimeSpan.FromMilliseconds(100));
Check(await timeoutCase.StartIfDueAsync() && timeoutStarted.Wait(2000), "Timeout callback fixture did not start.");
Check(timeoutCallbackStarted.Wait(2000), "Timeout did not request cancellation.");
await Until(() => timeoutCase.Snapshot().HasSchedule, "Blocked cancellation callback delayed timeout scheduling.");
Check(timeoutCase.Snapshot() is { Busy: true, Failures: 1, Available: null }, "Timeout callback produced a false result.");
timeoutCallbackRelease.Set();
timeoutFetchRelease.Set();
await Until(() => !timeoutCase.Snapshot().Busy, "Timeout callback fixture did not release its slot.");
timeoutCase.Stop();

Interlocked.Exchange(ref clock, 0);
using var utcBlocked = new ManualResetEventSlim(false);
using var utcRelease = new ManualResetEventSlim(false);
using var deadlineCancellation = new ManualResetEventSlim(false);
var delayedFetch = new TaskCompletionSource<ProbeResult>(TaskCreationOptions.RunContinuationsAsynchronously);
DateTimeOffset BlockingUtc() { utcBlocked.Set(); utcRelease.Wait(); return Now(); }
Task<ProbeResult> FetchDuringUtc(Action<ProbeHeaders> headers, CancellationToken token)
{
    token.Register(() => deadlineCancellation.Set());
    return delayedFetch.Task;
}
var utcCase = new UpdateCoordinator(FetchDuringUtc, Select, Tick, BlockingUtc, 10, TimeSpan.FromMilliseconds(100));
Check(await utcCase.StartIfDueAsync() && utcBlocked.Wait(2000), "Blocked UTC fixture did not reach its deadline.");
Check(deadlineCancellation.Wait(2000), "Deadline cancellation waited for UTC.");
var utcWatch = Stopwatch.StartNew();
utcCase.Stop();
Check(utcWatch.Elapsed < TimeSpan.FromMilliseconds(500), "Stop waited for blocked UTC.");
utcRelease.Set();
delayedFetch.SetResult(new ProbeResult(true, "valid"));
await Until(() => !utcCase.Snapshot().Busy, "Blocked UTC fixture did not release.");
Check(utcCase.Snapshot().Available is null, "Stopped blocked UTC published a result.");

Interlocked.Exchange(ref clock, 0);
var brokenSelector = new UpdateCoordinator((headers, _) => { headers(new ProbeHeaders(new string?[] { "86400" })); return Task.FromResult(new ProbeResult(true, "valid")); },
    _ => throw new InvalidOperationException("synthetic"), Tick, Now, 10, TimeSpan.FromSeconds(3));
Check(await brokenSelector.StartIfDueAsync(), "Invalid selector fixture did not start.");
await Until(() => !brokenSelector.Snapshot().Busy, "Invalid selector fixture did not finish.");
Check(brokenSelector.Snapshot() is { Failures: 1, Available: null }, "Invalid selection was treated as success.");
Interlocked.Exchange(ref clock, 828000);
Check(!await brokenSelector.StartIfDueAsync(), "A selector error lost the server delay.");
brokenSelector.Stop();

Interlocked.Exchange(ref clock, 0);
using var fetchStarted = new ManualResetEventSlim(false);
using var unblockFetch = new ManualResetEventSlim(false);
using var cancelStarted = new ManualResetEventSlim(false);
using var unblockCancel = new ManualResetEventSlim(false);
Task<ProbeResult> Uncooperative(Action<ProbeHeaders> headers, CancellationToken token)
{
    token.Register(() => { cancelStarted.Set(); unblockCancel.Wait(); });
    fetchStarted.Set();
    unblockFetch.Wait();
    return Task.FromResult(new ProbeResult(true, "valid"));
}
var stopping = new UpdateCoordinator(Uncooperative, Select, Tick, Now, 10, TimeSpan.FromSeconds(3));
Check(await stopping.StartIfDueAsync() && fetchStarted.Wait(2000), "Stop fixture did not start.");
var watch = Stopwatch.StartNew();
stopping.Stop();
Check(watch.Elapsed < TimeSpan.FromMilliseconds(500), "Stop waited for the cancellation callback.");
Check(cancelStarted.Wait(2000), "Cancellation callback did not start.");
Check(stopping.Snapshot().Stopped && !await stopping.StartIfDueAsync(), "Stopped controller restarted.");
unblockCancel.Set();
unblockFetch.Set();
await Until(() => !stopping.Snapshot().Busy, "Stopped fetch slot did not release.");
Check(stopping.Snapshot().Available is null && !stopping.Snapshot().HasSchedule, "A late result was published after stop.");

var badClock = new UpdateCoordinator((_, _) => Task.FromResult(new ProbeResult(true, "valid")), Select,
    () => throw new InvalidOperationException("synthetic"), Now, 10, TimeSpan.FromSeconds(1));
// A new schedule is due without reading the clock only if the clock succeeds.
Check(!await badClock.StartIfDueAsync() && badClock.Snapshot().Faulted, "Clock failure was not isolated.");
badClock.Stop();

using var startClockEntered = new ManualResetEventSlim(false);
using var startClockRelease = new ManualResetEventSlim(false);
int blockedFetches = 0;
long BlockStartClock() { startClockEntered.Set(); startClockRelease.Wait(); return 0; }
var blockedStart = new UpdateCoordinator((_, _) => { Interlocked.Increment(ref blockedFetches); return Task.FromResult(new ProbeResult(true, "valid")); },
    Select, BlockStartClock, Now, 10, TimeSpan.FromSeconds(3));
Task<bool> startAttempt = blockedStart.StartIfDueAsync();
Check(startClockEntered.Wait(2000), "Blocking start clock did not start.");
bool[] blockedClockFollowers = await Task.WhenAll(Enumerable.Range(0, 100).Select(_ => blockedStart.StartIfDueAsync()));
Check(blockedClockFollowers.All(value => !value) && blockedStart.Snapshot().Busy, "A blocked clock admitted duplicate starts.");
watch.Restart();
blockedStart.Stop();
Check(watch.Elapsed < TimeSpan.FromMilliseconds(500), "Stop waited for the start clock.");
startClockRelease.Set();
Check(!await startAttempt && blockedFetches == 0, "A blocked start clock launched fetch after Stop.");

using var finishClockEntered = new ManualResetEventSlim(false);
using var finishClockRelease = new ManualResetEventSlim(false);
int clockCalls = 0;
long BlockFinishClock()
{
    if (Interlocked.Increment(ref clockCalls) > 1) { finishClockEntered.Set(); finishClockRelease.Wait(); }
    return 0;
}
var blockedFinish = new UpdateCoordinator((_, _) => Task.FromResult(new ProbeResult(true, "valid")),
    Select, BlockFinishClock, Now, 10, TimeSpan.FromSeconds(3));
Check(await blockedFinish.StartIfDueAsync() && finishClockEntered.Wait(2000), "Blocking finish clock did not start.");
watch.Restart();
blockedFinish.Stop();
Check(watch.Elapsed < TimeSpan.FromMilliseconds(500), "Stop waited for the finish clock.");
finishClockRelease.Set();
await Until(() => !blockedFinish.Snapshot().Busy, "Blocked finish clock did not release.");
Check(blockedFinish.Snapshot().Available is null && !blockedFinish.Snapshot().HasSchedule, "Stopped clock published an update.");
Interlocked.Exchange(ref clock, 0);
int paddedCalls = 0;
Task<ProbeResult> PaddedFetch(Action<ProbeHeaders> headers, CancellationToken token)
{
    if (Interlocked.Increment(ref paddedCalls) == 1)
        headers(new ProbeHeaders(new string?[] { "3600", new string('0', 251) + "172800" }));
    return Task.FromResult(new ProbeResult(false, null));
}
var paddedController = new UpdateCoordinator(PaddedFetch, Select, Tick, Now, 10, TimeSpan.FromSeconds(3));
Check(await paddedController.StartIfDueAsync(), "The padded-header fixture did not start.");
await Until(() => !paddedController.Snapshot().Busy, "The padded-header fixture did not finish.");
Interlocked.Exchange(ref clock, 36000);
Check(!await paddedController.StartIfDueAsync(), "A padded long delay was reduced to one hour.");
Interlocked.Exchange(ref clock, 1727999);
Check(!await paddedController.StartIfDueAsync(), "A padded long delay ended early.");
Interlocked.Exchange(ref clock, 1728000);
Check(await paddedController.StartIfDueAsync(), "A padded long delay never became due.");
await Until(() => !paddedController.Snapshot().Busy, "The padded-header retry did not finish.");
paddedController.Stop();

Interlocked.Exchange(ref clock, 0);
Task<ProbeResult> HugeFetch(Action<ProbeHeaders> headers, CancellationToken token)
{
    headers(new ProbeHeaders(new string?[] { "3600", "18446744073709551616" }));
    return Task.FromResult(new ProbeResult(false, null));
}
var hugeController = new UpdateCoordinator(HugeFetch, Select, Tick, Now, 1, TimeSpan.FromSeconds(3));
Check(await hugeController.StartIfDueAsync(), "The unrepresentable-header fixture did not start.");
await Until(() => !hugeController.Snapshot().Busy, "The unrepresentable-header fixture did not finish.");
Interlocked.Exchange(ref clock, long.MaxValue);
Check(!await hugeController.StartIfDueAsync(), "An unrepresentable delay allowed a retry.");
hugeController.Stop();
Console.WriteLine($"Synthetic update-controller checks passed: {checks} assertions.");
