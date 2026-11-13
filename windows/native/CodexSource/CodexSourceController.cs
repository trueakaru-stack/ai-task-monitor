using System.Security.Cryptography;
using AITaskMonitor.CodexDiscovery;
using AITaskMonitor.CodexIndex;
using AITaskMonitor.CodexState;

namespace AITaskMonitor.CodexSource;

// IDs and titles may be private. Callers must not log or disclose these values.
// The state projection deliberately omits the reducer's raw start key and times.
internal sealed record CodexTaskState(ThreadStatus Status, bool Unconfirmed);
internal sealed record CodexSourceTask(string Id, string Title, CodexTaskState State)
{
    public override string ToString() => nameof(CodexSourceTask);
}
internal sealed record CodexSourceSnapshot(bool Incomplete, IReadOnlyList<CodexSourceTask> Tasks)
{
    public override string ToString() => nameof(CodexSourceSnapshot);
}

/// <summary>
/// Synthetic-only composition. Internal visibility prevents linking this
/// incomplete source to the application. The caller supplies paths, a lock
/// observation and a clock; none is a trusted production integration.
/// </summary>
internal sealed class CodexSourceController
{
    private const int MaximumSessions = 128;
    private readonly object gate = new();
    private readonly string indexPath, sessionsRoot;
    private readonly Func<string, LockObservation> observeLock;
    private readonly Func<DateTimeOffset> utcNow;
    private readonly DateTimeOffset monitorStartedUtc;
    private readonly IDiscoveryClock? discoveryClock;
    private readonly ISessionFileSystem? fileSystem;
    private readonly Dictionary<string, KnownTask> known = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> lostIds = new(StringComparer.OrdinalIgnoreCase);
    private bool sourceLost, capacitySealed;
    private DateTimeOffset? lastClockUtc;

    internal CodexSourceController(string indexPath, string sessionsRoot,
        Func<string, LockObservation> observeLock, DateTimeOffset monitorStartedUtc,
        Func<DateTimeOffset> utcNow, IDiscoveryClock? discoveryClock = null, ISessionFileSystem? fileSystem = null)
    {
        this.observeLock = observeLock ?? throw new ArgumentNullException(nameof(observeLock));
        this.utcNow = utcNow ?? throw new ArgumentNullException(nameof(utcNow));
        this.monitorStartedUtc = monitorStartedUtc.ToUniversalTime();
        // Validate paths and clock using the existing components without reading files.
        _ = new CodexIndexReader(indexPath);
        _ = new SessionDiscovery(sessionsRoot, discoveryClock, fileSystem);
        this.indexPath = Path.GetFullPath(indexPath);
        this.sessionsRoot = Path.GetFullPath(sessionsRoot);
        this.discoveryClock = discoveryClock;
        this.fileSystem = fileSystem;
    }

    // Fresh helper instances prevent their internal per-ID caches from growing
    // across refreshes. Their individual scans are still unbounded: do not use
    // this synthetic controller with real profiles or on the UI thread.
    internal CodexSourceSnapshot Refresh(IEnumerable<string> heldOrUnavailableLockIds)
    {
        ArgumentNullException.ThrowIfNull(heldOrUnavailableLockIds);
        lock (gate)
        {
            if (sourceLost) return Snapshot(true);
            DateTimeOffset now;
            try { now = utcNow().ToUniversalTime(); }
            catch (Exception) { return LoseSource(); }
            if (now < monitorStartedUtc || (lastClockUtc is DateTimeOffset priorClock && now < priorClock))
                return LoseSource();
            lastClockUtc = now;

            string[] supplied = heldOrUnavailableLockIds.Take(MaximumSessions + 1).ToArray();
            bool incomplete = supplied.Length > MaximumSessions || capacitySealed;
            if (supplied.Length > MaximumSessions)
            {
                // No new ID can be confirmed when the overflow has not been examined.
                capacitySealed = true;
                supplied = [];
            }
            CodexIndexReadResult input;
            try { input = new CodexIndexReader(indexPath).Read(known.Keys, supplied); }
            catch (CodexIndexUnavailableException) { return LoseSource(); }
            if (input.HasUnsupportedRows) return LoseSource();

            var present = new HashSet<string>(input.Entries.Select(entry => entry.Id), StringComparer.OrdinalIgnoreCase);
            foreach (string id in supplied)
            {
                if (present.Contains(id)) continue;
                incomplete = true;
                RememberLoss(id, null);
            }

            var represented = new HashSet<string>(known.Keys, StringComparer.OrdinalIgnoreCase);
            represented.UnionWith(lostIds);
            int newIds = input.Entries.Count(entry => !represented.Contains(entry.Id));
            bool permitNew = !capacitySealed && represented.Count + newIds <= MaximumSessions;
            if (!permitNew && newIds > 0) { incomplete = true; capacitySealed = true; }
            CodexIndexEntry[] selected = input.Entries.Where(entry => known.ContainsKey(entry.Id) ||
                lostIds.Contains(entry.Id) || permitNew).ToArray();
            var discovery = new SessionDiscovery(sessionsRoot, discoveryClock, fileSystem);
            try
            {
                discovery.BeginCycle(selected.Select(entry =>
                    new SessionIndexEntry(entry.Id, entry.UpdatedVersion, entry.Date)));
            }
            catch (ArgumentException) { return LoseSource(); }

            foreach (CodexIndexEntry entry in selected)
            {
                known.TryGetValue(entry.Id, out KnownTask? previous);
                if (lostIds.Contains(entry.Id) || previous?.Lost == true)
                {
                    incomplete = true;
                    MarkUnknown(previous);
                    continue;
                }
                string? path;
                try { path = discovery.Find(entry.Id); }
                catch (SessionDiscoveryUnavailableException)
                {
                    incomplete = true; RememberLoss(entry.Id, previous); continue;
                }
                if (path is null) { incomplete = true; RememberLoss(entry.Id, previous); continue; }

                LockObservation observedLock;
                try { observedLock = observeLock(entry.Id); }
                catch (Exception) { incomplete = true; RememberLoss(entry.Id, previous); continue; }
                if (!Enum.IsDefined(observedLock) || observedLock == LockObservation.Unavailable ||
                    (previous is not null && previous.LastLock != observedLock))
                {
                    incomplete = true;
                    RememberLoss(entry.Id, previous);
                    continue;
                }
                JournalRead? journal = BoundedJournalReader.Read(path, entry.Id, now);
                if (journal is null) { incomplete = true; RememberLoss(entry.Id, previous); continue; }
                try
                {
                    if (previous is not null && !IsContinuation(previous, path, journal))
                    {
                        incomplete = true;
                        RememberLoss(entry.Id, previous);
                        continue;
                    }
                    LifecycleState state = previous?.State ?? LifecycleState.Empty;
                    Reduction reduction = CodexLifecycleReducer.Reduce(state,
                        new ThreadObservation(true, journal.UpdatedUtc, observedLock, EventBatchKind.FullHistory, journal.Events),
                        monitorStartedUtc);
                    if (reduction.SourceUnavailable || reduction.Snapshot is null)
                    {
                        incomplete = true;
                        RememberLoss(entry.Id, previous);
                        continue;
                    }
                    ThreadSnapshot snapshot = reduction.Snapshot;
                    bool visible = snapshot.Status == ThreadStatus.Active || snapshot.Unconfirmed;
                    // Retain evidence even for a completed, interrupted, unknown or
                    // unobserved session; visibility is a separate property.
                    known[entry.Id] = new KnownTask(entry.Id, entry.Title, reduction.State, snapshot,
                        path, journal.Bytes.Length, journal.Hash, observedLock, visible);
                }
                finally { Array.Clear(journal.Bytes, 0, journal.Bytes.Length); }
            }

            foreach (KnownTask previous in known.Values)
            {
                if (present.Contains(previous.Id)) continue;
                incomplete = true;
                RememberLoss(previous.Id, previous);
            }
            return Snapshot(incomplete);
        }
    }

    private static bool IsContinuation(KnownTask previous, string path, JournalRead current)
    {
        if (!string.Equals(previous.Path, path, StringComparison.Ordinal) || current.Bytes.Length < previous.Length)
            return false;
        byte[] prefixHash = SHA256.HashData(current.Bytes.AsSpan(0, previous.Length));
        return CryptographicOperations.FixedTimeEquals(previous.Hash, prefixHash);
    }

    private CodexSourceSnapshot LoseSource()
    {
        sourceLost = true;
        foreach (KnownTask task in known.Values) { task.Lost = true; MarkUnknown(task); }
        return Snapshot(true);
    }

    private void RememberLoss(string id, KnownTask? task)
    {
        if (task is not null) { task.Lost = true; MarkUnknown(task); return; }
        if (known.Count + lostIds.Count >= MaximumSessions) { capacitySealed = true; return; }
        lostIds.Add(id);
    }

    private static void MarkUnknown(KnownTask? task)
    {
        if (task is { Visible: true })
            task.Snapshot = task.Snapshot with { Status = ThreadStatus.Unknown, Unconfirmed = true };
    }

    private CodexSourceSnapshot Snapshot(bool incomplete) => new(incomplete,
        known.Values.Where(task => task.Visible).Select(task => new CodexSourceTask(task.Id, task.Title,
            new CodexTaskState(task.Snapshot.Status, task.Snapshot.Unconfirmed))).ToArray());

    private sealed class KnownTask(string id, string title, LifecycleState state, ThreadSnapshot snapshot,
        string path, int length, byte[] hash, LockObservation lastLock, bool visible)
    {
        internal string Id { get; } = id;
        internal string Title { get; } = title;
        internal LifecycleState State { get; } = state;
        internal ThreadSnapshot Snapshot { get; set; } = snapshot;
        internal string Path { get; } = path;
        internal int Length { get; } = length;
        internal byte[] Hash { get; } = hash;
        internal LockObservation LastLock { get; } = lastLock;
        internal bool Visible { get; } = visible;
        internal bool Lost { get; set; }
    }
}
