using System.Text.Json;
using AITaskMonitor.CodexLoop;

if (args.Length != 1) throw new ArgumentException("A synthetic fixture path is required.");
var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
Fixture fixture = JsonSerializer.Deserialize<Fixture>(File.ReadAllText(args[0]), options)
    ?? throw new InvalidOperationException("Invalid fixture.");
byte[] key = Enumerable.Range(0, 32).Select(number => (byte)number).ToArray();
Preflight(key, fixture.Since);
using var tracker = new CodexLoopTracker(key, fixture.Since, fixture.Threshold, fixture.WindowMinutes);
var output = new List<object>();
foreach (Operation op in fixture.Operations)
{
    if (op.Kind == "event")
        tracker.Update(new LoopEvent(op.RecordType, op.EventType, op.ItemType, op.Id, op.Time,
            op.Status, op.ExitCode, op.Command, op.WorkingDirectory), op.Now);
    else if (op.Kind == "dismiss") tracker.Dismissed = true;
    else if (op.Kind == "refresh") tracker.Refresh(op.Now);
    else if (op.Kind == "reset") tracker.Reset();
    else if (op.Kind == "configure") tracker.Configure(op.Threshold, op.WindowMinutes);
    else throw new InvalidOperationException("Unknown synthetic operation.");
    output.Add(new { warning = tracker.Warning, dismissed = tracker.Dismissed, count = tracker.Count });
}
Console.WriteLine(JsonSerializer.Serialize(output));

static void Preflight(byte[] key, DateTimeOffset now)
{
    using var original = new CodexLoopTracker(key, now, 3, 1);
    LoopEvent Event(string id, int offset) => new("event_msg", "item_completed", "CommandExecution", id,
        now.AddSeconds(offset), "failed", 1, ["synthetic-tool", "SYNTHETIC_SECRET"], "/synthetic/path");
    original.Update(Event("one", 1), now.AddSeconds(5));
    original.Update(Event("two", 2), now.AddSeconds(5));
    foreach (var field in typeof(CodexLoopTracker).GetFields(System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic))
    {
        if (field.GetValue(original) is string value &&
            (value.Contains("SYNTHETIC_SECRET", StringComparison.Ordinal) || value.Contains("/synthetic/path", StringComparison.Ordinal)))
            throw new InvalidOperationException("Tracker state retained a raw command or path.");
    }
    using (var copy = original.Copy())
    {
        copy.Update(Event("three", 3), now.AddSeconds(5));
        if (!copy.Warning || original.Warning || original.Count != 2)
            throw new InvalidOperationException("A copied tracker must be independent.");
        copy.Dismissed = true;
        copy.Refresh(now.AddSeconds(64));
        if (copy.Warning || copy.Dismissed) throw new InvalidOperationException("The warning did not expire.");
    }
    original.Configure(4, 1);
    original.Update(Event("one", 1), now.AddSeconds(5));
    if (original.Count != 0) throw new InvalidOperationException("Reconfiguration must retain duplicate history.");
    original.Update(Event("three", 3), now.AddSeconds(5));
    original.Configure(4, 1);
    if (original.Count != 1) throw new InvalidOperationException("Unchanged settings must not reset the sequence.");
    bool rejected = false;
    try { using var invalid = new CodexLoopTracker(new byte[31], now); }
    catch (ArgumentException) { rejected = true; }
    if (!rejected || key[1] != 1) throw new InvalidOperationException("Key validation or caller ownership failed.");
}

internal sealed class Fixture
{
    public DateTimeOffset Since { get; set; }
    public int Threshold { get; set; }
    public int WindowMinutes { get; set; }
    public List<Operation> Operations { get; set; } = [];
}

internal sealed class Operation
{
    public string Kind { get; set; } = "";
    public DateTimeOffset Now { get; set; }
    public string? RecordType { get; set; }
    public string? EventType { get; set; }
    public string? ItemType { get; set; }
    public string? Id { get; set; }
    public DateTimeOffset? Time { get; set; }
    public string? Status { get; set; }
    public long? ExitCode { get; set; }
    public string?[]? Command { get; set; }
    public string? WorkingDirectory { get; set; }
    public int Threshold { get; set; }
    public int WindowMinutes { get; set; }
}
