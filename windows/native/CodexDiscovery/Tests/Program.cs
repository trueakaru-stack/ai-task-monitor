using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using AITaskMonitor.CodexDiscovery;

if (args.Length != 1) throw new ArgumentException("Expected an isolated test directory.");
string work = Path.GetFullPath(args[0]);
string input = Console.In.ReadToEnd();
var cases = JsonSerializer.Deserialize<List<ReferenceCase>>(input, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
    ?? throw new InvalidOperationException("Reference fixtures are missing.");
if (cases.Count < 6) throw new InvalidOperationException("Reference fixture set is incomplete.");
int assertions = 0, lookups = 0;
void Check(bool condition, string message) { assertions++; if (!condition) throw new InvalidOperationException(message); }
void Equal<T>(T expected, T actual, string message) => Check(EqualityComparer<T>.Default.Equals(expected, actual),
    $"{message}: expected {expected}, got {actual}");
void ExpectUnavailable(Action action, string message)
{
    try { action(); throw new InvalidOperationException(message + ": source error was not reported"); }
    catch (SessionDiscoveryUnavailableException) { assertions++; }
}

foreach (ReferenceCase scenario in cases)
{
    string root = Path.Combine(work, "reference-replay", scenario.Name, "sessions");
    var clock = new FakeClock();
    var discovery = new SessionDiscovery(root, clock);
    foreach (ReferenceStep step in scenario.Steps)
    {
        string relative = step.Path ?? "";
        string path = Path.Combine(root, relative);
        string context = scenario.Name + " / " + step.Operation + " / " + (step.Id ?? relative);
        switch (step.Operation)
        {
            case "root": if (step.Present) Directory.CreateDirectory(root); break;
            case "mkdir": Directory.CreateDirectory(path); break;
            case "write":
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, "{}\n");
                break;
            case "attributes":
                FileAttributes attribute = Enum.Parse<FileAttributes>(step.Attributes ?? throw new InvalidOperationException(context));
                File.SetAttributes(path, File.GetAttributes(path) | attribute);
                Check((File.GetAttributes(path) & attribute) != 0, context + " synthetic attribute");
                break;
            case "move":
                string destination = Path.Combine(root, step.Target ?? throw new InvalidOperationException(context));
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.Move(path, destination);
                break;
            case "delete": File.Delete(path); break;
            case "advance": clock.Advance(step.Seconds); break;
            case "cycle":
                SessionIndexEntry[] entries = (step.Entries ?? []).Select(entry => new SessionIndexEntry(entry.Id, entry.Version,
                    string.IsNullOrEmpty(entry.Date) ? null : DateOnly.ParseExact(entry.Date, "yyyy-MM-dd", CultureInfo.InvariantCulture))).ToArray();
                discovery.BeginCycle(entries);
                Equal(step.Retry, discovery.Diagnostics().RetrySeconds, context + " retry");
                break;
            case "find":
                lookups++;
                int scans = discovery.Diagnostics().RecursiveScans;
                string? result = null; bool failed = false;
                try { result = discovery.Find(step.Id ?? throw new InvalidOperationException(context)); }
                catch (SessionDiscoveryUnavailableException) { failed = true; }
                string actual = result is null ? "" : Path.GetRelativePath(root, result);
                Equal(step.Error, failed, context + " unavailable");
                Equal(step.Result ?? "", actual, context + " path");
                Equal(step.Scanned, scans != discovery.Diagnostics().RecursiveScans, context + " scan");
                Equal(step.Retry, discovery.Diagnostics().RetrySeconds, context + " retry");
                break;
            default: throw new InvalidOperationException("Unknown reference fixture action.");
        }
    }
}

string independent = Path.Combine(work, "independent");
Directory.CreateDirectory(independent);
string safeRoot = Path.Combine(independent, "validation"); Directory.CreateDirectory(safeRoot);
var safeFiles = new CountingFileSystem();
var safe = new SessionDiscovery(safeRoot, new FakeClock(), safeFiles);
foreach (string invalid in new[] { "", "../outside", "a/b", "a\\b", "a*", "a?", "a:b", ".", "кодекс", new string('a', 129), "id\n" })
{
    try { safe.Find(invalid); throw new InvalidOperationException("An invalid session ID was accepted."); }
    catch (ArgumentException) { assertions++; }
}
try { safe.BeginCycle([new SessionIndexEntry("valid", "v1"), new SessionIndexEntry("../bad", "v1")]);
    throw new InvalidOperationException("An invalid index ID was accepted."); }
catch (ArgumentException) { assertions++; }
Equal(0, safeFiles.AttributesCalls, "invalid IDs did not reach filesystem");
Equal(0, safe.Diagnostics().DatedMissCount, "invalid cycle did not modify discovery state");

string unicodeRoot = Path.Combine(independent, "профиль 🌿");
string unicodeDate = Path.Combine(unicodeRoot, "2026", "11", "05"); Directory.CreateDirectory(unicodeDate);
string unicodeFile = Path.Combine(unicodeDate, "rollout-unicode.jsonl"); File.WriteAllText(unicodeFile, "{}");
var unicodeDiscovery = new SessionDiscovery(unicodeRoot, new FakeClock());
unicodeDiscovery.BeginCycle([new SessionIndexEntry("unicode", "v1", new DateOnly(2026, 11, 5))]);
Equal(unicodeFile, unicodeDiscovery.Find("unicode"), "Unicode source path");

string rootDated = Path.Combine(independent, "dated");
string dateFolder = Path.Combine(rootDated, "2026", "11", "05"); Directory.CreateDirectory(dateFolder);
var dateClock = new FakeClock(); var dateFiles = new CountingFileSystem();
var dated = new SessionDiscovery(rootDated, dateClock, dateFiles);
SessionIndexEntry entry = new("one", "v1", new DateOnly(2026, 11, 5));
dated.BeginCycle([entry]);
Equal<string?>(null, dated.Find("one"), "first dated miss");
Equal<string?>(null, dated.Find("one"), "cached dated miss");
Equal(1, dateFiles.DatedCalls, "dated misses share short cache");
Equal(1, dated.Diagnostics().RecursiveScans, "fallback snapshot is shared");
dated.BeginCycle([entry]);
dateFiles.DenyDated = true;
ExpectUnavailable(() => dated.Find("one"), "denied dated folder");
Equal(0, dated.Diagnostics().DatedMissCount, "failed dated lookup is not negatively cached");
dateFiles.DenyDated = false;
string available = Path.Combine(dateFolder, "rollout-one.jsonl"); File.WriteAllText(available, "{}");
Equal(available, dated.Find("one"), "dated folder recovers immediately");
dateFiles.DenyAttributesPath = available;
ExpectUnavailable(() => dated.Find("one"), "denied positive cache file");
dateFiles.DenyAttributesPath = null;
Equal(available, dated.Find("one"), "positive cache recovers after access restored");

string rootClock = Path.Combine(independent, "clock");
Directory.CreateDirectory(Path.Combine(rootClock, "2026", "11", "05"));
var precisionClock = new FakeClock(); var precisionFiles = new CountingFileSystem();
var precision = new SessionDiscovery(rootClock, precisionClock, precisionFiles);
precision.BeginCycle([new SessionIndexEntry("precision", "v1", new DateOnly(2026, 11, 5))]);
Equal<string?>(null, precision.Find("precision"), "precision initial miss");
precisionClock.AdvanceTicks(precisionClock.Frequency - 1);
Equal<string?>(null, precision.Find("precision"), "dated miss just before one second");
Equal(1, precisionFiles.DatedCalls, "dated miss is retained below one second");
precisionClock.AdvanceTicks(1);
Equal<string?>(null, precision.Find("precision"), "dated miss at one second");
Equal(2, precisionFiles.DatedCalls, "dated miss expires at exactly one second");
precisionClock.Advance(-3);
Equal<string?>(null, precision.Find("precision"), "monotonic clock moved backwards");
Equal(3, precisionFiles.DatedCalls, "dated miss does not survive a negative age");
Equal(1, precision.Diagnostics().RecursiveScans, "clock rollback resets scan timestamp instead of scanning immediately");
Equal(5, precision.Diagnostics().RetrySeconds, "clock rollback restores quick retry");

string rootRecursive = Path.Combine(independent, "recursive"); Directory.CreateDirectory(rootRecursive);
File.WriteAllText(Path.Combine(rootRecursive, "rollout-recovered.jsonl"), "{}");
var recursiveClock = new FakeClock(); var recursiveFiles = new CountingFileSystem { DenyRecursive = true };
var recursive = new SessionDiscovery(rootRecursive, recursiveClock, recursiveFiles);
ExpectUnavailable(() => recursive.Find("recovered"), "recursive access failure");
Check(recursive.Diagnostics().ScanFailed, "failed scan should be recorded");
recursiveFiles.DenyRecursive = false;
ExpectUnavailable(() => recursive.Find("recovered"), "failed scan backoff");
Equal(1, recursiveFiles.RecursiveCalls, "failed scan was not immediately repeated");
recursiveClock.Advance(6);
Equal(Path.Combine(rootRecursive, "rollout-recovered.jsonl"), recursive.Find("recovered"), "recursive failure recovery");
Equal(5, recursive.Diagnostics().RetrySeconds, "recovered scan returns to quick retry");

string rootConcurrent = Path.Combine(independent, "concurrent"); Directory.CreateDirectory(rootConcurrent);
for (int i = 0; i < 48; i++) File.WriteAllText(Path.Combine(rootConcurrent, $"rollout-synthetic-{i:D2}.jsonl"), "{}");
var concurrentFiles = new CountingFileSystem { BlockRecursive = true };
var concurrent = new SessionDiscovery(rootConcurrent, new FakeClock(), concurrentFiles);
using var go = new ManualResetEventSlim(false);
Task<string?>[] jobs = Enumerable.Range(0, 48).Select(i => Task.Factory.StartNew(() =>
{
    if (!go.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Concurrent start timed out.");
    return concurrent.Find($"synthetic-{i:D2}");
}, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default)).ToArray();
go.Set();
Check(concurrentFiles.RecursiveEntered.Wait(TimeSpan.FromSeconds(10)), "recursive scan entered");
using var cycleStarted = new ManualResetEventSlim(false);
Task cycle = Task.Factory.StartNew(() =>
{
    cycleStarted.Set();
    concurrent.BeginCycle([new SessionIndexEntry("new-id", "v1")]);
}, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
try
{
    Check(cycleStarted.Wait(TimeSpan.FromSeconds(10)), "concurrent index refresh started");
    Check(!cycle.Wait(TimeSpan.FromMilliseconds(100)), "index refresh waits for the active discovery scan");
}
finally { concurrentFiles.AllowRecursive.Set(); }
Check(Task.WaitAll(jobs.Cast<Task>().Append(cycle).ToArray(), TimeSpan.FromSeconds(30)), "concurrent lookups finished");
for (int i = 0; i < jobs.Length; i++) Equal(Path.Combine(rootConcurrent, $"rollout-synthetic-{i:D2}.jsonl"), jobs[i].Result, "concurrent lookup");
Equal(1, concurrent.Diagnostics().RecursiveScans, "concurrent lookups use one shared scan");
Equal(1, concurrentFiles.RecursiveCalls, "filesystem observed one shared scan");

// Test a real Windows list-directory denial only on an isolated fixture.
string aclRoot = Path.Combine(independent, "acl");
string aclDate = Path.Combine(aclRoot, "2026", "11", "05"); Directory.CreateDirectory(aclDate);
var aclDiscovery = new SessionDiscovery(aclRoot, new FakeClock());
var aclEntry = new SessionIndexEntry("acl-id", "v1", new DateOnly(2026, 11, 5));
aclDiscovery.BeginCycle([aclEntry]);
Equal<string?>(null, aclDiscovery.Find("acl-id"), "ACL fixture initial miss");
aclDiscovery.BeginCycle([aclEntry]);
var info = new DirectoryInfo(aclDate);
DirectorySecurity original = info.GetAccessControl(AccessControlSections.Access);
DirectorySecurity denied = info.GetAccessControl(AccessControlSections.Access);
using WindowsIdentity identity = WindowsIdentity.GetCurrent();
SecurityIdentifier user = identity.User ?? throw new InvalidOperationException("Current Windows identity is unavailable.");
var denyRule = new FileSystemAccessRule(user, FileSystemRights.ListDirectory, InheritanceFlags.None,
    PropagationFlags.None, AccessControlType.Deny);
string originalAccess = original.GetSecurityDescriptorSddlForm(AccessControlSections.Access);
denied.AddAccessRule(denyRule);
try
{
    info.SetAccessControl(denied);
    ExpectUnavailable(() => aclDiscovery.Find("acl-id"), "real Windows ACL denial");
}
finally
{
    DirectorySecurity restored = info.GetAccessControl(AccessControlSections.Access);
    restored.RemoveAccessRuleSpecific(denyRule);
    info.SetAccessControl(restored);
    string finalAccess = info.GetAccessControl(AccessControlSections.Access).GetSecurityDescriptorSddlForm(AccessControlSections.Access);
    Check(string.Equals(originalAccess, finalAccess, StringComparison.Ordinal), "synthetic ACL was restored exactly");
}
string aclFile = Path.Combine(aclDate, "rollout-acl-id.jsonl"); File.WriteAllText(aclFile, "{}");
Equal(aclFile, aclDiscovery.Find("acl-id"), "real Windows ACL recovery");

Console.WriteLine($"Codex discovery: {cases.Count} reference sequences, {lookups} differential lookups, {assertions} comparisons and assertions passed.");
Console.WriteLine("Independent checks: invalid IDs, short miss cache, injected failures, 48 concurrent lookups, and one real Windows ACL denial/recovery.");

sealed class FakeClock : IDiscoveryClock
{
    public long Frequency => TimeSpan.TicksPerSecond;
    private long ticks = 1_000 * TimeSpan.TicksPerSecond;
    public long GetTimestamp() => Interlocked.Read(ref ticks);
    public void Advance(int seconds) => Interlocked.Add(ref ticks, checked((long)seconds * Frequency));
    public void AdvanceTicks(long value) => Interlocked.Add(ref ticks, value);
}
sealed class CountingFileSystem : ISessionFileSystem
{
    private readonly PhysicalSessionFileSystem inner = new();
    private int attributesCalls, datedCalls, recursiveCalls;
    public int AttributesCalls => Volatile.Read(ref attributesCalls);
    public int DatedCalls => Volatile.Read(ref datedCalls);
    public int RecursiveCalls => Volatile.Read(ref recursiveCalls);
    public bool DenyDated, DenyRecursive, BlockRecursive;
    public string? DenyAttributesPath;
    public ManualResetEventSlim RecursiveEntered { get; } = new(false);
    public ManualResetEventSlim AllowRecursive { get; } = new(false);
    public FileAttributes GetAttributes(string path)
    {
        Interlocked.Increment(ref attributesCalls);
        if (string.Equals(path, DenyAttributesPath, StringComparison.OrdinalIgnoreCase)) throw new UnauthorizedAccessException();
        return inner.GetAttributes(path);
    }
    public IEnumerable<string> EnumerateDatedFiles(string directory, string validatedId)
    {
        Interlocked.Increment(ref datedCalls);
        if (DenyDated) throw new UnauthorizedAccessException();
        return inner.EnumerateDatedFiles(directory, validatedId);
    }
    public IEnumerable<string> EnumerateRecursively(string directory)
    {
        Interlocked.Increment(ref recursiveCalls);
        if (DenyRecursive) throw new UnauthorizedAccessException();
        if (BlockRecursive)
        {
            RecursiveEntered.Set();
            if (!AllowRecursive.Wait(TimeSpan.FromSeconds(20))) throw new TimeoutException("Synthetic scan was not released.");
        }
        return inner.EnumerateRecursively(directory);
    }
}
sealed class ReferenceCase { public string Name { get; set; } = ""; public List<ReferenceStep> Steps { get; set; } = []; }
sealed class ReferenceStep
{
    public string Operation { get; set; } = "";
    public string? Id { get; set; }
    public string? Path { get; set; }
    public string? Target { get; set; }
    public string? Result { get; set; }
    public string? Attributes { get; set; }
    public int Seconds { get; set; }
    public int Retry { get; set; }
    public bool Error { get; set; }
    public bool Scanned { get; set; }
    public bool Present { get; set; }
    public List<ReferenceEntry>? Entries { get; set; }
}
sealed class ReferenceEntry { public string Id { get; set; } = ""; public string Version { get; set; } = ""; public string Date { get; set; } = ""; }
