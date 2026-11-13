using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using AITaskMonitor.ClaudeLoopClient;

return Checks.Run(args);

static class Checks
{
    private const string DirectoryValue = @"C:\Synthetic\Проект 🌿";
    private const string CommandValue = "echo SYNTHETIC_PRIVATE_COMMAND 🌿";
    private const string ExpectedFingerprint = "0f6d334758d37b92f7b7ffe3a731c25929789360b75a97d5f275f7b38d421c36";
    private static readonly byte[] Key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
    private static int checks;
    private sealed class AssertionFailure : Exception
    {
        internal AssertionFailure(string message) : base(message) { }
    }

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new AssertionFailure(message);
    }

    public static int Run(string[] args)
    {
        try
        {
            if (args.Length != 0) throw new ArgumentException("This synthetic test accepts no input.");
            VerifyCanonicalFingerprint();
            VerifyClassification();
            VerifyResetBoundaries();
            VerifyInvalidInput();
            VerifyFraming();
            Console.WriteLine($"Claude loop packet: {checks} synthetic assertions passed.");
            return 0;
        }
        catch (AssertionFailure error)
        {
            Console.Error.WriteLine("Synthetic assertion failed: " + error.Message);
            return 1;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Synthetic loop packet test failed: " + error.GetType().Name);
            return 1;
        }
    }

    private static Dictionary<string, object?> Event(string name, string tool = "Bash") => new()
    {
        ["session_id"] = "test_1",
        ["hook_event_name"] = name,
        ["tool_name"] = tool,
        ["tool_use_id"] = "tool-1",
        ["tool_input"] = new Dictionary<string, object?> { ["command"] = CommandValue },
        ["cwd"] = DirectoryValue
    };

    private static string Json(Dictionary<string, object?> value) => JsonSerializer.Serialize(value);

    private static JsonDocument Packet(string json, ReadOnlySpan<byte> key, out byte[] bytes)
    {
        Check(ClaudeLoopPacket.TryCreate(json, key, out byte[]? packet) && packet is not null, "Expected a sanitized packet.");
        bytes = packet!;
        Check(bytes.Length >= 6 && BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(0, 4)) == bytes.Length - 4 &&
            bytes.Length - 4 <= ClaudeLoopPacket.MaximumBodyBytes, "Packet framing or length was invalid.");
        string text = Encoding.UTF8.GetString(bytes.AsSpan(4));
        Check(!text.Contains("SYNTHETIC_PRIVATE_COMMAND", StringComparison.Ordinal) &&
            !text.Contains(DirectoryValue, StringComparison.Ordinal), "Raw synthetic command or directory entered the packet.");
        JsonDocument document = JsonDocument.Parse(bytes.AsMemory(4));
        Check(document.RootElement.EnumerateObject().All(property => property.Name is "session" or "tool" or "kind" or "exitCode" or "fingerprint"),
            "Packet contained an unexpected field.");
        return document;
    }

    private static void VerifyCanonicalFingerprint()
    {
        Check(DirectoryValue.Length == 22 && CommandValue.Length == 33, "The UTF-16 fixture lengths changed.");
        byte[] originalKey = Key.ToArray();
        var input = Event("PreToolUse");
        using JsonDocument packet = Packet(Json(input), Key, out byte[] bytes);
        JsonElement root = packet.RootElement;
        Check(root.GetProperty("session").GetString() == "test_1" && root.GetProperty("tool").GetString() == "tool-1" &&
            root.GetProperty("kind").GetString() == "start" && root.GetProperty("fingerprint").GetString() == ExpectedFingerprint,
            "The independent UTF-16 HMAC vector did not match.");
        Check(root.EnumerateObject().Count() == 4 && !root.TryGetProperty("exitCode", out _), "A start packet has an unexpected shape.");
        string expected = "{\"session\":\"test_1\",\"tool\":\"tool-1\",\"kind\":\"start\",\"fingerprint\":\"" + ExpectedFingerprint + "\"}";
        Check(Encoding.UTF8.GetString(bytes.AsSpan(4)) == expected, "The compact packet body differs from the synthetic reference.");
        Check(Key.SequenceEqual(originalKey), "The caller-owned key was modified.");

        byte[] altered = Key.ToArray(); altered[0] ^= 1;
        using JsonDocument withAnotherKey = Packet(Json(input), altered, out _);
        Check(withAnotherKey.RootElement.GetProperty("fingerprint").GetString() != ExpectedFingerprint, "Changing the key did not change the fingerprint.");
        var otherCommand = Event("PreToolUse");
        otherCommand["tool_input"] = new Dictionary<string, object?> { ["command"] = CommandValue + "x" };
        using JsonDocument changedCommand = Packet(Json(otherCommand), Key, out _);
        Check(changedCommand.RootElement.GetProperty("fingerprint").GetString() != ExpectedFingerprint, "Changing the command did not change the fingerprint.");
        var otherDirectory = Event("PreToolUse"); otherDirectory["cwd"] = DirectoryValue + "x";
        using JsonDocument changedDirectory = Packet(Json(otherDirectory), Key, out _);
        Check(changedDirectory.RootElement.GetProperty("fingerprint").GetString() != ExpectedFingerprint, "Changing the directory did not change the fingerprint.");
        var differentIds = Event("PreToolUse"); differentIds["session_id"] = "test_2"; differentIds["tool_use_id"] = "tool-2";
        using JsonDocument sameCommand = Packet(Json(differentIds), Key, out _);
        Check(sameCommand.RootElement.GetProperty("fingerprint").GetString() == ExpectedFingerprint, "Session identity changed the command fingerprint.");

        var powershell = Event("PostToolUseFailure", "PowerShell");
        powershell["cwd"] = @"D:\fixture\Пример";
        powershell["tool_input"] = new Dictionary<string, object?> { ["command"] = "Write-Output '🌿'" };
        powershell["error"] = "Exit code -7\nSYNTHETIC_PRIVATE_ERROR";
        using JsonDocument powershellPacket = Packet(Json(powershell), Key, out byte[] powershellBytes);
        Check(powershellPacket.RootElement.GetProperty("kind").GetString() == "failed" &&
            powershellPacket.RootElement.GetProperty("exitCode").GetInt32() == -7 &&
            powershellPacket.RootElement.GetProperty("fingerprint").GetString() == "add525d41634f781a9f2808f84566245e26b5ae8918fa901b61fc8abb6cdbbd9",
            "The independent PowerShell HMAC vector did not match.");
        string powershellBody = Encoding.UTF8.GetString(powershellBytes.AsSpan(4));
        Check(!powershellBody.Contains("Write-Output", StringComparison.Ordinal) &&
            !powershellBody.Contains("SYNTHETIC_PRIVATE_ERROR", StringComparison.Ordinal), "Raw synthetic command or error entered the packet.");

        CultureInfo before = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("ar-SA");
            using JsonDocument otherCulture = Packet(Json(input), Key, out _);
            Check(otherCulture.RootElement.GetProperty("fingerprint").GetString() == ExpectedFingerprint, "The fingerprint changed with process culture.");
        }
        finally { CultureInfo.CurrentCulture = before; }
    }

    private static void VerifyClassification()
    {
        foreach (string name in new[] { "Stop", "SessionEnd", "StopFailure", "UserPromptSubmit" })
            ExpectKind(Event(name), "stop", "", null);
        foreach (string tool in new[] { "Edit", "Write", "MultiEdit", "NotebookEdit" })
            foreach (string name in new[] { "PreToolUse", "PostToolUse" }) ExpectKind(Event(name, tool), "edit", "", null);
        foreach (string tool in new[] { "Bash", "PowerShell" })
        {
            ExpectKind(Event("PreToolUse", tool), "start", "tool-1", null);
            ExpectKind(Event("PostToolUse", tool), "success", "tool-1", null);
            var success = Event("PostToolUse", tool);
            success["tool_response"] = new Dictionary<string, object?> { ["interrupted"] = false };
            ExpectKind(success, "success", "tool-1", null);
            var emptyResponse = Event("PostToolUse", tool);
            emptyResponse["tool_response"] = new Dictionary<string, object?>();
            ExpectKind(emptyResponse, "success", "tool-1", null);
            foreach (object? invalidResponse in new object?[] { null, 0, true, "synthetic", Array.Empty<object>() })
            {
                var malformedResponse = Event("PostToolUse", tool);
                malformedResponse["tool_response"] = invalidResponse;
                ExpectKind(malformedResponse, "reset", "", null);
            }
            var interrupted = Event("PostToolUse", tool);
            interrupted["tool_response"] = new Dictionary<string, object?> { ["interrupted"] = true };
            ExpectKind(interrupted, "reset", "", null);
            var malformedInterrupted = Event("PostToolUse", tool);
            malformedInterrupted["tool_response"] = new Dictionary<string, object?> { ["interrupted"] = "false" };
            ExpectKind(malformedInterrupted, "reset", "", null);
            var nullInterrupted = Event("PostToolUse", tool);
            nullInterrupted["tool_response"] = new Dictionary<string, object?> { ["interrupted"] = null };
            ExpectKind(nullInterrupted, "reset", "", null);
            foreach (object invalidInterrupted in new object[] { 0, Array.Empty<object>(), new Dictionary<string, object?>() })
            {
                var malformedInterruptedType = Event("PostToolUse", tool);
                malformedInterruptedType["tool_response"] = new Dictionary<string, object?> { ["interrupted"] = invalidInterrupted };
                ExpectKind(malformedInterruptedType, "reset", "", null);
            }
        }
        foreach ((string error, int? expected) in new[]
        {
            ("Exit code -7", (int?)-7), ("Exit code 2147483647\nsynthetic", (int?)int.MaxValue),
            ("Exit code -2147483648\r\nsynthetic", (int?)int.MinValue), ("Exit code 0", (int?)null),
            ("Exit code -0", (int?)null), ("Exit code 2147483648", (int?)null),
            ("Exit code -2147483649", (int?)null), ("Exit code +1", (int?)null),
            ("exit code 7", (int?)null), ("Exit code 7\rsynthetic", (int?)null), ("SYNTHETIC_PRIVATE_ERROR", (int?)null)
        })
        {
            var failed = Event("PostToolUseFailure"); failed["error"] = error;
            ExpectKind(failed, expected.HasValue ? "failed" : "reset", expected.HasValue ? "tool-1" : "", expected);
        }
        var interruptedFailure = Event("PostToolUseFailure"); interruptedFailure["error"] = "Exit code 3"; interruptedFailure["is_interrupt"] = true;
        ExpectKind(interruptedFailure, "reset", "", null);
        var nullInterrupt = Event("PostToolUseFailure"); nullInterrupt["error"] = "Exit code 3"; nullInterrupt["is_interrupt"] = null;
        ExpectKind(nullInterrupt, "reset", "", null);
        foreach (object invalidInterrupt in new object[] { "false", 0, Array.Empty<object>(), new Dictionary<string, object?>() })
        {
            var malformedInterrupt = Event("PostToolUseFailure");
            malformedInterrupt["error"] = "Exit code 3"; malformedInterrupt["is_interrupt"] = invalidInterrupt;
            ExpectKind(malformedInterrupt, "reset", "", null);
        }
        var explicitNotInterrupted = Event("PostToolUseFailure");
        explicitNotInterrupted["error"] = "Exit code 3"; explicitNotInterrupted["is_interrupt"] = false;
        ExpectKind(explicitNotInterrupted, "failed", "tool-1", 3);
        ExpectKind(Event("PostToolUseFailure"), "reset", "", null);
        var nonStringError = Event("PostToolUseFailure"); nonStringError["error"] = 3;
        ExpectKind(nonStringError, "reset", "", null);
        var invalidFailure = Event("PostToolUseFailure"); invalidFailure["error"] = "Exit code 3"; invalidFailure["cwd"] = "";
        ExpectKind(invalidFailure, "reset", "", null);
        Check(!ClaudeLoopPacket.TryCreate(Json(Event("PreToolUse", "bash")), Key, out _), "Tool names must be case-sensitive.");
        Check(!ClaudeLoopPacket.TryCreate(Json(Event("pretooluse")), Key, out _), "Event names must be case-sensitive.");
        Check(!ClaudeLoopPacket.TryCreate(Json(Event("PostToolUseFailure", "Edit")), Key, out _), "An unrelated edit event was classified.");
    }

    private static void VerifyResetBoundaries()
    {
        foreach ((string name, object? value) in new (string, object?)[]
        {
            ("tool_use_id", ""), ("tool_use_id", "bad id"), ("tool_use_id", "bad\n"),
            ("tool_use_id", new string('x', 129)), ("tool_use_id", 123),
            ("cwd", ""), ("cwd", null), ("cwd", 3), ("cwd", Array.Empty<object>()), ("cwd", new string('x', 32_769)),
            ("tool_input", null), ("tool_input", 3), ("tool_input", Array.Empty<object>()),
            ("tool_input", new Dictionary<string, object?>()), ("tool_input", new Dictionary<string, object?> { ["command"] = "" }),
            ("tool_input", new Dictionary<string, object?> { ["command"] = 3 }),
            ("tool_input", new Dictionary<string, object?> { ["command"] = new string('x', 131_073) })
        })
        {
            var valueToCheck = Event("PreToolUse"); valueToCheck[name] = value;
            ExpectKind(valueToCheck, "reset", "", null);
        }
        var atMaximum = Event("PreToolUse");
        atMaximum["cwd"] = new string('x', 32_768);
        atMaximum["tool_input"] = new Dictionary<string, object?> { ["command"] = new string('y', 131_072) };
        ExpectKind(atMaximum, "start", "tool-1", null);
        var supplementaryAtLimit = Event("PreToolUse");
        supplementaryAtLimit["cwd"] = new string('x', 32_766) + "🌿";
        supplementaryAtLimit["tool_input"] = new Dictionary<string, object?> { ["command"] = new string('y', 131_070) + "🌿" };
        ExpectKind(supplementaryAtLimit, "start", "tool-1", null);
        supplementaryAtLimit["cwd"] = new string('x', 32_767) + "🌿";
        ExpectKind(supplementaryAtLimit, "reset", "", null);
        var atIdMaximum = Event("PreToolUse"); atIdMaximum["tool_use_id"] = new string('x', 128);
        ExpectKind(atIdMaximum, "start", new string('x', 128), null);
        var acceptedWhitespace = Event("PreToolUse");
        acceptedWhitespace["cwd"] = " "; acceptedWhitespace["tool_input"] = new Dictionary<string, object?> { ["command"] = " " };
        ExpectKind(acceptedWhitespace, "start", "tool-1", null);
    }

    private static void VerifyInvalidInput()
    {
        Check(!ClaudeLoopPacket.TryCreate(null, Key, out byte[]? empty) && empty is null, "Null input was accepted.");
        foreach (string input in new[] { "", "{", "[]", "null", "{\"session_id\":\"one\",\"session_id\":\"two\"}",
            "{\"session_id\":\"one\",\"SESSION_ID\":\"two\"}",
            "{\"session_id\":\"one\",\"hook_event_name\":\"Stop\",\"ignored\":{\"a\":1,\"A\":2}}" })
            Check(!ClaudeLoopPacket.TryCreate(input, Key, out byte[]? packet) && packet is null, "Malformed or ambiguous input was accepted.");
        foreach (object? session in new object?[] { null, "", "bad id", "bad\n", new string('x', 129), 123 })
        {
            var value = Event("Stop"); value["session_id"] = session;
            Check(!ClaudeLoopPacket.TryCreate(Json(value), Key, out _), "An invalid session was accepted.");
        }
        var atMaximum = Event("Stop"); atMaximum["session_id"] = new string('x', 128);
        ExpectKind(atMaximum, "stop", "", null);
        foreach (string field in new[] { "hook_event_name", "tool_name" })
        {
            var invalidField = Event("PreToolUse"); invalidField[field] = 42;
            Check(!ClaudeLoopPacket.TryCreate(Json(invalidField), Key, out _), "An invalid event or tool type was classified.");
        }
        foreach (int size in new[] { 0, 1, 31, 33, 64 })
            Check(!ClaudeLoopPacket.TryCreate(Json(Event("Stop")), new byte[size], out byte[]? packet) && packet is null,
                "A key with an invalid length was accepted.");

        const string prefix = "{\"session_id\":\"test_1\",\"hook_event_name\":\"Stop\",\"ignored\":\"";
        const string suffix = "\"}";
        string maximum = prefix + new string('x', ClaudeLoopPacket.MaximumInputCodeUnits - prefix.Length - suffix.Length) + suffix;
        Check(ClaudeLoopPacket.TryCreate(maximum, Key, out _), "An exact-limit valid input was rejected.");
        string over = prefix + new string('x', ClaudeLoopPacket.MaximumInputCodeUnits - prefix.Length - suffix.Length + 1) + suffix;
        using (JsonDocument valid = JsonDocument.Parse(over)) Check(valid.RootElement.ValueKind == JsonValueKind.Object, "The over-limit fixture is not valid JSON.");
        Check(!ClaudeLoopPacket.TryCreate(over, Key, out _), "A valid input over the limit was accepted.");
        string deep = "{\"session_id\":\"test_1\",\"hook_event_name\":\"Stop\",\"ignored\":" + new string('[', 40) + "0" + new string(']', 40) + "}";
        Check(!ClaudeLoopPacket.TryCreate(deep, Key, out _), "Input beyond the nesting limit was accepted.");
    }

    private static void VerifyFraming()
    {
        foreach (int size in new[] { 0, 1, 4097 })
            Check(!ClaudeLoopPacket.TryFrame(new byte[size], out byte[]? packet) && packet is null, "An invalid frame size was accepted.");
        foreach (int size in new[] { 2, 4096 })
        {
            byte[] payload = Enumerable.Repeat((byte)0x5a, size).ToArray();
            Check(ClaudeLoopPacket.TryFrame(payload, out byte[]? frame) && frame is not null, "A valid frame size was rejected.");
            Check(frame!.Length == size + 4 && BinaryPrimitives.ReadInt32LittleEndian(frame.AsSpan(0, 4)) == size &&
                frame.AsSpan(4).SequenceEqual(payload), "The length prefix or body was corrupted.");
            if (size == 4096) Check(frame[0] == 0 && frame[1] == 16 && frame[2] == 0 && frame[3] == 0, "The length prefix is not little-endian.");
        }
    }

    private static void ExpectKind(Dictionary<string, object?> input, string expectedKind, string expectedTool, int? expectedCode)
    {
        using JsonDocument document = Packet(Json(input), Key, out _);
        JsonElement root = document.RootElement;
        Check(root.GetProperty("session").GetString() == (input["session_id"] as string),
            "The packet session differs from the validated synthetic session.");
        Check(root.GetProperty("kind").GetString() == expectedKind && root.GetProperty("tool").GetString() == expectedTool,
            "The event kind or tool identity differs from the expected classification.");
        bool hasFingerprint = root.TryGetProperty("fingerprint", out JsonElement fingerprint);
        bool hasExitCode = root.TryGetProperty("exitCode", out JsonElement code);
        bool command = expectedKind is "start" or "success" or "failed";
        Check(hasFingerprint == command && (!hasFingerprint ||
            Regex.IsMatch(fingerprint.GetString() ?? "", @"\A[a-f0-9]{64}\z", RegexOptions.CultureInvariant)),
            "The packet fingerprint shape is invalid.");
        Check(hasExitCode == expectedCode.HasValue && (!hasExitCode || code.GetInt32() == expectedCode), "The packet exit code is invalid.");
        Check(root.EnumerateObject().Count() == 3 + (command ? 1 : 0) + (expectedCode.HasValue ? 1 : 0),
            "The packet contains an unexpected number of fields.");
    }
}
