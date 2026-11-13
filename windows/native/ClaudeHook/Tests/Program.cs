using System.Diagnostics;
using System.Text;
using System.Text.Json;
using AITaskMonitor.ClaudeHook;
using ClaudeReader = AITaskMonitor.Claude.Reader;

if (Environment.GetEnvironmentVariable("HOME") is not null || Environment.GetEnvironmentVariable("CODEX_HOME") is not null)
    throw new InvalidOperationException("The isolated test environment must omit HOME and CODEX_HOME.");
ClaudeHookInputReaderTests.RunAsync().GetAwaiter().GetResult();
if (args.Length == 1 && args[0] == "--native-only") return HookChecks.Run(null, "", null);
if (args.Length != 3) throw new ArgumentException("Expected --native-only or synthetic hook path, work directory and Windows PowerShell path.");
return HookChecks.Run(Path.GetFullPath(args[0]), Path.GetFullPath(args[1]), Path.GetFullPath(args[2]));

static class HookChecks
{
    private static int checks;
    private static readonly DateTimeOffset FixedTime = new(2026, 11, 5, 15, 30, 0, TimeSpan.FromHours(3));
    private const string Prompt = """{"hook_event_name":"UserPromptSubmit","session_id":"one","prompt":"SYNTHETIC_PRIVATE_PROMPT","cwd":"SYNTHETIC_PRIVATE_PATH"}""";
    private const string CreateBefore = """{"hook_event_name":"PreToolUse","session_id":"one","tool_name":"TaskCreate","tool_input":{"subject":"First step","command":"SYNTHETIC_PRIVATE_COMMAND"}}""";
    private const string CreateAfter = """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"TaskCreate","tool_input":{"subject":"First step"},"tool_response":{"task":{"id":"step-1","subject":"First step"},"private":"SYNTHETIC_PRIVATE_RESPONSE"}}""";
    private const string UpdateBefore = """{"hook_event_name":"PreToolUse","session_id":"one","tool_name":"TaskUpdate","tool_input":{"taskId":"step-1","status":"in_progress"}}""";
    private const string UpdateAfter = """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"TaskUpdate","tool_input":{"taskId":"step-1","status":"in_progress"},"tool_response":{"taskId":"step-1","success":true,"updatedFields":["status"],"statusChange":{"from":"pending","to":"in_progress"}}}""";
    private const string UpdateUnknown = """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"TaskUpdate","tool_input":{"taskId":"step-1","status":"in_progress"},"tool_response":{"taskId":"step-1","success":true,"updatedFields":["status","subject"],"statusChange":{"from":"pending","to":"in_progress"}}}""";
    private const string StopClear = """{"hook_event_name":"Stop","session_id":"one","background_tasks":[],"session_crons":[]}""";
    private const string StopUnknown = """{"hook_event_name":"Stop","session_id":"one"}""";

    private static void Check(bool condition, string message) { checks++; if (!condition) throw new InvalidOperationException(message); }

    public static int Run(string? hook, string root, string? windowsPowerShell)
    {
        bool compareLegacy = hook is not null && windowsPowerShell is not null;
        if (compareLegacy)
        {
            Check(File.Exists(hook) && File.Exists(windowsPowerShell), "A synthetic test dependency is missing.");
            Check(File.Exists(Path.Combine(Path.GetDirectoryName(hook!)!, "ClaudeStageObservation.dll")), "The current phase helper is missing.");
            Check(!File.Exists(Path.Combine(Path.GetDirectoryName(hook!)!, "store-channel.marker")), "The test hook layout is not isolated.");
        }
        var cases = new (string Name, string Json)[]
        {
            ("prompt privacy", Prompt), ("create attempt", CreateBefore), ("create observed", CreateAfter),
            ("update attempt", UpdateBefore), ("update observed", UpdateAfter), ("update uncertain", UpdateUnknown),
            ("create missing response", """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"TaskCreate","tool_input":{"subject":"First step"}}"""),
            ("create failure", """{"hook_event_name":"PostToolUseFailure","session_id":"one","tool_name":"TaskCreate","tool_input":{"subject":"First step"}}"""),
            ("create mismatched subject", """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"TaskCreate","tool_input":{"subject":"First step"},"tool_response":{"task":{"id":"step-1","subject":"Different"}}}"""),
            ("create error", """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"TaskCreate","tool_input":{"subject":"First step"},"tool_response":{"error":"SYNTHETIC_PRIVATE_ERROR","task":{"id":"step-1","subject":"First step"}}}"""),
            ("update failure", """{"hook_event_name":"PostToolUseFailure","session_id":"one","tool_name":"TaskUpdate","tool_input":{"taskId":"step-1","status":"completed"}}"""),
            ("update alias conflict", """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"TaskUpdate","tool_input":{"taskId":"step-1","task_id":"other","status":"completed"},"tool_response":{"taskId":"step-1","success":true,"updatedFields":["status"],"statusChange":{"from":"pending","to":"completed"}}}"""),
            ("created notice", """{"hook_event_name":"TaskCreated","session_id":"one","task_id":"step-1","task_subject":"First step"}"""),
            ("completed notice", """{"hook_event_name":"TaskCompleted","session_id":"one","task_id":"step-1","task_subject":"First step"}"""),
            ("stop clear", StopClear), ("stop unknown", StopUnknown),
            ("stop background", """{"hook_event_name":"Stop","session_id":"one","background_tasks":[{}],"session_crons":[]}"""),
            ("stop failure", """{"hook_event_name":"StopFailure","session_id":"one"}"""),
            ("session end", """{"hook_event_name":"SessionEnd","session_id":"one"}"""),
            ("subagent", """{"hook_event_name":"SubagentStart","session_id":"one"}"""),
            ("unknown event", """{"hook_event_name":"Notification","session_id":"one"}"""),
            ("wrong event case", """{"hook_event_name":"sToP","session_id":"one"}"""),
            ("wrong tool case", """{"hook_event_name":"PreToolUse","session_id":"one","tool_name":"taskcreate"}"""),
            ("missing session", """{"hook_event_name":"Stop"}"""), ("malformed JSON", "{"), ("empty input", ""),
            ("duplicate field", """{"hook_event_name":"Stop","session_id":"one","session_id":"two"}"""),
            ("case-conflicting field", """{"hook_event_name":"Stop","session_id":"one","SESSION_ID":"two"}"""),
            ("non scalar", """{"hook_event_name":"TaskCreated","session_id":"one","task_id":{"prompt":"SYNTHETIC_PRIVATE_PROMPT"}}"""),
            ("unicode", """{"hook_event_name":"TaskCreated","session_id":"unicode","task_id":"step-1","task_subject":"Пример 🌿"}""")
        };
        foreach ((string name, string json) in cases)
        {
            ClaudeEventRecord native = TranslateOrLoss(json, FixedTime);
            if (compareLegacy)
            {
                LegacyResult old = InvokeLegacy(hook!, root, windowsPowerShell!, json);
                Check(old.ExitCode == 0 && old.Record is not null, name + ": the current hook produced no record.");
                using (old.Record) Compare(name, old.Record!, native);
            }
            else
            {
                string output = JsonSerializer.Serialize(native);
                Check(!output.Contains("SYNTHETIC_PRIVATE_", StringComparison.Ordinal), name + ": private synthetic input entered the record.");
            }
        }

        Check(Translate(CreateAfter).StagePhase == "create_observed", "Successful creation lost its observed phase.");
        ClaudeEventRecord updateAttempt = Translate(UpdateBefore);
        Check(updateAttempt.StagePhase == "update_attempt" && updateAttempt.TaskId == "" &&
            updateAttempt.TaskStatus == "" && updateAttempt.StageTaskId == "step-1" &&
            updateAttempt.StageRequestedStatus == "in_progress", "An update attempt was represented as a proven update.");
        ClaudeEventRecord update = Translate(UpdateAfter);
        Check(update.StagePhase == "update_observed" && update.TaskId == "step-1" &&
            update.TaskStatus == "in_progress" && update.StagePreviousStatus == "pending", "An observed update lost its transition.");
        Check(Translate(UpdateUnknown).StagePhase == "update_unknown", "A multi-field update was incorrectly confirmed.");
        Check(Translate(StopClear) is { Active: false, StagePhase: "stop_clear" }, "A clear stop was not represented.");
        Check(Translate(StopUnknown) is { Active: null, StagePhase: "stop_uncertain" }, "An ambiguous stop was marked complete.");
        Check(Translate("""{"hook_event_name":"TaskCreated","session_id":"one","task_id":"step-1","task_subject":"First step"}""")
            is { Event: "StageNotice", StagePhase: "created_notice", TaskId: "", StageTaskId: "step-1" }, "A blockable notice was marked as observed.");

        foreach (string input in new[] { Prompt, CreateBefore, CreateAfter })
            Check(!JsonSerializer.Serialize(Translate(input)).Contains("SYNTHETIC_PRIVATE_", StringComparison.Ordinal),
                "Private input entered the record.");
        Check(!ClaudeHookTranslator.TryTranslate("{", FixedTime, out _) && !ClaudeHookTranslator.TryTranslate("[]", FixedTime, out _), "Malformed input was accepted.");
        const string prefix = "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"one\",\"prompt\":\"";
        const string suffix = "\"}";
        string maximum = prefix + new string('x', ClaudeHookTranslator.MaximumInputCodeUnits - prefix.Length - suffix.Length) + suffix;
        Check(ClaudeHookTranslator.TryTranslate(maximum, FixedTime, out _), "An exact-limit valid event was rejected.");
        string oversized = prefix + new string('x', ClaudeHookTranslator.MaximumInputCodeUnits - prefix.Length - suffix.Length + 1) + suffix;
        using (JsonDocument validOversized = JsonDocument.Parse(oversized))
            Check(validOversized.RootElement.ValueKind == JsonValueKind.Object && oversized.Length == ClaudeHookTranslator.MaximumInputCodeUnits + 1,
                "The oversized fixture is not valid JSON one unit above the limit.");
        Check(!ClaudeHookTranslator.TryTranslate(oversized, FixedTime, out _), "Oversized valid input was accepted.");
        Check(!ClaudeHookTranslator.TryTranslate("""{"hook_event_name":"Stop","session_id":"one","session_id":"two"}""", FixedTime, out _), "Duplicate fields were accepted.");
        const string dateLike = """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"TaskCreate","tool_input":{"subject":"/Date(0)/"},"tool_response":{"task":{"id":"step-1","subject":"/Date(0)/"}}}""";
        Check(Translate(dateLike).StagePhase == "create_unknown", "A date-like subject was incorrectly confirmed as a string.");
        Check(ClaudeHookTranslator.SourceUncertain(FixedTime) is { Event: "Unknown", Active: null, StagePhase: "source_uncertain", StageVersion: 1 }, "Input loss did not produce the explicit uncertainty marker.");
        Check(Translate(Prompt).Timestamp == "2026-11-05T12:30:00.0000000Z", "Injected time was not normalized to UTC.");
        ReaderChecks();
        Console.WriteLine($"Claude phase translation: {cases.Length} {(compareLegacy ? "differential" : "native-only")} cases and synthetic reader checks; {checks} assertions passed.");
        return 0;
    }

    private static void ReaderChecks()
    {
        string Journal(params string[] inputs) => string.Join("\n", inputs.Select((input, index) =>
            JsonSerializer.Serialize(TranslateOrLoss(input, FixedTime.AddMilliseconds(index * 100)))));
        DateTime now = FixedTime.UtcDateTime.AddSeconds(5), observedSince = FixedTime.UtcDateTime.AddSeconds(-1);
        var createdOnly = ClaudeReader.Read(Journal(Prompt, CreateBefore, CreateAfter), "", now, observedSince).Single();
        Check(!createdOnly.PlanConfirmed && createdOnly.Steps.Single().status == "unknown", "Creation alone confirmed an unobserved status.");
        var known = ClaudeReader.Read(Journal(Prompt, CreateBefore, CreateAfter, UpdateBefore, UpdateAfter), "", now, observedSince).Single();
        Check(known.PlanConfirmed && known.KnownStepCount == 1 && known.Steps.Single().status == "active", "A fully observed known step was not confirmed.");
        var uncertain = ClaudeReader.Read(Journal(Prompt, CreateBefore, CreateAfter, UpdateBefore, UpdateUnknown), "", now, observedSince).Single();
        Check(!uncertain.PlanConfirmed && uncertain.Steps.Any(step => step.title == "First step" && step.status == "unknown"), "An uncertain update hid or confirmed the known step.");
        var ambiguousStop = ClaudeReader.Read(Journal(Prompt, CreateBefore, CreateAfter, UpdateBefore, UpdateAfter, StopUnknown), "", now, observedSince).Single();
        Check(ambiguousStop.Unconfirmed && !ambiguousStop.PlanConfirmed, "An ambiguous stop hid or confirmed an active task.");
        Check(ClaudeReader.Read(Journal(Prompt, CreateBefore, CreateAfter, UpdateBefore, UpdateAfter, StopClear), "", now, observedSince).Length == 0, "A clear stop did not close the observed task.");
        string loss = Journal(Prompt, CreateBefore, CreateAfter, UpdateBefore, UpdateAfter) + "\n" +
            JsonSerializer.Serialize(ClaudeHookTranslator.SourceUncertain(FixedTime.AddSeconds(1)));
        var lost = ClaudeReader.Read(loss, "", now, observedSince).Single();
        Check(lost.Unconfirmed && !lost.PlanConfirmed, "A source-loss marker did not preserve uncertainty.");
        // PlanConfirmed is evidence about observed steps; it does not prove the total plan is complete.
    }

    private static ClaudeEventRecord Translate(string json)
    {
        Check(ClaudeHookTranslator.TryTranslate(json, FixedTime, out ClaudeEventRecord? result) && result is not null, "A valid synthetic input was rejected.");
        return result!;
    }

    private static ClaudeEventRecord TranslateOrLoss(string? json, DateTimeOffset time) =>
        ClaudeHookTranslator.TryTranslate(json, time, out ClaudeEventRecord? result) ? result! : ClaudeHookTranslator.SourceUncertain(time);

    private static void Compare(string name, JsonDocument legacy, ClaudeEventRecord record)
    {
        using JsonDocument native = JsonDocument.Parse(JsonSerializer.Serialize(record));
        JsonElement a = legacy.RootElement, b = native.RootElement;
        Check(a.EnumerateObject().Count() == b.EnumerateObject().Count(), name + ": event field count differs.");
        foreach (JsonProperty field in a.EnumerateObject())
        {
            if (field.Name == "timestamp") continue;
            Check(b.TryGetProperty(field.Name, out JsonElement actual) && Same(field.Value, actual), name + ": mismatch in " + field.Name + ".");
        }
    }

    private static bool Same(JsonElement a, JsonElement b) => a.ValueKind == b.ValueKind && (a.ValueKind switch
    {
        JsonValueKind.String => a.GetString() == b.GetString(),
        JsonValueKind.Number => a.GetDecimal() == b.GetDecimal(),
        JsonValueKind.True or JsonValueKind.False => a.GetBoolean() == b.GetBoolean(),
        JsonValueKind.Null => true,
        _ => false
    });

    private sealed record LegacyResult(int ExitCode, JsonDocument? Record);

    private static LegacyResult InvokeLegacy(string hook, string root, string shell, string json)
    {
        string id = Guid.NewGuid().ToString("N");
        string home = Path.Combine(root, "home-" + id), local = Path.Combine(home, "local"), appdata = Path.Combine(home, "appdata"), temp = Path.Combine(home, "temp");
        Directory.CreateDirectory(local); Directory.CreateDirectory(appdata); Directory.CreateDirectory(temp);
        string system = Environment.GetEnvironmentVariable("SystemRoot") ?? throw new InvalidOperationException("SystemRoot missing.");
        var start = new ProcessStartInfo(shell) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = home,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string argument in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", hook,
            "-LoopTestPipe", "AITM.Test." + id, "-LogTestMutex", "AITM.Test." + id }) start.ArgumentList.Add(argument);
        start.Environment.Clear();
        start.Environment["SystemRoot"] = system; start.Environment["windir"] = system;
        start.Environment["PATH"] = Path.Combine(system, "System32");
        start.Environment["PSModulePath"] = Path.Combine(system, "System32", "WindowsPowerShell", "v1.0", "Modules");
        start.Environment["USERPROFILE"] = home; start.Environment["LOCALAPPDATA"] = local; start.Environment["APPDATA"] = appdata;
        start.Environment["TEMP"] = temp; start.Environment["TMP"] = temp;
        start.Environment["AI_TASK_MONITOR_AUDIT"] = "1"; start.Environment["PSModuleAnalysisCachePath"] = Path.Combine(temp, "ModuleAnalysisCache");
        start.Environment["DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"] = "0";
        using Process process = Process.Start(start) ?? throw new InvalidOperationException("The synthetic hook did not start.");
        Task<string> stdout = process.StandardOutput.ReadToEndAsync(), stderr = process.StandardError.ReadToEndAsync();
        byte[] bytes = Encoding.UTF8.GetBytes(json);
        process.StandardInput.BaseStream.Write(bytes); process.StandardInput.Close();
        if (!process.WaitForExit(15000)) { process.Kill(true); throw new TimeoutException("The synthetic hook timed out."); }
        _ = stdout.GetAwaiter().GetResult(); _ = stderr.GetAwaiter().GetResult();
        string path = Path.Combine(local, "CodexTaskProgress", "claude-events-v2.jsonl");
        if (!File.Exists(path)) return new LegacyResult(process.ExitCode, null);
        string[] lines = File.ReadAllLines(path, Encoding.UTF8);
        Check(lines.Length == 1, "The synthetic hook wrote an unexpected number of records.");
        return new LegacyResult(process.ExitCode, JsonDocument.Parse(lines[0]));
    }
}
