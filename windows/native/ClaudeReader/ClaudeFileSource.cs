#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("ClaudeFileSource.Tests")]
[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("AITaskMonitor.ClaudePump.Tests")]

namespace AITaskMonitor.Claude;

public enum ClaudeConnection { Disconnected, Partial, Connected }

public sealed record ClaudeSourceSnapshot(IReadOnlyList<Task> Tasks, bool Unavailable)
{
    public long Generation { get; internal init; }
    internal object? Owner { get; init; }
    internal Task[]? RetainedFallback { get; init; }
}

// One instance belongs to one monitor session. Paths and connection state are
// supplied by its caller; this class does not find profiles or install hooks.
public sealed class ClaudeFileSource
{
    private const int MaximumTailBytes = 4 * 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly object gate = new();
    private readonly object signalGate = new();
    private readonly object identity = new();
    private readonly string currentPath;
    private readonly string? legacyPath;
    private readonly DateTime observedSinceUtc;
    private readonly Action? afterReadBeforeSnapshot;
    private readonly Action<string>? afterFirstFileRead;
    private readonly Func<SafeFileHandle, ClaudeFileIdentity?> readIdentity;
    private readonly SessionReader reader = new();
    private Task[] previous = [];
    private bool currentSeen, legacySeen;
    private bool pendingRead, pendingLoss, connectionLoss;
    private Cursor? currentCursor, legacyCursor;
    private ClaudeConnection? signalledConnection;
    private long generation;
    private bool signalLoss, generationExhausted;
    private Task[]? pendingFallback;

    public ClaudeFileSource(string currentPath, string? legacyPath, DateTime observedSinceUtc)
        : this(currentPath, legacyPath, observedSinceUtc, null) { }

    // A synchronization seam for synthetic tests; production uses the public constructor.
    internal ClaudeFileSource(string currentPath, string? legacyPath, DateTime observedSinceUtc,
        Action? afterReadBeforeSnapshot, Action<string>? afterFirstFileRead = null,
        Func<SafeFileHandle, ClaudeFileIdentity?>? readIdentity = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(currentPath);
        if (!Path.IsPathFullyQualified(currentPath)) throw new ArgumentException("Current event path must be absolute.", nameof(currentPath));
        if (legacyPath is not null && !Path.IsPathFullyQualified(legacyPath)) throw new ArgumentException("Legacy event path must be absolute.", nameof(legacyPath));
        if (observedSinceUtc.Kind != DateTimeKind.Utc) throw new ArgumentException("Observation time must be UTC.", nameof(observedSinceUtc));
        this.currentPath = currentPath;
        this.legacyPath = legacyPath;
        this.observedSinceUtc = observedSinceUtc;
        this.afterReadBeforeSnapshot = afterReadBeforeSnapshot;
        this.afterFirstFileRead = afterFirstFileRead;
        this.readIdentity = readIdentity ?? ClaudeFileIdentityReader.Read;
    }

    // Call as soon as the owner observes a change, including while a poll runs.
    // A separate lock lets notification invalidate an in-flight result promptly.
    public void NotifyConnection(ClaudeConnection connection)
    {
        if (!Enum.IsDefined(connection)) throw new ArgumentOutOfRangeException(nameof(connection));
        lock (signalGate)
        {
            if (signalledConnection == connection) return;
            signalledConnection = connection;
            if (connection != ClaudeConnection.Connected) signalLoss = true;
            AdvanceGeneration();
        }
    }

    // Does not wait for the file-read lock. A source-owned snapshot may be
    // retained as an unconfirmed fallback after the in-flight read finishes.
    public void NotifyUnavailable(ClaudeSourceSnapshot? fallback)
    {
        lock (signalGate)
        {
            if (fallback is not null && ReferenceEquals(fallback.Owner, identity) &&
                fallback.RetainedFallback is { Length: > 0 } && pendingFallback is null)
                pendingFallback = fallback.RetainedFallback;
            signalLoss = true;
            AdvanceGeneration();
        }
    }

    private void AdvanceGeneration()
    {
        // Caller holds signalGate. Once exhausted, no snapshot is considered current.
        if (generation == long.MaxValue) generationExhausted = true;
        else generation++;
    }

    private readonly record struct ConnectionSignal(ClaudeConnection? Connection, long Generation, bool Loss, bool Exhausted,
        Task[]? Fallback);
    private ConnectionSignal Signal()
    {
        lock (signalGate) return new(signalledConnection, generation, signalLoss, generationExhausted, pendingFallback);
    }

    // Exposes the retained-loss marker to the synthetic test assembly only.
    internal bool HasObservedSourceLoss => reader.SourceUncertain;

    private ClaudeSourceSnapshot Stamp(ClaudeSourceSnapshot snapshot, ConnectionSignal signal)
    {
        // Freeze bounded names while already off the UI thread. The deadline
        // signal can then retain this private copy without taking the file lock.
        Task[] fallback = MergePending([], snapshot.Tasks, out _);
        return snapshot with { Generation = signal.Generation, Owner = identity, RetainedFallback = fallback };
    }

    // The owner must serialize this check with presentation and notifications.
    public bool IsCurrent(ClaudeSourceSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        lock (signalGate)
            return !generationExhausted && ReferenceEquals(snapshot.Owner, identity) && snapshot.Generation == generation;
    }

    public ClaudeSourceSnapshot Poll(ClaudeConnection connection, DateTime utcNow)
    {
        if (utcNow.Kind != DateTimeKind.Utc) throw new ArgumentException("Poll time must be UTC.", nameof(utcNow));
        NotifyConnection(connection);
        return Poll(utcNow);
    }

    // Uses the last signalled connection rather than a potentially stale caller snapshot.
    public ClaudeSourceSnapshot Poll(DateTime utcNow)
    {
        if (utcNow.Kind != DateTimeKind.Utc) throw new ArgumentException("Poll time must be UTC.", nameof(utcNow));
        lock (gate)
        {
            ConnectionSignal start = Signal();
            if (start.Connection is null) throw new InvalidOperationException("A connection must be signalled before polling.");
            Task[] before = previous;
            if (start.Loss || start.Exhausted) MarkConnectionLoss();
            ConsumeFallback(start.Fallback);
            ClaudeSourceSnapshot result = PollLocked(start.Connection.Value, utcNow);
            afterReadBeforeSnapshot?.Invoke();
            ConnectionSignal end = Signal();
            if (end.Generation != start.Generation || end.Exhausted)
            {
                if (end.Loss || end.Exhausted)
                {
                    MarkConnectionLoss();
                    previous = MergePending(before, previous, out bool overflow);
                    if (overflow) reader.MarkSourceLoss();
                    ConsumeFallback(end.Fallback);
                }
                result = end.Connection == ClaudeConnection.Disconnected
                    ? new ClaudeSourceSnapshot([], false)
                    : new ClaudeSourceSnapshot(Copy(previous, true), true);
            }
            return Stamp(result, end);
        }
    }

    private void MarkConnectionLoss()
    {
        if (connectionLoss) return;
        connectionLoss = true;
        reader.MarkSourceLoss();
        previous = MergePending([], previous, out bool overflow);
        if (overflow) reader.MarkSourceLoss();
        pendingLoss = true;
    }

    private void ConsumeFallback(Task[]? fallback)
    {
        if (fallback is null) return;
        previous = MergePending(fallback, previous, out bool overflow);
        if (overflow) reader.MarkSourceLoss();
        lock (signalGate)
        {
            if (ReferenceEquals(pendingFallback, fallback)) pendingFallback = null;
        }
    }

    private ClaudeSourceSnapshot PollLocked(ClaudeConnection connection, DateTime utcNow)
    {
            if (connection == ClaudeConnection.Disconnected)
            {
                pendingRead = false;
                return new ClaudeSourceSnapshot([], false);
            }
            try
            {
                Tail? current = ReadOptional(currentPath, ref currentSeen, ref currentCursor, afterFirstFileRead, readIdentity);
                Tail? legacy = legacyPath is null ? null : ReadOptional(legacyPath, ref legacySeen, ref legacyCursor, afterFirstFileRead, readIdentity);
                bool isPending = current?.Pending == true || legacy?.Pending == true;
                if (current?.Discontinuity == true || legacy?.Discontinuity == true ||
                    current?.WindowMoved == true || legacy?.WindowMoved == true)
                {
                    reader.MarkSourceLoss();
                    if (pendingRead || isPending) pendingLoss = true;
                }
                if (isPending)
                {
                    // Do not mutate the stateful reader until all visible input
                    // is complete: a Stop in the prefix can otherwise erase the
                    // retained card before a subsequent read failure or loss.
                    bool provisionalLoss;
                    Task[] provisional = Reader.ReadWithSourceLoss(current?.Text ?? "", legacy?.Text ?? "",
                        utcNow, observedSinceUtc, false, out provisionalLoss, null!, null!, null!, null!);
                    if (provisionalLoss) { reader.MarkSourceLoss(); pendingLoss = true; }
                    previous = MergePending(previous, provisional, out bool overflow);
                    if (overflow) { reader.MarkSourceLoss(); pendingLoss = true; }
                    pendingRead = true;
                    bool unavailable = previous.Length != 0 || legacy?.Pending == true ||
                        connection == ClaudeConnection.Partial || reader.RetentionOverflow || pendingLoss;
                    return new ClaudeSourceSnapshot(Copy(previous, true), unavailable);
                }
                bool sourceWasUncertain = reader.SourceUncertain;
                Task[] parsed = reader.Read(current?.Text ?? "", legacy?.Text ?? "", utcNow, observedSinceUtc);
                // A newly rejected event can hide a relevant earlier record.
                // Keep the previously visible cards until a recovery protocol exists.
                if (!sourceWasUncertain && reader.SourceUncertain) pendingLoss = true;
                if (pendingRead && reader.SourceUncertain) pendingLoss = true;
                pendingRead = false;
                if (pendingLoss)
                {
                    previous = MergePending(previous, parsed, out bool overflow);
                    if (overflow) reader.MarkSourceLoss();
                    return new ClaudeSourceSnapshot(Copy(previous, true), true);
                }
                bool uncertain = connection == ClaudeConnection.Partial;
                previous = Copy(parsed, uncertain);
                return new ClaudeSourceSnapshot(Copy(previous, false), uncertain || reader.RetentionOverflow || reader.SourceUncertain);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException or DecoderFallbackException)
            {
                if (pendingRead) pendingLoss = true;
                reader.MarkSourceLoss();
                previous = Copy(previous, true);
                return new ClaudeSourceSnapshot(Copy(previous, false), true);
            }
    }

    public ClaudeSourceSnapshot ReportUnavailable()
    {
        lock (signalGate)
        {
            signalLoss = true;
            AdvanceGeneration();
        }
        lock (gate)
        {
            MarkConnectionLoss();
            ConnectionSignal signal = Signal();
            ConsumeFallback(signal.Fallback);
            ClaudeSourceSnapshot result = signal.Connection == ClaudeConnection.Disconnected
                ? new ClaudeSourceSnapshot([], false)
                : new ClaudeSourceSnapshot(Copy(previous, true), true);
            return Stamp(result, signal);
        }
    }

    private readonly record struct Cursor(long Length, byte[] ObservedDigest, long FirstCompleteOffset);
    private readonly record struct Tail(string Text, bool Pending, Cursor Cursor, bool Discontinuity, bool WindowMoved);

    private static Tail? ReadOptional(string path, ref bool seen, ref Cursor? cursor, Action<string>? afterFirstFileRead,
        Func<SafeFileHandle, ClaudeFileIdentity?> readIdentity)
    {
        try
        {
            Tail text = ReadCompleteTail(path, cursor, afterFirstFileRead, readIdentity);
            seen = true;
            cursor = text.Cursor;
            return text;
        }
        catch (FileNotFoundException) when (!seen) { return null; }
        catch (DirectoryNotFoundException) when (!seen) { return null; }
    }

    // Read the bounded window twice through independently opened handles. An
    // append after the captured length may wait until the next poll, but a
    // changed captured range records source loss. Matching identities are
    // required while both handles are open; identity is not kept across polls.
    private static Tail ReadCompleteTail(string path, Cursor? prior, Action<string>? afterFirstFileRead,
        Func<SafeFileHandle, ClaudeFileIdentity?> readIdentity)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
        long length = stream.Length;
        int count = (int)Math.Min(length, MaximumTailBytes);
        long start = length - count;
        int prefix = start > 0 ? 1 : 0;
        long readStart = start - prefix;
        var captured = new byte[count + prefix];
        stream.Seek(readStart, SeekOrigin.Begin);
        stream.ReadExactly(captured);
        afterFirstFileRead?.Invoke(path);
        try
        {
            using var verify = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
            ClaudeFileIdentity? capturedIdentity, verifiedIdentity;
            try
            {
                capturedIdentity = readIdentity(stream.SafeFileHandle);
                verifiedIdentity = readIdentity(verify.SafeFileHandle);
            }
            catch (Exception error) { throw new IOException("Event source identity could not be checked.", error); }
            if (!capturedIdentity.HasValue || !verifiedIdentity.HasValue ||
                !capturedIdentity.Value.IsUsable || !verifiedIdentity.Value.IsUsable ||
                capturedIdentity.Value != verifiedIdentity.Value)
                throw new IOException("Event source identity changed or could not be checked.");
            if (verify.Length < length) throw new IOException("Event source shortened during reading.");
            var repeated = new byte[captured.Length];
            verify.Seek(readStart, SeekOrigin.Begin);
            verify.ReadExactly(repeated);
            if (verify.Length < length || !captured.AsSpan().SequenceEqual(repeated))
                throw new IOException("Event source changed during reading.");
        }
        // Once the first open succeeded, a missing path is a read loss, not an
        // optional source that has never existed.
        catch (FileNotFoundException error) { throw new IOException("Event source disappeared during reading.", error); }
        catch (DirectoryNotFoundException error) { throw new IOException("Event source disappeared during reading.", error); }

        ReadOnlySpan<byte> bytes = captured.AsSpan(prefix, count);
        bool atLineBoundary = start == 0 || captured[0] == '\n';
        int first = 0;
        if (!atLineBoundary)
        {
            int boundary = bytes.IndexOf((byte)'\n');
            if (boundary < 0) throw new IOException("No complete event fits in the source tail.");
            first = boundary + 1;
        }
        int last = bytes.LastIndexOf((byte)'\n');
        long firstCompleteOffset = start + first;
        // A first bounded read has no evidence about any omitted prefix. On
        // later reads, crossing a previously observed line has the same effect.
        bool windowMoved = prior is { } oldWindow
            ? firstCompleteOffset > oldWindow.FirstCompleteOffset
            : start > 0;
        bool discontinuity = false;
        if (prior is { } old)
        {
            if (length < old.Length || old.FirstCompleteOffset < start || old.FirstCompleteOffset > old.Length)
                discontinuity = true;
            else
            {
                int oldOffset = checked((int)(old.FirstCompleteOffset - start));
                int oldCount = checked((int)(old.Length - old.FirstCompleteOffset));
                byte[] oldDigest = SHA256.HashData(bytes.Slice(oldOffset, oldCount));
                discontinuity = !CryptographicOperations.FixedTimeEquals(oldDigest, old.ObservedDigest);
            }
        }
        byte[] digest = SHA256.HashData(bytes[first..]);
        var cursor = new Cursor(length, digest, firstCompleteOffset);
        if (count == 0) return new Tail("", false, cursor, discontinuity, windowMoved);
        if (last < first)
        {
            return new Tail("", true, cursor, discontinuity, windowMoved);
        }
        string text = StrictUtf8.GetString(bytes.Slice(first, last - first + 1));
        return new Tail(text.Length > 0 && text[0] == '\uFEFF' ? text[1..] : text,
            last != bytes.Length - 1, cursor, discontinuity, windowMoved);
    }

    private static Task[] MergePending(IEnumerable<Task> prior, IEnumerable<Task> fresh, out bool overflow)
    {
        overflow = false;
        var result = new List<Task>();
        var positions = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (Task item in prior.Concat(fresh))
        {
            if (positions.TryGetValue(item.Id, out int index))
            {
                Task merged = SessionReader.Freeze(item, result[index], true);
                if (merged.RetainedPlanIncomplete) overflow = true;
                result[index] = merged;
            }
            else if (result.Count < SessionReader.MaximumRetained)
            {
                Task retained = SessionReader.Freeze(item, null!, true);
                if (retained.RetainedPlanIncomplete) overflow = true;
                positions.Add(item.Id, result.Count);
                result.Add(retained);
            }
            else overflow = true;
        }
        return result.ToArray();
    }

    private static Task[] Copy(IEnumerable<Task> source, bool forceUnconfirmed) => source.Select(item =>
    {
        Step[] steps = item.Steps.Select(step => new Step { id = step.id, title = step.title,
            status = forceUnconfirmed ? "unknown" : step.status, generated = step.generated,
            RetainedIdentity = step.RetainedIdentity }).ToArray();
        return new Task { Id = item.Id, Activity = forceUnconfirmed ? "" : item.Activity,
            Updated = item.Updated, Started = item.Started, StartKey = item.StartKey, Steps = steps,
            Unconfirmed = forceUnconfirmed || item.Unconfirmed,
            PlanConfirmed = !forceUnconfirmed && item.PlanConfirmed,
            KnownStepCount = forceUnconfirmed ? 0 : item.KnownStepCount,
            KnownDoneCount = forceUnconfirmed ? 0 : item.KnownDoneCount,
            UnknownStepCount = forceUnconfirmed ? steps.Length : item.UnknownStepCount,
            SessionEvidenceUncertain = item.SessionEvidenceUncertain,
            PlanEvidenceUncertain = item.PlanEvidenceUncertain,
            RetainedPlanIncomplete = item.RetainedPlanIncomplete };
    }).ToArray();
}
