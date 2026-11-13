using System.Reflection;
using System.Text;
using System.Text.Json;
using AITaskMonitor.CodexDiscovery;
using AITaskMonitor.CodexSource;
using AITaskMonitor.CodexState;

if (args.Length != 1 || !Path.IsPathFullyQualified(args[0]))
    throw new ArgumentException("Provide one existing absolute synthetic test directory.");
string root = Path.GetFullPath(args[0]);
if (!Directory.Exists(root)) throw new ArgumentException("The synthetic test directory must already exist.");
foreach (string key in new[] { "USERPROFILE", "APPDATA", "LOCALAPPDATA", "HOME", "CODEX_HOME" })
{
    string? value = Environment.GetEnvironmentVariable(key);
    if (string.IsNullOrWhiteSpace(value)) continue;
    if (!Path.IsPathFullyQualified(value)) throw new ArgumentException("A protected directory is not absolute.");
    string protectedPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
    string candidate = Path.TrimEndingDirectorySeparator(root);
    if (candidate.Equals(protectedPath, StringComparison.OrdinalIgnoreCase) ||
        candidate.StartsWith(protectedPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        throw new ArgumentException("The synthetic directory must be outside protected directories.");
}
for (DirectoryInfo? item = new(root); item is not null; item = item.Parent)
    if ((item.Attributes & FileAttributes.ReparsePoint) != 0)
        throw new ArgumentException("The synthetic directory cannot have a reparse-point ancestor.");
string fixtureRoot = Path.Combine(root, "codex-source-fixture-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(fixtureRoot);

int assertions = 0;
void Check(bool condition, string message)
{
    assertions++;
    if (!condition) throw new InvalidOperationException(message);
}
CodexSourceTask Get(CodexSourceSnapshot snapshot, string id) => snapshot.Tasks.Single(task => task.Id == id);
void Active(CodexSourceSnapshot snapshot, string id) =>
    Check(Get(snapshot, id).State is { Status: ThreadStatus.Active, Unconfirmed: false }, "Expected synthetic active state.");
void Unknown(CodexSourceSnapshot snapshot, string id) =>
    Check(Get(snapshot, id).State is { Status: ThreadStatus.Unknown, Unconfirmed: true }, "Expected synthetic unconfirmed state.");
void Hidden(CodexSourceSnapshot snapshot, string id) =>
    Check(snapshot.Tasks.All(task => task.Id != id), "An unconfirmed synthetic session was shown as confirmed.");

Check(!typeof(CodexSourceController).IsPublic, "The incomplete controller can be linked by the application.");
var basic = new Fixture(fixtureRoot);
CodexSourceSnapshot first = basic.Controller.Refresh([]);
Check(!first.Incomplete && first.Tasks.Count == 2, "Two synthetic sessions were not found.");
Active(first, "alpha"); Active(first, "beta");
Check(Get(first, "alpha").Title == "Synthetic alpha", "The synthetic index title was not retained.");
Check(!Get(first, "alpha").ToString().Contains("alpha", StringComparison.OrdinalIgnoreCase), "Task diagnostics exposed an ID.");
Check(!first.ToString().Contains("Synthetic", StringComparison.Ordinal), "Source diagnostics exposed a title.");
Check(!Get(first, "alpha").State.ToString().Contains("turn-a", StringComparison.Ordinal), "State diagnostics exposed a turn ID.");
Check(!Get(first, "alpha").State.ToString().Contains("2026", StringComparison.Ordinal), "State diagnostics exposed a timestamp.");

File.AppendAllText(basic.Alpha, Fixture.Line("task_complete", "turn-a", "2026-01-02T00:00:01Z"), new UTF8Encoding(false));
CodexSourceSnapshot completed = basic.Controller.Refresh([]);
Check(!completed.Incomplete && completed.Tasks.Count == 1, "A completed session was not removed.");
Hidden(completed, "alpha"); Active(completed, "beta");
File.AppendAllText(basic.Alpha, Fixture.Line("turn_started", "turn-c", "2026-01-02T00:00:02Z"), new UTF8Encoding(false));
CodexSourceSnapshot newTurn = basic.Controller.Refresh([]);
Check(!newTurn.Incomplete && newTurn.Tasks.Count == 2, "A continuous new turn was not observed.");
Active(newTurn, "alpha"); Active(newTurn, "beta");

var aborted = new Fixture(fixtureRoot);
Check(aborted.Controller.Refresh([]).Tasks.Count == 2, "Abort fixture did not start.");
File.AppendAllText(aborted.Alpha, Fixture.Line("turn_aborted", "turn-a", "2026-01-02T00:00:01Z"), Fixture.Utf8);
CodexSourceSnapshot interrupted = aborted.Controller.Refresh([]);
Check(!interrupted.Incomplete && interrupted.Tasks.Count == 1, "A supported interruption was not removed.");
Hidden(interrupted, "alpha"); Active(interrupted, "beta");

var terminalAnchor = new Fixture(fixtureRoot);
Check(terminalAnchor.Controller.Refresh([]).Tasks.Count == 2, "Terminal-anchor fixture did not start.");
byte[] oldStart = File.ReadAllBytes(terminalAnchor.Alpha);
File.AppendAllText(terminalAnchor.Alpha, Fixture.Line("task_complete", "turn-a", "2026-01-02T00:00:01Z"), new UTF8Encoding(false));
Hidden(terminalAnchor.Controller.Refresh([]), "alpha");
File.WriteAllBytes(terminalAnchor.Alpha, oldStart);
CodexSourceSnapshot replayed = terminalAnchor.Controller.Refresh([]);
Check(replayed.Incomplete, "Loss after a terminal was not reported.");
Hidden(replayed, "alpha"); Active(replayed, "beta");

foreach ((string terminalType, string repeatedId) in new[]
{
    ("task_complete", "turn-a"),
    ("turn_aborted", "TURN-A")
})
{
    var sameBatch = new Fixture(fixtureRoot);
    Check(sameBatch.Controller.Refresh([]).Tasks.Count == 2, "Repeated-turn fixture did not start.");
    File.AppendAllText(sameBatch.Alpha,
        Fixture.Line(terminalType, "turn-a", "2026-01-02T00:00:01Z") +
        Fixture.Line("task_started", repeatedId, "2026-01-02T00:00:02Z"), Fixture.Utf8);
    Check(BoundedJournalReader.Read(sameBatch.Alpha, "alpha", Fixture.Clock) is null,
        "The journal reader accepted a previously closed turn.");
    CodexSourceSnapshot repeated = sameBatch.Controller.Refresh([]);
    Check(repeated.Incomplete, "A previously closed turn was accepted again.");
    Unknown(repeated, "alpha"); Active(repeated, "beta");

    var separateBatch = new Fixture(fixtureRoot);
    Check(separateBatch.Controller.Refresh([]).Tasks.Count == 2, "Separate repeated-turn fixture did not start.");
    File.AppendAllText(separateBatch.Alpha,
        Fixture.Line(terminalType, "turn-a", "2026-01-02T00:00:01Z"), Fixture.Utf8);
    CodexSourceSnapshot closed = separateBatch.Controller.Refresh([]);
    Check(!closed.Incomplete, "A valid terminal was rejected.");
    Hidden(closed, "alpha"); Active(closed, "beta");
    File.AppendAllText(separateBatch.Alpha,
        Fixture.Line("task_started", repeatedId, "2026-01-02T00:00:02Z"), Fixture.Utf8);
    CodexSourceSnapshot afterClosed = separateBatch.Controller.Refresh([]);
    Check(afterClosed.Incomplete, "A previously observed closed turn was accepted again.");
    Hidden(afterClosed, "alpha"); Active(afterClosed, "beta");
}

var unseenAnchor = new Fixture(fixtureRoot, "2025-12-31T23:59:59Z");
CodexSourceSnapshot unseen = unseenAnchor.Controller.Refresh([]);
Check(!unseen.Incomplete, "A supported old session made the source incomplete.");
Hidden(unseen, "alpha"); Active(unseen, "beta");
File.WriteAllText(unseenAnchor.Alpha, Fixture.Meta("alpha") + Fixture.Line("task_started", "turn-a"), Fixture.Utf8);
CodexSourceSnapshot changedUnseen = unseenAnchor.Controller.Refresh([]);
Check(changedUnseen.Incomplete, "An unobserved session lost its anchor.");
Hidden(changedUnseen, "alpha"); Active(changedUnseen, "beta");

var lockFailure = new Fixture(fixtureRoot);
Check(lockFailure.Controller.Refresh([]).Tasks.Count == 2, "Lock fixture did not start.");
lockFailure.Locks["alpha"] = LockObservation.Unavailable;
CodexSourceSnapshot missingLock = lockFailure.Controller.Refresh([]);
Check(missingLock.Incomplete, "An unavailable lock was not reported.");
Unknown(missingLock, "alpha"); Active(missingLock, "beta");
lockFailure.Locks["alpha"] = LockObservation.Held;
CodexSourceSnapshot unchangedLock = lockFailure.Controller.Refresh([]);
Check(unchangedLock.Incomplete, "Unavailable lock was silently cleared.");
Unknown(unchangedLock, "alpha"); Active(unchangedLock, "beta");
File.AppendAllText(lockFailure.Alpha,
    Fixture.Line("task_complete", "turn-a", "2026-01-02T00:00:01Z") +
    Fixture.Line("task_started", "turn-c", "2026-01-02T00:00:02Z"), Fixture.Utf8);
CodexSourceSnapshot apparentNewTurn = lockFailure.Controller.Refresh([]);
Check(apparentNewTurn.Incomplete, "An unverified new turn cleared lock uncertainty.");
Unknown(apparentNewTurn, "alpha"); Active(apparentNewTurn, "beta");

var freeLock = new Fixture(fixtureRoot);
Check(freeLock.Controller.Refresh([]).Tasks.Count == 2, "Free-lock fixture did not start.");
freeLock.Locks["alpha"] = LockObservation.Free;
CodexSourceSnapshot released = freeLock.Controller.Refresh([]);
Check(released.Incomplete, "A changed lock observation was not marked uncertain.");
Unknown(released, "alpha"); Active(released, "beta");
freeLock.Locks["alpha"] = LockObservation.Held;
CodexSourceSnapshot reacquired = freeLock.Controller.Refresh([]);
Check(reacquired.Incomplete, "A reacquired lock confirmed an old turn.");
Unknown(reacquired, "alpha"); Active(reacquired, "beta");

var indexFailure = new Fixture(fixtureRoot);
Check(indexFailure.Controller.Refresh([]).Tasks.Count == 2, "Index fixture did not start.");
using (var occupied = new FileStream(indexFailure.Index, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
{
    CodexSourceSnapshot lost = indexFailure.Controller.Refresh([]);
    Check(lost.Incomplete && lost.Tasks.Count == 2, "An unavailable index lost synthetic tasks.");
    Unknown(lost, "alpha"); Unknown(lost, "beta");
}
CodexSourceSnapshot afterIndexError = indexFailure.Controller.Refresh([]);
Check(afterIndexError.Incomplete, "An index error was silently cleared.");
Unknown(afterIndexError, "alpha"); Unknown(afterIndexError, "beta");

var firstIndexFailure = new Fixture(fixtureRoot);
using (var occupied = new FileStream(firstIndexFailure.Index, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
{
    CodexSourceSnapshot lost = firstIndexFailure.Controller.Refresh([]);
    Check(lost.Incomplete && lost.Tasks.Count == 0, "An unavailable initial index was accepted.");
}
CodexSourceSnapshot afterInitialIndexError = firstIndexFailure.Controller.Refresh([]);
Check(afterInitialIndexError.Incomplete && afterInitialIndexError.Tasks.Count == 0,
    "Old starts were confirmed after an initial index error.");

var unsupported = new Fixture(fixtureRoot);
Check(unsupported.Controller.Refresh([]).Tasks.Count == 2, "Unsupported-index fixture did not start.");
string originalIndex = File.ReadAllText(unsupported.Index);
File.WriteAllText(unsupported.Index, originalIndex + "{invalid}\n", Fixture.Utf8);
CodexSourceSnapshot badIndex = unsupported.Controller.Refresh([]);
Check(badIndex.Incomplete, "An unsupported index row was accepted.");
Unknown(badIndex, "alpha"); Unknown(badIndex, "beta");
File.WriteAllText(unsupported.Index, originalIndex, Fixture.Utf8);
CodexSourceSnapshot afterBadIndex = unsupported.Controller.Refresh([]);
Check(afterBadIndex.Incomplete, "An unsupported index row was silently forgotten.");
Unknown(afterBadIndex, "alpha"); Unknown(afterBadIndex, "beta");

var firstJournalFailure = new Fixture(fixtureRoot);
byte[] validInitial = File.ReadAllBytes(firstJournalFailure.Alpha);
File.WriteAllText(firstJournalFailure.Alpha, "{partial", Fixture.Utf8);
CodexSourceSnapshot lostInitialJournal = firstJournalFailure.Controller.Refresh([]);
Check(lostInitialJournal.Incomplete, "An invalid initial journal was accepted.");
Hidden(lostInitialJournal, "alpha"); Active(lostInitialJournal, "beta");
File.WriteAllBytes(firstJournalFailure.Alpha, validInitial);
CodexSourceSnapshot afterInitialJournalError = firstJournalFailure.Controller.Refresh([]);
Check(afterInitialJournalError.Incomplete, "An initial journal error was silently cleared.");
Hidden(afterInitialJournalError, "alpha"); Active(afterInitialJournalError, "beta");

void InvalidAppend(string record, string reason)
{
    var fixture = new Fixture(fixtureRoot);
    Check(fixture.Controller.Refresh([]).Tasks.Count == 2, reason + ": fixture did not start.");
    File.AppendAllText(fixture.Alpha, record, Fixture.Utf8);
    CodexSourceSnapshot invalid = fixture.Controller.Refresh([]);
    Check(invalid.Incomplete, reason + ": invalid record was accepted.");
    Unknown(invalid, "alpha"); Active(invalid, "beta");
}
InvalidAppend(Fixture.Raw("task_complete", ",\"turn_id\":\"turn-a\"").TrimEnd('\n'), "complete terminal without newline");
InvalidAppend("{invalid}\n", "malformed record");
InvalidAppend(Fixture.Line("task_complete", "turn-a", "2026-01-01T23:59:59Z"), "decreasing timestamp");
InvalidAppend(Fixture.Line("task_complete", "turn-a", "2026-01-02T01:00:00+01:00"), "equal timestamp in another zone");
InvalidAppend(Fixture.Raw("task_complete", ""), "terminal without turn ID");
InvalidAppend(Fixture.Raw("task_complete", ",\"turn_id\":null"), "terminal with null turn ID");
InvalidAppend(Fixture.Raw("task_complete", ",\"turn_id\":\"turn-other\""), "terminal with mismatched turn ID");
InvalidAppend(Fixture.Raw("turn_aborted", ""), "abort without turn ID");
InvalidAppend(Fixture.Raw("turn_aborted", ",\"turn_id\":null"), "abort with null turn ID");
InvalidAppend(Fixture.Raw("task_complete", ",\"turn_id\":\"turn-a\",\"error\":\"failed\""), "terminal error");
InvalidAppend("{\"timestamp\":\"2026-01-02T00:00:01Z\",\"type\":\"unknown_lifecycle\",\"payload\":{\"turn_id\":\"turn-a\"}}\n", "unknown top-level record");
InvalidAppend("{\"type\":\"token_usage_record\",\"payload\":null}\n", "invalid token-usage payload");
InvalidAppend("{\"timestamp\":\"2026-01-02T00:00:01Z\",\"type\":\"event_msg\",\"Type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-a\"}}\n", "case-colliding record type");
InvalidAppend("{\"timestamp\":\"2026-01-02T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"Type\":\"task_complete\",\"turn_id\":\"turn-a\"}}\n", "case-colliding event type");
InvalidAppend("{\"timestamp\":\"2026-01-02T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-a\"},\"Payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-a\"}}\n", "case-colliding payload");
InvalidAppend("{\"timestamp\":\"2026-01-02T00:00:01Z\",\"Timestamp\":\"2026-01-02T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-a\"}}\n", "case-colliding timestamp");
InvalidAppend("{\"timestamp\":\"2026-01-02T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-a\",\"Turn_Id\":\"turn-a\"}}\n", "case-colliding turn ID");

var collisionControl = new Fixture(fixtureRoot);
Check(collisionControl.Controller.Refresh([]).Tasks.Count == 2, "Collision-control fixture did not start.");
File.AppendAllText(collisionControl.Alpha,
    Fixture.Raw("task_complete", ",\"turn_id\":\"turn-a\""), Fixture.Utf8);
CodexSourceSnapshot ordinaryTerminal = collisionControl.Controller.Refresh([]);
Check(!ordinaryTerminal.Incomplete, "A later terminal without collisions was rejected.");
Hidden(ordinaryTerminal, "alpha"); Active(ordinaryTerminal, "beta");

var validNullError = new Fixture(fixtureRoot);
Check(validNullError.Controller.Refresh([]).Tasks.Count == 2, "Null-error fixture did not start.");
File.AppendAllText(validNullError.Alpha,
    Fixture.Raw("task_complete", ",\"turn_id\":\"turn-a\",\"error\":null"), Fixture.Utf8);
CodexSourceSnapshot nullError = validNullError.Controller.Refresh([]);
Check(!nullError.Incomplete, "A null terminal error was rejected.");
Hidden(nullError, "alpha"); Active(nullError, "beta");

var unknownType = new Fixture(fixtureRoot, "2025-12-31T23:59:59Z");
CodexSourceSnapshot old = unknownType.Controller.Refresh([]);
Hidden(old, "alpha"); Active(old, "beta");
File.AppendAllText(unknownType.Alpha, Fixture.Raw("unrecognized_service_event", ",\"turn_id\":\"turn-a\""), Fixture.Utf8);
CodexSourceSnapshot unknownEvent = unknownType.Controller.Refresh([]);
Check(unknownEvent.Incomplete, "An unknown service event was accepted.");
Hidden(unknownEvent, "alpha"); Active(unknownEvent, "beta");

foreach (string badTimestamp in new[] { "2026-01-02T00:00:00", "2026-01-04T00:00:00Z" })
{
    var fixture = new Fixture(fixtureRoot, badTimestamp);
    CodexSourceSnapshot invalid = fixture.Controller.Refresh([]);
    Check(invalid.Incomplete, "An ambiguous or future timestamp was accepted.");
    Hidden(invalid, "alpha"); Active(invalid, "beta");
}
var zoneBoundary = new Fixture(fixtureRoot, "2026-01-03T03:00:00+03:00");
CodexSourceSnapshot boundary = zoneBoundary.Controller.Refresh([]);
Check(!boundary.Incomplete, "A timestamp exactly at the supplied clock was rejected.");
Active(boundary, "alpha"); Active(boundary, "beta");
var zoneOrder = new Fixture(fixtureRoot);
Check(zoneOrder.Controller.Refresh([]).Tasks.Count == 2, "Time-zone ordering fixture did not start.");
File.AppendAllText(zoneOrder.Alpha,
    Fixture.Line("task_complete", "turn-a", "2026-01-01T19:00:01-05:00"), Fixture.Utf8);
CodexSourceSnapshot orderedZone = zoneOrder.Controller.Refresh([]);
Check(!orderedZone.Incomplete, "A later UTC instant in another time zone was rejected.");
Hidden(orderedZone, "alpha"); Active(orderedZone, "beta");

foreach (string rawTurn in new[] { "", ",\"turn_id\":null" })
{
    var fixture = new Fixture(fixtureRoot);
    File.WriteAllText(fixture.Alpha, Fixture.Meta("alpha") + Fixture.Raw("task_started", rawTurn), Fixture.Utf8);
    CodexSourceSnapshot invalid = fixture.Controller.Refresh([]);
    Check(invalid.Incomplete, "A start without a turn ID was accepted.");
    Hidden(invalid, "alpha"); Active(invalid, "beta");
}

var invalidUtf8 = new Fixture(fixtureRoot);
const string invalidMarker = "SYNTHETIC_INVALID_BYTES";
string utf8Fixture = Fixture.UsageRecord(invalidMarker);
int invalidPosition = utf8Fixture.IndexOf(invalidMarker, StringComparison.Ordinal);
Check(invalidPosition >= 0, "The invalid UTF-8 marker is absent.");
using (var stream = new FileStream(invalidUtf8.Alpha, FileMode.Append, FileAccess.Write, FileShare.Read))
{
    stream.Write(Fixture.Utf8.GetBytes(utf8Fixture[..invalidPosition]));
    stream.WriteByte(0xFF);
    stream.Write(Fixture.Utf8.GetBytes(utf8Fixture[(invalidPosition + invalidMarker.Length)..]));
}
CodexSourceSnapshot invalidBytes = invalidUtf8.Controller.Refresh([]);
Check(invalidBytes.Incomplete, "Invalid UTF-8 was accepted.");
Hidden(invalidBytes, "alpha"); Active(invalidBytes, "beta");

var validUtf8 = new Fixture(fixtureRoot);
File.AppendAllText(validUtf8.Alpha, Fixture.UsageRecord("\uFFFD"), Fixture.Utf8);
CodexSourceSnapshot validBytes = validUtf8.Controller.Refresh([]);
Check(!validBytes.Incomplete, "A small valid token-usage record was rejected.");
Active(validBytes, "alpha"); Active(validBytes, "beta");
var oldStartWithUsage = new Fixture(fixtureRoot, "2025-12-31T23:59:59Z");
File.AppendAllText(oldStartWithUsage.Alpha, Fixture.UsageRecord("small"), Fixture.Utf8);
CodexSourceSnapshot oldWithUsage = oldStartWithUsage.Controller.Refresh([]);
Check(!oldWithUsage.Incomplete, "A supported token-usage record made the source incomplete.");
Hidden(oldWithUsage, "alpha"); Active(oldWithUsage, "beta");

var oversize = new Fixture(fixtureRoot);
File.AppendAllText(oversize.Alpha,
    Fixture.UsageRecord(new string('x', 1_048_577)), Fixture.Utf8);
CodexSourceSnapshot large = oversize.Controller.Refresh([]);
Check(large.Incomplete, "An oversized journal was accepted.");
Hidden(large, "alpha"); Active(large, "beta");

var replaced = new Fixture(fixtureRoot);
Check(replaced.Controller.Refresh([]).Tasks.Count == 2, "Replacement fixture did not start.");
string replacement = Fixture.Meta("alpha") + Fixture.Line("task_started", "turn-x");
Check(Encoding.UTF8.GetByteCount(replacement) == new FileInfo(replaced.Alpha).Length,
    "The same-length replacement fixture is invalid.");
File.WriteAllText(replaced.Alpha, replacement, Fixture.Utf8);
CodexSourceSnapshot changed = replaced.Controller.Refresh([]);
Check(changed.Incomplete, "A changed same-length journal was accepted.");
Unknown(changed, "alpha"); Active(changed, "beta");

var missingIdentity = new Fixture(fixtureRoot);
File.WriteAllText(missingIdentity.Alpha, Fixture.Line("task_started", "turn-a"), Fixture.Utf8);
CodexSourceSnapshot noIdentity = missingIdentity.Controller.Refresh([]);
Check(noIdentity.Incomplete, "A journal without session identity was accepted.");
Hidden(noIdentity, "alpha"); Active(noIdentity, "beta");
var collisionIdentity = new Fixture(fixtureRoot);
File.WriteAllText(collisionIdentity.Alpha,
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"alpha\",\"Id\":\"alpha\"}}\n" + Fixture.Line("task_started", "turn-a"), Fixture.Utf8);
CodexSourceSnapshot identityCollision = collisionIdentity.Controller.Refresh([]);
Check(identityCollision.Incomplete, "A case-colliding session identity was accepted.");
Hidden(identityCollision, "alpha"); Active(identityCollision, "beta");

string conflictRoot = Path.Combine(fixtureRoot, Guid.NewGuid().ToString("N"));
string conflictSessions = Path.Combine(conflictRoot, "sessions");
Directory.CreateDirectory(conflictSessions);
string conflictIndex = Path.Combine(conflictRoot, "index.jsonl");
string conflictAlpha = Path.Combine(conflictSessions, "rollout-alpha.jsonl");
string conflictOther = Path.Combine(conflictSessions, "rollout-beta-alpha.jsonl");
File.WriteAllText(conflictIndex, "{\"id\":\"alpha\",\"thread_name\":\"Alpha\"}\n" +
    "{\"id\":\"beta-alpha\",\"thread_name\":\"Beta\"}\n", Fixture.Utf8);
File.WriteAllText(conflictAlpha, Fixture.Meta("alpha") + Fixture.Line("task_started", "turn-a"), Fixture.Utf8);
File.WriteAllText(conflictOther, Fixture.Meta("beta-alpha") + Fixture.Line("task_started", "turn-b"), Fixture.Utf8);
var conflict = new CodexSourceController(conflictIndex, conflictSessions, _ => LockObservation.Held,
    Fixture.Started, () => Fixture.Clock, fileSystem: new OrderedFiles(conflictOther, conflictAlpha));
CodexSourceSnapshot distinct = conflict.Refresh([]);
Check(distinct.Incomplete, "A suffix collision was not reported.");
Hidden(distinct, "alpha"); Active(distinct, "beta-alpha");

var ghost = new Fixture(fixtureRoot);
Check(ghost.Controller.Refresh([]).Tasks.Count == 2, "Missing-ID fixture did not start.");
CodexSourceSnapshot missing = ghost.Controller.Refresh(["ghost"]);
Check(missing.Incomplete, "A lock ID absent from the index was ignored.");
Active(missing, "alpha"); Active(missing, "beta");
for (int i = 0; i < 140; i++)
{
    CodexSourceSnapshot many = ghost.Controller.Refresh(["ghost" + i]);
    Check(many.Incomplete, "A missing ID was reported complete.");
    Active(many, "alpha"); Active(many, "beta");
}
FieldInfo lostField = typeof(CodexSourceController).GetField("lostIds", BindingFlags.Instance | BindingFlags.NonPublic)
    ?? throw new InvalidOperationException("Synthetic loss-bound state is unavailable.");
var lostIds = (HashSet<string>)(lostField.GetValue(ghost.Controller) ?? throw new InvalidOperationException());
Check(lostIds.Count <= 128, "Loss tracking grew without a bound.");

var limits = new Fixture(fixtureRoot);
Check(limits.Controller.Refresh([]).Tasks.Count == 2, "Limit fixture did not start.");
CodexSourceSnapshot tooMany = limits.Controller.Refresh(Enumerable.Range(0, 129).Select(value => "item" + value));
Check(tooMany.Incomplete && tooMany.Tasks.Count == 2, "Too many synthetic lock IDs were not reported.");
Active(tooMany, "alpha"); Active(tooMany, "beta");

var clockFailure = new Fixture(fixtureRoot);
Check(clockFailure.Controller.Refresh([]).Tasks.Count == 2, "Clock fixture did not start.");
clockFailure.Now = Fixture.Started.AddSeconds(-1);
CodexSourceSnapshot backwards = clockFailure.Controller.Refresh([]);
Check(backwards.Incomplete, "A backward clock was accepted.");
Unknown(backwards, "alpha"); Unknown(backwards, "beta");
clockFailure.Now = Fixture.Clock;
CodexSourceSnapshot afterClock = clockFailure.Controller.Refresh([]);
Check(afterClock.Incomplete, "A backward clock was silently forgotten.");
Unknown(afterClock, "alpha"); Unknown(afterClock, "beta");

var midClockFailure = new Fixture(fixtureRoot);
Check(midClockFailure.Controller.Refresh([]).Tasks.Count == 2, "Clock-regression fixture did not start.");
midClockFailure.Now = Fixture.Clock.AddSeconds(-1);
CodexSourceSnapshot midBackward = midClockFailure.Controller.Refresh([]);
Check(midBackward.Incomplete, "A clock regression after monitor start was accepted.");
Unknown(midBackward, "alpha"); Unknown(midBackward, "beta");
midClockFailure.Now = Fixture.Clock;
CodexSourceSnapshot afterMidBackward = midClockFailure.Controller.Refresh([]);
Check(afterMidBackward.Incomplete, "A clock regression was silently cleared.");
Unknown(afterMidBackward, "alpha"); Unknown(afterMidBackward, "beta");

var forwardClock = new Fixture(fixtureRoot);
Check(forwardClock.Controller.Refresh([]).Tasks.Count == 2, "Forward-clock fixture did not start.");
forwardClock.Now = Fixture.Clock.AddSeconds(1);
CodexSourceSnapshot advancedClock = forwardClock.Controller.Refresh([]);
Check(!advancedClock.Incomplete, "An advancing clock was rejected.");
Active(advancedClock, "alpha"); Active(advancedClock, "beta");

Console.WriteLine($"Codex source integration: {assertions} synthetic assertions passed.");

sealed class Fixture
{
    internal static readonly UTF8Encoding Utf8 = new(false);
    internal static readonly DateTimeOffset Started = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    internal static readonly DateTimeOffset Clock = new(2026, 1, 3, 0, 0, 0, TimeSpan.Zero);
    internal string Index { get; }
    internal string Alpha { get; }
    internal string Beta { get; }
    internal DateTimeOffset Now { get; set; } = Clock;
    internal Dictionary<string, LockObservation> Locks { get; } = new(StringComparer.OrdinalIgnoreCase)
    {
        ["alpha"] = LockObservation.Held,
        ["beta"] = LockObservation.Held
    };
    internal CodexSourceController Controller { get; }

    internal Fixture(string root, string alphaTimestamp = "2026-01-02T00:00:00Z")
    {
        string caseRoot = Path.Combine(root, Guid.NewGuid().ToString("N"));
        string sessions = Path.Combine(caseRoot, "sessions");
        Directory.CreateDirectory(sessions);
        Index = Path.Combine(caseRoot, "index.jsonl");
        Alpha = Path.Combine(sessions, "rollout-alpha.jsonl");
        Beta = Path.Combine(sessions, "rollout-beta.jsonl");
        File.WriteAllText(Index,
            "{\"id\":\"alpha\",\"thread_name\":\"Synthetic alpha\"}\n" +
            "{\"id\":\"beta\",\"thread_name\":\"Synthetic beta\"}\n", Utf8);
        File.WriteAllText(Alpha, Meta("alpha") + Line("task_started", "turn-a", alphaTimestamp), Utf8);
        File.WriteAllText(Beta, Meta("beta") + Line("turn_started", "turn-b"), Utf8);
        Controller = new CodexSourceController(Index, sessions,
            id => Locks.TryGetValue(id, out LockObservation value) ? value : LockObservation.Unavailable,
            Started, () => Now);
    }

    internal static string Meta(string id) => JsonSerializer.Serialize(new
    {
        type = "session_meta", payload = new { id }
    }) + "\n";

    internal static string Line(string kind, string turn, string timestamp = "2026-01-02T00:00:00Z") => JsonSerializer.Serialize(new
    {
        timestamp, type = "event_msg", payload = new { type = kind, turn_id = turn }
    }) + "\n";

    internal static string Raw(string kind, string turnFields) =>
        "{\"timestamp\":\"2026-01-02T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"" + kind + "\"" + turnFields + "}}\n";

    internal static string UsageRecord(string extra)
    {
        var usage = new
        {
            input_tokens = 0, cached_input_tokens = 0, cache_write_input_tokens = 0,
            output_tokens = 0, reasoning_output_tokens = 0, total_tokens = 0
        };
        return JsonSerializer.Serialize(new
        {
            timestamp = "2026-01-02T00:00:01Z",
            type = "token_usage_record",
            payload = new
            {
                thread_id = "00000000-0000-0000-0000-000000000001",
                turn_id = "turn-a",
                session_id = "00000000-0000-0000-0000-000000000001",
                root_turn_id = "turn-a",
                response_id = "resp_synthetic",
                usage,
                turn_token_usage = usage,
                thread_token_usage = usage,
                test_data = extra
            }
        }) + "\n";
    }
}

sealed class OrderedFiles(params string[] paths) : ISessionFileSystem
{
    public FileAttributes GetAttributes(string path) => File.GetAttributes(path);
    public IEnumerable<string> EnumerateDatedFiles(string directory, string validatedId) => [];
    public IEnumerable<string> EnumerateRecursively(string directory) => paths;
}
