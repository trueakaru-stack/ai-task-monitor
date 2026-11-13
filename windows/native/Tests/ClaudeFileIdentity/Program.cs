using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using AITaskMonitor.Claude;
using Microsoft.Win32.SafeHandles;

if (args.Length != 0) throw new ArgumentException("This test accepts no external input.");
if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("The file-identity checks require Windows.");
string work = Directory.CreateTempSubdirectory("aitm-claude-file-identity-").FullName;
using JsonDocument fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "status-retention.synthetic.json")));
string events = fixture.RootElement.GetProperty("complete").GetString()!;
DateTime now = DateTime.Parse(fixture.RootElement.GetProperty("now").GetString()!, null,
    System.Globalization.DateTimeStyles.AdjustToUniversal);
DateTime observed = DateTime.MinValue.ToUniversalTime();
var utf8 = new UTF8Encoding(false);
int checks = 0;
void Check(bool condition, string message) { checks++; if (!condition) throw new InvalidOperationException(message); }
string Event(string id) => JsonSerializer.Serialize(new Dictionary<string, object> {
    ["session_id"] = id, ["timestamp"] = now.ToString("O"), ["event"] = "UserPromptSubmit", ["active"] = true }) + "\n";
string NewPath(string name)
{
    string path = Path.Combine(work, name + ".jsonl");
    File.WriteAllText(path, events, utf8);
    return path;
}

string ordinaryPath = NewPath("ordinary");
var ordinarySource = new ClaudeFileSource(ordinaryPath, null, observed);
ClaudeSourceSnapshot snapshot = ordinarySource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Single().PlanConfirmed && !snapshot.Tasks.Single().Unconfirmed,
    "A stable local file must preserve its normal confirmed plan.");

var valid = new ClaudeFileIdentity(7, 11, 13);
SafeFileHandle? firstHandle = null, secondHandle = null;
int identities = 0;
var handlesSource = new ClaudeFileSource(NewPath("handle-lifetime"), null, observed, null, null, handle =>
{
    if (Interlocked.Increment(ref identities) == 1) firstHandle = handle;
    else
    {
        secondHandle = handle;
        Check(firstHandle is not null && !firstHandle.IsClosed && !secondHandle.IsClosed,
            "Both file handles must be open while their identities are compared.");
    }
    return valid;
});
snapshot = handlesSource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Single().PlanConfirmed && identities == 2 &&
    firstHandle is { IsClosed: true } && secondHandle is { IsClosed: true },
    "The identity comparison must release both handles after the poll.");

var failures = new (string Name, ClaudeFileIdentity? First, ClaudeFileIdentity? Second)[] {
    ("first-unavailable", null, valid),
    ("second-unavailable", valid, null),
    ("first-zero", new ClaudeFileIdentity(7, 0, 0), valid),
    ("second-zero", valid, new ClaudeFileIdentity(7, 0, 0)),
    ("first-ff", new ClaudeFileIdentity(7, ulong.MaxValue, ulong.MaxValue), valid),
    ("second-ff", valid, new ClaudeFileIdentity(7, ulong.MaxValue, ulong.MaxValue)),
    ("different-volume", valid, new ClaudeFileIdentity(8, 11, 13)),
    ("different-first-half", valid, new ClaudeFileIdentity(7, 12, 13)),
    ("different-second-half", valid, new ClaudeFileIdentity(7, 11, 14))
};
foreach (var test in failures)
{
    int call = 0;
    var source = new ClaudeFileSource(NewPath("invalid-" + test.Name), null, observed, null, null,
        _ => Interlocked.Increment(ref call) == 1 ? test.First : test.Second);
    snapshot = source.Poll(ClaudeConnection.Connected, now);
    Check(snapshot.Unavailable && snapshot.Tasks.Count == 0 && source.HasObservedSourceLoss,
        "An unavailable, sentinel or mismatched identity must be reported as loss: " + test.Name);
}

var exceptionSource = new ClaudeFileSource(NewPath("identity-exception"), null, observed, null, null,
    _ => throw new InvalidOperationException("synthetic identity error"));
snapshot = exceptionSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Count == 0 && exceptionSource.HasObservedSourceLoss,
    "An identity lookup exception must be treated as loss.");

int identityFailure = 0;
var retainedSource = new ClaudeFileSource(NewPath("retained-after-failure"), null, observed, null, null,
    _ => Volatile.Read(ref identityFailure) == 0 ? valid : null);
Check(retainedSource.Poll(ClaudeConnection.Connected, now).Tasks.Single().PlanConfirmed,
    "The identity failure fixture must start confirmed.");
Volatile.Write(ref identityFailure, 1);
snapshot = retainedSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Single().Unconfirmed &&
    snapshot.Tasks.Single().Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }),
    "A later identity failure must retain previous names without confirmation.");
Volatile.Write(ref identityFailure, 0);
snapshot = retainedSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Single().Unconfirmed,
    "Restoring identity lookup must not erase the observed loss.");

string replacementPath = NewPath("replace-with-prefix");
string temporaryReplacement = Path.Combine(work, "replacement.tmp");
string replacement = events + Event("late-session");
byte[] originalBytes = utf8.GetBytes(events), replacementBytes = utf8.GetBytes(replacement);
Check(replacementBytes.Length > originalBytes.Length && replacementBytes.AsSpan(0, originalBytes.Length).SequenceEqual(originalBytes),
    "The replacement fixture must keep the complete original prefix and add an event.");
File.WriteAllText(temporaryReplacement, replacement, utf8);
int replaceArmed = 0;
var replacementSource = new ClaudeFileSource(replacementPath, null, observed, null, path =>
{
    if (Interlocked.Exchange(ref replaceArmed, 0) != 0) File.Replace(temporaryReplacement, path, null);
});
Check(replacementSource.Poll(ClaudeConnection.Connected, now).Tasks.Single().PlanConfirmed,
    "The replacement fixture must start confirmed.");
Volatile.Write(ref replaceArmed, 1);
snapshot = replacementSource.Poll(ClaudeConnection.Connected, now);
Check(snapshot.Unavailable && snapshot.Tasks.Single().Unconfirmed && replacementSource.HasObservedSourceLoss &&
    snapshot.Tasks.Single().Steps.Select(x => x.title).SequenceEqual(new[] { "First step", "Second step" }) &&
    File.ReadAllText(replacementPath, utf8) == replacement,
    "A replacement with an identical prefix and append must be detected while both handles are open.");

string appendPath = NewPath("same-file-append");
int appendArmed = 0;
var appendSource = new ClaudeFileSource(appendPath, null, observed, null, path =>
{
    if (Interlocked.Exchange(ref appendArmed, 0) != 0) File.AppendAllText(path, Event("late-session"), utf8);
});
Check(appendSource.Poll(ClaudeConnection.Connected, now).Tasks.Single().PlanConfirmed,
    "The append fixture must start confirmed.");
Volatile.Write(ref appendArmed, 1);
snapshot = appendSource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Count == 1 && snapshot.Tasks.Single().PlanConfirmed && !appendSource.HasObservedSourceLoss,
    "An ordinary append after capture must not look like a replacement.");
snapshot = appendSource.Poll(ClaudeConnection.Connected, now);
Check(!snapshot.Unavailable && snapshot.Tasks.Any(x => x.Id == "late-session" && !x.Unconfirmed),
    "The subsequent poll must see the ordinary append.");

Console.WriteLine($"Claude file identity: {checks} synthetic checks passed.");
