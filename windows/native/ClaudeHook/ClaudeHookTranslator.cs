using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace AITaskMonitor.ClaudeHook;

// This record is the event-log contract. Input prompts, paths, commands,
// transcripts and tool responses have no output properties.
public sealed record ClaudeEventRecord(
    [property: JsonPropertyName("timestamp")] string Timestamp,
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("session_id")] string SessionId,
    [property: JsonPropertyName("event")] string Event,
    [property: JsonPropertyName("active")] bool Active,
    [property: JsonPropertyName("activity")] string Activity,
    [property: JsonPropertyName("task_id")] string TaskId,
    [property: JsonPropertyName("task_subject")] string TaskSubject,
    [property: JsonPropertyName("task_status")] string TaskStatus,
    [property: JsonPropertyName("tool_name")] string ToolName);

public static class ClaudeHookTranslator
{
    public const int MaximumInputCodeUnits = 1_048_576;
    private static readonly Regex Whitespace = new(@"\s+", RegexOptions.CultureInvariant);

    // The caller must impose the same input limit while reading the stream;
    // accepting a string here does not bound allocation by that caller.
    public static bool TryTranslate(string? json, DateTimeOffset timestamp, out ClaudeEventRecord? record)
    {
        record = null;
        if (string.IsNullOrEmpty(json) || json.Length > MaximumInputCodeUnits) return false;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 64 });
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !Validate(root)) return false;
            TryGet(root, "tool_input", out JsonElement input);

            string eventName = Read(root, "hook_event_name", "Unknown");
            string sessionId = Read(root, "session_id", "");
            string taskId = Has(root, "task_id") ? Read(root, "task_id", "")
                : Has(input, "taskId") ? Read(input, "taskId", "") : Read(input, "task_id", "");
            string taskStatus = Read(input, "status", "");
            string subject = Clip(Has(root, "task_subject") ? Read(root, "task_subject", "") : Read(input, "subject", ""), 240);
            string toolName = Clip(Read(root, "tool_name", ""), 120);

            string activity = eventName.ToUpperInvariant() switch
            {
                "USERPROMPTSUBMIT" => "New request",
                "PRETOOLUSE" => toolName.Length == 0 ? "Running tool" : "Running: " + toolName,
                "POSTTOOLUSE" => toolName.Length == 0 ? "Tool completed" : "Completed: " + toolName,
                "POSTTOOLUSEFAILURE" => toolName.Length == 0 ? "Tool failed" : "Failed: " + toolName,
                "TASKCREATED" => subject.Length == 0 ? "Added step" : "Added step: " + subject,
                "TASKCOMPLETED" => subject.Length == 0 ? "Step completed" : "Completed step: " + subject,
                "SUBAGENTSTART" => "Subagent started",
                "SUBAGENTSTOP" => "Subagent stopped",
                "STOP" => "Waiting for the next request",
                "SESSIONEND" => "Session ended",
                _ => eventName
            };
            bool active = !string.Equals(eventName, "Stop", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(eventName, "SessionEnd", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(eventName, "StopFailure", StringComparison.OrdinalIgnoreCase);
            record = new ClaudeEventRecord(timestamp.UtcDateTime.ToString("o", CultureInfo.InvariantCulture),
                "claude", sessionId, eventName, active, activity, taskId, subject, taskStatus, toolName);
            return true;
        }
        catch (JsonException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (ArgumentException) { return false; }
    }

    private static bool Validate(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (JsonProperty property in element.EnumerateObject())
            {
                if (names.TryGetValue(property.Name, out string? previous) && !string.Equals(previous, property.Name, StringComparison.Ordinal)) return false;
                names[property.Name] = property.Name;
                if (!Validate(property.Value)) return false;
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in element.EnumerateArray()) if (!Validate(item)) return false;
        }
        else if (element.ValueKind == JsonValueKind.Number &&
            (!element.TryGetDouble(out double number) || double.IsInfinity(number) || double.IsNaN(number))) return false;
        return true;
    }

    private static bool TryGet(JsonElement element, string name, out JsonElement result)
    {
        result = default;
        if (element.ValueKind != JsonValueKind.Object) return false;
        bool found = false;
        foreach (JsonProperty property in element.EnumerateObject())
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase)) { result = property.Value; found = true; }
        return found;
    }
    private static bool Has(JsonElement element, string name) => TryGet(element, name, out _);
    private static string Read(JsonElement element, string name, string fallback)
    {
        if (!TryGet(element, name, out JsonElement value)) return fallback;
        string text = value.ValueKind switch
        {
            JsonValueKind.Null => "",
            JsonValueKind.String => value.GetString() ?? "",
            JsonValueKind.True => "True",
            JsonValueKind.False => "False",
            JsonValueKind.Number => Number(value),
            _ => throw new InvalidOperationException("A selected hook field has a non-scalar value.")
        };
        if (!HasValidUtf16(text)) throw new InvalidOperationException("A selected hook field contains invalid UTF-16.");
        return text;
    }
    private static string Number(JsonElement value)
    {
        string raw = value.GetRawText();
        if (!raw.Contains('.') && !raw.Contains('e') && !raw.Contains('E') && value.TryGetInt64(out long integer))
            return integer.ToString(CultureInfo.InvariantCulture);
        if (!raw.Contains('e') && !raw.Contains('E') && value.TryGetDecimal(out decimal number))
            return number.ToString(CultureInfo.InvariantCulture);
        if (value.TryGetDouble(out double floating) && double.IsFinite(floating)) return floating.ToString("G", CultureInfo.InvariantCulture);
        throw new InvalidOperationException("A selected hook number is not finite.");
    }
    private static bool HasValidUtf16(string value)
    {
        for (int i = 0; i < value.Length; i++)
        {
            if (char.IsHighSurrogate(value[i]))
            {
                if (i + 1 >= value.Length || !char.IsLowSurrogate(value[i + 1])) return false;
                i++;
            }
            else if (char.IsLowSurrogate(value[i])) return false;
        }
        return true;
    }
    private static string Clip(string value, int limit)
    {
        if (value.Length == 0) return "";
        string clean = Whitespace.Replace(value, " ").Trim();
        if (clean.Length <= limit) return clean;
        int length = limit - 3;
        if (length > 0 && char.IsHighSurrogate(clean[length - 1]) && char.IsLowSurrogate(clean[length])) length--;
        return clean.Substring(0, length) + "...";
    }
}
