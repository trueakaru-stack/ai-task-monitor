using System.Globalization;
using System.Text.Json;
using AITaskMonitor.CodexState;

string input = Console.In.ReadToEnd();
var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
List<FixtureCase> fixtures = JsonSerializer.Deserialize<List<FixtureCase>>(input, options)
    ?? throw new InvalidOperationException("Reference fixtures are missing.");
if (fixtures.Count < 7) throw new InvalidOperationException("Reference fixture set is incomplete.");

int checks = 0, steps = 0;
void Equal<T>(T expected, T actual, string context)
{
    checks++;
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
        throw new InvalidOperationException($"{context}: expected {expected}, got {actual}.");
}

DateTimeOffset ParseUtc(string text) => DateTimeOffset.Parse(text, CultureInfo.InvariantCulture,
    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
DateTimeOffset? ParseEventTimestamp(string text) => DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture,
    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed) ? parsed : null;

foreach (FixtureCase fixture in fixtures)
{
    LifecycleState state = LifecycleState.Empty;
    DateTimeOffset monitorStart = ParseUtc(fixture.MonitorStartedUtc);
    foreach (FixtureStep step in fixture.Steps)
    {
        steps++;
        string context = fixture.Name + " / " + step.Name;
        var events = step.Events.Select(item => new LifecycleEvent(
            Enum.Parse<LifecycleEventKind>(item.Kind), item.TurnId,
            ParseEventTimestamp(item.Timestamp), item.Timestamp)).ToArray();
        var observation = new ThreadObservation(step.SourcePresent, ParseUtc(step.UpdatedUtc),
            Enum.Parse<LockObservation>(step.Lock, true), Enum.Parse<EventBatchKind>(step.BatchKind), events);
        Reduction result = CodexLifecycleReducer.Reduce(state, observation, monitorStart);
        Equal(step.SourceUnavailable, result.SourceUnavailable, context + " source unavailable");
        Equal(step.ExpectedState.Marker, result.State.Marker.ToString(), context + " marker");
        Equal(step.ExpectedState.TurnId, result.State.TurnId, context + " turn");
        Equal(step.ExpectedState.LastEventTicks, result.State.LastEventUtc.UtcTicks, context + " last event");
        Equal(step.ExpectedState.StartKey, result.State.StartKey, context + " state start key");
        Equal(step.ExpectedState.StartedTicks, result.State.StartedUtc.UtcTicks, context + " state start");
        Equal(step.ExpectedState.Observed, result.State.Observed, context + " observed");
        if (step.ExpectedSnapshot is null)
        {
            Equal<ThreadSnapshot?>(null, result.Snapshot, context + " snapshot on error");
        }
        else
        {
            ThreadSnapshot snapshot = result.Snapshot ?? throw new InvalidOperationException(context + " snapshot missing");
            Equal(step.ExpectedSnapshot.Status, snapshot.Status.ToString().ToLowerInvariant(), context + " status");
            Equal(step.ExpectedSnapshot.HasStartMarker, snapshot.HasStartMarker, context + " has start");
            Equal(step.ExpectedSnapshot.UpdatedTicks, snapshot.UpdatedUtc.UtcTicks, context + " updated");
            Equal(step.ExpectedSnapshot.StartKey, snapshot.StartKey, context + " snapshot start key");
            Equal(step.ExpectedSnapshot.StartedTicks, snapshot.StartedUtc.UtcTicks, context + " snapshot start");
            Equal(step.ExpectedSnapshot.Unconfirmed, snapshot.Unconfirmed, context + " unconfirmed");
        }
        state = result.State;
    }
}

// These checks exercise separate state instances directly, rather than deriving
// every assertion from the reference implementation.
DateTimeOffset start = ParseUtc("2026-01-01T00:00:00Z");
ThreadObservation NewObservation(params LifecycleEvent[] events) => new(true, start.AddSeconds(1),
    LockObservation.Held, EventBatchKind.Incremental, events);
var first = new LifecycleEvent(LifecycleEventKind.Started, "first", start.AddSeconds(1));
var second = new LifecycleEvent(LifecycleEventKind.Started, "second", start.AddSeconds(2));
Reduction a = CodexLifecycleReducer.Reduce(LifecycleState.Empty, NewObservation(first), start);
Reduction b = CodexLifecycleReducer.Reduce(LifecycleState.Empty, NewObservation(second), start);
Reduction closedA = CodexLifecycleReducer.Reduce(a.State,
    NewObservation(new LifecycleEvent(LifecycleEventKind.Completed, "first")), start);
Equal(ThreadStatus.Completed, closedA.Snapshot!.Status, "independent A closes");
Equal(ThreadStatus.Active, b.Snapshot!.Status, "independent B stays active");
Equal("second", b.State.TurnId, "independent B keeps turn");
Equal(LifecycleMarker.Started, a.State.Marker, "previous immutable state unchanged");
Equal(a, CodexLifecycleReducer.Reduce(LifecycleState.Empty, NewObservation(first), start), "same inputs are deterministic");

// A source failure is not a free lock, and a terminal marker does not need one.
var unavailable = new ThreadObservation(true, start.AddSeconds(3), LockObservation.Unavailable,
    EventBatchKind.Incremental, Array.Empty<LifecycleEvent>());
Reduction failed = CodexLifecycleReducer.Reduce(a.State, unavailable, start);
Equal(true, failed.SourceUnavailable, "unavailable lock signals error");
Equal<ThreadSnapshot?>(null, failed.Snapshot, "unavailable lock has no successful snapshot");
Equal(true, failed.State.Observed, "source error preserves observation");

Console.WriteLine($"Codex lifecycle: {fixtures.Count} reference sequences, {steps} polls, {checks} comparisons and independent assertions passed.");

sealed class FixtureCase
{
    public string Name { get; set; } = "";
    public string MonitorStartedUtc { get; set; } = "";
    public List<FixtureStep> Steps { get; set; } = [];
}
sealed class FixtureStep
{
    public string Name { get; set; } = "";
    public List<FixtureEvent> Events { get; set; } = [];
    public string Lock { get; set; } = "";
    public string UpdatedUtc { get; set; } = "";
    public bool SourcePresent { get; set; }
    public string BatchKind { get; set; } = "";
    public bool SourceUnavailable { get; set; }
    public ExpectedState ExpectedState { get; set; } = new();
    public ExpectedSnapshot? ExpectedSnapshot { get; set; }
}
sealed class FixtureEvent
{
    public string Kind { get; set; } = "";
    public string TurnId { get; set; } = "";
    public string Timestamp { get; set; } = "";
}
sealed class ExpectedState
{
    public string Marker { get; set; } = "";
    public string TurnId { get; set; } = "";
    public long LastEventTicks { get; set; }
    public string StartKey { get; set; } = "";
    public long StartedTicks { get; set; }
    public bool Observed { get; set; }
}
sealed class ExpectedSnapshot
{
    public string Status { get; set; } = "";
    public bool HasStartMarker { get; set; }
    public long UpdatedTicks { get; set; }
    public string StartKey { get; set; } = "";
    public long StartedTicks { get; set; }
    public bool Unconfirmed { get; set; }
}
