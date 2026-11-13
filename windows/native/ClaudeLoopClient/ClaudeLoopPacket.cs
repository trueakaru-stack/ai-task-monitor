using System.Buffers;
using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AITaskMonitor.ClaudeLoopClient;

/// <summary>Creates a sanitized loop observation; does not open a channel.</summary>
public static class ClaudeLoopPacket
{
    public const int MaximumInputCodeUnits = 1_048_576;
    public const int MaximumBodyBytes = 4096;
    public const int KeyBytes = 32;
    private const int MaximumCommandCodeUnits = 131_072;
    private const int MaximumDirectoryCodeUnits = 32_768;
    private static readonly Regex SafeId = new(@"\A[A-Za-z0-9_-]{1,128}\z", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex ExitCode = new(@"\AExit code (-?[0-9]+)(?:\r?\n|\z)", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    /// <summary>
    /// Produces a length-prefixed observation for a valid event and a 32-byte
    /// channel key. False means no packet was produced, not that no event was
    /// lost. The input, command, working directory, and key are never logged.
    /// </summary>
    public static bool TryCreate(string? json, ReadOnlySpan<byte> key, out byte[]? packet)
    {
        packet = null;
        if (key.Length != KeyBytes || string.IsNullOrEmpty(json) || json.Length > MaximumInputCodeUnits) return false;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 32 });
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !HasUniqueNames(root)) return false;
            string? session = StringField(root, "session_id");
            string? eventName = StringField(root, "hook_event_name");
            string toolName = StringField(root, "tool_name") ?? "";
            if (session is null || !SafeId.IsMatch(session) || eventName is null) return false;

            string? kind = Classify(root, eventName, toolName, out int? exitCode);
            if (kind is null) return false;
            string toolId = "";
            string? fingerprint = null;
            if (kind is "start" or "success" or "failed")
            {
                string? candidateId = StringField(root, "tool_use_id");
                JsonElement input = ObjectField(root, "tool_input");
                string? command = StringField(input, "command");
                string? cwd = StringField(root, "cwd");
                if (candidateId is null || !SafeId.IsMatch(candidateId) || string.IsNullOrEmpty(command) ||
                    command.Length > MaximumCommandCodeUnits || string.IsNullOrEmpty(cwd) || cwd.Length > MaximumDirectoryCodeUnits)
                {
                    kind = "reset";
                    exitCode = null;
                }
                else
                {
                    toolId = candidateId;
                    fingerprint = Fingerprint(key, toolName, cwd, command);
                }
            }

            var buffer = new ArrayBufferWriter<byte>();
            using (var writer = new Utf8JsonWriter(buffer))
            {
                writer.WriteStartObject();
                writer.WriteString("session", session);
                writer.WriteString("tool", toolId);
                writer.WriteString("kind", kind);
                if (kind == "failed") writer.WriteNumber("exitCode", exitCode!.Value);
                if (fingerprint is not null) writer.WriteString("fingerprint", fingerprint);
                writer.WriteEndObject();
                writer.Flush();
            }
            return TryFrame(buffer.WrittenSpan, out packet);
        }
        catch (JsonException) { return false; }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (CryptographicException) { return false; }
    }

    private static string? Classify(JsonElement root, string eventName, string toolName, out int? exitCode)
    {
        exitCode = null;
        if (eventName is "Stop" or "SessionEnd" or "StopFailure" or "UserPromptSubmit") return "stop";
        bool shell = toolName is "Bash" or "PowerShell";
        if ((eventName is "PreToolUse" or "PostToolUse") && (toolName is "Edit" or "Write" or "MultiEdit" or "NotebookEdit")) return "edit";
        if (shell && eventName == "PreToolUse") return "start";
        if (shell && eventName == "PostToolUse")
            return ResponseNotInterrupted(root) ? "success" : "reset";
        if (shell && eventName == "PostToolUseFailure")
        {
            string? error = StringField(root, "error");
            if (IsFalseOrMissing(root, "is_interrupt") && error is not null)
            {
                Match match = ExitCode.Match(error);
                if (match.Success && int.TryParse(match.Groups[1].Value, NumberStyles.AllowLeadingSign,
                    CultureInfo.InvariantCulture, out int parsed) && parsed != 0)
                {
                    exitCode = parsed;
                    return "failed";
                }
            }
            return "reset";
        }
        return null;
    }

    private static bool ResponseNotInterrupted(JsonElement root)
    {
        if (!root.TryGetProperty("tool_response", out JsonElement response)) return true;
        return response.ValueKind == JsonValueKind.Object && IsFalseOrMissing(response, "interrupted");
    }

    private static bool IsFalseOrMissing(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(name, out JsonElement field)) return true;
        return field.ValueKind == JsonValueKind.False;
    }

    private static JsonElement ObjectField(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out JsonElement field) && field.ValueKind == JsonValueKind.Object
            ? field : default;

    private static string? StringField(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out JsonElement field) && field.ValueKind == JsonValueKind.String
            ? field.GetString() : null;

    private static bool HasUniqueNames(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (JsonProperty property in value.EnumerateObject())
                if (!names.Add(property.Name) || !HasUniqueNames(property.Value)) return false;
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (JsonElement element in value.EnumerateArray())
                if (!HasUniqueNames(element)) return false;
        return true;
    }

    private static string Fingerprint(ReadOnlySpan<byte> key, string toolName, string cwd, string command)
    {
        byte[] keyCopy = key.ToArray();
        try
        {
            using var hmac = IncrementalHash.CreateHMAC(HashAlgorithmName.SHA256, keyCopy);
            hmac.AppendData("claude\0"u8);
            AppendUtf8(hmac, toolName);
            hmac.AppendData("\0"u8);
            AppendUtf8(hmac, cwd.Length.ToString(CultureInfo.InvariantCulture));
            hmac.AppendData(":"u8);
            AppendUtf8(hmac, cwd);
            AppendUtf8(hmac, command.Length.ToString(CultureInfo.InvariantCulture));
            hmac.AppendData(":"u8);
            AppendUtf8(hmac, command);
            byte[] digest = hmac.GetHashAndReset();
            try { return Convert.ToHexStringLower(digest); }
            finally { CryptographicOperations.ZeroMemory(digest); }
        }
        finally { CryptographicOperations.ZeroMemory(keyCopy); }
    }

    private static void AppendUtf8(IncrementalHash hmac, string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        try { hmac.AppendData(bytes); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    // This framing helper is internal: public callers can only frame the
    // sanitized fields produced above, never an arbitrary command or path.
    internal static bool TryFrame(ReadOnlySpan<byte> body, out byte[]? packet)
    {
        packet = null;
        if (body.Length < 2 || body.Length > MaximumBodyBytes) return false;
        byte[] result = new byte[4 + body.Length];
        BinaryPrimitives.WriteInt32LittleEndian(result.AsSpan(0, 4), body.Length);
        body.CopyTo(result.AsSpan(4));
        packet = result;
        return true;
    }
}
