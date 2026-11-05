using System.Globalization;
using System.Security;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AITaskMonitor.CodexIndex;

// The reader never discovers a profile or opens session transcripts. Paths,
// observed IDs and held/unavailable lock IDs are supplied by the caller.
public sealed record CodexIndexEntry(string Id, string Title, string UpdatedVersion, DateOnly? Date)
{
    public override string ToString() => nameof(CodexIndexEntry);
}

// A malformed or noncanonical row is reported without retaining its contents.
// The eventual integration must decide how to present an uncertain source.
public sealed record CodexIndexReadResult(IReadOnlyList<CodexIndexEntry> Entries, bool HasUnsupportedRows);

public sealed class CodexIndexUnavailableException : IOException
{
    public CodexIndexUnavailableException() : base("The Codex session index cannot be read.") { }
}

public sealed class CodexIndexReader
{
    private const int TailCount = 50;
    private const int MaximumHistoryLine = 1_048_576;
    private static readonly StringComparer Keys = StringComparer.OrdinalIgnoreCase;
    private static readonly Regex ValidId = new(@"\A[A-Za-z0-9_-]{1,128}\z", RegexOptions.CultureInvariant);
    private readonly object gate = new();
    private readonly string indexPath;
    private string? cacheVersion;
    private Dictionary<string, CodexIndexEntry?> historical = new(Keys);
    private bool historicalUnsupported;

    public CodexIndexReader(string indexFile)
    {
        if (string.IsNullOrWhiteSpace(indexFile) || !Path.IsPathFullyQualified(indexFile))
            throw new ArgumentException("An absolute index file path is required.", nameof(indexFile));
        indexPath = Path.GetFullPath(indexFile);
    }

    public CodexIndexReadResult Read(IEnumerable<string> observedIds, IEnumerable<string> heldOrUnavailableLockIds)
    {
        ArgumentNullException.ThrowIfNull(observedIds);
        ArgumentNullException.ThrowIfNull(heldOrUnavailableLockIds);
        // Materialize before changing cache state and serialize all calls on this reader.
        string[] observed = observedIds.ToArray();
        string[] locks = heldOrUnavailableLockIds.ToArray();
        lock (gate)
        {
            try
            {
                return ReadCore(observed, locks);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException or DecoderFallbackException)
            {
                // Do not copy the source exception, file path, or row contents.
                throw new CodexIndexUnavailableException();
            }
        }
    }

    private CodexIndexReadResult ReadCore(string[] observed, string[] locks)
    {
        var entries = new Dictionary<string, CodexIndexEntry>(Keys);
        bool unsupported = false;
        foreach (string line in ReadTail())
        {
            Row row = Parse(line);
            unsupported |= row.Unsupported;
            if (row.Entry is not null) entries[row.Entry.Id] = row.Entry;
        }

        var needed = new HashSet<string>(Keys);
        foreach (string? id in observed.Concat(locks))
        {
            if (id is null || !ValidId.IsMatch(id)) { unsupported = true; continue; }
            if (!entries.ContainsKey(id)) needed.Add(id);
        }

        if (needed.Count > 0)
        {
            var info = new FileInfo(indexPath);
            info.Refresh();
            string version = string.Concat(info.FullName, "|", info.Length.ToString(CultureInfo.InvariantCulture),
                "|", info.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture));
            if (!string.Equals(cacheVersion, version, StringComparison.Ordinal))
            {
                cacheVersion = version;
                historical = new Dictionary<string, CodexIndexEntry?>(Keys);
                historicalUnsupported = false;
            }
            string[] missing = needed.Where(id => !historical.ContainsKey(id)).ToArray();
            if (missing.Length > 0)
            {
                // Publish cache updates only after a successful scan. The old
                // script retains negative entries after a failed scan.
                var pending = missing.ToDictionary(id => id, _ => (CodexIndexEntry?)null, Keys);
                bool scanUnsupported = false;
                string filter = "\"(?:" + string.Join("|", missing.Select(Regex.Escape)) + ")\"";
                var matcher = new Regex(filter, RegexOptions.IgnoreCase);
                using var stream = Open();
                IndexEncoding encoding = DetectEncoding(stream);
                stream.Position = encoding.PreambleLength;
                using var reader = new StreamReader(stream, encoding.Encoding, false);
                while (reader.ReadLine() is string line)
                {
                    if (line.Length > MaximumHistoryLine) throw new IOException();
                    Row row = Parse(line);
                    scanUnsupported |= row.Unsupported;
                    if (!matcher.IsMatch(line)) continue;
                    if (row.Entry is not null && pending.ContainsKey(row.Entry.Id))
                        pending[row.Entry.Id] = row.Entry;
                }
                foreach ((string id, CodexIndexEntry? entry) in pending) historical[id] = entry;
                historicalUnsupported |= scanUnsupported;
            }
            unsupported |= historicalUnsupported;
            foreach (string id in needed)
                if (historical.TryGetValue(id, out CodexIndexEntry? entry) && entry is not null)
                    entries[id] = entry;
        }
        return new CodexIndexReadResult(entries.Values.ToArray(), unsupported);
    }

    private FileStream Open() => new(indexPath, FileMode.Open, FileAccess.Read,
        FileShare.ReadWrite | FileShare.Delete);

    // Do not let StreamReader's automatic BOM detection replace a strict
    // decoder with a replacement-fallback decoder.
    private sealed record IndexEncoding(Encoding Encoding, int PreambleLength, bool Wide);

    private static IndexEncoding DetectEncoding(FileStream stream)
    {
        byte[] prefix = new byte[4];
        stream.Position = 0;
        int count = 0;
        while (count < prefix.Length)
        {
            int read = stream.Read(prefix, count, prefix.Length - count);
            if (read == 0) break;
            count += read;
        }
        if (count >= 4 && prefix[0] == 0x00 && prefix[1] == 0x00 && prefix[2] == 0xfe && prefix[3] == 0xff)
            return new IndexEncoding(new UTF32Encoding(true, true, true), 4, true);
        if (count >= 4 && prefix[0] == 0xff && prefix[1] == 0xfe && prefix[2] == 0x00 && prefix[3] == 0x00)
            return new IndexEncoding(new UTF32Encoding(false, true, true), 4, true);
        if (count >= 2 && prefix[0] == 0xfe && prefix[1] == 0xff)
            return new IndexEncoding(new UnicodeEncoding(true, true, true), 2, true);
        if (count >= 2 && prefix[0] == 0xff && prefix[1] == 0xfe)
            return new IndexEncoding(new UnicodeEncoding(false, true, true), 2, true);
        if (count >= 3 && prefix[0] == 0xef && prefix[1] == 0xbb && prefix[2] == 0xbf)
            return new IndexEncoding(new UTF8Encoding(false, true), 3, false);
        return new IndexEncoding(new UTF8Encoding(false, true), 0, false);
    }

    // Locate the final 50 UTF-8 lines backwards; BOM-marked UTF-16/32 is read
    // forwards because newline bytes are not independent code points there.
    private IEnumerable<string> ReadTail()
    {
        using var stream = Open();
        long length = stream.Length;
        if (length == 0) return Array.Empty<string>();
        IndexEncoding encoding = DetectEncoding(stream);
        long start = encoding.Wide ? encoding.PreambleLength : FindTailStart(stream, length);
        if (start == 0) start = encoding.PreambleLength;
        stream.Position = start;
        using var reader = new StreamReader(stream, encoding.Encoding, false);
        var tail = new Queue<string>(TailCount);
        while (reader.ReadLine() is string line)
        {
            if (tail.Count == TailCount) tail.Dequeue();
            tail.Enqueue(line);
        }
        return tail.ToArray();
    }

    private static long FindTailStart(FileStream stream, long length)
    {
        byte[] buffer = new byte[8192];
        long position = length;
        int count = 0;
        bool skipPairedCr = false;
        while (position > 0)
        {
            int requested = (int)Math.Min(buffer.Length, position);
            position -= requested;
            stream.Position = position;
            int read = 0;
            while (read < requested)
            {
                int n = stream.Read(buffer, read, requested - read);
                if (n == 0) throw new IOException();
                read += n;
            }
            for (int i = read - 1; i >= 0; i--)
            {
                byte value = buffer[i];
                if (skipPairedCr)
                {
                    skipPairedCr = false;
                    if (value == (byte)'\r') continue;
                }
                if (value != (byte)'\r' && value != (byte)'\n') continue;
                long after = position + i + 1;
                if (value == (byte)'\n') skipPairedCr = true;
                if (after == length) continue;
                if (++count == TailCount) return after;
            }
        }
        return 0;
    }

    private sealed record Row(CodexIndexEntry? Entry, bool Unsupported);

    private static Row Parse(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return new Row(null, false);
        try
        {
            using JsonDocument json = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 100 });
            JsonElement root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object || HasCaseCollision(root)) return new Row(null, true);
            JsonElement? idValue = Property(root, "id");
            if (idValue is null || idValue.Value.ValueKind == JsonValueKind.Null) return new Row(null, true);
            if (idValue.Value.ValueKind != JsonValueKind.String) return new Row(null, true);
            string id = idValue.Value.GetString() ?? "";
            if (!ValidId.IsMatch(id)) return new Row(null, true);
            JsonElement? title = Property(root, "thread_name");
            JsonElement? updated = Property(root, "updated_at");
            if (!StringOrNull(title) || !StringOrNull(updated)) return new Row(null, true);
            string titleText = title is { ValueKind: JsonValueKind.String } ? title.Value.GetString() ?? "" : "";
            string version = updated is { ValueKind: JsonValueKind.String } ? updated.Value.GetString() ?? "" : "";
            DateOnly? date = DateTime.TryParse(version, CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTime value)
                ? DateOnly.FromDateTime(value) : null;
            return new Row(new CodexIndexEntry(id, titleText, version, date), false);
        }
        catch (JsonException) { return new Row(null, true); }
        catch (InvalidOperationException) { return new Row(null, true); }
    }

    private static bool StringOrNull(JsonElement? value) =>
        value is null || value.Value.ValueKind is JsonValueKind.String or JsonValueKind.Null;

    // PowerShell property access is case-insensitive; repeated identical keys
    // select the last value, while differently cased keys cause a parse error.
    private static JsonElement? Property(JsonElement root, string name)
    {
        JsonElement? found = null;
        foreach (JsonProperty property in root.EnumerateObject())
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase)) found = property.Value;
        return found;
    }

    private static bool HasCaseCollision(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Array)
            return element.EnumerateArray().Any(HasCaseCollision);
        if (element.ValueKind != JsonValueKind.Object) return false;
        var names = new Dictionary<string, string>(Keys);
        foreach (JsonProperty property in element.EnumerateObject())
        {
            if (names.TryGetValue(property.Name, out string? prior) &&
                !string.Equals(prior, property.Name, StringComparison.Ordinal)) return true;
            names[property.Name] = property.Name;
            if (HasCaseCollision(property.Value)) return true;
        }
        return false;
    }
}
