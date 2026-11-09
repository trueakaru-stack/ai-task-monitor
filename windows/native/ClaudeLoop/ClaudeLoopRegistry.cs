namespace AITaskMonitor.ClaudeLoop;

public sealed record SessionObservation(string SessionId, LoopObservation Observation);
public sealed record LoopStatus(bool Warning, bool Dismissed, int FailureCount, int InFlightCount, DateTimeOffset LastSeen);

// A controller owns this registry on one serialized thread. The channel remains
// responsible for its own ACL and for marking lost or malformed frames as gaps.
public sealed class ClaudeLoopRegistry
{
    private const int MaximumSessions = 256;
    private const int MaximumBatch = 2048;
    private readonly Dictionary<string, ClaudeLoopTracker> sessions = new(StringComparer.Ordinal);
    private int? configuredThreshold;
    private int? configuredWindow;

    public int Count => sessions.Count;

    public bool Poll(Channel channel, int threshold, int windowMinutes, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(channel);
        try
        {
            if (channel.IsStopped) { Clear(); return false; }
            LoopBatch batch = channel.Drain();
            if (channel.IsStopped) { Clear(); return false; }
            SessionObservation[] observations = batch.Events.Select(item => new SessionObservation(item.SessionId,
                new LoopObservation(item.Time, item.Kind, item.ToolId, item.Fingerprint, item.ExitCode))).ToArray();
            return Apply(batch.Gap, observations, threshold, windowMinutes, now);
        }
        catch (Exception)
        {
            Clear();
            return false;
        }
    }

    // A gap has no sequence position within the drained batch. Drop that
    // entire batch instead of counting a potentially incomplete sequence.
    public bool Apply(bool gap, IReadOnlyList<SessionObservation> batch, int threshold, int windowMinutes, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(batch);
        if (threshold is < 3 or > 10) throw new ArgumentOutOfRangeException(nameof(threshold));
        if (windowMinutes is < 1 or > 30) throw new ArgumentOutOfRangeException(nameof(windowMinutes));
        now = now.ToUniversalTime();
        bool settingsChanged = configuredThreshold.HasValue &&
            (configuredThreshold != threshold || configuredWindow != windowMinutes);
        configuredThreshold = threshold;
        configuredWindow = windowMinutes;
        if (settingsChanged)
        {
            // The batch can contain events queued before the user's change.
            sessions.Clear();
            return false;
        }
        if (gap || batch.Count > MaximumBatch || batch.Any(item => item is null || !ValidSession(item.SessionId) || item.Observation is null))
        {
            sessions.Clear();
            return false;
        }

        DateTimeOffset cutoff = now.UtcTicks < 30 * TimeSpan.TicksPerMinute
            ? DateTimeOffset.MinValue : now.AddMinutes(-30);
        DateTimeOffset futureLimit = now.UtcTicks > DateTimeOffset.MaxValue.UtcTicks - 5 * TimeSpan.TicksPerMinute
            ? DateTimeOffset.MaxValue : now.AddMinutes(5);
        foreach (ClaudeLoopTracker tracker in sessions.Values) tracker.Configure(threshold, windowMinutes);
        foreach (SessionObservation item in batch)
        {
            if (!sessions.TryGetValue(item.SessionId, out ClaudeLoopTracker? tracker))
            {
                if (item.Observation.Kind != "start" || item.Observation.Time is not DateTimeOffset started ||
                    started.ToUniversalTime() < cutoff || started.ToUniversalTime() > futureLimit ||
                    !ValidToolId(item.Observation.ToolId) || !ValidFingerprint(item.Observation.Fingerprint)) continue;
                if (sessions.Count >= MaximumSessions)
                {
                    string oldest = sessions.OrderBy(pair => pair.Value.LastSeen)
                        .ThenBy(pair => pair.Key, StringComparer.Ordinal).First().Key;
                    sessions.Remove(oldest);
                }
                tracker = new ClaudeLoopTracker(threshold, windowMinutes);
                sessions.Add(item.SessionId, tracker);
            }
            tracker.Update(item.Observation, now);
            if (item.Observation.Kind == "stop") sessions.Remove(item.SessionId);
        }
        foreach (string id in sessions.Keys.ToArray())
        {
            ClaudeLoopTracker tracker = sessions[id];
            tracker.Refresh(now);
            if (tracker.LastSeen < cutoff) sessions.Remove(id);
        }
        return true;
    }

    public LoopStatus? GetStatus(string sessionId)
    {
        if (!ValidSession(sessionId) || !sessions.TryGetValue(sessionId, out ClaudeLoopTracker? tracker)) return null;
        return new LoopStatus(tracker.Warning, tracker.Dismissed, tracker.Count, tracker.InFlightCount, tracker.LastSeen);
    }

    public bool Dismiss(string sessionId)
    {
        if (!ValidSession(sessionId) || !sessions.TryGetValue(sessionId, out ClaudeLoopTracker? tracker) || !tracker.Warning) return false;
        tracker.Dismissed = true;
        return true;
    }

    public void Clear()
    {
        sessions.Clear();
        configuredThreshold = null;
        configuredWindow = null;
    }

    private static bool ValidSession(string? value) => value is { Length: >= 1 and <= 128 } &&
        value.All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_');

    private static bool ValidToolId(string? value) => value is { Length: >= 1 and <= 128 } &&
        value.All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_');

    private static bool ValidFingerprint(string? value) => value is { Length: 64 } &&
        value.All(c => c is >= 'a' and <= 'f' or >= '0' and <= '9');
}
