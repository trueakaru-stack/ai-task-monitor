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
store.RetainProviders(["deepseek", "opencode", "kimi"]);
store.RetainSessionScopes("deepseek", [a, b]);
Check(store.Apply(Frame("deepseek", a + "_first", "active"), now), "A frame was rejected.");
Check(store.Apply(Frame("opencode", "open", "active"), now), "OpenCode was rejected.");
Check(store.Apply(Frame("kimi", c + "_task", "active"), now), "Kimi was rejected.");
for (int i = 0; i < 253; i++)
    Check(store.Apply(Frame("deepseek", b + "_" + i, "active"), now), "A bounded task was rejected.");
Check(store.Snapshot(now).Length == 256 && store.Snapshot(now).Count(x => x.Status == "active") == 255 &&
    store.Snapshot(now).Single(x => x.Provider == "kimi").Status == "unknown",
    "Normal V1 startup or Kimi's unconfirmed policy changed.");
Check(!store.Apply(Frame("deepseek", a + "_overflow", "active"), now), "Overflow was silently admitted.");
Check(store.Snapshot(now).Length == 256 && store.CapacityLimitedScopes("deepseek").SequenceEqual([a]) &&
    store.CapacityLimitedProviders.SequenceEqual(["deepseek"]) && store.LossAffectedProviders.SequenceEqual(["deepseek"]),
    "A scoped loss was not recorded.");
Check(store.Snapshot(now).Single(x => x.Session == a + "_first").Status == "unknown" &&
    store.Snapshot(now).Count(x => x.Session.StartsWith(b + "_", StringComparison.Ordinal) && x.Status == "active") == 253 &&
    store.Snapshot(now).Single(x => x.Provider == "opencode").Status == "active",
    "A scoped loss degraded an unrelated profile or provider.");
Check(store.Apply(Frame("deepseek", a + "_first", "completed"), now) &&
    store.Apply(Frame("deepseek", a + "_first", "active"), now) &&
    store.Snapshot(now).Single(x => x.Session == a + "_first").Status == "unknown", "A late event changed an unconfirmed card.");
Check(store.Snapshot(now).Count(x => x.Session.StartsWith(b + "_", StringComparison.Ordinal)) == 253 &&
    store.Snapshot(now).Any(x => x.Provider == "kimi") && store.Snapshot(now).Any(x => x.Provider == "opencode"),
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

var bounded = new StateStore();
bounded.RetainProviders(["opencode", "deepseek"]);
for (int i = 0; i < 256; i++) Check(bounded.Apply(Frame("opencode", "s" + i, "active"), now), "Could not fill the store.");
for (int i = 0; i < 300; i++)
    Check(!bounded.Apply(Frame("deepseek", i.ToString("x32") + "_overflow", "active"), now), "A full store lost a card.");
Check(bounded.CapacityLimitedScopes("deepseek").Length <= 256 && bounded.CapacityLimitedProviders.Contains("deepseek") &&
    bounded.Snapshot(now).Length == 256, "Loss accounting exceeded its bound or hid existing cards.");

var hermes = new StateStore();
hermes.RetainProviders(["hermes"]);
hermes.RetainSessionScopes("hermes", [a, b]);
Thread.Sleep(2);
Check(hermes.Apply(Hermes(a + "_one", "started"), now) && hermes.Apply(Hermes(b + "_two", "started"), now),
    "Hermes observations were rejected.");
Check(hermes.Snapshot(now).Count(x => x.Status == "active") == 2, "Fresh observer fixtures did not establish the initial state.");
Check(hermes.Apply(Hermes(a + "_one", "gap"), now), "A scoped Hermes gap was rejected.");
Check(hermes.Snapshot(now).Single(x => x.Session == a + "_one").Status == "unknown" &&
    hermes.Snapshot(now).Single(x => x.Session == b + "_two").Status == "active", "A Hermes gap affected a neighbor.");
Thread.Sleep(2);
Check(hermes.Apply(Hermes(a + "_one", "completed"), now) && hermes.Apply(Hermes(a + "_one", "started"), now) &&
    hermes.Snapshot(now).Single(x => x.Session == a + "_one").Status == "unknown", "A later Hermes event restored confidence.");
Check(hermes.Apply(Hermes(a + "_new", "started"), now) &&
    hermes.Snapshot(now).All(x => x.Session != a + "_new"), "A new permanent Hermes card was invented after loss.");
for (int i = 0; i < 300; i++)
    Check(hermes.Apply(Hermes(i.ToString("x32") + "_gap", "gap"), now), "A bounded Hermes gap was rejected.");
Check(hermes.Snapshot(now).Single(x => x.Session == b + "_two").Status == "active", "Bounded loss history degraded a healthy profile.");
foreach (string field in new[] { "hermesLostScopes", "hermesTrustedAtOverflow", "hermesScopeBarriers" })
{
    object value = typeof(StateStore).GetField(field, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(hermes)!;
    int count = (int)value.GetType().GetProperty("Count")!.GetValue(value)!;
    Check(count <= 256, "Hermes loss history exceeded its bound.");
}
Console.WriteLine($"Provider V1 recovery: {checks} synthetic checks passed.");
