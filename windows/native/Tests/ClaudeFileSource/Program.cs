using System.Text;
using System.Text.Json;
using AITaskMonitor.Claude;

try
{
if (args.Length != 0) throw new ArgumentException("This test accepts no external input.");
string work = Directory.CreateTempSubdirectory("aitm-claude-file-source-").FullName;
string allowedFixture = Path.Combine(AppContext.BaseDirectory, "status-retention.synthetic.json");
using JsonDocument fixture = JsonDocument.Parse(File.ReadAllText(allowedFixture));
string Get(string name) => fixture.RootElement.GetProperty(name).GetString()!;
DateTime now = DateTime.Parse(Get("now"), null, System.Globalization.DateTimeStyles.AdjustToUniversal);
var utf8 = new UTF8Encoding(false);
int checks = 0;
void Check(bool condition, string message) { checks++; if (!condition) throw new InvalidOperationException(message); }
string current = Path.Combine(work, "current.jsonl"), legacy = Path.Combine(work, "legacy.jsonl");
var source = new ClaudeFileSource(current, legacy, DateTime.MinValue.ToUniversalTime());
var snapshot = source.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Count == 0 && !snapshot.Unavailable, "Optional new source missing");
string complete = Get("complete");
string neighbor = JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "neighbor", ["timestamp"] = now.AddMilliseconds(-1).ToString("O"), ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n";
int firstLine = complete.IndexOf('\n') + 1;
string first = complete[..firstLine];
File.WriteAllText(current, first[..^2], utf8);
snapshot = source.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Count == 0 && !snapshot.Unavailable, "Incomplete first event should wait");
File.AppendAllText(current, first[^2..] + complete[firstLine..] + neighbor, utf8);
snapshot = source.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Count == 2 && !snapshot.Unavailable, "Completed events should appear");
var observed = snapshot.Tasks.Single(x => x.Id == "observed");
Check(observed.PlanConfirmed && observed.KnownStepCount == 2 && !observed.Unconfirmed, "Known steps should be confirmed");
string firstTitle = observed.Steps[0].title;
observed.Steps[0].title = "externally modified";
snapshot = source.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Single(x => x.Id == "observed").Steps[0].title == firstTitle, "Returned task must be isolated");
snapshot = source.Poll(ClaudeConnection.Partial, now);
Check(snapshot.Unavailable && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed), "Partial connection must be unconfirmed");
Check(snapshot.Tasks.Single(x => x.Id == "observed").Steps[0].title == firstTitle, "Partial state preserves step names");
snapshot = source.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "observed").PlanConfirmed, "Complete connection recovers after partial state");
string stop = $"{{\"session_id\":\"observed\",\"timestamp\":\"{now.AddSeconds(1):O}\",\"event\":\"Stop\",\"active\":false,\"stage_version\":1,\"stage_phase\":\"stop_clear\"}}";
File.AppendAllText(current, stop, utf8);
snapshot = source.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
Check(snapshot.Tasks.Count == 2, "Unterminated event must not be applied");
File.AppendAllText(current, "\n", utf8);
snapshot = source.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
Check(!snapshot.Tasks.Any(x => x.Id == "observed") && snapshot.Tasks.Any(x => x.Id == "neighbor"), "Completed stop affects only its session");
File.Delete(current);
snapshot = source.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
Check(snapshot.Unavailable && snapshot.Tasks.Single().Id == "neighbor" && snapshot.Tasks.Single().Unconfirmed, "Disappearing current file retains unconfirmed task");
File.WriteAllText(current, complete + neighbor, utf8);
snapshot = source.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
Check(snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed), "Observed source loss is retained after recovery");
snapshot = source.Poll(ClaudeConnection.Disconnected, now);
Check(snapshot.Tasks.Count == 0 && !snapshot.Unavailable, "Disconnect clears displayed tasks");

var second = new ClaudeFileSource(current, legacy, DateTime.MinValue.ToUniversalTime());
snapshot = second.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Count == 2 && !snapshot.Unavailable, "Absent legacy file remains optional");
File.WriteAllText(legacy, "", utf8);
_ = second.Poll(ClaudeConnection.Connected, now);
File.Delete(legacy);
snapshot = second.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.All(x => x.Unconfirmed), "Previously seen legacy loss is surfaced");

string large = Path.Combine(work, "large.jsonl");
using (var writer = new StreamWriter(large, false, utf8)) { writer.Write(new string('x', 4 * 1024 * 1024 + 512)); writer.Write('\n'); writer.Write(complete + neighbor); }
var largeSource = new ClaudeFileSource(large, null, DateTime.MinValue.ToUniversalTime());
snapshot = largeSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Count == 2 && !snapshot.Unavailable, "Bounded tail starts at next full line");
string boundary = Path.Combine(work, "boundary.jsonl");
string tailPrefix = complete + neighbor;
int remaining = 4 * 1024 * 1024 - utf8.GetByteCount(tailPrefix);
string fillerHead = $"{{\"session_id\":\"filler\",\"timestamp\":\"{now:O}\",\"event\":\"PreToolUse\",\"active\":true,\"padding\":\"";
const string fillerEnd = "\"}\n";
using (var writer = new StreamWriter(boundary, false, utf8))
{
    writer.Write("outside\n"); writer.Write(tailPrefix);
    while (remaining > 0)
    {
        int payload = Math.Min(900000, remaining - fillerHead.Length - fillerEnd.Length);
        if (payload < 0) throw new InvalidOperationException("Synthetic boundary cannot be filled exactly.");
        writer.Write(fillerHead); writer.Write(new string('x', payload)); writer.Write(fillerEnd);
        remaining -= fillerHead.Length + payload + fillerEnd.Length;
    }
}
var boundarySource = new ClaudeFileSource(boundary, null, DateTime.MinValue.ToUniversalTime());
snapshot = boundarySource.Poll(ClaudeConnection.Connected, now);
var boundaryTask = snapshot.Tasks.Single(x => x.Id == "observed");
Check(boundaryTask.PlanConfirmed, $"A tail beginning on a line boundary must keep the first complete record; steps={boundaryTask.Steps.Length}, known={boundaryTask.KnownStepCount}, unconfirmed={boundaryTask.Unconfirmed}");
string invalid = Path.Combine(work, "invalid.jsonl");
File.WriteAllBytes(invalid, [0xff, 0x0a]);
snapshot = new ClaudeFileSource(invalid, null, DateTime.MinValue.ToUniversalTime()).Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 0, "Invalid UTF-8 is surfaced");
string locked = Path.Combine(work, "locked.jsonl");
File.WriteAllText(locked, complete, utf8);
var lockedSource = new ClaudeFileSource(locked, null, DateTime.MinValue.ToUniversalTime());
_ = lockedSource.Poll(ClaudeConnection.Connected, now);
using (var exclusive = new FileStream(locked, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
{
    snapshot = lockedSource.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && snapshot.Tasks.Single().Unconfirmed, "Read failure preserves unconfirmed task");
}
snapshot = lockedSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Single().Unconfirmed, "Read failure remains visible after release");
string recovered = Path.Combine(work, "recovered.jsonl");
File.WriteAllText(recovered, complete, utf8);
var recoveredSource = new ClaudeFileSource(recovered, null, DateTime.MinValue.ToUniversalTime());
var beforeLoss = recoveredSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
Check(beforeLoss.Steps.Length == 2, "Recovery setup has two observed step titles");
File.Delete(recovered);
var duringLoss = recoveredSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
Check(duringLoss.Unconfirmed && duringLoss.Steps.Length == 2, "Loss retains names unconfirmed");
File.WriteAllText(recovered, "", utf8);
var afterLoss = recoveredSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
Check(afterLoss.Unconfirmed && !afterLoss.PlanConfirmed && afterLoss.Steps.Length == 2 &&
      afterLoss.Steps.Select(x => x.title).SequenceEqual(beforeLoss.Steps.Select(x => x.title)),
      "Recovery must retain observed step names unconfirmed");
string suffixFile = Path.Combine(work, "suffix.jsonl");
File.WriteAllText(suffixFile, complete, utf8);
var suffixSource = new ClaudeFileSource(suffixFile, null, DateTime.MinValue.ToUniversalTime());
_ = suffixSource.Poll(ClaudeConnection.Connected, now);
File.Delete(suffixFile);
_ = suffixSource.Poll(ClaudeConnection.Connected, now);
string unnamed = JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "observed", ["timestamp"] = now.AddSeconds(1).ToString("O"), ["event"] = "TaskCompleted", ["active"] = true, ["task_id"] = "first" }) + "\n";
File.WriteAllText(suffixFile, unnamed, utf8);
var suffix = suffixSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2)).Tasks.Single();
Check(suffix.Unconfirmed && suffix.Steps.Select(x => x.title).SequenceEqual(beforeLoss.Steps.Select(x => x.title)),
      "A generated suffix placeholder must not replace a known title");
string truncated = Path.Combine(work, "truncated.jsonl");
File.WriteAllText(truncated, complete, utf8);
var truncatedSource = new ClaudeFileSource(truncated, null, DateTime.MinValue.ToUniversalTime());
_ = truncatedSource.Poll(ClaudeConnection.Connected, now);
File.WriteAllText(truncated, unnamed, utf8);
var afterTruncate = truncatedSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2)).Tasks.Single();
Check(afterTruncate.Unconfirmed && !afterTruncate.PlanConfirmed &&
      afterTruncate.Steps.Select(x => x.title).SequenceEqual(beforeLoss.Steps.Select(x => x.title)),
      "Truncating in place must preserve previously observed names as unconfirmed");
string replaced = Path.Combine(work, "replaced.jsonl");
File.WriteAllText(replaced, complete + neighbor, utf8);
var replacedSource = new ClaudeFileSource(replaced, null, DateTime.MinValue.ToUniversalTime());
_ = replacedSource.Poll(ClaudeConnection.Connected, now);
File.WriteAllText(replaced, complete + neighbor.Replace("neighbor", "neighbOr", StringComparison.Ordinal), utf8);
var afterReplace = replacedSource.Poll(ClaudeConnection.Connected, now);
Check(afterReplace.Tasks.Single(x => x.Id == "observed").Unconfirmed,
      "A same-length replacement that changes the previous tail must be unconfirmed");
string newPromptPath = Path.Combine(work, "new-prompt.jsonl");
File.WriteAllText(newPromptPath, complete, utf8);
var newPromptSource = new ClaudeFileSource(newPromptPath, null, DateTime.MinValue.ToUniversalTime());
var priorPrompt = newPromptSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
File.Delete(newPromptPath);
_ = newPromptSource.Poll(ClaudeConnection.Connected, now);
File.WriteAllText(newPromptPath, Get("suffix"), utf8);
var nextPrompt = newPromptSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2)).Tasks.Single();
Check(nextPrompt.Unconfirmed && !nextPrompt.PlanConfirmed && nextPrompt.Started > priorPrompt.Started &&
      nextPrompt.Steps.Length == 3 && priorPrompt.Steps.All(p => nextPrompt.Steps.Any(s => s.title == p.title)) &&
      nextPrompt.Steps.Any(s => s.title == "Third step"),
      "After loss, a new prompt must keep known names without confirming the plan");
string oldPromptPath = Path.Combine(work, "older-prompt.jsonl");
File.WriteAllText(oldPromptPath, complete, utf8);
var oldPromptSource = new ClaudeFileSource(oldPromptPath, null, DateTime.MinValue.ToUniversalTime());
_ = oldPromptSource.Poll(ClaudeConnection.Connected, now);
string oldPrompt = JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "observed", ["timestamp"] = now.AddMinutes(-5).ToString("O"), ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n";
File.WriteAllText(oldPromptPath, oldPrompt + unnamed, utf8);
var afterOldPrompt = oldPromptSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2)).Tasks.Single();
Check(afterOldPrompt.Unconfirmed && afterOldPrompt.Steps.Select(x => x.title).SequenceEqual(beforeLoss.Steps.Select(x => x.title)),
      "An older surviving prompt must not erase previously observed names");
string bounded = Path.Combine(work, "bounded.jsonl");
var many = new StringBuilder();
many.Append(JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "many", ["timestamp"] = now.AddMinutes(-1).ToString("O"), ["event"] = "UserPromptSubmit", ["active"] = true })).Append('\n');
for (int i = 0; i < 129; i++)
    many.Append(JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "many", ["timestamp"] = now.AddSeconds(-30).AddMilliseconds(i).ToString("O"), ["event"] = "TaskCreated", ["active"] = true, ["task_id"] = i.ToString(), ["task_subject"] = "Synthetic " + i })).Append('\n');
File.WriteAllText(bounded, many.ToString(), utf8);
var boundedSource = new ClaudeFileSource(bounded, null, DateTime.MinValue.ToUniversalTime());
Check(boundedSource.Poll(ClaudeConnection.Connected, now).Tasks.Single().Steps.Length == 129, "Bounded setup has 129 observed names");
File.Delete(bounded);
_ = boundedSource.Poll(ClaudeConnection.Connected, now);
File.WriteAllText(bounded, "", utf8);
var limited = boundedSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
Check(limited.Unconfirmed && limited.RetainedPlanIncomplete && limited.Steps.Length == 128, "Truncated retained plan must be labeled incomplete");
Console.WriteLine($"Claude file source: {checks} synthetic checks passed.");
}
catch (Exception error)
{
    Console.Error.WriteLine(error);
    Environment.ExitCode = 1;
}
