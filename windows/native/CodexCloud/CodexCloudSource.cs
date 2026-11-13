using System.Collections.ObjectModel;
using System.Text.Json.Serialization;

namespace AITaskMonitor.CodexCloud;

public sealed class CloudTask
{
    internal CloudTask(string id, string? title, DateTimeOffset? updatedAt)
    {
        Id = id;
        Title = title;
        UpdatedAt = updatedAt;
    }

    public string Id { get; }
    public string? Title { get; }
    public DateTimeOffset? UpdatedAt { get; }
    public bool Active => false;
    public bool Unconfirmed => true;
    public double? Progress => null;
    public bool PlanConfirmed => false;
    public override string ToString() => "Codex Cloud task";
}

public sealed class CloudSnapshot
{
    internal CloudSnapshot(bool enabled, bool scanned, bool partial, bool unavailable, CloudTask[] tasks)
    {
        Enabled = enabled;
        Scanned = scanned;
        Partial = partial;
        Unavailable = unavailable;
        Tasks = Array.AsReadOnly(tasks);
    }

    public bool Enabled { get; }
    public bool Scanned { get; }
    public bool Partial { get; }
    public bool Unavailable { get; }
    public ReadOnlyCollection<CloudTask> Tasks { get; }
    public override string ToString() => "Codex Cloud snapshot";
}

public sealed class CloudPageRequest
{
    internal CloudPageRequest(object owner, object scan, string? cursor)
    {
        Owner = owner;
        Scan = scan;
        Cursor = cursor;
    }

    internal object Owner { get; }
    internal object Scan { get; }

    // Only a future transport needs this opaque value. Do not log it.
    [JsonIgnore]
    public string? Cursor { get; }
    public override string ToString() => "Codex Cloud page request";
}

public enum CloudPageDisposition
{
    Ignored,
    NextPage,
    Complete,
    Partial,
    Failed
}

public sealed class CloudPageResult
{
    internal CloudPageResult(CloudPageDisposition disposition, CloudPageRequest? nextRequest = null)
    {
        Disposition = disposition;
        NextRequest = nextRequest;
    }

    public CloudPageDisposition Disposition { get; }
    public CloudPageRequest? NextRequest { get; }
    public override string ToString() => "Codex Cloud page result";
}

// This is a bounded, in-memory state machine, not a CLI or network client.
public sealed class CodexCloudSource
{
    public const int MaximumPages = 5;
    public const int MaximumRetainedTasks = 256;

    private readonly object gate = new();
    private readonly object owner = new();
    private bool enabled;
    private bool scanned;
    private bool partial;
    private bool unavailable;
    private CloudTask[] published = [];
    private Scan? scan;

    private sealed class Scan
    {
        internal readonly object Token = new();
        internal readonly Dictionary<string, CloudTask?> Tasks = new(StringComparer.Ordinal);
        internal readonly HashSet<string> Cursors = new(StringComparer.Ordinal);
        internal int Pages;
        internal CloudPageRequest? Current;
    }

    public CloudSnapshot GetSnapshot()
    {
        lock (gate)
            return new CloudSnapshot(enabled, scanned, partial, unavailable, (CloudTask[])published.Clone());
    }

    public void SetEnabled(bool value)
    {
        lock (gate)
        {
            if (enabled == value) return;
            enabled = value;
            scan = null;
            published = [];
            scanned = false;
            partial = false;
            unavailable = false;
        }
    }

    public CloudPageRequest? BeginScan()
    {
        lock (gate)
        {
            if (!enabled || scan is not null) return null;
            scan = new Scan();
            scan.Current = new CloudPageRequest(owner, scan.Token, null);
            return scan.Current;
        }
    }

    public CloudPageResult AcceptPage(CloudPageRequest request, ReadOnlyMemory<byte> input)
    {
        ArgumentNullException.ThrowIfNull(request);
        lock (gate)
        {
            if (!IsCurrent(request)) return new(CloudPageDisposition.Ignored);
        }

        // Parsing occurs outside the lock; recheck ownership before committing any result.
        bool valid = CloudPageReader.TryRead(input, out ParsedPage? page);
        lock (gate)
        {
            if (!IsCurrent(request)) return new(CloudPageDisposition.Ignored);
            if (!valid || page is null) return FailCurrent();

            Scan current = scan!;
            foreach (ParsedTask item in page.Tasks)
            {
                if (current.Tasks.ContainsKey(item.Id)) return FailCurrent();
                current.Tasks.Add(item.Id, item.Terminal ? null : new CloudTask(item.Id, item.Title, item.UpdatedAt));
            }
            current.Pages++;

            if (page.Cursor is not null && !current.Cursors.Add(page.Cursor))
                return FailCurrent();

            if (page.Cursor is not null && current.Pages < MaximumPages)
            {
                current.Current = new CloudPageRequest(owner, current.Token, page.Cursor);
                return new(CloudPageDisposition.NextPage, current.Current);
            }

            var next = new List<CloudTask>(current.Tasks.Count + published.Length);
            foreach (CloudTask? task in current.Tasks.Values)
                if (task is not null) next.Add(task);

            bool isPartial = page.Cursor is not null;
            if (isPartial)
            {
                foreach (CloudTask previous in published)
                    if (!current.Tasks.ContainsKey(previous.Id)) next.Add(previous);
            }
            // Do not silently evict older cards if repeated partial scans accumulate.
            if (next.Count > MaximumRetainedTasks) return FailCurrent();

            published = next.ToArray();
            scanned = true;
            partial = isPartial;
            unavailable = false;
            scan = null;
            return new(isPartial ? CloudPageDisposition.Partial : CloudPageDisposition.Complete);
        }
    }

    // A transport reports an error or deadline for the current request only.
    public bool ReportFailure(CloudPageRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        lock (gate)
        {
            if (!IsCurrent(request)) return false;
            _ = FailCurrent();
            return true;
        }
    }

    // An owner may cancel its scan using any request from that scan.
    public bool CancelScan(CloudPageRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        lock (gate)
        {
            if (!enabled || scan is null || !ReferenceEquals(request.Owner, owner) ||
                !ReferenceEquals(request.Scan, scan.Token))
                return false;
            _ = FailCurrent();
            return true;
        }
    }

    private bool IsCurrent(CloudPageRequest request) =>
        enabled && scan is not null &&
        ReferenceEquals(request.Owner, owner) &&
        ReferenceEquals(request.Scan, scan.Token) &&
        ReferenceEquals(request, scan.Current);

    private CloudPageResult FailCurrent()
    {
        scan = null;
        unavailable = true;
        return new(CloudPageDisposition.Failed);
    }
}
