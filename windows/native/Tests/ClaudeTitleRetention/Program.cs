using System.Text;
using System.Text.Json;
using AITaskMonitor.Claude;

string work = Directory.CreateTempSubdirectory("aitm-title-retention-").FullName;
DateTime now = DateTime.UtcNow;
string Event(string session, string name, int seconds, string? id = null, string? title = null, string? phase = null)
{
    var data = new Dictionary<string, object?> { ["session_id"] = session, ["event"] = name,
        ["timestamp"] = now.AddSeconds(seconds).ToString("O"), ["active"] = name == "Unknown" ? null : true };
    if (id is not null) data["task_id"] = id;
    if (title is not null) data["task_subject"] = title;
    if (phase is not null) { data["stage_phase"] = phase; data["stage_version"] = 1; }
    return JsonSerializer.Serialize(data) + "\n";
}
string prompt = Event("one", "UserPromptSubmit", -20);
string old = Event("one", "TaskCreated", -19, "shared", "Old known name");
string next = Event("one", "UserPromptSubmit", -10) + Event("one", "TaskCreated", -9, "shared", "New known name");
string marker = Event("", "Unknown", -11, phase: "source_uncertain");
string path = Path.Combine(work, "events.jsonl");
var utf8 = new UTF8Encoding(false);

File.WriteAllText(path, prompt + old, utf8);
var incremental = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
var before = incremental.Poll(ClaudeConnection.Connected, now).Tasks.Single();
if (!before.Steps.Any(step => step.title == "Old known name")) throw new Exception("Old-name setup failed");
File.Delete(path);
_ = incremental.Poll(ClaudeConnection.Connected, now);
File.WriteAllText(path, next, utf8);
var after = incremental.Poll(ClaudeConnection.Connected, now).Tasks.Single();
bool incrementalOk = after.Unconfirmed && !after.PlanConfirmed &&
    after.Steps.Any(step => step.title == "Old known name") && after.Steps.Any(step => step.title == "New known name");
Console.WriteLine("Observed-loss titles: " + string.Join(" | ", after.Steps.Select(step => step.title)) + "; required both: " + incrementalOk);

File.WriteAllText(path, prompt + old + marker + next, utf8);
var firstRead = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
var combined = firstRead.Poll(ClaudeConnection.Connected, now).Tasks.Single();
bool combinedOk = combined.Unconfirmed && !combined.PlanConfirmed &&
    combined.Steps.Any(step => step.title == "Old known name") && combined.Steps.Any(step => step.title == "New known name");
Console.WriteLine("First-read marked-loss titles: " + string.Join(" | ", combined.Steps.Select(step => step.title)) + "; required both: " + combinedOk);
bool unknownStates = after.Steps.All(step => step.status == "unknown") && combined.Steps.All(step => step.status == "unknown");
File.WriteAllText(path, prompt + old + next, utf8);
var noLoss = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime()).Poll(ClaudeConnection.Connected, now).Tasks.Single();
bool ordinaryRename = noLoss.Steps.Count(step => step.id == "shared") == 1 && noLoss.Steps.Single(step => step.id == "shared").title == "New known name";
File.WriteAllText(path, prompt + old, utf8);
var ordinarySource = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
_ = ordinarySource.Poll(ClaudeConnection.Connected, now);
File.AppendAllText(path, next, utf8);
var sequentialRename = ordinarySource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
ordinaryRename &= sequentialRename.Steps.Length == 1 && sequentialRename.Steps.Single().title == "New known name";

string neighbor = Event("two", "UserPromptSubmit", -20) + Event("two", "TaskCreated", -18, "shared", "Neighbor name");
string scoped = Event("one", "Unknown", -11, phase: "session_uncertain");
File.WriteAllText(path, prompt + old + neighbor + scoped + next, utf8);
var scopedSource = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
var scopedTasks = scopedSource.Poll(ClaudeConnection.Connected, now).Tasks;
var scopedOne = scopedTasks.Single(task => task.Id == "one");
var scopedTwo = scopedTasks.Single(task => task.Id == "two");
bool isolated = scopedOne.Unconfirmed && scopedOne.Steps.Select(step => step.title).SequenceEqual(new[] { "Old known name", "New known name" }) &&
    !scopedTwo.Unconfirmed && scopedTwo.Steps.Single().title == "Neighbor name";
var repeated = scopedSource.Poll(ClaudeConnection.Connected, now).Tasks.Single(task => task.Id == "one");
bool noDuplicates = repeated.Steps.Select(step => step.title).SequenceEqual(new[] { "Old known name", "New known name" });
var scopedMemory = new SessionReader();
_ = scopedMemory.Read(prompt + old + scoped, "", now, DateTime.MinValue.ToUniversalTime());
var afterMarkerDisappears = scopedMemory.Read(next, "", now, DateTime.MinValue.ToUniversalTime()).Single();
bool remembersScope = afterMarkerDisappears.Steps.Select(step => step.title).SequenceEqual(new[] { "Old known name", "New known name" }) &&
    afterMarkerDisappears.Unconfirmed && !afterMarkerDisappears.PlanConfirmed;
var stoppedMarkerMemory = new SessionReader();
_ = stoppedMarkerMemory.Read(prompt + old, "", now, DateTime.MinValue.ToUniversalTime());
_ = stoppedMarkerMemory.Read(prompt + old + scoped.Replace("\"active\":null", "\"active\":false", StringComparison.Ordinal), "", now, DateTime.MinValue.ToUniversalTime());
var afterStoppedMarker = stoppedMarkerMemory.Read(next, "", now, DateTime.MinValue.ToUniversalTime()).Single();
remembersScope &= afterStoppedMarker.Steps.Select(step => step.title).SequenceEqual(new[] { "Old known name", "New known name" });

var many = new StringBuilder(Event("many", "UserPromptSubmit", -400));
for (int i = 0; i < 129; i++) many.Append(Event("many", "TaskCreated", -399 + i, "same", "Known name " + i));
many.Append(Event("", "Unknown", -260, phase: "source_uncertain"));
File.WriteAllText(path, many.ToString(), utf8);
var bounded = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime()).Poll(ClaudeConnection.Connected, now).Tasks.Single();
bool boundedOk = bounded.Unconfirmed && bounded.RetainedPlanIncomplete && bounded.Steps.Length == 128 &&
    bounded.Steps.Any(step => step.title == "Known name 128") && !bounded.Steps.Any(step => step.title == "Known name 0");
many = new StringBuilder(Event("many", "UserPromptSubmit", -400));
for (int i = 0; i < 129; i++) many.Append(Event("many", "TaskCreated", -399 + i, "same", "Known name " + i));
many.Append(Event("many", "Unknown", -260, phase: "session_uncertain"));
many.Append(Event("many", "UserPromptSubmit", -250));
many.Append(neighbor);
File.WriteAllText(path, many.ToString(), utf8);
var scopedBounded = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime()).Poll(ClaudeConnection.Connected, now).Tasks;
bool boundedIsolation = scopedBounded.Single(task => task.Id == "many").RetainedPlanIncomplete &&
    !scopedBounded.Single(task => task.Id == "two").Unconfirmed;
string clear = JsonSerializer.Serialize(new Dictionary<string, object?> { ["session_id"] = "one", ["event"] = "Stop", ["timestamp"] = now.AddSeconds(-6).ToString("O"), ["active"] = false, ["stage_phase"] = "stop_clear", ["stage_version"] = 1 }) + "\n";
string laterUnknown = Event("one", "Unknown", -5, phase: "session_uncertain");
File.WriteAllText(path, prompt + old, utf8);
var stoppedSource = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
_ = stoppedSource.Poll(ClaudeConnection.Connected, now);
File.AppendAllText(path, clear + laterUnknown, utf8);
bool noFalseRevival = stoppedSource.Poll(ClaudeConnection.Connected, now).Tasks.All(task => task.Id != "one");
File.AppendAllText(path, Event("one", "PreToolUse", -4), utf8);
bool workAfterStop = stoppedSource.Poll(ClaudeConnection.Connected, now).Tasks.Any(task => task.Id == "one");

string longId = new('x', 129);
File.WriteAllText(path, Event("long", "UserPromptSubmit", -20) + Event("long", "TaskCreated", -19, longId, "Long ID name"), utf8);
var longSource = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
_ = longSource.Poll(ClaudeConnection.Connected, now);
File.Delete(path);
_ = longSource.Poll(ClaudeConnection.Connected, now);
File.WriteAllText(path, Event("long", "UserPromptSubmit", -10) + Event("long", "TaskCreated", -9, longId, "Long ID name"), utf8);
var longFirst = longSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
var longSecond = longSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
bool longDedup = longFirst.RetainedPlanIncomplete && longSecond.RetainedPlanIncomplete &&
    longFirst.Steps.Count(step => step.title == "Long ID name") == 1 && longSecond.Steps.Count(step => step.title == "Long ID name") == 1;
File.AppendAllText(path, Event("long", "TaskCreated", -8, longId, "Long ID revised"), utf8);
var longAfterLossRename = longSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
bool longLossNames = longAfterLossRename.Steps.Select(step => step.title).SequenceEqual(new[] { "Long ID name", "Long ID revised" });
File.WriteAllText(path, Event("long", "UserPromptSubmit", -20) + Event("long", "TaskCreated", -19, longId, "Long ID name"), utf8);
var longOrdinary = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime());
_ = longOrdinary.Poll(ClaudeConnection.Connected, now);
File.AppendAllText(path, Event("long", "TaskCreated", -9, longId, "Long ID revised"), utf8);
var longRenamed = longOrdinary.Poll(ClaudeConnection.Connected, now).Tasks.Single();
var longRepeated = longOrdinary.Poll(ClaudeConnection.Connected, now).Tasks.Single();
bool longNoLoss = longRenamed.Steps.Length == 1 && longRenamed.Steps[0].title == "Long ID revised" &&
    longRepeated.Steps.Length == 1 && longRepeated.RetainedPlanIncomplete;
File.WriteAllText(path, Event("long", "UserPromptSubmit", -20) + Event("long", "TaskCreated", -19, longId, "Same name") +
    Event("long", "TaskCreated", -18, new string('y', 129), "Same name") + marker, utf8);
var differentLong = new ClaudeFileSource(path, null, DateTime.MinValue.ToUniversalTime()).Poll(ClaudeConnection.Connected, now).Tasks.Single();
bool distinctLong = differentLong.RetainedPlanIncomplete && differentLong.Steps.Count(step => step.title == "Same name") == 2;
Console.WriteLine($"Unknown statuses: {unknownStates}; ordinary rename: {ordinaryRename}; session isolation: {isolated}; repeat dedup: {noDuplicates}; retained scope: {remembersScope}; bounded history: {boundedOk}; bounded isolation: {boundedIsolation}; no false revival: {noFalseRevival}; new work returns: {workAfterStop}; long-ID dedup: {longDedup}; long-ID loss names: {longLossNames}; long-ID ordinary: {longNoLoss}; distinct long IDs: {distinctLong}");
if (!incrementalOk || !combinedOk || !unknownStates || !ordinaryRename || !isolated || !noDuplicates || !remembersScope || !boundedOk || !boundedIsolation || !noFalseRevival || !workAfterStop || !longDedup || !longLossNames || !longNoLoss || !distinctLong) Environment.ExitCode = 1;
