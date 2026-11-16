using System.Text;
using System.Text.Json;
using AITaskMonitor.CodexHookEvidence;

if (!OperatingSystem.IsWindows() ||
    !string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase) ||
    !string.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase) ||
    !string.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"), "github-hosted", StringComparison.OrdinalIgnoreCase) ||
    !string.Equals(Environment.GetEnvironmentVariable("RUNNER_OS"), "Windows", StringComparison.OrdinalIgnoreCase) ||
    Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") != "0")
    throw new InvalidOperationException("A disposable hosted Windows environment is required.");

int checks = 0;
void Check(bool value, string message)
{
    checks++;
    if (!value) throw new InvalidOperationException(message);
}
byte[] Event(string kind, string session = "session-one", string turn = "turn-one") =>
    JsonSerializer.SerializeToUtf8Bytes(new
    {
        session_id = session,
        turn_id = turn,
        hook_event_name = kind,
        prompt = "SYNTHETIC_PRIVATE_PROMPT",
        cwd = "SYNTHETIC_PRIVATE_PATH",
        model = "SYNTHETIC_PRIVATE_MODEL",
        extra = new { command = "SYNTHETIC_PRIVATE_COMMAND", token = "SYNTHETIC_PRIVATE_TOKEN" }
    });
byte[] Json(string value) => Encoding.UTF8.GetBytes(value);

var collector = new HookEvidenceCollector();
HookEvidenceSnapshot before = collector.Snapshot();
Check(!before.Connected && before.CoverageIncomplete && before.Turns.Count == 0,
    "A new collector claimed complete source coverage.");
HookConnection connection = collector.Connect();
HookEvidenceSnapshot initial = collector.Snapshot();
Check(initial.Connected && initial.CoverageIncomplete && !initial.GapObserved && initial.Turns.Count == 0,
    "Connecting invented a task or complete baseline.");

Check(collector.Accept(connection, Event("PreModelRequest", "running-session", "turn-a")) == HookAcceptance.Accepted,
    "An observed mid-turn model request was rejected.");
HookTurnEvidence first = collector.Snapshot().Turns.Single();
Check(first.SessionId == "running-session" && first.TurnId == "turn-a" &&
    first.Kinds == ObservedHookKinds.ModelRequestStarting && !first.CurrentActivityConfirmed && !first.CompletionConfirmed,
    "A mid-turn observation was presented as confirmed current state.");
Check(collector.Accept(connection, Event("Stop", "running-session", "turn-a")) == HookAcceptance.Accepted,
    "A stop proposal was rejected.");
Check(collector.Accept(connection, Event("UserPromptSubmit", "running-session", "turn-a")) == HookAcceptance.Accepted,
    "An out-of-order prompt was rejected.");
Check(collector.Accept(connection, Event("Interrupt", "running-session", "turn-a")) == HookAcceptance.Accepted,
    "An interrupt observation was rejected.");
Check(collector.Accept(connection, Event("Stop", "running-session", "turn-a")) == HookAcceptance.Accepted,
    "A repeated stop was rejected.");
HookTurnEvidence merged = collector.Snapshot().Turns.Single();
Check(merged.Kinds == (ObservedHookKinds.PromptSubmitted | ObservedHookKinds.ModelRequestStarting |
    ObservedHookKinds.StopProposed | ObservedHookKinds.Interrupted) && !merged.CurrentActivityConfirmed && !merged.CompletionConfirmed,
    "Out-of-order or repeated events changed the evidence semantics.");
Check(collector.Accept(connection, Event("UserPromptSubmit", "running-session", "turn-b")) == HookAcceptance.Accepted &&
    collector.Accept(connection, Event("Stop", "running-session", "turn-a")) == HookAcceptance.Accepted &&
    collector.Snapshot().Turns.Any(item => item.TurnId == "turn-b" && item.Kinds == ObservedHookKinds.PromptSubmitted),
    "A late stop for one turn erased evidence for another.");

string serialized = JsonSerializer.Serialize(collector.Snapshot());
Check(!serialized.Contains("SYNTHETIC_PRIVATE_", StringComparison.Ordinal) &&
    !serialized.Contains("running-session", StringComparison.Ordinal) && !serialized.Contains("turn-a", StringComparison.Ordinal) &&
    !collector.Snapshot().ToString().Contains("running-session", StringComparison.Ordinal) &&
    !merged.ToString().Contains("turn-a", StringComparison.Ordinal), "Private metadata entered diagnostics.");

byte[] subagent = Json("{\"session_id\":\"parent\",\"turn_id\":\"child-turn\",\"hook_event_name\":\"UserPromptSubmit\",\"agent_id\":\"child\",\"agent_type\":\"worker\"}");
int beforeIgnored = collector.Snapshot().Turns.Count;
Check(collector.Accept(connection, subagent) == HookAcceptance.Ignored && collector.Snapshot().Turns.Count == beforeIgnored,
    "A subagent event was merged into a root task.");
Check(collector.Accept(connection, Json("{\"session_id\":\"parent\",\"turn_id\":\"turn\",\"hook_event_name\":\"UserPromptSubmit\",\"agent_id\":null}")) == HookAcceptance.Ignored &&
    collector.Snapshot().Turns.Count == beforeIgnored, "An ambiguous agent identity was treated as a root task.");
Check(collector.Accept(connection, Json("{\"hook_event_name\":\"SessionStart\",\"session_id\":\"idle\"}")) == HookAcceptance.Ignored &&
    collector.Snapshot().Turns.Count == beforeIgnored, "A session-start event invented an active task.");

HookConnection otherOwner = new HookEvidenceCollector().Connect();
Check(collector.Accept(otherOwner, Event("Stop")) == HookAcceptance.Stale && !collector.NotifyLoss(otherOwner),
    "A connection belonging to another collector was accepted.");
Check(collector.Disconnect(connection) && !collector.Snapshot().Connected && collector.Snapshot().GapObserved,
    "Disconnection did not mark an observation gap.");
HookConnection replacement = collector.Connect();
Check(collector.Accept(connection, Event("Stop")) == HookAcceptance.Stale &&
    collector.Snapshot().Turns.Any(item => item.TurnId == "turn-b"), "An old callback modified retained evidence.");
Check(collector.Accept(replacement, Event("Stop", "running-session", "turn-b")) == HookAcceptance.Accepted &&
    collector.Snapshot().Turns.Single(item => item.TurnId == "turn-b").CompletionConfirmed == false,
    "A delayed event arriving through a new connection was presented as completion.");
Check(collector.NotifyLoss(replacement) && collector.Snapshot().GapObserved && !collector.Disconnect(connection),
    "An observed loss or stale disconnect was mishandled.");

var bad = new HookEvidenceCollector();
HookConnection badConnection = bad.Connect();
foreach (byte[] invalid in new[]
{
    Json("{"),
    Json("[]"),
    Json("{\"hook_event_name\":\"Stop\",\"session_id\":\"one\"}"),
    Json("{\"hook_event_name\":\"Stop\",\"session_id\":\"one\",\"SESSION_ID\":\"two\",\"turn_id\":\"a\"}"),
    Json("{\"hook_event_name\":\"Stop\",\"session_id\":\"one\",\"turn_id\":\"a\"} {}"),
    Json("{\"hook_event_name\":\"Stop\",\"session_id\":\"one\\nline\",\"turn_id\":\"a\"}"),
    Json("{\"hook_event_name\":\"Stop\",\"session_id\":\"one\",\"turn_id\":\"\\ud800\"}"),
    [(byte)'{', (byte)'\"', 0xff, (byte)'\"', (byte)':', (byte)'1', (byte)'}'],
    new byte[1_048_577]
})
    Check(bad.Accept(badConnection, invalid) == HookAcceptance.Invalid, "Malformed input was accepted.");
Check(bad.Snapshot().GapObserved && bad.Snapshot().Turns.Count == 0,
    "Malformed input invented evidence or failed to mark loss.");

var concurrent = new HookEvidenceCollector();
HookConnection concurrentConnection = concurrent.Connect();
int rejected = 0;
string[] kinds = ["UserPromptSubmit", "PreModelRequest", "Stop", "Interrupt"];
Parallel.For(0, 2048, i =>
{
    if (concurrent.Accept(concurrentConnection, Event(kinds[i % kinds.Length], "concurrent", "turn")) != HookAcceptance.Accepted)
        Interlocked.Increment(ref rejected);
});
HookTurnEvidence concurrentTurn = concurrent.Snapshot().Turns.Single();
Check(rejected == 0 && concurrentTurn.Kinds == (ObservedHookKinds.PromptSubmitted | ObservedHookKinds.ModelRequestStarting |
    ObservedHookKinds.StopProposed | ObservedHookKinds.Interrupted) && !concurrentTurn.CompletionConfirmed,
    "Concurrent delivery lost evidence or created confirmed completion.");

var disconnectRace = new HookEvidenceCollector();
HookConnection raceConnection = disconnectRace.Connect();
using var go = new ManualResetEventSlim(false);
using var started = new CountdownEvent(8);
Task[] workers = Enumerable.Range(0, 8).Select(worker => Task.Factory.StartNew(() =>
{
    started.Signal();
    go.Wait();
    for (int i = 0; i < 512; i++)
        disconnectRace.Accept(raceConnection, Event(kinds[i % kinds.Length], "race", "turn-" + worker));
}, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default)).ToArray();
started.Wait();
go.Set();
Check(disconnectRace.Disconnect(raceConnection), "Concurrent disconnect failed.");
string disconnectedSnapshot = JsonSerializer.Serialize(disconnectRace.Snapshot());
Task.WaitAll(workers);
Check(disconnectedSnapshot == JsonSerializer.Serialize(disconnectRace.Snapshot()) &&
    disconnectRace.Accept(raceConnection, Event("Stop")) == HookAcceptance.Stale,
    "An in-flight callback changed evidence after disconnect returned.");

var capped = new HookEvidenceCollector();
HookConnection cappedConnection = capped.Connect();
for (int i = 0; i < HookEvidenceCollector.MaximumSessions; i++)
    Check(capped.Accept(cappedConnection, Event("UserPromptSubmit", "session-" + i, "turn")) == HookAcceptance.Accepted,
        "A session within the bound was rejected.");
Check(capped.Accept(cappedConnection, Event("UserPromptSubmit", "too-many", "turn")) == HookAcceptance.Overflow &&
    capped.Snapshot().CapacityExceeded && capped.Snapshot().GapObserved &&
    capped.Snapshot().Turns.Count == HookEvidenceCollector.MaximumSessions, "Session overflow was silent or erased evidence.");
var cappedTurns = new HookEvidenceCollector();
HookConnection cappedTurnsConnection = cappedTurns.Connect();
for (int i = 0; i < HookEvidenceCollector.MaximumTurnsPerSession; i++)
    Check(cappedTurns.Accept(cappedTurnsConnection, Event("UserPromptSubmit", "session", "turn-" + i)) == HookAcceptance.Accepted,
        "A turn within the bound was rejected.");
Check(cappedTurns.Accept(cappedTurnsConnection, Event("Stop", "session", "overflow")) == HookAcceptance.Overflow &&
    cappedTurns.Snapshot().CapacityExceeded && cappedTurns.Snapshot().Turns.Count == HookEvidenceCollector.MaximumTurnsPerSession &&
    cappedTurns.Accept(cappedTurnsConnection, Event("Stop", "session", "turn-0")) == HookAcceptance.Accepted,
    "Turn overflow was silent or prevented existing evidence from updating.");

Console.WriteLine($"Codex hook evidence: {checks} synthetic checks passed.");
