using System.Globalization;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using AITaskMonitor.CodexState;

namespace AITaskMonitor.CodexSource;

internal sealed record JournalRead(byte[] Bytes, byte[] Hash, DateTimeOffset UpdatedUtc,
    IReadOnlyList<LifecycleEvent> Events);

// This reader only uses explicit paths supplied by its caller. It is not a
// profile locator or a filesystem sandbox.
internal static class BoundedJournalReader
{
    internal const int MaximumBytes = 1_048_576;
    private const int MaximumLines = 8192;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private static readonly Regex ExplicitZone = new(@"(?:[zZ]|[+-][0-9]{2}:[0-9]{2})\z", RegexOptions.CultureInvariant);

    internal static JournalRead? Read(string path, string expectedId, DateTimeOffset nowUtc)
    {
        try
        {
            var before = new FileInfo(path);
            before.Refresh();
            if (!before.Exists || before.Length > MaximumBytes) return null;
            long length = before.Length;
            DateTime stamp = before.LastWriteTimeUtc;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
            if (stream.Length != length) return null;
            byte[] bytes = new byte[(int)length];
            stream.ReadExactly(bytes);
            if (stream.ReadByte() != -1 || stream.Length != length) return null;
            var after = new FileInfo(path);
            after.Refresh();
            if (!after.Exists || after.Length != length || after.LastWriteTimeUtc != stamp) return null;
            if (bytes.Length > 0 && bytes[^1] != (byte)'\n') return null;

            string text = StrictUtf8.GetString(bytes);
            if (text.StartsWith('\uFEFF')) text = text[1..];
            string[] lines = text.Split('\n');
            if (lines.Length > MaximumLines + 1) return null;
            var events = new List<LifecycleEvent>();
            bool identitySeen = false;
            string? openTurn = null;
            DateTimeOffset? lastTimestamp = null;
            var closedTurns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string raw in lines)
            {
                string line = raw.TrimEnd('\r');
                if (string.IsNullOrWhiteSpace(line)) continue;
                using JsonDocument document = JsonDocument.Parse(line);
                if (!identitySeen)
                {
                    if (!ValidIdentity(document.RootElement, expectedId)) return null;
                    identitySeen = true;
                    continue;
                }
                if (!TryEvent(document.RootElement, nowUtc, out LifecycleEvent? item)) return null;
                if (item is null) continue;
                if (item.Timestamp is not DateTimeOffset timestamp ||
                    (lastTimestamp is DateTimeOffset previous && timestamp <= previous)) return null;
                lastTimestamp = timestamp;
                if (item.Kind == LifecycleEventKind.Started)
                {
                    if (openTurn is not null || item.TurnId is null || closedTurns.Contains(item.TurnId)) return null;
                    openTurn = item.TurnId;
                }
                else
                {
                    if (openTurn is null || !string.Equals(openTurn, item.TurnId, StringComparison.Ordinal)) return null;
                    closedTurns.Add(openTurn);
                    openTurn = null;
                }
                events.Add(item);
            }
            if (!identitySeen) return null;
            return new JournalRead(bytes, SHA256.HashData(bytes), new DateTimeOffset(stamp, TimeSpan.Zero), events);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException
            or DecoderFallbackException or JsonException or ArgumentException or NotSupportedException)
        {
            // Do not expose a source path or raw record in diagnostics.
            return null;
        }
    }

    private static bool ValidIdentity(JsonElement record, string expectedId)
    {
        return record.ValueKind == JsonValueKind.Object && Unique(record, "type", out JsonElement type)
            && type.ValueKind == JsonValueKind.String && type.GetString() == "session_meta"
            && Unique(record, "payload", out JsonElement payload) && payload.ValueKind == JsonValueKind.Object
            && Unique(payload, "id", out JsonElement id) && id.ValueKind == JsonValueKind.String
            && string.Equals(id.GetString(), expectedId, StringComparison.Ordinal);
    }

    private static bool TryEvent(JsonElement record, DateTimeOffset nowUtc, out LifecycleEvent? item)
    {
        item = null;
        if (record.ValueKind != JsonValueKind.Object || !Unique(record, "type", out JsonElement type)
            || type.ValueKind != JsonValueKind.String) return false;
        if (type.GetString() == "token_usage_record")
            return Unique(record, "payload", out JsonElement usage) && usage.ValueKind == JsonValueKind.Object;
        if (type.GetString() != "event_msg") return false;
        if (!Unique(record, "payload", out JsonElement payload) || payload.ValueKind != JsonValueKind.Object
            || !Unique(payload, "type", out JsonElement kind) || kind.ValueKind != JsonValueKind.String) return false;

        string? eventType = kind.GetString();
        if (string.IsNullOrEmpty(eventType)) return false;
        LifecycleEventKind? mapped = eventType switch
        {
            "task_started" or "turn_started" => LifecycleEventKind.Started,
            "task_complete" or "turn_complete" => LifecycleEventKind.Completed,
            "turn_aborted" => LifecycleEventKind.Aborted,
            _ => null
        };
        if (mapped is null) return false;
        if (!OptionalString(payload, "turn_id", out string? turn)
            || !OptionalString(record, "timestamp", out string? rawTimestamp)) return false;
        if (string.IsNullOrEmpty(turn) || turn.Length > 256 || string.IsNullOrEmpty(rawTimestamp) || rawTimestamp.Length > 128
            || !ExplicitZone.IsMatch(rawTimestamp)
            || !DateTimeOffset.TryParse(rawTimestamp, CultureInfo.InvariantCulture, DateTimeStyles.None,
                out DateTimeOffset parsed)) return false;
        if (mapped != LifecycleEventKind.Started && !MissingOrNull(payload, "error")) return false;
        DateTimeOffset timestamp = parsed.ToUniversalTime();
        if (timestamp > nowUtc) return false;
        item = new LifecycleEvent(mapped.Value, turn, timestamp, rawTimestamp);
        return true;
    }

    private static bool MissingOrNull(JsonElement value, string name)
    {
        bool found = false;
        foreach (JsonProperty property in value.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase)) continue;
            if (found || !string.Equals(property.Name, name, StringComparison.Ordinal)) return false;
            found = true;
            if (property.Value.ValueKind != JsonValueKind.Null) return false;
        }
        return true;
    }

    private static bool OptionalString(JsonElement value, string name, out string? result)
    {
        result = null;
        bool found = false;
        foreach (JsonProperty property in value.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase)) continue;
            if (found || !string.Equals(property.Name, name, StringComparison.Ordinal)) return false;
            found = true;
            if (property.Value.ValueKind == JsonValueKind.Null) continue;
            if (property.Value.ValueKind != JsonValueKind.String) return false;
            result = property.Value.GetString();
        }
        return true;
    }

    private static bool Unique(JsonElement value, string name, out JsonElement result)
    {
        result = default;
        bool found = false;
        foreach (JsonProperty property in value.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase)) continue;
            if (found || !string.Equals(property.Name, name, StringComparison.Ordinal)) return false;
            found = true;
            result = property.Value;
        }
        return found;
    }
}
