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
var partialSource = new ClaudeFileSource(current, legacy, DateTime.MinValue.ToUniversalTime());
_ = partialSource.Poll(ClaudeConnection.Connected, now);
snapshot = partialSource.Poll(ClaudeConnection.Partial, now);
Check(snapshot.Unavailable && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed), "Partial connection must be unconfirmed");
Check(snapshot.Tasks.Single(x => x.Id == "observed").Steps[0].title == firstTitle, "Partial state preserves step names");
snapshot = partialSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed) &&
    snapshot.Tasks.Single(x => x.Id == "observed").Steps[0].title == firstTitle,
    "A complete connection must not confirm an old journal after partial state");
string nonTerminal = JsonSerializer.Serialize(new Dictionary<string, object> {
    ["session_id"] = "observed", ["timestamp"] = now.AddMilliseconds(-2).ToString("O"),
    ["event"] = "PreToolUse", ["tool_name"] = "Read", ["active"] = true }) + "\r\n";
int split = nonTerminal.Length / 2;
File.AppendAllText(current, nonTerminal[..split], utf8);
snapshot = source.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed &&
    x.KnownStepCount == 0 && x.KnownDoneCount == 0 && x.Activity == "" && x.Steps.All(step => step.status == "unknown")),
    "An incomplete final event after complete records must make every visible task unconfirmed");
Check(snapshot.Tasks.Single(x => x.Id == "observed").Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
    "An incomplete final event must preserve known step titles");
snapshot.Tasks.Single(x => x.Id == "observed").Steps[0].status = "done";
snapshot = source.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "observed").Steps.All(x => x.status == "unknown"),
    "Repeated polling of a pending tail must stay unconfirmed and isolate the returned snapshot");
File.AppendAllText(current, nonTerminal[split..], utf8);
snapshot = source.Poll(ClaudeConnection.Connected, now);
observed = snapshot.Tasks.Single(x => x.Id == "observed");
Check(!snapshot.Unavailable && !observed.Unconfirmed && observed.PlanConfirmed && observed.KnownStepCount == 2 &&
    observed.Steps.Select(x => x.status).SequenceEqual(new[] { "done", "active" }),
    "A normal append completing the event should restore confirmed known steps");

string firstPendingPath = Path.Combine(work, "complete-plus-pending.jsonl");
File.WriteAllText(firstPendingPath, complete + neighbor + nonTerminal[..split], utf8);
var firstPendingSource = new ClaudeFileSource(firstPendingPath, null, DateTime.MinValue.ToUniversalTime());
snapshot = firstPendingSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed) &&
    snapshot.Tasks.Single(x => x.Id == "observed").Steps.All(x => x.status == "unknown"),
    "A first poll with complete records and a partial tail must show known cards as unconfirmed");
File.AppendAllText(firstPendingPath, nonTerminal[split..], utf8);
snapshot = firstPendingSource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "observed").PlanConfirmed,
    "Finishing the initial pending tail must permit confirmation");

string pendingLegacyCurrent = Path.Combine(work, "pending-legacy-current.jsonl");
string pendingLegacyPath = Path.Combine(work, "pending-legacy.jsonl");
string legacyEvent = JsonSerializer.Serialize(new Dictionary<string, object> {
    ["session_id"] = "other", ["timestamp"] = now.AddSeconds(-20).ToString("O"), ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n";
int legacySplit = legacyEvent.Length / 2;
File.WriteAllText(pendingLegacyCurrent, complete + neighbor, utf8);
File.WriteAllText(pendingLegacyPath, legacyEvent + legacyEvent[..legacySplit], utf8);
var pendingLegacySource = new ClaudeFileSource(pendingLegacyCurrent, pendingLegacyPath, DateTime.MinValue.ToUniversalTime());
snapshot = pendingLegacySource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed),
    "An incomplete legacy tail must not confirm current tasks");
File.AppendAllText(pendingLegacyPath, legacyEvent[legacySplit..], utf8);
snapshot = pendingLegacySource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "observed").PlanConfirmed,
    "A completed legacy tail without loss should permit confirmation");

string pendingAfterStopPath = Path.Combine(work, "pending-after-complete-stop.jsonl");
File.WriteAllText(pendingAfterStopPath, complete + neighbor, utf8);
var pendingAfterStop = new ClaudeFileSource(pendingAfterStopPath, null, DateTime.MinValue.ToUniversalTime());
_ = pendingAfterStop.Poll(ClaudeConnection.Connected, now);
string completeStop = $"{{\"session_id\":\"observed\",\"timestamp\":\"{now.AddSeconds(1):O}\",\"event\":\"Stop\",\"active\":false,\"stage_version\":1,\"stage_phase\":\"stop_clear\"}}\n";
string afterStopEvent = JsonSerializer.Serialize(new Dictionary<string, object> {
    ["session_id"] = "neighbor", ["timestamp"] = now.AddMilliseconds(1500).ToString("O"),
    ["event"] = "PreToolUse", ["tool_name"] = "Read", ["active"] = true }) + "\n";
int afterStopSplit = afterStopEvent.Length / 2;
File.AppendAllText(pendingAfterStopPath, completeStop + afterStopEvent[..afterStopSplit], utf8);
snapshot = pendingAfterStop.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
Check(snapshot.Unavailable && snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed),
    "A complete stop before a partial tail must not prematurely remove a previously visible task");
File.AppendAllText(pendingAfterStopPath, afterStopEvent[afterStopSplit..], utf8);
snapshot = pendingAfterStop.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
Check(!snapshot.Unavailable && snapshot.Tasks.Count == 1 && snapshot.Tasks.Single().Id == "neighbor" && !snapshot.Tasks.Single().Unconfirmed,
    "A complete tail must apply an earlier confirmed stop");

string SessionEvent(string id) => JsonSerializer.Serialize(new Dictionary<string, object> {
    ["session_id"] = id, ["timestamp"] = now.ToString("O"),
    ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n";
string idLimitPath = Path.Combine(work, "session-id-limit.jsonl");
string idLimitPrefix = new('s', 127);
string idLimitA = idLimitPrefix + "a", idLimitB = idLimitPrefix + "b";
string idLimitUnicode = new string('u', 126) + "😀";
Check(idLimitA.Length == 128 && idLimitB.Length == 128 && idLimitUnicode.Length == 128,
    "The boundary identity fixtures must contain exactly 128 UTF-16 units");
File.WriteAllText(idLimitPath, SessionEvent(idLimitA) + SessionEvent(idLimitB) + SessionEvent(idLimitUnicode), utf8);
var idLimitSource = new ClaudeFileSource(idLimitPath, null, DateTime.MinValue.ToUniversalTime());
snapshot = idLimitSource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Count == 3 && snapshot.Tasks.All(x => !x.Unconfirmed) &&
    snapshot.Tasks.Any(x => x.Id == idLimitA) && snapshot.Tasks.Any(x => x.Id == idLimitB) &&
    snapshot.Tasks.Any(x => x.Id == idLimitUnicode),
    "Distinct boundary-length session identities must remain separate and confirmed");

string oversizedIdPrefix = new('x', 1_000_000);
string oversizedIdA = oversizedIdPrefix + "a", oversizedIdB = oversizedIdPrefix + "b";
string oversizedEvents = SessionEvent(new string('v', 129)) + SessionEvent(oversizedIdA) + SessionEvent(oversizedIdB);
string oversizedOnlyPath = Path.Combine(work, "oversized-only-sessions.jsonl");
File.WriteAllText(oversizedOnlyPath, oversizedEvents, utf8);
var oversizedOnlySource = new ClaudeFileSource(oversizedOnlyPath, null, DateTime.MinValue.ToUniversalTime());
snapshot = oversizedOnlySource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 0,
    "Unsupported oversized identities must report source loss without inventing or merging cards");

string oversizedLegacyCurrent = Path.Combine(work, "oversized-legacy-current.jsonl");
string oversizedLegacyPath = Path.Combine(work, "oversized-legacy.jsonl");
File.WriteAllText(oversizedLegacyCurrent, complete, utf8);
File.WriteAllText(oversizedLegacyPath, SessionEvent(new string('v', 129)), utf8);
var oversizedLegacySource = new ClaudeFileSource(oversizedLegacyCurrent, oversizedLegacyPath, DateTime.MinValue.ToUniversalTime());
snapshot = oversizedLegacySource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Single().Id == "observed" && snapshot.Tasks.Single().Unconfirmed,
    "An unsupported legacy identity must report loss without creating a card");

string emptyCurrentPath = Path.Combine(work, "empty-current-with-legacy.jsonl");
string emptyLegacyPath = Path.Combine(work, "empty-current-legacy.jsonl");
File.WriteAllText(emptyCurrentPath, "", utf8);
File.WriteAllText(emptyLegacyPath, SessionEvent("legacy-only"), utf8);
var emptyLegacyControl = new ClaudeFileSource(emptyCurrentPath, emptyLegacyPath, DateTime.MinValue.ToUniversalTime());
snapshot = emptyLegacyControl.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Count == 0, "Valid legacy-only records must not create cards");
File.WriteAllText(emptyLegacyPath, SessionEvent(new string('v', 129)), utf8);
var emptyLegacyLoss = new ClaudeFileSource(emptyCurrentPath, emptyLegacyPath, DateTime.MinValue.ToUniversalTime());
snapshot = emptyLegacyLoss.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 0,
    "An unsupported legacy identity must report loss even with an empty current journal");
File.Delete(emptyCurrentPath);
var absentCurrentLegacyLoss = new ClaudeFileSource(emptyCurrentPath, emptyLegacyPath, DateTime.MinValue.ToUniversalTime());
snapshot = absentCurrentLegacyLoss.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 0,
    "An unsupported legacy identity must report loss even before the current journal exists");

string SizedSessionEvent(string id, int padding) => JsonSerializer.Serialize(new Dictionary<string, object> {
    ["session_id"] = id, ["timestamp"] = now.ToString("O"), ["event"] = "UserPromptSubmit",
    ["active"] = true, ["padding"] = new string('p', padding) }) + "\n";
string pendingLossRecord = SessionEvent(new string('v', 129));
int replacementPadding = utf8.GetByteCount(pendingLossRecord) - utf8.GetByteCount(SizedSessionEvent("safe", 0));
Check(replacementPadding >= 0, "The equal-length replacement fixture cannot be constructed");
string pendingSafeRecord = SizedSessionEvent("safe", replacementPadding);
string pendingLaterRecord = SizedSessionEvent("later", 512);
int pendingLaterCut = pendingLaterRecord.Length - 2;
Check(utf8.GetByteCount(pendingLossRecord) == utf8.GetByteCount(pendingSafeRecord) &&
    utf8.GetByteCount(pendingLaterRecord[..pendingLaterCut]) > 128,
    "The pending-loss fixture must preserve the checked byte boundary");

string windowPadding = SizedSessionEvent("window-padding", 512);
foreach (bool mutateLegacy in new[] { false, true })
{
    string windowCurrent = Path.Combine(work, $"full-window-current-{mutateLegacy}.jsonl");
    string windowLegacy = Path.Combine(work, $"full-window-legacy-{mutateLegacy}.jsonl");
    string windowTarget = mutateLegacy ? windowLegacy : windowCurrent;
    string originalWindow = mutateLegacy ? SessionEvent("unrelated") + windowPadding : complete + windowPadding;
    string changedWindow = mutateLegacy
        ? originalWindow.Replace("unrelated", "unrelAted", StringComparison.Ordinal)
        : originalWindow.Replace("First step", "F1rst step", StringComparison.Ordinal);
    byte[] originalWindowBytes = utf8.GetBytes(originalWindow), changedWindowBytes = utf8.GetBytes(changedWindow);
    Check(originalWindowBytes.Length == changedWindowBytes.Length &&
        originalWindowBytes.AsSpan(originalWindowBytes.Length - 128).SequenceEqual(changedWindowBytes.AsSpan(changedWindowBytes.Length - 128)) &&
        !originalWindowBytes.AsSpan().SequenceEqual(changedWindowBytes),
        "The early-rewrite fixture must change bytes while preserving length and the last 128 bytes");
    File.WriteAllText(windowCurrent, mutateLegacy ? complete : originalWindow, utf8);
    if (mutateLegacy) File.WriteAllText(windowLegacy, originalWindow, utf8);
    var fullWindowSource = new ClaudeFileSource(windowCurrent, mutateLegacy ? windowLegacy : null, DateTime.MinValue.ToUniversalTime());
    var fullWindowBefore = fullWindowSource.Poll(ClaudeConnection.Connected, now);
    Check(!fullWindowBefore.Unavailable && fullWindowBefore.Tasks.Single(x => x.Id == "observed").PlanConfirmed,
        "The early-rewrite fixture must start with a confirmed known plan");
    File.WriteAllText(windowTarget, changedWindow, utf8);
    snapshot = fullWindowSource.Poll(ClaudeConnection.Connected, now);
    var fullWindowAfter = snapshot.Tasks.Single(x => x.Id == "observed");
    Check(snapshot.Unavailable && fullWindowAfter.Unconfirmed && !fullWindowAfter.PlanConfirmed &&
        fullWindowAfter.Steps.Any(x => x.title == "First step") && fullWindowAfter.Steps.All(x => x.status == "unknown"),
        "Changing earlier bytes in either journal must preserve old names as unconfirmed");
    Check(idLimitSource.Poll(ClaudeConnection.Connected, now).Tasks.All(x => !x.Unconfirmed),
        "A different source must not inherit the changed-window loss");
}

foreach (bool atomicReplacement in new[] { false, true })
{
    string raceReadPath = Path.Combine(work, $"read-race-{atomicReplacement}.jsonl");
    string replacementPath = Path.Combine(work, $"read-replacement-{atomicReplacement}.jsonl");
    string readOriginal = complete + windowPadding;
    string readChanged = readOriginal.Replace("First step", "F1rst step", StringComparison.Ordinal);
    File.WriteAllText(raceReadPath, readOriginal, utf8);
    int changeArmed = 0;
    var readRaceSource = new ClaudeFileSource(raceReadPath, null, DateTime.MinValue.ToUniversalTime(), null, path =>
    {
        if (System.Threading.Interlocked.Exchange(ref changeArmed, 0) == 0) return;
        if (atomicReplacement)
        {
            File.WriteAllText(replacementPath, readChanged, utf8);
            File.Replace(replacementPath, path, null);
        }
        else File.WriteAllText(path, readChanged, utf8);
    });
    Check(readRaceSource.Poll(ClaudeConnection.Connected, now).Tasks.Single(x => x.Id == "observed").PlanConfirmed,
        "The read-race fixture must begin with a confirmed plan");
    System.Threading.Volatile.Write(ref changeArmed, 1);
    snapshot = readRaceSource.Poll(ClaudeConnection.Connected, now);
    var racedTask = snapshot.Tasks.Single(x => x.Id == "observed");
    Check(snapshot.Unavailable && readRaceSource.HasObservedSourceLoss && racedTask.Unconfirmed &&
        racedTask.Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }) &&
        File.ReadAllText(raceReadPath, utf8) == readChanged,
        "A changed or replaced path during reading must report loss and retain previous names");
}

string appendReadPath = Path.Combine(work, "append-during-read.jsonl");
File.WriteAllText(appendReadPath, complete, utf8);
int appendArmed = 0;
var appendReadSource = new ClaudeFileSource(appendReadPath, null, DateTime.MinValue.ToUniversalTime(), null, path =>
{
    if (System.Threading.Interlocked.Exchange(ref appendArmed, 0) != 0) File.AppendAllText(path, SessionEvent("after-capture"), utf8);
});
_ = appendReadSource.Poll(ClaudeConnection.Connected, now);
System.Threading.Volatile.Write(ref appendArmed, 1);
snapshot = appendReadSource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && !snapshot.Tasks.Any(x => x.Id == "after-capture") && !appendReadSource.HasObservedSourceLoss,
    "A pure append after capture must be left for the next poll without a false loss");
snapshot = appendReadSource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Any(x => x.Id == "after-capture" && !x.Unconfirmed),
    "The next poll must see a pure append without losing confirmation");

string vanishDuringRead = Path.Combine(work, "vanish-during-first-read.jsonl");
File.WriteAllText(vanishDuringRead, SessionEvent("vanishing"), utf8);
var vanishSource = new ClaudeFileSource(vanishDuringRead, null, DateTime.MinValue.ToUniversalTime(), null,
    path => File.Delete(path));
snapshot = vanishSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 0 && vanishSource.HasObservedSourceLoss,
    "A source disappearing after its first open must be loss, not an optional missing source");
snapshot = vanishSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 0,
    "A source that vanished during its first read must remain unavailable while absent");

foreach (bool pendingInLegacy in new[] { false, true })
{
    string pendingIdentityCurrent = Path.Combine(work, $"pending-identity-current-{pendingInLegacy}.jsonl");
    string pendingIdentityLegacy = Path.Combine(work, $"pending-identity-legacy-{pendingInLegacy}.jsonl");
    string target = pendingInLegacy ? pendingIdentityLegacy : pendingIdentityCurrent;
    File.WriteAllText(pendingIdentityCurrent, pendingInLegacy ? SessionEvent("fresh") :
        pendingLossRecord + pendingLaterRecord[..pendingLaterCut], utf8);
    if (pendingInLegacy) File.WriteAllText(pendingIdentityLegacy, pendingLossRecord + pendingLaterRecord[..pendingLaterCut], utf8);
    var pendingIdentitySource = new ClaudeFileSource(pendingIdentityCurrent, pendingInLegacy ? pendingIdentityLegacy : null,
        DateTime.MinValue.ToUniversalTime());
    snapshot = pendingIdentitySource.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && pendingIdentitySource.HasObservedSourceLoss && snapshot.Tasks.All(x => x.Unconfirmed),
        "A complete oversized identity before a partial tail must immediately report loss");

    // This replacement preserves the length and last 128 bytes. The complete
    // replacement is confirmable for a fresh source; the assertion above checks
    // that the pending read already recorded loss before this rewrite.
    File.WriteAllText(target, pendingSafeRecord + pendingLaterRecord[..pendingLaterCut], utf8);
    File.AppendAllText(target, pendingLaterRecord[pendingLaterCut..], utf8);
    var cleanIdentityControl = new ClaudeFileSource(pendingIdentityCurrent, pendingInLegacy ? pendingIdentityLegacy : null,
        DateTime.MinValue.ToUniversalTime());
    var cleanIdentitySnapshot = cleanIdentityControl.Poll(ClaudeConnection.Connected, now);
    Check(!cleanIdentitySnapshot.Unavailable && cleanIdentitySnapshot.Tasks.Count > 0 &&
        cleanIdentitySnapshot.Tasks.All(x => !x.Unconfirmed), "The replaced journal must be confirmable without prior loss");
    snapshot = pendingIdentitySource.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && snapshot.Tasks.Count > 0 && snapshot.Tasks.All(x => x.Unconfirmed),
        "Finishing a partial tail must not forget the rejected identity");

    string truncatedIdentityCurrent = Path.Combine(work, $"truncated-identity-current-{pendingInLegacy}.jsonl");
    string truncatedIdentityLegacy = Path.Combine(work, $"truncated-identity-legacy-{pendingInLegacy}.jsonl");
    string truncatedTarget = pendingInLegacy ? truncatedIdentityLegacy : truncatedIdentityCurrent;
    File.WriteAllText(truncatedIdentityCurrent, pendingInLegacy ? SessionEvent("fresh") :
        pendingLossRecord + pendingLaterRecord[..pendingLaterCut], utf8);
    if (pendingInLegacy) File.WriteAllText(truncatedIdentityLegacy, pendingLossRecord + pendingLaterRecord[..pendingLaterCut], utf8);
    var truncatedIdentitySource = new ClaudeFileSource(truncatedIdentityCurrent, pendingInLegacy ? truncatedIdentityLegacy : null,
        DateTime.MinValue.ToUniversalTime());
    Check(truncatedIdentitySource.Poll(ClaudeConnection.Connected, now).Unavailable,
        "The truncation fixture must first observe source loss");
    File.WriteAllText(truncatedTarget, pendingInLegacy ? "" : SessionEvent("safe"), utf8);
    snapshot = truncatedIdentitySource.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && snapshot.Tasks.Count > 0 && snapshot.Tasks.All(x => x.Unconfirmed),
        "Truncation after a partial tail must retain source uncertainty");
}

string oversizedWithKnownPath = Path.Combine(work, "oversized-with-known-session.jsonl");
File.WriteAllText(oversizedWithKnownPath, complete, utf8);
var oversizedWithKnownSource = new ClaudeFileSource(oversizedWithKnownPath, null, DateTime.MinValue.ToUniversalTime());
Check(oversizedWithKnownSource.Poll(ClaudeConnection.Connected, now).Tasks.Single().PlanConfirmed,
    "Oversized-session recovery setup must start with a confirmed plan");
File.AppendAllText(oversizedWithKnownPath, oversizedEvents + completeStop, utf8);
snapshot = oversizedWithKnownSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
var oversizedKnownTask = snapshot.Tasks.Single();
Check(snapshot.Unavailable && oversizedKnownTask.Id == "observed" && oversizedKnownTask.Unconfirmed &&
    !oversizedKnownTask.PlanConfirmed && oversizedKnownTask.Steps.All(x => x.status == "unknown") &&
    oversizedKnownTask.Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
    "A rejected identity must retain a previously visible task as unconfirmed even beside a stop");
File.WriteAllText(oversizedWithKnownPath, "", utf8);
snapshot = oversizedWithKnownSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
Check(snapshot.Unavailable && snapshot.Tasks.Single().Id == "observed" && snapshot.Tasks.Single().Unconfirmed &&
    snapshot.Tasks.Single().Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
    "Recovery from oversized identities must retain known names without confirmation");

foreach (ClaudeConnection interrupted in new[] { ClaudeConnection.Disconnected, ClaudeConnection.Partial })
{
    string connectionPath = Path.Combine(work, $"connection-{interrupted}.jsonl");
    File.WriteAllText(connectionPath, complete + neighbor, utf8);
    var connectionSource = new ClaudeFileSource(connectionPath, null, DateTime.MinValue.ToUniversalTime());
    var original = connectionSource.Poll(ClaudeConnection.Connected, now);
    Check(original.Tasks.Single(x => x.Id == "observed").PlanConfirmed && connectionSource.IsCurrent(original),
        "Connection setup must begin with a confirmed plan");
    snapshot = connectionSource.Poll(interrupted, now);
    Check(!connectionSource.IsCurrent(original), "A connection transition must invalidate an earlier snapshot");
    if (interrupted == ClaudeConnection.Disconnected)
    {
        Check(snapshot.Tasks.Count == 0 && !snapshot.Unavailable, "A disconnect must hide cards");
        var whileDisconnected = connectionSource.ReportUnavailable();
        Check(whileDisconnected.Tasks.Count == 0 && !whileDisconnected.Unavailable,
            "A read-error report must not show cards while disconnected");
    }
    else Check(snapshot.Unavailable && snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed),
        "A partial connection must keep cards unconfirmed");

    // A later arrival cannot prove whether this stop came from before or after the gap.
    File.AppendAllText(connectionPath, completeStop, utf8);
    snapshot = connectionSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
    var connectionTask = snapshot.Tasks.Single(x => x.Id == "observed");
    Check(snapshot.Unavailable && connectionTask.Unconfirmed && !connectionTask.PlanConfirmed &&
        connectionTask.Steps.All(x => x.status == "unknown") &&
        connectionTask.Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }) &&
        snapshot.Tasks.Single(x => x.Id == "neighbor").Unconfirmed,
        "Reconnection must preserve prior names and must not confirm a delayed stop");
    string delayed = JsonSerializer.Serialize(new Dictionary<string, object> {
        ["session_id"] = "delayed", ["timestamp"] = now.AddSeconds(1).ToString("O"),
        ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n";
    File.AppendAllText(connectionPath, delayed, utf8);
    snapshot = connectionSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
    Check(snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "delayed").Unconfirmed &&
        snapshot.Tasks.Single(x => x.Id == "observed").Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
        "A delayed event after reconnect must not establish a new epoch or erase names");
}

foreach (ClaudeConnection initial in new[] { ClaudeConnection.Disconnected, ClaudeConnection.Partial })
{
    string initialPath = Path.Combine(work, $"initial-{initial}.jsonl");
    File.WriteAllText(initialPath, complete, utf8);
    var initialSource = new ClaudeFileSource(initialPath, null, DateTime.MinValue.ToUniversalTime());
    _ = initialSource.Poll(initial, now);
    snapshot = initialSource.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && snapshot.Tasks.Single().Unconfirmed && !snapshot.Tasks.Single().PlanConfirmed,
        "A first non-connected observation cannot confirm an older journal on reconnect");
}

string connectionManyPath = Path.Combine(work, "connection-many-cards.jsonl");
var connectionMany = new StringBuilder();
for (int i = 0; i < 257; i++)
    connectionMany.Append(JsonSerializer.Serialize(new Dictionary<string, object> {
        ["session_id"] = $"connection-{i}", ["timestamp"] = now.ToString("O"),
        ["event"] = "UserPromptSubmit", ["active"] = true })).Append('\n');
File.WriteAllText(connectionManyPath, connectionMany.ToString(), utf8);
var connectionManySource = new ClaudeFileSource(connectionManyPath, null, DateTime.MinValue.ToUniversalTime());
_ = connectionManySource.Poll(ClaudeConnection.Connected, now);
Check(connectionManySource.Poll(ClaudeConnection.Disconnected, now).Tasks.Count == 0,
    "Disconnect must hide all cards even when retention reaches its limit");
snapshot = connectionManySource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 256 && snapshot.Tasks.All(x => x.Unconfirmed),
    "Reconnection retention must be bounded and unconfirmed");

string independentPath = Path.Combine(work, "independent-connection.jsonl");
File.WriteAllText(independentPath, complete, utf8);
var independentSource = new ClaudeFileSource(independentPath, null, DateTime.MinValue.ToUniversalTime());
try
{
    _ = independentSource.Poll(now);
    throw new ArgumentException("A poll without a connection signal unexpectedly succeeded.");
}
catch (InvalidOperationException) { checks++; }
var independentSnapshot = independentSource.Poll(ClaudeConnection.Connected, now);
Check(independentSnapshot.Tasks.Single().PlanConfirmed, "The independent source must begin confirmed");

foreach (bool reconnectBeforeReturn in new[] { false, true })
{
    string racePath = Path.Combine(work, $"connection-race-{reconnectBeforeReturn}.jsonl");
    File.WriteAllText(racePath, complete + neighbor, utf8);
    using var readReached = new System.Threading.ManualResetEventSlim();
    using var finishRead = new System.Threading.ManualResetEventSlim();
    int arm = 0;
    var raceSource = new ClaudeFileSource(racePath, null, DateTime.MinValue.ToUniversalTime(), () =>
    {
        if (System.Threading.Interlocked.Exchange(ref arm, 0) != 0)
        {
            readReached.Set();
            if (!finishRead.Wait(TimeSpan.FromSeconds(8))) throw new TimeoutException("The synthetic poll was not released.");
        }
    });
    var beforeRace = raceSource.Poll(ClaudeConnection.Connected, now);
    Check(beforeRace.Tasks.Single(x => x.Id == "observed").PlanConfirmed, "Concurrent setup must begin confirmed");
    File.AppendAllText(racePath, completeStop, utf8);
    System.Threading.Volatile.Write(ref arm, 1);
    var inFlight = System.Threading.Tasks.Task.Run(() => raceSource.Poll(now.AddSeconds(2)));
    try
    {
        Check(readReached.Wait(TimeSpan.FromSeconds(8)), "The synthetic poll did not reach its synchronization point");
        var notify = System.Threading.Tasks.Task.Run(() => raceSource.NotifyConnection(ClaudeConnection.Disconnected));
        Check(notify.Wait(TimeSpan.FromSeconds(8)), "Connection notification blocked behind a file poll");
        notify.GetAwaiter().GetResult();
        Check(!raceSource.IsCurrent(beforeRace) && !raceSource.IsCurrent(independentSnapshot) &&
            independentSource.IsCurrent(independentSnapshot),
            "A disconnect must invalidate only its own source's earlier snapshot");
        if (reconnectBeforeReturn) raceSource.NotifyConnection(ClaudeConnection.Connected);
    }
    finally { finishRead.Set(); }
    snapshot = inFlight.WaitAsync(TimeSpan.FromSeconds(8)).GetAwaiter().GetResult();
    if (!reconnectBeforeReturn)
    {
        Check(snapshot.Tasks.Count == 0 && raceSource.IsCurrent(snapshot), "An in-flight disconnect must hide the result");
        raceSource.NotifyConnection(ClaudeConnection.Connected);
        snapshot = raceSource.Poll(now.AddSeconds(2));
    }
    Check(snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "observed").Unconfirmed &&
        snapshot.Tasks.Single(x => x.Id == "observed").Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }) &&
        snapshot.Tasks.Single(x => x.Id == "neighbor").Unconfirmed,
        "A disconnect during polling must retain earlier names without confirming the delayed stop");
    Check(independentSource.Poll(ClaudeConnection.Connected, now).Tasks.Single().PlanConfirmed,
        "A different source must remain confirmed after the interruption");
}

foreach (bool readFailure in new[] { false, true })
{
    string casePath = Path.Combine(work, readFailure ? "pending-stop-read-error.jsonl" : "pending-stop-truncate.jsonl");
    File.WriteAllText(casePath, complete + neighbor, utf8);
    var caseSource = new ClaudeFileSource(casePath, null, DateTime.MinValue.ToUniversalTime());
    Check(caseSource.Poll(ClaudeConnection.Connected, now).Tasks.Single(x => x.Id == "observed").PlanConfirmed,
        "Interrupted pending setup must start with a confirmed plan");
    File.AppendAllText(casePath, completeStop + afterStopEvent[..afterStopSplit], utf8);
    snapshot = caseSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
    Check(snapshot.Tasks.Any(x => x.Id == "observed" && x.Unconfirmed), "The pending stop lost its previous task");
    if (readFailure)
    {
        using (var exclusive = new FileStream(casePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            Check(caseSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2)).Unavailable,
                "A read error during the pending stop was not surfaced");
        File.AppendAllText(casePath, afterStopEvent[afterStopSplit..], utf8);
    }
    else File.WriteAllText(casePath, complete + neighbor + completeStop, utf8);
    snapshot = caseSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
    var retainedAfterPendingLoss = snapshot.Tasks.Single(x => x.Id == "observed");
    Check(snapshot.Unavailable && retainedAfterPendingLoss.Unconfirmed && !retainedAfterPendingLoss.PlanConfirmed &&
        retainedAfterPendingLoss.Steps.All(x => x.status == "unknown") &&
        retainedAfterPendingLoss.Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
        "Loss after a pending stop must preserve the previous card and known titles as unconfirmed");
}

string unicodePendingPath = Path.Combine(work, "pending-unicode.jsonl");
File.WriteAllText(unicodePendingPath, complete + neighbor, utf8);
var unicodePendingSource = new ClaudeFileSource(unicodePendingPath, null, DateTime.MinValue.ToUniversalTime());
_ = unicodePendingSource.Poll(ClaudeConnection.Connected, now);
string unicodeEvent = $"{{\"session_id\":\"observed\",\"timestamp\":\"{now.AddMilliseconds(-2):O}\",\"event\":\"PreToolUse\",\"tool_name\":\"Read\",\"active\":true,\"synthetic\":\"漢\"}}\n";
byte[] unicodeBytes = utf8.GetBytes(unicodeEvent);
int unicodeSplit = Array.IndexOf(unicodeBytes, (byte)0xe6) + 1;
Check(unicodeSplit > 0, "The split UTF-8 fixture is invalid");
using (var stream = new FileStream(unicodePendingPath, FileMode.Append, FileAccess.Write, FileShare.Read))
    stream.Write(unicodeBytes, 0, unicodeSplit);
snapshot = unicodePendingSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed),
    "A partial UTF-8 scalar after complete records must wait without confirming");
using (var stream = new FileStream(unicodePendingPath, FileMode.Append, FileAccess.Write, FileShare.Read))
    stream.Write(unicodeBytes, unicodeSplit, unicodeBytes.Length - unicodeSplit);
snapshot = unicodePendingSource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "observed").PlanConfirmed,
    "Completing a split UTF-8 scalar must permit confirmation");

string lostPendingPath = Path.Combine(work, "pending-truncate.jsonl");
File.WriteAllText(lostPendingPath, complete + neighbor, utf8);
var lostPendingSource = new ClaudeFileSource(lostPendingPath, null, DateTime.MinValue.ToUniversalTime());
_ = lostPendingSource.Poll(ClaudeConnection.Connected, now);
File.AppendAllText(lostPendingPath, nonTerminal[..split], utf8);
_ = lostPendingSource.Poll(ClaudeConnection.Connected, now);
File.WriteAllText(lostPendingPath, complete + neighbor, utf8);
snapshot = lostPendingSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed &&
    x.Steps.All(step => step.status == "unknown")), "Truncation while pending must remain unconfirmed after restoration");

string failedPendingPath = Path.Combine(work, "pending-read-error.jsonl");
File.WriteAllText(failedPendingPath, complete + neighbor, utf8);
var failedPendingSource = new ClaudeFileSource(failedPendingPath, null, DateTime.MinValue.ToUniversalTime());
_ = failedPendingSource.Poll(ClaudeConnection.Connected, now);
File.AppendAllText(failedPendingPath, nonTerminal[..split], utf8);
_ = failedPendingSource.Poll(ClaudeConnection.Connected, now);
using (var exclusive = new FileStream(failedPendingPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
{
    snapshot = failedPendingSource.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && snapshot.Tasks.All(x => x.Unconfirmed), "A read failure during a pending tail must be unconfirmed");
}
File.AppendAllText(failedPendingPath, nonTerminal[split..], utf8);
snapshot = failedPendingSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed &&
    x.Steps.All(step => step.status == "unknown")), "A read failure must remain unconfirmed after finishing the tail");

string displacedPath = Path.Combine(work, "pending-displaced-plan.jsonl");
File.WriteAllText(displacedPath, complete + neighbor, utf8);
var displacedSource = new ClaudeFileSource(displacedPath, null, DateTime.MinValue.ToUniversalTime());
_ = displacedSource.Poll(ClaudeConnection.Connected, now);
string fillerPrefix = $"{{\"session_id\":\"filler\",\"timestamp\":\"{now.AddSeconds(-10):O}\",\"event\":\"UserPromptSubmit\",\"active\":true,\"padding\":\"";
string fillerLine = fillerPrefix + new string('x', 900_000) + "\"}\n";
string paddingBurst = string.Concat(Enumerable.Repeat(fillerLine, 5));
string completeNewPlan = Get("suffix");
var suffixAlone = Reader.Read(completeNewPlan, "", now, DateTime.MinValue.ToUniversalTime());
Check(suffixAlone.Length == 1 && suffixAlone[0].PlanConfirmed &&
    suffixAlone[0].Steps.Single().title == "Third step", "The complete suffix must reproduce the false-confirmation condition");

foreach (bool useLegacy in new[] { false, true })
{
    string currentPath = Path.Combine(work, useLegacy ? "finish-shift-legacy-current.jsonl" : "finish-shift-current.jsonl");
    string legacyPath = Path.Combine(work, "finish-shift-legacy.jsonl");
    File.WriteAllText(currentPath, complete + neighbor, utf8);
    if (useLegacy) File.WriteAllText(legacyPath, "", utf8);
    var shiftedSource = new ClaudeFileSource(currentPath, useLegacy ? legacyPath : null, DateTime.MinValue.ToUniversalTime());
    Check(shiftedSource.Poll(ClaudeConnection.Connected, now).Tasks.Single(x => x.Id == "observed").PlanConfirmed,
        "Finishing and shifting setup must start with a confirmed plan");
    string target = useLegacy ? legacyPath : currentPath;
    File.AppendAllText(target, nonTerminal[..split], utf8);
    snapshot = shiftedSource.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "observed").Unconfirmed,
        "The partial event preceding the window shift was not surfaced");
    File.AppendAllText(target, nonTerminal[split..] + paddingBurst + nonTerminal, utf8);
    snapshot = shiftedSource.Poll(ClaudeConnection.Connected, now);
    var shifted = snapshot.Tasks.Single(x => x.Id == "observed");
    Check(snapshot.Unavailable && shifted.Unconfirmed && !shifted.PlanConfirmed &&
        shifted.Steps.All(x => x.status == "unknown") &&
        shifted.Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
        "Completing a pending event while shifting either window must retain earlier names unconfirmed");
}

foreach (bool useLegacy in new[] { false, true })
{
    string currentPath = Path.Combine(work, useLegacy ? "complete-shift-legacy-current.jsonl" : "complete-window-shift.jsonl");
    string legacyPath = Path.Combine(work, "complete-shift-legacy.jsonl");
    File.WriteAllText(currentPath, complete + neighbor, utf8);
    if (useLegacy) File.WriteAllText(legacyPath, "", utf8);
    var completeShiftSource = new ClaudeFileSource(currentPath, useLegacy ? legacyPath : null, DateTime.MinValue.ToUniversalTime());
    _ = completeShiftSource.Poll(ClaudeConnection.Connected, now);
    File.AppendAllText(useLegacy ? legacyPath : currentPath, paddingBurst + completeNewPlan, utf8);
    snapshot = completeShiftSource.Poll(ClaudeConnection.Connected, now);
    var completeShift = snapshot.Tasks.Single(x => x.Id == "observed");
    Check(snapshot.Unavailable && completeShift.Unconfirmed && !completeShift.PlanConfirmed &&
        completeShift.Steps.All(x => x.status == "unknown") &&
        completeShift.Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step", "Third step" }),
        "A complete window shift in either journal must not replace the prior plan with a falsely confirmed suffix");
}

foreach (bool useLegacy in new[] { false, true })
{
    string currentPath = Path.Combine(work, useLegacy ? "first-large-legacy-current.jsonl" : "first-large-current.jsonl");
    string legacyPath = Path.Combine(work, "first-large-legacy.jsonl");
    if (useLegacy)
    {
        File.WriteAllText(currentPath, completeNewPlan, utf8);
        File.WriteAllText(legacyPath, complete + paddingBurst + nonTerminal, utf8);
    }
    else File.WriteAllText(currentPath, complete + paddingBurst + completeNewPlan, utf8);
    var firstLargeSource = new ClaudeFileSource(currentPath, useLegacy ? legacyPath : null, DateTime.MinValue.ToUniversalTime());
    snapshot = firstLargeSource.Poll(ClaudeConnection.Connected, now);
    var firstLarge = snapshot.Tasks.Single(x => x.Id == "observed");
    Check(snapshot.Unavailable && firstLarge.Unconfirmed && !firstLarge.PlanConfirmed &&
        firstLarge.Steps.Length == 1 && firstLarge.Steps[0].title == "Third step" && firstLarge.Steps[0].status == "unknown",
        "A first bounded read must leave a complete visible suffix unconfirmed without inventing unseen names");
}

string newerStep = JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "observed",
    ["timestamp"] = now.AddMilliseconds(-1).ToString("O"), ["event"] = "TaskCreated", ["active"] = true,
    ["task_id"] = "third", ["task_subject"] = "Third step" }) + "\n";
using (var writer = new StreamWriter(displacedPath, true, utf8))
{
    for (int i = 0; i < 5; i++) writer.Write(fillerLine);
    writer.Write(nonTerminal);
    writer.Write(newerStep);
    writer.Write(afterStopEvent[..afterStopSplit]);
}
snapshot = displacedSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
var displaced = snapshot.Tasks.Single(x => x.Id == "observed");
Check(snapshot.Unavailable && displaced.Unconfirmed && !displaced.PlanConfirmed &&
    displaced.Steps.All(x => x.status == "unknown") &&
    displaced.Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step", "Third step" }),
    "Sliding past the old plan during a pending event must preserve earlier titles");
File.AppendAllText(displacedPath, afterStopEvent[afterStopSplit..], utf8);
snapshot = displacedSource.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
displaced = snapshot.Tasks.Single(x => x.Id == "observed");
Check(snapshot.Unavailable && displaced.Unconfirmed && !displaced.PlanConfirmed && displaced.Steps.Length == 3,
    "Completing a tail after prior plan evidence moved outside the window must not restore confirmation");

string cyclingPath = Path.Combine(work, "pending-cycling-ids.jsonl");
File.WriteAllText(cyclingPath, "", utf8);
var cyclingSource = new ClaudeFileSource(cyclingPath, null, DateTime.MinValue.ToUniversalTime());
_ = cyclingSource.Poll(ClaudeConnection.Connected, now);
for (int cycle = 0; cycle < 5; cycle++)
{
    using (var writer = new StreamWriter(cyclingPath, true, utf8))
    {
        if (cycle != 0) writer.Write(nonTerminal[split..]);
        for (int i = 0; i < 5; i++) writer.Write(fillerLine);
        for (int i = 0; i < 64; i++)
            writer.Write(JsonSerializer.Serialize(new Dictionary<string, object> {
                ["session_id"] = $"cycle-{cycle}-{i}", ["timestamp"] = now.AddSeconds(-2).ToString("O"),
                ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n");
        writer.Write(nonTerminal[..split]);
    }
    snapshot = cyclingSource.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && snapshot.Tasks.Count <= 256 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed),
        "Changing IDs across pending windows must remain bounded and unconfirmed");
}
Check(snapshot.Tasks.Count == 256 && snapshot.Tasks.Any(x => x.Id == "cycle-0-0") &&
    !snapshot.Tasks.Any(x => x.Id == "cycle-4-63"), "Card retention overflow was not bounded and surfaced");
File.AppendAllText(cyclingPath, nonTerminal[split..], utf8);
snapshot = cyclingSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count <= 256 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed),
    "Overflow must stay visible and unconfirmed after the pending tail completes");

string stop = $"{{\"session_id\":\"observed\",\"timestamp\":\"{now.AddSeconds(1):O}\",\"event\":\"Stop\",\"active\":false,\"stage_version\":1,\"stage_phase\":\"stop_clear\"}}";
File.AppendAllText(current, stop, utf8);
snapshot = source.Poll(ClaudeConnection.Connected, now.AddSeconds(2));
Check(snapshot.Unavailable && snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed),
    "An unterminated stop must not be applied or leave other statuses confirmed");
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
Check(snapshot.Tasks.Count == 2 && snapshot.Unavailable && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed) &&
    snapshot.Tasks.Single(x => x.Id == "observed").Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
    "A first bounded tail must keep complete records but treat its unseen prefix as loss");
File.AppendAllText(large, nonTerminal[..split], utf8);
snapshot = largeSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 2 && snapshot.Tasks.All(x => x.Unconfirmed && !x.PlanConfirmed),
    "A partial final event in a bounded tail must remain unconfirmed");
File.AppendAllText(large, nonTerminal[split..], utf8);
snapshot = largeSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Single(x => x.Id == "observed").Unconfirmed &&
    !snapshot.Tasks.Single(x => x.Id == "observed").PlanConfirmed,
    "Completing a bounded tail must not clear the loss of its unseen prefix");
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
Check(snapshot.Unavailable && boundaryTask.Unconfirmed && !boundaryTask.PlanConfirmed &&
    boundaryTask.Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
    "A boundary-aligned tail must preserve complete names but remain unconfirmed after an unseen prefix");
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
var disconnectBoundedSource = new ClaudeFileSource(bounded, null, DateTime.MinValue.ToUniversalTime());
Check(disconnectBoundedSource.Poll(ClaudeConnection.Connected, now).Tasks.Single().Steps.Length == 129,
    "Disconnect retention setup must contain all 129 observed names");
_ = disconnectBoundedSource.Poll(ClaudeConnection.Disconnected, now);
var disconnectBounded = disconnectBoundedSource.Poll(ClaudeConnection.Connected, now).Tasks.Single();
Check(disconnectBounded.Unconfirmed && disconnectBounded.RetainedPlanIncomplete && disconnectBounded.Steps.Length == 128,
    "Disconnect must preserve only bounded names and flag the truncated plan");
var boundedSource = new ClaudeFileSource(bounded, null, DateTime.MinValue.ToUniversalTime());
Check(boundedSource.Poll(ClaudeConnection.Connected, now).Tasks.Single().Steps.Length == 129, "Bounded setup has 129 observed names");
string manyEvent = JsonSerializer.Serialize(new Dictionary<string, object> { ["session_id"] = "many",
    ["timestamp"] = now.AddMilliseconds(-1).ToString("O"), ["event"] = "PreToolUse", ["tool_name"] = "Read", ["active"] = true }) + "\n";
int manySplit = manyEvent.Length / 2;
File.AppendAllText(bounded, manyEvent[..manySplit], utf8);
snapshot = boundedSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Single().Unconfirmed && snapshot.Tasks.Single().RetainedPlanIncomplete &&
    snapshot.Tasks.Single().Steps.Length == 128 && snapshot.Tasks.Single().Steps.All(x => x.status == "unknown"),
    "A pending plan exceeding the title limit must expose incomplete retention");
File.AppendAllText(bounded, manyEvent[manySplit..], utf8);
snapshot = boundedSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Single().Unconfirmed && snapshot.Tasks.Single().RetainedPlanIncomplete,
    "Title retention overflow must remain visible after the tail completes");
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
