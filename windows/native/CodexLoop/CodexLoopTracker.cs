using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace AITaskMonitor.CodexLoop;

// Input has already been decoded and type-checked by a future adapter. This
// prototype does not read logs, discover sessions, or start external agents.
public sealed record LoopEvent(
    string? RecordType, string? EventType, string? ItemType, string? Id,
    DateTimeOffset? Timestamp, string? Status, long? ExitCode,
    string?[]? Command, string? WorkingDirectory);

public sealed class CodexLoopTracker : IDisposable
{
    private static readonly Regex SafeId = new("^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant);
    private readonly byte[] key;
    private readonly DateTimeOffset since;
    private int threshold;
    private int windowMinutes;
    private readonly HashSet<string> seen = new(StringComparer.Ordinal);
    private readonly Queue<string> seenOrder = new();
    private readonly List<DateTimeOffset> times = new();
    private string fingerprint = "";
    private long? exitCode;
    private bool disposed;

    public CodexLoopTracker(byte[] comparisonKey, DateTimeOffset since, int threshold = 5, int windowMinutes = 10)
    {
        ArgumentNullException.ThrowIfNull(comparisonKey);
        if (comparisonKey.Length < 32) throw new ArgumentException("The comparison key must contain at least 32 bytes.", nameof(comparisonKey));
        if (threshold is < 3 or > 10) throw new ArgumentOutOfRangeException(nameof(threshold));
        if (windowMinutes is < 1 or > 30) throw new ArgumentOutOfRangeException(nameof(windowMinutes));
        key = comparisonKey.ToArray();
        this.since = since.ToUniversalTime();
        this.threshold = threshold;
        this.windowMinutes = windowMinutes;
    }

    public bool Warning { get; private set; }
    public bool Dismissed { get; set; }
    public int Count => times.Count;

    public void Configure(int threshold, int windowMinutes)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (threshold is < 3 or > 10) throw new ArgumentOutOfRangeException(nameof(threshold));
        if (windowMinutes is < 1 or > 30) throw new ArgumentOutOfRangeException(nameof(windowMinutes));
        if (this.threshold == threshold && this.windowMinutes == windowMinutes) return;
        Reset(); // Retain previously seen event IDs, as the existing runtime does.
        this.threshold = threshold;
        this.windowMinutes = windowMinutes;
    }

    public CodexLoopTracker Copy()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var copy = new CodexLoopTracker(key, since, threshold, windowMinutes)
        {
            fingerprint = fingerprint, exitCode = exitCode, Warning = Warning, Dismissed = Dismissed
        };
        copy.times.AddRange(times);
        foreach (string id in seenOrder)
            if (copy.seen.Add(id)) copy.seenOrder.Enqueue(id);
        return copy;
    }

    public void Reset()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        fingerprint = "";
        exitCode = null;
        times.Clear();
        Warning = false;
        Dismissed = false;
    }

    public void Update(LoopEvent item, DateTimeOffset now)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        ArgumentNullException.ThrowIfNull(item);
        if (item.RecordType != "event_msg" || item.EventType is not ("item_started" or "item_completed") ||
            item.ItemType is not ("CommandExecution" or "FileChange") || item.Id is null ||
            !SafeId.IsMatch(item.Id) || item.Timestamp is not DateTimeOffset time ||
            time < since || time > now.ToUniversalTime().AddMinutes(5)) return;

        string eventKey = Digest("event", item.EventType + "\0" + item.ItemType + "\0" + item.Id);
        if (!seen.Add(eventKey)) return;
        seenOrder.Enqueue(eventKey);
        while (seenOrder.Count > 4096) seen.Remove(seenOrder.Dequeue());

        if (item.ItemType == "FileChange")
        {
            if (item.EventType == "item_completed") Reset();
            return;
        }
        if (item.EventType == "item_started")
        {
            string next = CommandDigest(item);
            if (fingerprint.Length > 0 && (next.Length == 0 || fingerprint != next)) Reset();
            return;
        }
        if (item.Status != "failed" || item.ExitCode is null or 0) { Reset(); return; }
        string current = CommandDigest(item);
        if (current.Length == 0) { Reset(); return; }
        if (fingerprint != current || exitCode != item.ExitCode || (times.Count > 0 && time < times[^1]))
        {
            Reset();
            fingerprint = current;
            exitCode = item.ExitCode;
        }
        DateTimeOffset cutoff = time.AddMinutes(-windowMinutes);
        while (times.Count > 0 && times[0] < cutoff) times.RemoveAt(0);
        if (times.Count < threshold && Warning) { Warning = false; Dismissed = false; }
        times.Add(time);
        while (times.Count > 10) times.RemoveAt(0);
        if (times.Count >= threshold) Warning = true;
    }

    public void Refresh(DateTimeOffset now)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        DateTimeOffset cutoff = now.ToUniversalTime().AddMinutes(-windowMinutes);
        while (times.Count > 0 && times[0] < cutoff) times.RemoveAt(0);
        if (times.Count < threshold) { Warning = false; Dismissed = false; }
    }

    private string CommandDigest(LoopEvent item)
    {
        if (item.Command is null || item.Command.Length is 0 or > 256 || item.WorkingDirectory is null ||
            item.WorkingDirectory.Length > 32768) return "";
        var builder = new StringBuilder();
        builder.Append(item.WorkingDirectory.Length.ToString(CultureInfo.InvariantCulture)).Append(':').Append(item.WorkingDirectory);
        foreach (string? argument in item.Command)
        {
            if (argument is null || argument.Length > 32768 || builder.Length + argument.Length > 131072) return "";
            builder.Append(argument.Length.ToString(CultureInfo.InvariantCulture)).Append(':').Append(argument);
        }
        return Digest("command", builder.ToString());
    }

    private string Digest(string context, string value)
    {
        byte[] input = Encoding.UTF8.GetBytes(context + "\0" + value);
        try { return Convert.ToHexString(HMACSHA256.HashData(key, input)).ToLowerInvariant(); }
        finally { CryptographicOperations.ZeroMemory(input); }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        CryptographicOperations.ZeroMemory(key);
        seen.Clear(); seenOrder.Clear(); times.Clear(); fingerprint = "";
    }
}
