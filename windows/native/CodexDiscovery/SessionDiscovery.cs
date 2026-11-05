using System.Diagnostics;
using System.Globalization;
using System.Security;
using System.Text.RegularExpressions;

namespace AITaskMonitor.CodexDiscovery;

public interface IDiscoveryClock
{
    long Frequency { get; }
    long GetTimestamp();
}

public sealed class StopwatchDiscoveryClock : IDiscoveryClock
{
    public long Frequency => Stopwatch.Frequency;
    public long GetTimestamp() => Stopwatch.GetTimestamp();
}

public interface ISessionFileSystem
{
    FileAttributes GetAttributes(string path);
    IEnumerable<string> EnumerateDatedFiles(string directory, string validatedId);
    IEnumerable<string> EnumerateRecursively(string directory);
}

public sealed class PhysicalSessionFileSystem : ISessionFileSystem
{
    // Windows PowerShell's Get-ChildItem -File omits Hidden without -Force,
    // but admits System by itself. Preserve Win32 wildcard matching.
    private static readonly EnumerationOptions DatedEnumeration = new()
    {
        AttributesToSkip = FileAttributes.Hidden,
        IgnoreInaccessible = false,
        MatchType = MatchType.Win32,
        RecurseSubdirectories = false
    };
    public FileAttributes GetAttributes(string path) => File.GetAttributes(path);
    public IEnumerable<string> EnumerateDatedFiles(string directory, string validatedId) =>
        Directory.EnumerateFiles(directory, "*" + validatedId + ".jsonl", DatedEnumeration);
    public IEnumerable<string> EnumerateRecursively(string directory) =>
        Directory.EnumerateFiles(directory, "*.jsonl", SearchOption.AllDirectories);
}

public sealed class SessionDiscoveryUnavailableException : IOException
{
    public SessionDiscoveryUnavailableException() : base("Codex session files cannot be read.") { }
}

// Date is the already-parsed calendar date used for the source's dated folders.
// The caller owns parsing and supplies the unmodified index version separately.
public sealed record SessionIndexEntry(string Id, string UpdatedVersion, DateOnly? Date = null);

public sealed record DiscoveryDiagnostics(bool ScanAttempted, bool ScanFailed, int RetrySeconds,
    long LastScanTimestamp, long HotUntilTimestamp, int RecursiveScans, int PositiveCount,
    int DatedMissCount, int FallbackMissCount);

public sealed class SessionDiscovery
{
    private static readonly Regex SafeId = new(@"\A[A-Za-z0-9_-]{1,128}\z", RegexOptions.CultureInvariant);
    private static readonly StringComparer Keys = StringComparer.OrdinalIgnoreCase;
    private readonly object gate = new();
    private readonly string root;
    private readonly IDiscoveryClock clock;
    private readonly ISessionFileSystem files;
    private readonly long frequency;
    private readonly Dictionary<string, string> positive = new(Keys);
    private readonly Dictionary<string, string> dates = new(Keys);
    private readonly Dictionary<string, DatedMiss> datedMisses = new(Keys);
    private readonly HashSet<string> fallbackMisses = new(Keys);
    private Dictionary<string, string> indexVersions = new(Keys);
    private string[]? rollouts;
    private long lastScan, hotUntil;
    private bool attempted, failed;
    private int retrySeconds = 5, recursiveScans;

    public SessionDiscovery(string sessionsRoot, IDiscoveryClock? clock = null, ISessionFileSystem? fileSystem = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionsRoot);
        if (!Path.IsPathFullyQualified(sessionsRoot)) throw new ArgumentException("The session root must be absolute.", nameof(sessionsRoot));
        root = Path.GetFullPath(sessionsRoot);
        this.clock = clock ?? new StopwatchDiscoveryClock();
        files = fileSystem ?? new PhysicalSessionFileSystem();
        frequency = this.clock.Frequency;
        if (frequency <= 0 || frequency > long.MaxValue / 60) throw new ArgumentException("The clock frequency is invalid.", nameof(clock));
    }

    // Every refresh drops short dated misses, even if less than one second passed.
    // A changed/new unresolved index entry permits quicker retries but never
    // forces a recursive scan earlier than the existing five-second minimum.
    public void BeginCycle(IEnumerable<SessionIndexEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        var input = entries.ToArray();
        foreach (SessionIndexEntry item in input)
        {
            ArgumentNullException.ThrowIfNull(item);
            ValidateId(item.Id);
        }
        lock (gate)
        {
            datedMisses.Clear();
            // The published index reader has already coalesced duplicate IDs.
            var unique = new Dictionary<string, SessionIndexEntry>(Keys);
            foreach (SessionIndexEntry item in input) unique[item.Id] = item;
            var versions = new Dictionary<string, string>(Keys);
            bool newActivity = false;
            foreach (SessionIndexEntry item in unique.Values)
            {
                if (item.Date is DateOnly date) dates[item.Id] = DatedFolder(date);
                string version = item.UpdatedVersion ?? "";
                versions[item.Id] = version;
                if (!positive.ContainsKey(item.Id) &&
                    (!indexVersions.TryGetValue(item.Id, out string? previous) || !string.Equals(previous, version, StringComparison.Ordinal)))
                    newActivity = true;
            }
            indexVersions = versions;
            if (newActivity) MarkActivity();
        }
    }

    public string? Find(string id)
    {
        ValidateId(id);
        lock (gate)
        {
            if (positive.TryGetValue(id, out string? cached))
            {
                if (FileAvailable(cached)) return cached;
                positive.Remove(id);
                datedMisses.Remove(id);
                MarkActivity();
            }

            if (dates.TryGetValue(id, out string? folder))
            {
                bool skip = false;
                if (datedMisses.TryGetValue(id, out DatedMiss? miss))
                {
                    long now = clock.GetTimestamp();
                    if (string.Equals(miss.Folder, folder, StringComparison.OrdinalIgnoreCase) &&
                        now >= miss.Timestamp && Delta(now, miss.Timestamp) < (ulong)frequency) skip = true;
                    else datedMisses.Remove(id);
                }
                if (!skip)
                {
                    try
                    {
                        if (DirectoryAvailable(folder))
                        {
                            string? found = files.EnumerateDatedFiles(folder, id).FirstOrDefault();
                            if (found is not null)
                            {
                                datedMisses.Remove(id);
                                positive[id] = found;
                                MarkActivity();
                                return found;
                            }
                        }
                        datedMisses[id] = new DatedMiss(folder, clock.GetTimestamp());
                    }
                    catch (Exception error) when (IsFileSystemError(error))
                    {
                        datedMisses.Remove(id);
                        throw new SessionDiscoveryUnavailableException();
                    }
                }
            }

            try
            {
                if ((files.GetAttributes(root) & FileAttributes.Directory) == 0) throw new IOException();
            }
            catch (Exception error) when (IsFileSystemError(error)) { throw new SessionDiscoveryUnavailableException(); }

            long current = clock.GetTimestamp();
            if (attempted && current < lastScan) { lastScan = current; retrySeconds = 5; }
            long interval = frequency * Math.Max(5, retrySeconds);
            if (!attempted || Delta(current, lastScan) >= (ulong)interval)
            {
                bool previousAttempt = attempted, previousFailure = failed;
                fallbackMisses.Clear();
                try
                {
                    recursiveScans++;
                    rollouts = files.EnumerateRecursively(root).ToArray();
                    failed = false;
                    if (previousFailure) MarkActivity();
                }
                catch (Exception error) when (IsFileSystemError(error))
                {
                    rollouts = null;
                    failed = true;
                }
                finally
                {
                    lastScan = clock.GetTimestamp();
                    attempted = true;
                    if (previousAttempt && lastScan >= hotUntil) retrySeconds = Math.Min(60, retrySeconds * 2);
                }
            }
            if (failed) throw new SessionDiscoveryUnavailableException();
            if (fallbackMisses.Contains(id)) return null;
            bool matched = false;
            foreach (string path in rollouts ?? Array.Empty<string>())
            {
                if (!path.EndsWith(id + ".jsonl", StringComparison.OrdinalIgnoreCase)) continue;
                matched = true;
                if (!FileAvailable(path)) continue;
                positive[id] = path;
                MarkActivity();
                return path;
            }
            if (!matched) fallbackMisses.Add(id);
            return null;
        }
    }

    public DiscoveryDiagnostics Diagnostics()
    {
        lock (gate) return new DiscoveryDiagnostics(attempted, failed, retrySeconds, lastScan, hotUntil,
            recursiveScans, positive.Count, datedMisses.Count, fallbackMisses.Count);
    }

    private string DatedFolder(DateOnly date) => Path.Combine(root,
        date.Year.ToString(CultureInfo.InvariantCulture), date.Month.ToString("00", CultureInfo.InvariantCulture),
        date.Day.ToString("00", CultureInfo.InvariantCulture));
    private void MarkActivity()
    {
        retrySeconds = 5;
        long now = clock.GetTimestamp(), duration = frequency * 30;
        hotUntil = now > long.MaxValue - duration ? long.MaxValue : now + duration;
    }
    private bool FileAvailable(string path)
    {
        try
        {
            if ((files.GetAttributes(path) & FileAttributes.Directory) != 0) throw new IOException();
            return true;
        }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
        catch (Exception error) when (IsFileSystemError(error)) { throw new SessionDiscoveryUnavailableException(); }
    }
    private bool DirectoryAvailable(string path)
    {
        try { return (files.GetAttributes(path) & FileAttributes.Directory) != 0; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }
    private static bool IsFileSystemError(Exception error) => error is IOException or UnauthorizedAccessException or SecurityException or ArgumentException or NotSupportedException;
    private static ulong Delta(long current, long earlier) => unchecked((ulong)current - (ulong)earlier);
    private static void ValidateId(string id)
    {
        if (id is null || !SafeId.IsMatch(id)) throw new ArgumentException("Invalid Codex session ID.", nameof(id));
    }
    private sealed record DatedMiss(string Folder, long Timestamp);
}
