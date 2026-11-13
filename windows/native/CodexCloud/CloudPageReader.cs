using System.Globalization;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AITaskMonitor.CodexCloud;

internal sealed record ParsedTask(string Id, string? Title, DateTimeOffset? UpdatedAt, bool Terminal)
{
    public override string ToString() => "Codex Cloud parsed task";
}

internal sealed record ParsedPage(IReadOnlyList<ParsedTask> Tasks, string? Cursor)
{
    public override string ToString() => "Codex Cloud parsed page";
}

internal static class CloudPageReader
{
    internal const int MaxPageBytes = 1_048_576;
    internal const int MaxTasks = 20;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    internal static bool TryRead(ReadOnlyMemory<byte> input, out ParsedPage? page)
    {
        page = null;
        if (input.Length == 0 || input.Length > MaxPageBytes)
            return false;

        // Take a bounded copy so that later parsing does not use the caller's buffer.
        // A caller must not mutate its buffer during this copy.
        byte[]? copy = null;
        try
        {
            copy = input.ToArray();
            _ = StrictUtf8.GetCharCount(copy);
            using JsonDocument document = JsonDocument.Parse(copy, new JsonDocumentOptions
            {
                MaxDepth = 32,
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow
            });
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !TryUnique(root, "tasks", out JsonElement tasks, out bool hasTasks) ||
                !hasTasks || tasks.ValueKind != JsonValueKind.Array ||
                tasks.GetArrayLength() > MaxTasks ||
                !TryUnique(root, "cursor", out JsonElement cursorValue, out bool hasCursor) ||
                !TryOptionalString(cursorValue, hasCursor, out string? cursor) ||
                (cursor is not null && !ValidOpaqueValue(cursor, 1024)))
                return false;

            var parsed = new List<ParsedTask>(tasks.GetArrayLength());
            var identifiers = new HashSet<string>(StringComparer.Ordinal);
            foreach (JsonElement item in tasks.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object ||
                    !TryUnique(item, "id", out JsonElement idValue, out bool hasId) ||
                    !hasId || idValue.ValueKind != JsonValueKind.String ||
                    !TryUnique(item, "title", out JsonElement titleValue, out bool hasTitle) ||
                    !TryOptionalString(titleValue, hasTitle, out string? title) ||
                    !TryUnique(item, "status", out JsonElement statusValue, out bool hasStatus) ||
                    !TryOptionalString(statusValue, hasStatus, out string? status) ||
                    !TryUnique(item, "updated_at", out JsonElement dateValue, out bool hasDate) ||
                    !TryOptionalString(dateValue, hasDate, out string? date))
                    return false;

                string? id = idValue.GetString();
                if (id is null || !ValidOpaqueValue(id, 512))
                    return false;

                byte[] idBytes = StrictUtf8.GetBytes(id);
                string stableId;
                try
                {
                    stableId = "codex-cloud:" + Convert.ToHexString(SHA256.HashData(idBytes))[..32].ToLowerInvariant();
                }
                finally
                {
                    Array.Clear(idBytes);
                }
                if (!identifiers.Add(stableId))
                    return false;

                // Validate even optional strings that are otherwise ignored.
                if (title is not null) _ = StrictUtf8.GetByteCount(title);
                if (status is not null) _ = StrictUtf8.GetByteCount(status);
                if (date is not null) _ = StrictUtf8.GetByteCount(date);
                DateTimeOffset? updated = null;
                if (date is not null && DateTimeOffset.TryParse(date, CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind, out DateTimeOffset value))
                    updated = value;

                bool terminal = status is "ready" or "error";
                parsed.Add(new ParsedTask(stableId, NormalizeTitle(title), updated, terminal));
            }
            page = new ParsedPage(parsed, cursor);
            return true;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or
            ArgumentException or OverflowException or IOException or UnauthorizedAccessException or
            NotSupportedException or SecurityException)
        {
            return false;
        }
        finally
        {
            if (copy is not null) Array.Clear(copy);
        }
    }

    private static bool TryUnique(JsonElement obj, string name, out JsonElement value, out bool found)
    {
        value = default;
        found = false;
        foreach (JsonProperty property in obj.EnumerateObject())
        {
            if (!property.NameEquals(name)) continue;
            if (found) return false;
            found = true;
            value = property.Value;
        }
        return true;
    }

    private static bool TryOptionalString(JsonElement value, bool found, out string? result)
    {
        result = null;
        if (!found || value.ValueKind == JsonValueKind.Null) return true;
        if (value.ValueKind != JsonValueKind.String) return false;
        result = value.GetString();
        return result is not null;
    }

    private static bool ValidOpaqueValue(string value, int maximumBytes)
    {
        if (value.Length == 0 || StrictUtf8.GetByteCount(value) > maximumBytes) return false;
        foreach (char character in value)
            if (character < 0x20 || character == 0x7f) return false;
        return true;
    }

    private static string? NormalizeTitle(string? title)
    {
        if (title is null) return null;
        var result = new StringBuilder(Math.Min(title.Length, 241));
        bool pendingSpace = false;
        foreach (char character in title)
        {
            if (char.IsWhiteSpace(character) || char.IsControl(character))
            {
                pendingSpace = result.Length > 0;
                continue;
            }
            if (pendingSpace) result.Append(' ');
            result.Append(character);
            pendingSpace = false;
        }
        if (result.Length <= 240) return result.ToString();
        int length = 239;
        if (char.IsHighSurrogate(result[length - 1]) && char.IsLowSurrogate(result[length]))
            length--;
        return result.ToString(0, length) + "…";
    }
}
