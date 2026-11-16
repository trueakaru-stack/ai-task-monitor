using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using AITaskMonitor.ExternalProviders;

if (!OperatingSystem.IsWindows() ||
    !string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase) ||
    !string.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase) ||
    !string.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"), "github-hosted", StringComparison.OrdinalIgnoreCase) ||
    Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") != "0")
    throw new InvalidOperationException("Disposable hosted Windows runner required.");

int checks = 0;
void Check(bool condition, string message) { checks++; if (!condition) throw new InvalidOperationException(message); }
Event Frame(string provider, string session, string kind) =>
    EventParser.Parse(JsonSerializer.Serialize(new { version = 1, provider, session, kind }))
    ?? throw new InvalidOperationException("Invalid synthetic frame.");
Event Plan(string provider, string session) =>
    EventParser.Parse(JsonSerializer.Serialize(new { version = 1, provider, session, kind = "plan", steps = new[] { new { title = "One", status = "pending" } } }))
    ?? throw new InvalidOperationException("Invalid synthetic plan.");
Event ToolFinished(string provider, string session) =>
    EventParser.Parse(JsonSerializer.Serialize(new { version = 1, provider, session, kind = "tool_finished", call = "call" }))
    ?? throw new InvalidOperationException("Invalid synthetic tool event.");
long Nano()
{
    long ticks = Stopwatch.GetTimestamp(), frequency = Stopwatch.Frequency;
    return ticks / frequency * 1_000_000_000L + (long)((ticks % frequency) * (1_000_000_000.0 / frequency));
}
Event Hermes(string session, string kind, string turn = "turn")
{
    long epoch = Nano();
    return EventParser.Parse(JsonSerializer.Serialize(new { version = 1, provider = "hermes", session, kind, turn, tick = epoch, epoch }))
        ?? throw new InvalidOperationException("Invalid Hermes frame.");
}
var now = DateTimeOffset.UtcNow;
string a = new('a', 32), b = new('b', 32), c = new('c', 32);

var store = new StateStore();
store.RetainProviders(["deepseek", "opencode"]);
store.RetainSessionScopes("deepseek", [a, b]);
Check(store.Apply(Frame("deepseek", a + "_first", "active"), now), "A frame was rejected.");
Check(store.Apply(Frame("opencode", "open", "active"), now), "OpenCode was rejected.");
for (int i = 0; i < 254; i++)
    Check(store.Apply(Frame("deepseek", b + "_" + i, "active"), now), "A bounded task was rejected.");
Check(store.Snapshot(now).Length == 256 && store.Snapshot(now).Count(x => x.Status == "active") == 256,
    "Normal V1 startup changed.");
Check(!store.Apply(Frame("deepseek", a + "_overflow", "active"), now), "Overflow was silently admitted.");
Check(store.Snapshot(now).Length == 256 && store.CapacityLimitedScopes("deepseek").SequenceEqual([a]) &&
    store.CapacityLimitedProviders.SequenceEqual(["deepseek"]) && store.LossAffectedProviders.SequenceEqual(["deepseek"]),
    "A scoped loss was not recorded.");
Check(store.Snapshot(now).Single(x => x.Session == a + "_first").Status == "unknown" &&
    store.Snapshot(now).Count(x => x.Session.StartsWith(b + "_", StringComparison.Ordinal) && x.Status == "active") == 254 &&
    store.Snapshot(now).Single(x => x.Provider == "opencode").Status == "active",
    "A scoped loss degraded an unrelated profile or provider.");
Check(store.Apply(Frame("deepseek", a + "_first", "completed"), now) &&
    store.Apply(Frame("deepseek", a + "_first", "active"), now) &&
    store.Snapshot(now).Single(x => x.Session == a + "_first").Status == "unknown", "A late event changed an unconfirmed card.");
Check(store.Snapshot(now).Count(x => x.Session.StartsWith(b + "_", StringComparison.Ordinal)) == 254 &&
    store.Snapshot(now).Any(x => x.Provider == "opencode"),
    "Capacity displaced a neighboring visible card.");
store.ConfirmDeepSeekDisconnectedScopes([a]);
Check(store.CapacityLimitedProviders.Length == 0 && store.LossAffectedProviders.Length == 0 && store.Snapshot(now).Length == 255 &&
    store.Snapshot(now).All(x => x.Session != a + "_first"), "Confirmed scope removal changed the wrong area.");
Check(store.Apply(Frame("deepseek", a + "_late", "active"), now) &&
    store.Snapshot(now).Single(x => x.Session == a + "_late").Status == "unknown", "Reconnection invented a verified restart.");

var reconnect = new StateStore();
reconnect.RetainProviders(["opencode"]);
Check(reconnect.Apply(Frame("opencode", "first", "active"), now) &&
    reconnect.Snapshot(now).Single().Status == "active", "Normal OpenCode startup changed.");
reconnect.RetainProviders([]);
reconnect.RetainProviders(["opencode"]);
Check(reconnect.Apply(Frame("opencode", "delayed", "active"), now) &&
    reconnect.Snapshot(now).Single().Status == "unknown", "Reconnection invented an OpenCode restart.");
Check(reconnect.Apply(Frame("opencode", "delayed", "completed"), now) &&
    reconnect.Snapshot(now).Single().Status == "unknown", "A delayed terminal event confirmed completion after reconnect.");

var closed = new StateStore();
closed.RetainProviders(["opencode"]);
Check(closed.Apply(Frame("opencode", "closed", "active"), now) &&
    closed.Apply(Frame("opencode", "closed", "completed"), now) && closed.Snapshot(now).Length == 0,
    "Terminal fixture did not close.");
closed.MarkProviderGap("opencode");
Check(closed.Apply(Frame("opencode", "closed", "completed"), now) &&
    closed.Apply(Plan("opencode", "closed"), now) && closed.Apply(ToolFinished("opencode", "closed"), now) &&
    closed.Snapshot(now).Length == 0, "Delayed terminal, plan or tool completion revived a closed card after loss.");
Check(closed.Apply(Frame("opencode", "closed", "started"), now) &&
    closed.Snapshot(now).Single().Status == "unknown", "A later start after loss was treated as confirmed.");

var bounded = new StateStore();
bounded.RetainProviders(["opencode", "deepseek"]);
for (int i = 0; i < 256; i++) Check(bounded.Apply(Frame("opencode", "s" + i, "active"), now), "Could not fill the store.");
bounded.MarkProviderGap("opencode");
Check(bounded.Snapshot(now).All(x => x.Status == "unknown"), "The fixture did not contain 256 visible unknown cards.");
for (int i = 0; i < 300; i++)
    Check(!bounded.Apply(Frame("deepseek", i.ToString("x32") + "_overflow", "active"), now), "A full store lost a card.");
Check(bounded.CapacityLimitedScopes("deepseek").Length <= 256 && bounded.CapacityLimitedProviders.Contains("deepseek") &&
    bounded.Snapshot(now).Length == 256, "Loss accounting exceeded its bound or hid existing cards.");
for (int i = 0; i < 300; i++) bounded.ConfirmDeepSeekDisconnectedScopes([i.ToString("x32")]);
object retiredScopes = typeof(StateStore).GetField("retiredDeepSeekScopes", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(bounded)!;
Check((int)retiredScopes.GetType().GetProperty("Count")!.GetValue(retiredScopes)! <= 256 &&
    bounded.LossAffectedProviders.Contains("deepseek"), "Reconnect history was unbounded or silently lost.");

var hermes = new StateStore();
hermes.RetainProviders(["hermes", "deepseek"]);
hermes.RetainSessionScopes("hermes", [a, b]);
Thread.Sleep(2);
Check(hermes.Apply(Hermes(a + "_one", "started"), now) && hermes.Apply(Hermes(b + "_two", "started"), now),
    "Hermes observations were rejected.");
Check(hermes.Apply(Hermes(a + "_one", "gap"), now), "A scoped Hermes gap was rejected.");
Check(hermes.Snapshot(now).Single(x => x.Session == a + "_one").Status == "unknown" &&
    hermes.Snapshot(now).Single(x => x.Session == b + "_two").Status == "active", "A Hermes gap affected a neighbor.");
Thread.Sleep(2);
Check(hermes.Apply(Hermes(a + "_new", "started"), now) &&
    hermes.Snapshot(now).Any(x => x.Session == a + "_new" && x.Status == "active"),
    "Existing Hermes handling of a later observer changed.");
// This fixture tests old behavior only; a new epoch does not establish that
// every older Hermes process has stopped.
var sharedCapacity = new StateStore();
sharedCapacity.RetainProviders(["hermes", "opencode", "deepseek", "kimi"]);
sharedCapacity.RetainSessionScopes("hermes", [a]);
for (int i = 0; i < 254; i++) Check(sharedCapacity.Apply(Frame("opencode", "shared" + i, "active"), now), "Could not fill V1 capacity.");
sharedCapacity.MarkProviderGap("opencode");
Check(sharedCapacity.Apply(Frame("deepseek", b + "_healthy", "active"), now), "Healthy DeepSeek fixture could not start.");
Thread.Sleep(2);
Check(sharedCapacity.Apply(Hermes(a + "_live", "started"), now), "Hermes fixture could not start.");
Check(!sharedCapacity.Apply(Frame("kimi", c + "_overflow", "active"), now) &&
    sharedCapacity.CapacityLimitedProviders.Contains("kimi") &&
    sharedCapacity.Snapshot(now).Single(x => x.Session == b + "_healthy").Status == "active" &&
    sharedCapacity.Snapshot(now).Single(x => x.Session == a + "_live").Status == "active",
    "Kimi overflow degraded a healthy neighbor or hid the warning.");
Check(!sharedCapacity.Apply(Hermes(a + "_overflow", "started"), now) && sharedCapacity.Snapshot(now).Length == 256,
    "The shared capacity boundary was not exercised.");
Check(sharedCapacity.CapacityLimitedProviders.Contains("hermes") &&
    sharedCapacity.Snapshot(now).Single(x => x.Session == b + "_healthy").Status == "active" &&
    !sharedCapacity.LossAffectedProviders.Contains("deepseek"), "Hermes overflow degraded healthy DeepSeek or hid the warning.");
Console.WriteLine($"Provider V1 recovery: {checks} synthetic checks passed.");
