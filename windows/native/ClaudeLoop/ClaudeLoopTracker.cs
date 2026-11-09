namespace AITaskMonitor.ClaudeLoop;

// The caller supplies validated event fields. Raw commands and paths are not
// accepted or stored by this tracker. Each session needs its own instance.
public sealed record LoopObservation(DateTimeOffset? Time, string? Kind, string? ToolId,
    string? Fingerprint, long? ExitCode);

public sealed class ClaudeLoopTracker
{
    private sealed record PendingCommand(string Fingerprint, DateTimeOffset Time);
    private readonly List<DateTimeOffset> times = [];
    private readonly HashSet<string> seen = new(StringComparer.Ordinal);
    private readonly Queue<string> seenOrder = new();
    private readonly Dictionary<string, PendingCommand> inFlight = new(StringComparer.Ordinal);
    private string fingerprint = "";
    private long? exitCode;
    private int threshold;
    private int windowMinutes;

    public ClaudeLoopTracker(int threshold = 5, int windowMinutes = 10)
    {
        ValidateSettings(threshold, windowMinutes);
        this.threshold = threshold;
        this.windowMinutes = windowMinutes;
    }

    public bool Warning { get; private set; }
    public bool Dismissed { get; set; }
    public bool Overlap { get; private set; }
    public int Count => times.Count;
    public int InFlightCount => inFlight.Count;
    public DateTimeOffset LastSeen { get; private set; } = DateTimeOffset.MinValue;

    public void Configure(int threshold, int windowMinutes)
    {
        ValidateSettings(threshold, windowMinutes);
        if (this.threshold == threshold && this.windowMinutes == windowMinutes) return;
        Reset();
        this.threshold = threshold;
        this.windowMinutes = windowMinutes;
    }

    public void Reset()
    {
        ResetSequence();
        inFlight.Clear();
        Overlap = false;
    }

    public void Refresh(DateTimeOffset now)
    {
        DateTimeOffset cutoff = Cutoff(now, windowMinutes);
        while (times.Count > 0 && times[0] < cutoff) times.RemoveAt(0);
        if (times.Count < threshold) { Warning = false; Dismissed = false; }
        if (inFlight.Values.Any(item => item.Time < cutoff)) Reset();
    }

    public void Update(LoopObservation item, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(item);
        now = now.ToUniversalTime();
        if (item.Time is not DateTimeOffset supplied || supplied.ToUniversalTime() > FutureLimit(now))
        {
            Reset();
            return;
        }
        DateTimeOffset time = supplied.ToUniversalTime();
        if (LastSeen != DateTimeOffset.MinValue && time < LastSeen)
        {
            Reset();
            LastSeen = time;
            return;
        }
        LastSeen = time;
        Refresh(now);

        if (item.Kind is "stop" or "reset") { Reset(); return; }
        if (item.Kind == "edit")
        {
            ResetSequence();
            if (inFlight.Count > 0) Overlap = true;
            return;
        }
        if (item.Kind is not ("start" or "failed" or "success") ||
            !ValidToolId(item.ToolId) || !ValidFingerprint(item.Fingerprint))
        {
            Reset();
            return;
        }

        string toolId = item.ToolId!;
        string currentFingerprint = item.Fingerprint!;
        string eventId = item.Kind + "|" + toolId;
        if (!seen.Add(eventId)) return;
        seenOrder.Enqueue(eventId);
        while (seenOrder.Count > 4096) seen.Remove(seenOrder.Dequeue());

        if (item.Kind == "start")
        {
            if (inFlight.Count > 0) { ResetSequence(); Overlap = true; }
            if (fingerprint.Length > 0 && fingerprint != currentFingerprint) ResetSequence();
            if (inFlight.Count >= 32) Reset();
            inFlight[toolId] = new PendingCommand(currentFingerprint, time);
            return;
        }
        if (!inFlight.Remove(toolId, out PendingCommand? started)) { Reset(); return; }
        if (Overlap)
        {
            ResetSequence();
            if (inFlight.Count == 0) Overlap = false;
            return;
        }
        if (started.Fingerprint != currentFingerprint || item.Kind == "success")
        {
            ResetSequence();
            return;
        }
        if (item.ExitCode is null or 0) { ResetSequence(); return; }
        if (fingerprint != currentFingerprint || exitCode != item.ExitCode)
        {
            ResetSequence();
            fingerprint = currentFingerprint;
            exitCode = item.ExitCode;
        }
        DateTimeOffset cutoff = Cutoff(time, windowMinutes);
        while (times.Count > 0 && times[0] < cutoff) times.RemoveAt(0);
        if (times.Count < threshold && Warning) { Warning = false; Dismissed = false; }
        times.Add(time);
        while (times.Count > 10) times.RemoveAt(0);
        if (times.Count >= threshold) Warning = true;
    }

    private void ResetSequence()
    {
        fingerprint = "";
        exitCode = null;
        times.Clear();
        Warning = false;
        Dismissed = false;
    }

    private static void ValidateSettings(int threshold, int windowMinutes)
    {
        if (threshold is < 3 or > 10) throw new ArgumentOutOfRangeException(nameof(threshold));
        if (windowMinutes is < 1 or > 30) throw new ArgumentOutOfRangeException(nameof(windowMinutes));
    }

    private static DateTimeOffset Cutoff(DateTimeOffset value, int minutes)
    {
        DateTimeOffset utc = value.ToUniversalTime();
        long delta = minutes * TimeSpan.TicksPerMinute;
        return utc.UtcTicks < delta ? DateTimeOffset.MinValue : utc.AddMinutes(-minutes);
    }

    private static DateTimeOffset FutureLimit(DateTimeOffset value)
    {
        long delta = 5 * TimeSpan.TicksPerMinute;
        return value.UtcTicks > DateTimeOffset.MaxValue.UtcTicks - delta
            ? DateTimeOffset.MaxValue : value.AddMinutes(5);
    }

    private static bool ValidToolId(string? value) => value is { Length: >= 1 and <= 128 } &&
        value.All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_');

    private static bool ValidFingerprint(string? value) => value is { Length: 64 } &&
        value.All(c => c is >= 'a' and <= 'f' or >= '0' and <= '9');
}
