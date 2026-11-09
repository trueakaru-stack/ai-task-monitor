using System.Text.Json;
using AITaskMonitor.ClaudeConfiguration;

internal static class Program
{
    private const string Current = "powershell.exe -EncodedCommand SYNTHETIC";
    private const string Legacy = "powershell.exe -File synthetic-old";
    private static int checks;

    private static void Check(bool condition, string message)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Reject(string json, bool install = true)
    {
        try { ClaudeConfigPatch.Apply(json, Current, Legacy, install); }
        catch (Exception error) when (error is FormatException or JsonException) { checks++; return; }
        throw new InvalidOperationException("A malformed fixture was accepted.");
    }

    private static string Raw(JsonElement parent, string name) => parent.GetProperty(name).GetRawText();

    private static void RejectCommand(string current, string legacy)
    {
        try { ClaudeConfigPatch.Apply("{}", current, legacy, true); }
        catch (ArgumentException) { checks++; return; }
        throw new InvalidOperationException("An invalid UTF-16 command was accepted.");
    }

    public static void Main()
    {
        const string source = """
        {
          "unrelated": {"threshold": 0.12345678901234567890123456789,
                        "big": 90071992547409931234567890, "deep": [1e-320, {"вклад": "тест"}]},
          "hooks": {
            "PreToolUse": [
              {"matcher":"Bash", "plugin":{"threshold":0.12345678901234567890123456789},
               "hooks":[{"type":"command","command":"powershell.exe -File synthetic-old","timeout":10},
                        {"type":"command","command":"third-party","timeout":0.12345678901234567890123456789}]},
              {"hooks":[{"type":"command","command":"powershell.exe -EncodedCommand SYNTHETIC","timeout":10}]}
            ],
            "FutureEvent": [{"hooks":[{"type":"command","command":"other","timeout":12345678901234567890}]}]
          }
        }
        """;
        using var original = JsonDocument.Parse(source);
        ClaudeConfigPatch.Result installed = ClaudeConfigPatch.Apply(source, Current, Legacy, true);
        Check(installed.Changed, "The migration should change the fixture.");
        using var installedDoc = JsonDocument.Parse(installed.Json);
        JsonElement root = installedDoc.RootElement, hooks = root.GetProperty("hooks");
        Check(Raw(root, "unrelated") == Raw(original.RootElement, "unrelated"), "Unrelated values changed.");
        Check(Raw(hooks, "FutureEvent") == Raw(original.RootElement.GetProperty("hooks"), "FutureEvent"), "Unknown event changed.");
        JsonElement group = hooks.GetProperty("PreToolUse")[0];
        JsonElement oldGroup = original.RootElement.GetProperty("hooks").GetProperty("PreToolUse")[0];
        Check(Raw(group, "plugin") == Raw(oldGroup, "plugin"), "Group metadata changed.");
        Check(Raw(group, "matcher") == Raw(oldGroup, "matcher"), "Group matcher changed.");
        Check(group.GetProperty("hooks").GetArrayLength() == 1, "Only the legacy command should be removed.");
        Check(group.GetProperty("hooks")[0].GetRawText() == oldGroup.GetProperty("hooks")[1].GetRawText(), "Third-party command changed.");
        Check(hooks.GetProperty("PreToolUse").GetArrayLength() == 2, "The existing current command should remain.");
        string[] events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "TaskCreated",
            "TaskCompleted", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"];
        foreach (string name in events) Check(hooks.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Array,
            "A required event is missing.");
        ClaudeConfigPatch.Result again = ClaudeConfigPatch.Apply(installed.Json, Current, Legacy, true);
        Check(!again.Changed && again.Json == installed.Json, "Install should be idempotent.");
        ClaudeConfigPatch.Result removed = ClaudeConfigPatch.Apply(installed.Json, Current, Legacy, false);
        using var removedDoc = JsonDocument.Parse(removed.Json);
        JsonElement remaining = removedDoc.RootElement.GetProperty("hooks");
        Check(removed.Changed, "Remove should change the fixture.");
        Check(Raw(removedDoc.RootElement, "unrelated") == Raw(original.RootElement, "unrelated"), "Unrelated values changed on removal.");
        Check(Raw(remaining, "FutureEvent") == Raw(original.RootElement.GetProperty("hooks"), "FutureEvent"), "Unknown event changed on removal.");
        Check(remaining.GetProperty("PreToolUse").GetArrayLength() == 1, "Third-party group was not retained.");
        Check(remaining.GetProperty("PreToolUse")[0].GetProperty("hooks")[0].GetRawText() == oldGroup.GetProperty("hooks")[1].GetRawText(), "Third-party command changed on removal.");
        Check(!remaining.TryGetProperty("StopFailure", out _), "Monitor-only event remained.");
        Check(!ClaudeConfigPatch.Apply(removed.Json, Current, Legacy, false).Changed, "Remove should be idempotent.");
        Check(!ClaudeConfigPatch.Apply("{\"other\":1}", Current, Legacy, false).Changed, "Remove should not add hooks.");
        using var empty = JsonDocument.Parse(ClaudeConfigPatch.Apply("{}", Current, Legacy, true).Json);
        Check(empty.RootElement.GetProperty("hooks").EnumerateObject().Count() == 11, "Empty settings did not gain 11 events.");
        string bomInput = "\uFEFF{\"unrelated\":0.12345678901234567890123456789}";
        ClaudeConfigPatch.Result bomResult = ClaudeConfigPatch.Apply(bomInput, Current, Legacy, true);
        Check(bomResult.Json[0] == '\uFEFF', "The original UTF-8 BOM marker was lost.");
        using var bomDoc = JsonDocument.Parse(bomResult.Json[1..]);
        Check(Raw(bomDoc.RootElement, "unrelated") == "0.12345678901234567890123456789", "BOM settings lost numeric precision.");
        Check(ClaudeConfigPatch.Apply(bomInput, Current, Legacy, false).Json == bomInput, "An unchanged BOM file was rewritten.");
        const string specialCommand = "powershell.exe -File \"C:\\synthetic path\\Проверка\\a'b.ps1\"";
        ClaudeConfigPatch.Result special = ClaudeConfigPatch.Apply("{}", specialCommand, Legacy, true);
        using var specialDoc = JsonDocument.Parse(special.Json);
        Check(specialDoc.RootElement.GetProperty("hooks").GetProperty("Stop")[0].GetProperty("hooks")[0]
            .GetProperty("command").GetString() == specialCommand, "The command was not encoded losslessly.");
        Check(!ClaudeConfigPatch.Apply(special.Json, specialCommand, Legacy, true).Changed, "Unicode command was not recognized on reconnect.");
        RejectCommand("synthetic-\uD800", Legacy);
        RejectCommand(Current, "synthetic-\uDC00");
        string metadataGroup = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":";
        Reject(metadataGroup + JsonSerializer.Serialize(Legacy) + "}]}]}}");
        Reject(metadataGroup + JsonSerializer.Serialize(Current) + "}]}]}}", false);
        Reject("[]");
        Reject("{\"hooks\":null}");
        Reject("{\"hooks\":{},\"HOOKS\":{}}");
        Reject("{\"Hooks\":{}}");
        Reject("{\"hooks\":{\"PreToolUse\":{}}}");
        Reject("{\"hooks\":{\"PreToolUse\":[{\"hooks\":{}}]}}");
        Reject("{\"hooks\":{\"PreToolUse\":[{\"hooks\":[null]}]}}");
        Reject("{\"hooks\":{\"pretooluse\":[]}}");
        Reject("{\"hooks\":{\"Future\":{}}}", false);
        Reject("{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"TYPE\":\"command\"}]}]}}");
        Reject("{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"Type\":\"command\",\"command\":\"other\"}]}]}}");
        Reject("{invalid}");
        Console.WriteLine($"Native Claude settings patch: {checks} synthetic checks passed.");
    }
}
