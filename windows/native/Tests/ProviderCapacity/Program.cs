using AITaskMonitor.ExternalProviders;

static Event Frame(string provider, string session, string kind)
{
    string json = "{\"version\":1,\"provider\":\"" + provider +
        "\",\"session\":\"" + session + "\",\"kind\":\"" + kind + "\"}";
    return EventParser.Parse(json) ?? throw new Exception("Invalid synthetic frame.");
}
static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}
var now = DateTimeOffset.Parse("2026-11-04T10:00:00Z");
var state = new StateStore();
state.RetainProviders(["deepseek", "opencode", "kimi"]);
string first = new('a', 32), neighbour = new('b', 32);
Check(state.Apply(Frame("deepseek", first + "_one", "active"), now), "Could not add affected task.");
for (int i = 0; i < 253; i++)
    Check(state.Apply(Frame("deepseek", neighbour + "_s" + i, "active"), now), "Could not add neighbour.");
Check(state.Apply(Frame("opencode", "healthy", "active"), now), "Could not add independent task.");
Check(state.Apply(Frame("kimi", "uncertain", "active"), now), "Could not add uncertain task.");
Check(!state.Apply(Frame("deepseek", first + "_missing", "active"), now), "Overflow displaced visible evidence.");
TaskState[] shown = state.Snapshot(now);
Check(shown.Length == 256, "A visible task disappeared.");
Check(shown.Single(x => x.Provider == "kimi").Status == "unknown", "Uncertain card disappeared.");
Check(shown.Single(x => x.Provider == "opencode").Status == "active", "Other provider lost confidence.");
Check(shown.Single(x => x.Session == first + "_one").Status == "unknown", "Affected scope stayed confirmed.");
Check(shown.Count(x => x.Session.StartsWith(neighbour + "_") && x.Status == "active") == 253,
    "Neighbouring profile lost confidence.");
Check(state.CapacityLimitedProviders.SequenceEqual(["deepseek"]), "Capacity warning is incorrect.");
Console.WriteLine("Native provider capacity: scoped loss and visible-card preservation passed.");
