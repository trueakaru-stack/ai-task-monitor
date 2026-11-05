using System.Text;
using System.Text.Json;
using System.Security.AccessControl;
using System.Security.Principal;
using AITaskMonitor.CodexIndex;

if (args.Length != 2) throw new ArgumentException("Synthetic fixture and output roots are required.");
string fixturePath = Path.GetFullPath(args[0]);
string root = Path.GetFullPath(args[1]);
Directory.CreateDirectory(root);
Fixture[] fixtures = JsonSerializer.Deserialize<Fixture[]>(File.ReadAllText(fixturePath)) ?? throw new InvalidOperationException();
int assertions = 0, reads = 0, unsupported = 0, intentionalDifferences = 0;
string currentCase = "setup";
void Check(bool condition, string message)
{
    assertions++;
    if (!condition) throw new InvalidOperationException(currentCase + ": " + message);
}

foreach (Fixture fixture in fixtures)
{
    currentCase = fixture.Name;
    string caseRoot = Path.Combine(root, fixture.Name);
    Directory.CreateDirectory(caseRoot);
    string path = Path.Combine(caseRoot, "index.jsonl");
    var reader = new CodexIndexReader(path);
    foreach (Step step in fixture.Steps)
    {
        if (step.Operation == "write")
        {
            string content = step.Content ?? "";
            if (content.Contains("__AITM_SYNTHETIC_LIMIT__", StringComparison.Ordinal))
                content = content.Replace("__AITM_SYNTHETIC_LIMIT__", new string('x', 1_048_576), StringComparison.Ordinal);
            if (content.Contains("__AITM_SYNTHETIC_OVERSIZE__", StringComparison.Ordinal))
                content = content.Replace("__AITM_SYNTHETIC_OVERSIZE__", new string('x', 1_048_577), StringComparison.Ordinal);
            File.WriteAllText(path, content, MakeEncoding(step.Encoding ?? ""));
            File.SetLastWriteTimeUtc(path, new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(step.Version));
            continue;
        }
        if (step.Operation != "read") throw new InvalidOperationException("Unknown synthetic operation.");
        reads++;
        CodexIndexReadResult? actual = null;
        bool failed = false;
        try { actual = reader.Read(step.Observed ?? [], step.Held ?? []); }
        catch (CodexIndexUnavailableException) { failed = true; }
        if (step.FailedCacheDivergence)
        {
            // The legacy cache silently returns a negative hit after a failed
            // history scan. This reader keeps the source unavailable.
            Check(!step.Failed && failed, "Failed-history cache behavior changed unexpectedly.");
            intentionalDifferences++;
            continue;
        }
        Check(failed == step.Failed, "Synthetic source availability differs from the reference.");
        if (failed) continue;
        Check(actual is not null && actual.HasUnsupportedRows == step.Unsupported, "Unsupported-row signal is incorrect.");
        var expected = (step.Expected ?? []).ToDictionary(item => item.Id, StringComparer.OrdinalIgnoreCase);
        var found = actual!.Entries.ToDictionary(item => item.Id, StringComparer.OrdinalIgnoreCase);
        if (!step.Unsupported || fixture.Name != "malformed-and-noncanonical")
            Check(expected.Count == found.Count, "Synthetic candidate count differs from the reference.");
        else Check(expected.Count > found.Count, "Noncanonical compatibility difference was not exercised.");
        if (step.Unsupported) unsupported++;
        foreach ((string id, CodexIndexEntry item) in found)
        {
            Check(expected.TryGetValue(id, out Expected? old), "Unexpected synthetic ID.");
            Check(string.Equals(old!.Id, item.Id, StringComparison.Ordinal), "Synthetic ID casing differs.");
            Check(string.Equals(old.Title, item.Title, StringComparison.Ordinal), "Synthetic title differs.");
            Check(string.Equals(old.UpdatedVersion, item.UpdatedVersion, StringComparison.Ordinal), "Synthetic timestamp differs.");
            string? date = item.Date?.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
            Check(string.Equals(old.Date, date, StringComparison.Ordinal), "Synthetic date differs.");
        }
    }
}

// Unavailable source must stay an error and never reveal a path or row.
string isolated = Path.Combine(root, "extra");
currentCase = "extra";
Directory.CreateDirectory(isolated);
string source = Path.Combine(isolated, "index.jsonl");
var missingReader = new CodexIndexReader(source);
try { missingReader.Read([], []); throw new InvalidOperationException("Missing source was accepted."); }
catch (CodexIndexUnavailableException error) { Check(!error.ToString().Contains(source, StringComparison.OrdinalIgnoreCase), "An unavailable exception exposed a path."); }
CheckThrows<ArgumentException>(() => new CodexIndexReader("relative-index.jsonl"), "A relative source was accepted.");

File.WriteAllText(source, "{\"id\":\"safe\",\"thread_name\":\"Synthetic\",\"updated_at\":\"2026-11-05\"}\n", new UTF8Encoding(false));
var lockedReader = new CodexIndexReader(source);
using (var held = new FileStream(source, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
{
    CheckThrows<CodexIndexUnavailableException>(() => lockedReader.Read([], []), "A locked source was treated as empty.");
}
Check(lockedReader.Read([], []).Entries.Count == 1, "A source did not recover after lock release.");
CodexIndexEntry safeEntry = lockedReader.Read([], []).Entries.Single();
Check(!safeEntry.ToString().Contains("safe", StringComparison.OrdinalIgnoreCase) &&
    !safeEntry.ToString().Contains("Synthetic", StringComparison.Ordinal), "Entry diagnostics exposed fixture contents.");
Check(lockedReader.Read(["safe\n"], []).HasUnsupportedRows, "An unsafe legacy-compatible observed ID was not signalled.");
Check(lockedReader.Read([""], []).HasUnsupportedRows, "An empty requested ID was not signalled.");
Check(lockedReader.Read([], [null!]).HasUnsupportedRows, "A missing lock ID was not signalled.");

// Change only the synthetic file's ACL, and restore its exact access list.
var fileInfo = new FileInfo(source);
FileSecurity originalAccess = fileInfo.GetAccessControl(AccessControlSections.Access);
string originalSddl = originalAccess.GetSecurityDescriptorSddlForm(AccessControlSections.Access);
FileSecurity restricted = fileInfo.GetAccessControl(AccessControlSections.Access);
using WindowsIdentity identity = WindowsIdentity.GetCurrent();
SecurityIdentifier user = identity.User ?? throw new InvalidOperationException("The synthetic ACL identity is unavailable.");
var denyRead = new FileSystemAccessRule(user, FileSystemRights.ReadData, AccessControlType.Deny);
restricted.AddAccessRule(denyRead);
bool applied = false;
try
{
    fileInfo.SetAccessControl(restricted);
    applied = true;
    CheckThrows<CodexIndexUnavailableException>(() => lockedReader.Read([], []), "A denied source was treated as empty.");
}
finally
{
    if (applied)
    {
        FileSecurity restored = fileInfo.GetAccessControl(AccessControlSections.Access);
        restored.RemoveAccessRuleSpecific(denyRead);
        fileInfo.SetAccessControl(restored);
        Check(string.Equals(originalSddl, fileInfo.GetAccessControl(AccessControlSections.Access)
            .GetSecurityDescriptorSddlForm(AccessControlSections.Access), StringComparison.Ordinal), "The synthetic ACL was not restored.");
    }
}
Check(lockedReader.Read([], []).Entries.Count == 1, "A source did not recover after ACL restoration.");

// These rows cannot establish that no task exists, even if legacy skips them.
foreach (string row in new[]
{
    "{\"thread_name\":\"Synthetic missing ID\"}",
    "{\"id\":null,\"thread_name\":\"Synthetic null ID\"}",
    "{\"id\":\"\",\"thread_name\":\"Synthetic empty ID\"}",
    "{\"id\":\"../unsafe\",\"thread_name\":\"Synthetic invalid ID\"}",
    "{\"id\":\"" + new string('a', 129) + "\",\"thread_name\":\"Synthetic long ID\"}"
})
{
    File.WriteAllText(source, row + "\n", new UTF8Encoding(false));
    CodexIndexReadResult uncertain = new CodexIndexReader(source).Read([], []);
    Check(uncertain.HasUnsupportedRows && uncertain.Entries.Count == 0, "An unidentified row was treated as a confirmed absence.");
}

// Distinguish corrupt encodings from a legitimate, correctly encoded U+FFFD.
var encodings = new[]
{
    new EncodingCase("utf8", new UTF8Encoding(false, true), new byte[] { 0xff }),
    new EncodingCase("utf8bom", new UTF8Encoding(true, true), new byte[] { 0xff }),
    new EncodingCase("utf8-overlong", new UTF8Encoding(false, true), new byte[] { 0xc0, 0xaf }),
    new EncodingCase("utf8-incomplete", new UTF8Encoding(false, true), new byte[] { 0xe2, 0x82 }),
    new EncodingCase("utf8-surrogate", new UTF8Encoding(false, true), new byte[] { 0xed, 0xa0, 0x80 }),
    new EncodingCase("utf16le", new UnicodeEncoding(false, true, true), new byte[] { 0x00, 0xd8 }),
    new EncodingCase("utf16be", new UnicodeEncoding(true, true, true), new byte[] { 0xd8, 0x00 }),
    new EncodingCase("utf32le", new UTF32Encoding(false, true, true), new byte[] { 0x00, 0x00, 0x11, 0x00 }),
    new EncodingCase("utf32be", new UTF32Encoding(true, true, true), new byte[] { 0x00, 0x11, 0x00, 0x00 })
};
foreach (EncodingCase encodingCase in encodings)
{
    currentCase = "encoding-" + encodingCase.Name;
    string prefix = "{\"id\":\"synthetic\",\"thread_name\":\"before";
    string suffix = "after\",\"updated_at\":\"2026-11-05\"}\n";
    byte[] valid = encodingCase.Encoding.GetPreamble().Concat(
        encodingCase.Encoding.GetBytes(prefix + "\ufffd" + suffix)).ToArray();
    File.WriteAllBytes(source, valid);
    CodexIndexReadResult good = new CodexIndexReader(source).Read([], []);
    Check(!good.HasUnsupportedRows && good.Entries.Single().Title == "before\ufffdafter",
        "A correctly encoded replacement character was not preserved.");

    string filler = string.Concat(Enumerable.Range(0, 55).Select(i =>
        "{\"id\":\"filler-" + i + "\",\"thread_name\":\"Synthetic\"}\n"));
    File.WriteAllBytes(source, valid.Concat(encodingCase.Encoding.GetBytes(filler)).ToArray());
    CodexIndexReadResult goodHistory = new CodexIndexReader(source).Read(["synthetic"], []);
    Check(!goodHistory.HasUnsupportedRows &&
        goodHistory.Entries.Single(item => item.Id == "synthetic").Title == "before\ufffdafter",
        "A correctly encoded replacement character in history was not preserved.");

    byte[] damaged = encodingCase.Encoding.GetPreamble().Concat(encodingCase.Encoding.GetBytes(prefix))
        .Concat(encodingCase.Invalid).Concat(encodingCase.Encoding.GetBytes(suffix)).ToArray();
    File.WriteAllBytes(source, damaged);
    CheckThrows<CodexIndexUnavailableException>(() => new CodexIndexReader(source).Read([], []),
        "A damaged tail encoding was accepted.");

    byte[] damagedHistory = damaged.Concat(encodingCase.Encoding.GetBytes(filler)).ToArray();
    File.WriteAllBytes(source, damagedHistory);
    var historyReader = new CodexIndexReader(source);
    if (encodingCase.Name.StartsWith("utf8", StringComparison.Ordinal))
        Check(historyReader.Read([], []).Entries.Count == 50, "A valid UTF-8 tail after unread damaged history was not readable.");
    else CheckThrows<CodexIndexUnavailableException>(() => historyReader.Read([], []),
        "A wide-encoding forward scan accepted damaged history.");
    CheckThrows<CodexIndexUnavailableException>(() => historyReader.Read(["older"], []),
        "Damaged historical bytes were accepted.");
    CheckThrows<CodexIndexUnavailableException>(() => historyReader.Read(["older"], []),
        "A failed historical decode became a cached absence.");
}
currentCase = "extra";

// The native reader does not apply its history-only limit to a tail row.
// The reference test uses a smaller tail row because WinPS 5.1 is very slow
// on long lines; equivalence at this length is not asserted.
string largeTitle = new('z', 1_048_577);
File.WriteAllText(source, "{\"id\":\"large\",\"thread_name\":\"" + largeTitle +
    "\",\"updated_at\":\"2026-11-05\"}\n", new UTF8Encoding(false));
CodexIndexEntry largeEntry = new CodexIndexReader(source).Read([], []).Entries.Single();
Check(largeEntry.Title.Length == largeTitle.Length, "A valid large tail row was rejected.");

// One reader serializes its cache while callers concurrently use immutable data.
string[] rows = Enumerable.Range(0, 80).Select(i => "{\"id\":\"i-" + i +
    "\",\"thread_name\":\"Synthetic\",\"updated_at\":\"2026-11-05\"}").ToArray();
File.WriteAllLines(source, rows, new UTF8Encoding(false));
var concurrentReader = new CodexIndexReader(source);
var concurrentFailures = new System.Collections.Concurrent.ConcurrentQueue<string>();
Parallel.For(0, 64, _ =>
{
    try
    {
        CodexIndexReadResult result = concurrentReader.Read(["i-0"], []);
        if (result.Entries.Count != 51 || result.HasUnsupportedRows ||
            !result.Entries.Any(entry => entry.Id == "i-0")) concurrentFailures.Enqueue("Unexpected result");
    }
    catch { concurrentFailures.Enqueue("Unexpected failure"); }
});
Check(concurrentFailures.IsEmpty, "Concurrent reader calls disagreed on a stable index.");

// Actual replacement races use only synthetic content. No assertion claims
// that separate tail/history reads form an atomic snapshot.
var writerStart = new ManualResetEventSlim(false);
int replacementRetries = 0;
var writer = Task.Run(() =>
{
    writerStart.Wait();
    for (int i = 0; i < 150; i++)
    {
        string temp = Path.Combine(isolated, "replacement-" + i + ".jsonl");
        string label = i % 2 == 0 ? "Synthetic A" : "Synthetic B";
        File.WriteAllText(temp, "{\"id\":\"racing\",\"thread_name\":\"" + label +
            "\",\"updated_at\":\"2026-11-05\"}\n", new UTF8Encoding(false));
        bool moved = false;
        for (int retry = 0; retry < 100 && !moved; retry++)
        {
            try { File.Move(temp, source, true); moved = true; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                Interlocked.Increment(ref replacementRetries);
                Thread.Sleep(2);
            }
        }
        if (!moved) throw new IOException("The synthetic replacement could not finish.");
    }
});
writerStart.Set();
int raceReads = 0, raceUnavailable = 0;
for (int i = 0; i < 150; i++)
{
    try
    {
        foreach (CodexIndexEntry entry in concurrentReader.Read([], []).Entries)
            Check(entry.Id == "racing" || entry.Id.StartsWith("i-", StringComparison.Ordinal),
                "A replacement race produced an unexpected ID.");
        raceReads++;
    }
    catch (CodexIndexUnavailableException) { raceUnavailable++; }
}
writer.GetAwaiter().GetResult();
Check(raceReads + raceUnavailable == 150, "A replacement-race call did not finish.");
Check(concurrentReader.Read([], []).Entries.Single().Title == "Synthetic B", "The final replacement was not observed.");

Console.WriteLine($"Codex index: {reads} differential reads, {assertions} assertions; " +
    $"{unsupported} unsupported-data reads, {intentionalDifferences} documented failed-cache difference; " +
    $"{encodings.Length} strict-decoder cases in tail/history; " +
    $"150 synthetic replacements ({raceUnavailable} unavailable reads, {replacementRetries} writer retries).");

void CheckThrows<T>(Action action, string message) where T : Exception
{
    bool caught = false;
    try { action(); } catch (T) { caught = true; }
    Check(caught, message);
}

static Encoding MakeEncoding(string name) => name switch
{
    "utf8" => new UTF8Encoding(false),
    "utf8bom" => new UTF8Encoding(true),
    "utf16le" => new UnicodeEncoding(false, true),
    "utf16be" => new UnicodeEncoding(true, true),
    "utf32le" => new UTF32Encoding(false, true),
    "utf32be" => new UTF32Encoding(true, true),
    _ => throw new InvalidOperationException("Unsupported synthetic encoding.")
};

sealed record Fixture(string Name, Step[] Steps);
sealed record Step(string Operation, string? Content, string? Encoding, int Version, string[]? Observed,
    string[]? Held, string[]? Free, bool Failed, Expected[]? Expected, bool Unsupported, bool FailedCacheDivergence);
sealed record Expected(string Id, string Title, string UpdatedVersion, string? Date);
sealed record EncodingCase(string Name, Encoding Encoding, byte[] Invalid);
