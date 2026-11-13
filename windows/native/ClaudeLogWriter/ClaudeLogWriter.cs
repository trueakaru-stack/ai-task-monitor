using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using AITaskMonitor.ClaudeHook;

namespace AITaskMonitor.ClaudeLogWriter;

public enum ClaudeLogWriteResult { Written, Busy }

/// <summary>An isolated writer for already translated Claude events.</summary>
public static class ClaudeLogWriter
{
    public const string EventFileName = "claude-events-v2.jsonl";
    private static readonly UTF8Encoding Utf8 = new(false);
    private static readonly JsonSerializerOptions JsonOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private static readonly Regex MutexName = new(@"\ALocal\\[A-Za-z0-9_.-]{1,150}\z", RegexOptions.CultureInvariant);

    /// <summary>
    /// Appends one translated event under a caller-selected local mutex. The
    /// directory must be an existing drive-letter path (UNC is rejected), and
    /// all its components must be ordinary
    /// directories. Zero disables rotation; other limits are integral decimal
    /// megabytes from 1 to 100. I/O and unsafe-path failures are propagated.
    /// </summary>
    public static ClaudeLogWriteResult Write(string directory, string mutexName, long maximumBytes, ClaudeEventRecord record)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(mutexName);
        ArgumentNullException.ThrowIfNull(record);
        if (!MutexName.IsMatch(mutexName)) throw new ArgumentException("Expected a local mutex name.", nameof(mutexName));
        if (maximumBytes != 0 && (maximumBytes < 1_000_000 || maximumBytes > 100_000_000 || maximumBytes % 1_000_000 != 0))
            throw new ArgumentOutOfRangeException(nameof(maximumBytes));
        if (!Path.IsPathFullyQualified(directory)) throw new ArgumentException("An absolute drive-letter directory is required; UNC paths are not supported.", nameof(directory));
        string full = Path.GetFullPath(directory);
        string root = Path.GetPathRoot(full) ?? "";
        if (root.Length != 3 || !char.IsAsciiLetter(root[0]) || root[1] != ':' || root[2] != '\\')
            throw new ArgumentException("An absolute drive-letter directory is required; UNC paths are not supported.", nameof(directory));
        if (record.Provider != "claude" || record.Timestamp is null || record.SessionId is null || record.Event is null ||
            record.Activity is null || record.TaskId is null || record.TaskSubject is null || record.TaskStatus is null || record.ToolName is null)
            throw new ArgumentException("A translated Claude record is required.", nameof(record));
        // Match the reader's parser before touching the log. The marker and the
        // associated event must sort at the same instant, in file order.
        if (!DateTimeOffset.TryParse(record.Timestamp, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out DateTimeOffset eventTime))
            throw new ArgumentException("The record timestamp is invalid.", nameof(record));

        string line = JsonSerializer.Serialize(record, JsonOptions) + "\r\n";
        string eventPath = Path.Combine(full, EventFileName);
        AssertOrdinaryDirectoryAndAncestors(full);
        using var mutex = new Mutex(false, mutexName);
        bool owned = false;
        try
        {
            try { owned = mutex.WaitOne(TimeSpan.FromSeconds(2)); }
            catch (AbandonedMutexException) { owned = true; throw; }
            if (!owned) return ClaudeLogWriteResult.Busy;

            AssertOrdinaryDirectoryAndAncestors(full);
            bool exists = AssertOrdinaryFileOrMissing(eventPath);
            bool needsDelimiter = false;
            bool rotated = exists && maximumBytes > 0 && RotateIfNeeded(eventPath, maximumBytes, out needsDelimiter);
            AssertOrdinaryDirectoryAndAncestors(full);
            AssertOrdinaryFileOrMissing(eventPath);
            if (rotated)
            {
                // Rotation discards history. The marker must be its own line and
                // precede the associated event even when the reader sorts by time.
                var marker = ClaudeHookTranslator.SourceUncertain(eventTime) with { Activity = "" };
                File.AppendAllText(eventPath, (needsDelimiter ? "\n" : "") + JsonSerializer.Serialize(marker, JsonOptions) + "\r\n", Utf8);
            }
            File.AppendAllText(eventPath, line, Utf8);
            return ClaudeLogWriteResult.Written;
        }
        finally
        {
            if (owned) mutex.ReleaseMutex();
        }
    }

    private static bool RotateIfNeeded(string path, long maximumBytes, out bool needsDelimiter)
    {
        needsDelimiter = false;
        if (!AssertOrdinaryFileOrMissing(path)) return false;
        if (new FileInfo(path).Length <= maximumBytes) return false;

        string tail;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            long take = Math.Min(maximumBytes * 9 / 10, stream.Length);
            stream.Seek(-take, SeekOrigin.End);
            using var reader = new StreamReader(stream, Encoding.UTF8, true, 4096, leaveOpen: true);
            tail = reader.ReadToEnd();
        }
        int newline = tail.IndexOf('\n');
        if (newline >= 0) tail = tail[(newline + 1)..];
        needsDelimiter = tail.Length > 0 && tail[^1] != '\n';

        string temporary = Path.Combine(Path.GetDirectoryName(path)!, ".aitm-hook-retention-" + Guid.NewGuid().ToString("N") + ".tmp");
        bool created = false;
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                created = true;
                using var writer = new StreamWriter(output, Utf8);
                writer.Write(tail);
            }
            AssertOrdinaryDirectoryAndAncestors(Path.GetDirectoryName(path)!);
            if (!AssertOrdinaryFileOrMissing(path)) throw new IOException("The event file disappeared during rotation.");
            File.Replace(temporary, path, null);
            return true;
        }
        finally
        {
            if (created) try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static void AssertOrdinaryDirectoryAndAncestors(string directory)
    {
        for (DirectoryInfo? item = new(directory); item is not null; item = item.Parent)
        {
            FileAttributes attributes = File.GetAttributes(item.FullName);
            if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("The event directory has an unsafe component.");
        }
    }

    private static bool AssertOrdinaryFileOrMissing(string path)
    {
        FileAttributes attributes;
        try { attributes = File.GetAttributes(path); }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("The event path is not an ordinary file.");
        return true;
    }
}
