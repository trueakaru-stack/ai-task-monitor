using System.Text;
using System.Text.Json;
using AiTaskMonitor.ClaudeConnectionInspection;

internal static class Program
{
    private const string Current = "synthetic-current-command";
    private const string Legacy = "synthetic-legacy-command";
    private static readonly ExpectedCommands Commands = new(Current, Legacy);
    private static readonly string[] Events =
    {
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "TaskCreated", "TaskCompleted", "SubagentStart", "SubagentStop", "Stop",
        "StopFailure", "SessionEnd"
    };
    private static int checks;

    private static void Main()
    {
        CompleteAndPartialRegistrations();
        MatchersAndHandlerRestrictions();
        PolicyAndOtherSettings();
        InvalidDocuments();
        ReadFailuresAndBounds();
        SyntheticFileReads();
        Console.WriteLine($"Claude connection inspection: {checks} synthetic checks passed.");
    }

    private static void CompleteAndPartialRegistrations()
    {
        InspectionResult full = Inspect(Document());
        State(full, RegistrationState.RegisteredInFile, "full registration");
        Check(full.EventsWithMatchingCommand == 11 && full.EventsWithUnfilteredCommand == 11, "complete event counts");
        Unknown(full);

        foreach (string eventName in Events)
        {
            var root = Document();
            Hooks(root).Remove(eventName);
            InspectionResult partial = Inspect(root);
            State(partial, RegistrationState.PartialInFile, "one missing event");
            Note(partial, InspectionNotes.MissingUnfilteredEvents, "missing event note");
            Check(partial.EventsWithMatchingCommand == 10 && partial.EventsWithUnfilteredCommand == 10,
                "missing event counts");
        }

        var noHooks = new Dictionary<string, object?>();
        State(Inspect(noHooks), RegistrationState.NotFoundInFile, "empty settings object");
        var unrelated = Document("unrelated-command");
        State(Inspect(unrelated), RegistrationState.NotFoundInFile, "other command is not ours");
        var legacy = Document("  SYNTHETIC-LEGACY-COMMAND  ");
        State(Inspect(legacy), RegistrationState.RegisteredInFile, "legacy comparison matches existing installer");
        var wrongCurrentCase = Document("SYNTHETIC-CURRENT-COMMAND");
        State(Inspect(wrongCurrentCase), RegistrationState.NotFoundInFile, "current command remains case-sensitive");
        var currentTrimmed = Document("  " + Current + "  ");
        State(Inspect(currentTrimmed), RegistrationState.RegisteredInFile, "command outer whitespace");

        string resultText = full.ToString();
        Check(!resultText.Contains(Current, StringComparison.Ordinal)
            && !resultText.Contains(Legacy, StringComparison.Ordinal), "result does not expose command");
        Unknown(Inspect(noHooks));
    }

    private static void MatchersAndHandlerRestrictions()
    {
        foreach (string all in new[] { "", "*" })
        {
            var root = Document();
            Group(root, "PreToolUse")["matcher"] = all;
            State(Inspect(root), RegistrationState.RegisteredInFile, "documented match-all matcher");
        }
        foreach (string filtered in new[] { "Bash", ".*", " " })
        {
            var root = Document();
            Group(root, "PreToolUse")["matcher"] = filtered;
            InspectionResult result = Inspect(root);
            State(result, RegistrationState.PartialInFile, "matcher not assumed unfiltered");
            Note(result, InspectionNotes.FilteredOrUnsupportedHook, "matcher note");
            Check(result.EventsWithMatchingCommand == 11 && result.EventsWithUnfilteredCommand == 10,
                "matcher counts");
        }

        var ignoredMatcherEvent = Document();
        Group(ignoredMatcherEvent, "UserPromptSubmit")["matcher"] = "Bash";
        State(Inspect(ignoredMatcherEvent), RegistrationState.PartialInFile,
            "conservative treatment even for event without matcher support");

        foreach (string extra in new[] { "if", "args", "async", "shell", "futureField" })
        {
            var root = Document();
            Handler(root, "PreToolUse")[extra] = extra == "args" ? Array.Empty<string>() : "synthetic-value";
            InspectionResult result = Inspect(root);
            State(result, RegistrationState.PartialInFile, "additional handler field is uncertain");
            Note(result, InspectionNotes.FilteredOrUnsupportedHook, "handler note");
        }

        var extraGroupField = Document();
        Group(extraGroupField, "PreToolUse")["futureField"] = true;
        State(Inspect(extraGroupField), RegistrationState.PartialInFile, "additional group field is uncertain");
        var wrongType = Document();
        Handler(wrongType, "Stop")["type"] = "prompt";
        State(Inspect(wrongType), RegistrationState.PartialInFile, "matching command without command type");
        var invalidTimeout = Document();
        Handler(invalidTimeout, "Stop")["timeout"] = "10";
        State(Inspect(invalidTimeout), RegistrationState.PartialInFile, "unsupported timeout type");

        var duplicateGroup = Document();
        var groups = (List<Dictionary<string, object?>>)Hooks(duplicateGroup)["PreToolUse"]!;
        groups.Add(new Dictionary<string, object?>
        {
            ["matcher"] = "Bash",
            ["hooks"] = new[] { new Dictionary<string, object?> { ["type"] = "command", ["command"] = Current } }
        });
        State(Inspect(duplicateGroup), RegistrationState.PartialInFile,
            "extra filtered matching hook remains visible as uncertainty");

        var unrelatedHandler = Document();
        ((List<Dictionary<string, object?>>)Group(unrelatedHandler, "Stop")["hooks"]!).Add(
            new Dictionary<string, object?> { ["type"] = "prompt", ["prompt"] = "synthetic prompt" });
        State(Inspect(unrelatedHandler), RegistrationState.RegisteredInFile, "unrelated handler does not alter registration");
    }

    private static void PolicyAndOtherSettings()
    {
        foreach (string name in new[] { "disableAllHooks", "allowManagedHooksOnly" })
        {
            var root = Document();
            root[name] = true;
            InspectionResult result = Inspect(root);
            State(result, RegistrationState.PartialInFile, "local restriction mentioned");
            Note(result, name == "disableAllHooks" ? InspectionNotes.DisableAllHooksMentioned
                : InspectionNotes.ManagedOnlyMentioned, "restriction note");
            Unknown(result);
            root[name] = false;
            InspectionResult falseSetting = Inspect(root);
            State(falseSetting, RegistrationState.RegisteredInFile, "false local setting");
            Unknown(falseSetting);
            root[name] = "false";
            State(Inspect(root), RegistrationState.InvalidConfiguration, "policy setting must be boolean");
        }

        var unrelated = Document();
        unrelated["otherConfig"] = new Dictionary<string, object?> { ["value"] = "secret-synthetic-value" };
        InspectionResult resultWithOtherConfig = Inspect(unrelated);
        State(resultWithOtherConfig, RegistrationState.RegisteredInFile, "unrelated settings are ignored");
        Check(!resultWithOtherConfig.ToString().Contains("secret-synthetic-value", StringComparison.Ordinal),
            "result does not export unrelated settings");
    }

    private static void InvalidDocuments()
    {
        foreach (string raw in new[]
        {
            "", "null", "[]", "{", "{\"hooks\":[]}",
            "{\"hooks\":{},\"Hooks\":{}}", "{\"HOOKS\":{}}",
            "{\"hooks\":{\"PreToolUse\":{}}}",
            "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"command\":7}]}]}}",
            "{\"other\":{\"a\":1,\"A\":2}}"
        })
        {
            InspectionResult result = ClaudeConnectionInspector.InspectBytes(Encoding.UTF8.GetBytes(raw), Commands);
            State(result, RegistrationState.InvalidConfiguration, "invalid or ambiguous document");
            Unknown(result);
        }
        byte[] utf8 = Encoding.UTF8.GetBytes("{\"x\":\"a\"}");
        utf8[6] = 0xff;
        State(ClaudeConnectionInspector.InspectBytes(utf8, Commands), RegistrationState.InvalidConfiguration,
            "invalid UTF-8 inside otherwise valid string");

        byte[] valid = JsonSerializer.SerializeToUtf8Bytes(Document());
        byte[] withBom = new byte[valid.Length + 3];
        withBom[0] = 0xef; withBom[1] = 0xbb; withBom[2] = 0xbf;
        valid.CopyTo(withBom, 3);
        State(ClaudeConnectionInspector.InspectBytes(withBom, Commands), RegistrationState.RegisteredInFile, "UTF-8 BOM");
    }

    private static void ReadFailuresAndBounds()
    {
        byte[] valid = JsonSerializer.SerializeToUtf8Bytes(Document());
        State(ClaudeConnectionInspector.InspectStreams(() => throw new IOException("synthetic secret"), Commands),
            RegistrationState.ReadError, "read failure is not absence");
        InspectionResult denied = ClaudeConnectionInspector.InspectStreams(
            () => throw new UnauthorizedAccessException("synthetic secret"), Commands);
        State(denied, RegistrationState.ReadError, "access failure is not absence");
        Check(!denied.ToString().Contains("secret", StringComparison.Ordinal), "read exception is not exported");
        Unknown(denied);
        int opens = 0;
        InspectionResult changed = ClaudeConnectionInspector.InspectStreams(
            () => new MemoryStream(++opens == 1 ? valid : Encoding.UTF8.GetBytes("{}"), writable: false), Commands);
        State(changed, RegistrationState.ReadError, "different reads");
        Note(changed, InspectionNotes.DifferentReads, "different reads note");
        Check(opens == 2, "two reads performed");

        byte[] large = Encoding.UTF8.GetBytes("{\"other\":\"" + new string('x',
            ClaudeConnectionInspector.MaximumDocumentBytes) + "\"}");
        InspectionResult tooLarge = ClaudeConnectionInspector.InspectStreams(() => new MemoryStream(large, false), Commands);
        State(tooLarge, RegistrationState.ReadError, "bounded stream");
        Note(tooLarge, InspectionNotes.SizeLimit, "stream size limit note");
        InspectionResult largeBytes = ClaudeConnectionInspector.InspectBytes(large, Commands);
        State(largeBytes, RegistrationState.InvalidConfiguration, "bounded byte parser");
        Note(largeBytes, InspectionNotes.SizeLimit, "byte size limit note");

        opens = 0;
        InspectionResult secondFails = ClaudeConnectionInspector.InspectStreams(() =>
        {
            if (++opens == 2) throw new IOException("synthetic error");
            return new MemoryStream(valid, writable: false);
        }, Commands);
        State(secondFails, RegistrationState.ReadError, "second read failure");
    }

    private static void SyntheticFileReads()
    {
        string directory = Path.Combine(Path.GetTempPath(), "aitm-claude-inspection-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "synthetic.json");
        byte[] original = JsonSerializer.SerializeToUtf8Bytes(Document());
        try
        {
            State(ClaudeConnectionInspector.InspectFile(path, Commands), RegistrationState.ReadError,
                "missing file is not a disconnect");
            File.WriteAllBytes(path, original);
            using (var writer = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                State(ClaudeConnectionInspector.InspectFile(path, Commands), RegistrationState.RegisteredInFile,
                    "read allows an existing compatible writer");
            Check(File.ReadAllBytes(path).AsSpan().SequenceEqual(original), "inspection does not change file bytes");
            bool rejectedRelative = false;
            try { ClaudeConnectionInspector.InspectFile("relative.json", Commands); }
            catch (ArgumentException) { rejectedRelative = true; }
            Check(rejectedRelative, "relative paths rejected");
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            Directory.Delete(directory);
        }
    }

    private static Dictionary<string, object?> Document(string command = Current)
    {
        var hooks = new Dictionary<string, object?>();
        foreach (string name in Events)
        {
            var handler = new Dictionary<string, object?>
            {
                ["type"] = "command", ["command"] = command, ["timeout"] = 10
            };
            hooks[name] = new List<Dictionary<string, object?>>
            {
                new() { ["hooks"] = new List<Dictionary<string, object?>> { handler } }
            };
        }
        return new Dictionary<string, object?> { ["hooks"] = hooks };
    }

    private static Dictionary<string, object?> Hooks(Dictionary<string, object?> root)
        => (Dictionary<string, object?>)root["hooks"]!;

    private static Dictionary<string, object?> Group(Dictionary<string, object?> root, string eventName)
        => ((List<Dictionary<string, object?>>)Hooks(root)[eventName]!)[0];

    private static Dictionary<string, object?> Handler(Dictionary<string, object?> root, string eventName)
        => ((List<Dictionary<string, object?>>)Group(root, eventName)["hooks"]!)[0];

    private static InspectionResult Inspect(Dictionary<string, object?> root)
        => ClaudeConnectionInspector.InspectBytes(JsonSerializer.SerializeToUtf8Bytes(root), Commands);

    private static void Unknown(InspectionResult result)
    {
        Note(result, InspectionNotes.OtherSettingsAndPolicyNotInspected, "policy not verified");
        Note(result, InspectionNotes.EventDeliveryNotVerified, "delivery not verified");
    }

    private static void State(InspectionResult actual, RegistrationState expected, string description)
        => Check(actual.State == expected, description);

    private static void Note(InspectionResult actual, InspectionNotes expected, string description)
        => Check((actual.Notes & expected) == expected, description);

    private static void Check(bool condition, string description)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(description);
    }
}
