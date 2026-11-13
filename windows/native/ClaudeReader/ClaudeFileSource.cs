#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security;
using System.Security.Cryptography;
using System.Text;

namespace AITaskMonitor.Claude;

public enum ClaudeConnection { Disconnected, Partial, Connected }

public sealed record ClaudeSourceSnapshot(IReadOnlyList<Task> Tasks, bool Unavailable);

// One instance belongs to one monitor session. Paths and connection state are
// supplied by its caller; this class does not find profiles or install hooks.
public sealed class ClaudeFileSource
{
    private const int MaximumTailBytes = 4 * 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly object gate = new();
    private readonly string currentPath;
    private readonly string? legacyPath;
    private readonly DateTime observedSinceUtc;
    private readonly SessionReader reader = new();
    private Task[] previous = [];
    private bool currentSeen, legacySeen;
    private bool pendingRead, pendingLoss;
    private Cursor? currentCursor, legacyCursor;

    public ClaudeFileSource(string currentPath, string? legacyPath, DateTime observedSinceUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(currentPath);
        if (!Path.IsPathFullyQualified(currentPath)) throw new ArgumentException("Current event path must be absolute.", nameof(currentPath));
        if (legacyPath is not null && !Path.IsPathFullyQualified(legacyPath)) throw new ArgumentException("Legacy event path must be absolute.", nameof(legacyPath));
        if (observedSinceUtc.Kind != DateTimeKind.Utc) throw new ArgumentException("Observation time must be UTC.", nameof(observedSinceUtc));
        this.currentPath = currentPath;
        this.legacyPath = legacyPath;
        this.observedSinceUtc = observedSinceUtc;
    }

    public ClaudeSourceSnapshot Poll(ClaudeConnection connection, DateTime utcNow)
    {
        if (!Enum.IsDefined(connection)) throw new ArgumentOutOfRangeException(nameof(connection));
        if (utcNow.Kind != DateTimeKind.Utc) throw new ArgumentException("Poll time must be UTC.", nameof(utcNow));
        lock (gate)
        {
            if (connection == ClaudeConnection.Disconnected)
            {
                previous = [];
                pendingRead = false;
                return new ClaudeSourceSnapshot([], false);
            }
            try
            {
                Tail? current = ReadOptional(currentPath, ref currentSeen, ref currentCursor);
                if (current is null)
                    return new ClaudeSourceSnapshot([], connection == ClaudeConnection.Partial);
                Tail? legacy = legacyPath is null ? null : ReadOptional(legacyPath, ref legacySeen, ref legacyCursor);
                bool isPending = current.Value.Pending || legacy?.Pending == true;
                if (current.Value.Discontinuity || legacy?.Discontinuity == true ||
                    current.Value.WindowMoved || legacy?.WindowMoved == true)
                {
                    reader.MarkSourceLoss();
                    if (pendingRead || isPending) pendingLoss = true;
                }
                if (isPending)
                {
                    // Do not mutate the stateful reader until all visible input
                    // is complete: a Stop in the prefix can otherwise erase the
                    // retained card before a subsequent read failure or loss.
                    Task[] provisional = Reader.Read(current.Value.Text, legacy?.Text ?? "", utcNow, observedSinceUtc);
                    previous = MergePending(previous, provisional, out bool overflow);
                    if (overflow) { reader.MarkSourceLoss(); pendingLoss = true; }
                    pendingRead = true;
                    bool unavailable = previous.Length != 0 || legacy?.Pending == true ||
                        connection == ClaudeConnection.Partial || reader.RetentionOverflow || pendingLoss;
                    return new ClaudeSourceSnapshot(Copy(previous, true), unavailable);
                }
                Task[] parsed = reader.Read(current.Value.Text, legacy?.Text ?? "", utcNow, observedSinceUtc);
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
    }

    public ClaudeSourceSnapshot ReportUnavailable()
    {
        lock (gate)
        {
            if (pendingRead) pendingLoss = true;
            reader.MarkSourceLoss();
            previous = Copy(previous, true);
            return new ClaudeSourceSnapshot(Copy(previous, false), true);
        }
    }

    private readonly record struct Cursor(long Length, byte[] EndDigest, long FirstCompleteOffset);
    private readonly record struct Tail(string Text, bool Pending, Cursor Cursor, bool Discontinuity, bool WindowMoved);

    private static Tail? ReadOptional(string path, ref bool seen, ref Cursor? cursor)
    {
        try
        {
            Tail text = ReadCompleteTail(path, cursor);
            seen = true;
            cursor = text.Cursor;
            return text;
        }
        catch (FileNotFoundException) when (!seen) { return null; }
        catch (DirectoryNotFoundException) when (!seen) { return null; }
    }

    // Only complete newline-terminated records from a bounded snapshot are fed
    // to the reader. Concurrent appends wait until the next poll.
    private static byte[] DigestEnd(FileStream stream, long end)
    {
        int count = (int)Math.Min(128, end);
        var buffer = new byte[count];
        stream.Seek(end - count, SeekOrigin.Begin);
        stream.ReadExactly(buffer);
        return SHA256.HashData(buffer);
    }

    private static Tail ReadCompleteTail(string path, Cursor? prior)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
        long length = stream.Length;
        bool discontinuity = prior is { } old && (length < old.Length ||
            !CryptographicOperations.FixedTimeEquals(DigestEnd(stream, old.Length), old.EndDigest));
        byte[] digest = DigestEnd(stream, length);
        int count = (int)Math.Min(length, MaximumTailBytes);
        if (count == 0) return new Tail("", false, new Cursor(length, digest, 0), discontinuity, false);
        long start = length - count;
        bool atLineBoundary = start == 0;
        if (start > 0)
        {
            stream.Seek(start - 1, SeekOrigin.Begin);
            int precedingByte = stream.ReadByte();
            if (precedingByte < 0) throw new EndOfStreamException("Could not verify the source tail boundary.");
            atLineBoundary = precedingByte == '\n';
        }
        stream.Seek(start, SeekOrigin.Begin);
        var bytes = new byte[count];
        stream.ReadExactly(bytes);
        int first = 0;
        if (!atLineBoundary)
        {
            int boundary = Array.IndexOf(bytes, (byte)'\n');
            if (boundary < 0) throw new IOException("No complete event fits in the source tail.");
            first = boundary + 1;
        }
        int last = Array.LastIndexOf(bytes, (byte)'\n');
        long firstCompleteOffset = start + first;
        // A first bounded read has no evidence about any omitted prefix. On
        // later reads, crossing a previously observed line has the same effect.
        bool windowMoved = prior is { } oldWindow
            ? firstCompleteOffset > oldWindow.FirstCompleteOffset
            : start > 0;
        var cursor = new Cursor(length, digest, firstCompleteOffset);
        if (last < first)
        {
            return new Tail("", true, cursor, discontinuity, windowMoved);
        }
        string text = StrictUtf8.GetString(bytes, first, last - first + 1);
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
