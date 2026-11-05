using System.Diagnostics;
using System.Text;
using System.Text.Json;
using AITaskMonitor.ClaudeHook;

if (args.Length != 3) throw new ArgumentException("Expected synthetic hook path, work directory and Windows PowerShell path.");
ClaudeHookInputReaderTests.RunAsync().GetAwaiter().GetResult();
return HookChecks.Run(Path.GetFullPath(args[0]), Path.GetFullPath(args[1]), Path.GetFullPath(args[2]));

static class HookChecks
{
    private static int checks;
    private static readonly DateTimeOffset FixedTime = new(2026, 11, 5, 15, 30, 0, TimeSpan.FromHours(3));
    private static readonly string[] Fields = ["provider", "session_id", "event", "active", "activity", "task_id", "task_subject", "task_status", "tool_name"];
    private static void Check(bool condition, string message) { checks++; if (!condition) throw new InvalidOperationException(message); }

    public static int Run(string hook, string root, string windowsPowerShell)
    {
        Check(File.Exists(hook) && File.Exists(windowsPowerShell), "A synthetic test dependency is missing.");
        Check(!File.Exists(Path.Combine(Path.GetDirectoryName(hook)!, "store-channel.marker")), "The test hook layout is not isolated.");
        var cases = new List<(string Name, string Json)>
        {
            ("empty object", "{}"),
            ("request and private fields", """{"hook_event_name":"UserPromptSubmit","session_id":"synthetic","prompt":"SYNTHETIC_PRIVATE_PROMPT","cwd":"SYNTHETIC_PRIVATE_CWD","transcript_path":"SYNTHETIC_PRIVATE_TRANSCRIPT","tool_input":{"command":"SYNTHETIC_PRIVATE_COMMAND"},"tool_response":"SYNTHETIC_PRIVATE_RESPONSE"}"""),
            ("pre tool", """{"hook_event_name":"PreToolUse","session_id":"one","tool_name":"Bash","tool_input":{"command":"SYNTHETIC_PRIVATE_COMMAND"}}"""),
            ("pre tool absent name", """{"hook_event_name":"PreToolUse","session_id":"one"}"""),
            ("post tool", """{"hook_event_name":"PostToolUse","session_id":"one","tool_name":"Read"}"""),
            ("post tool no name", """{"hook_event_name":"PostToolUse","session_id":"one"}"""),
            ("failed tool", """{"hook_event_name":"PostToolUseFailure","session_id":"one","tool_name":"PowerShell"}"""),
            ("failed tool no name", """{"hook_event_name":"PostToolUseFailure","session_id":"one"}"""),
            ("plan created", """{"hook_event_name":"TaskCreated","session_id":"one","tool_input":{"taskId":"step-1","subject":"Собрать  первый\nэтап 🌿","status":"in_progress","command":"SYNTHETIC_PRIVATE_COMMAND"}}"""),
            ("plan completed", """{"hook_event_name":"TaskCompleted","session_id":"one","task_id":"top","task_subject":"Finish work","tool_input":{"taskId":"nested","subject":"Ignored","status":"completed"}}"""),
            ("plan fallback", """{"hook_event_name":"TaskCreated","session_id":"one","tool_input":{"task_id":"fallback","status":"pending"}}"""),
            ("plan null suppresses fallback", """{"hook_event_name":"TaskCreated","session_id":"one","task_id":null,"task_subject":null,"tool_input":{"taskId":"ignored","subject":"ignored"}}"""),
            ("subagent start", """{"hook_event_name":"SubagentStart","session_id":"one"}"""),
            ("subagent stop", """{"hook_event_name":"SubagentStop","session_id":"one"}"""),
            ("stop", """{"hook_event_name":"Stop","session_id":"one","stop_hook_active":true}"""),
            ("stop failure", """{"hook_event_name":"StopFailure","session_id":"one"}"""),
            ("session end", """{"hook_event_name":"SessionEnd","session_id":"one"}"""),
            ("case insensitive event", """{"hook_event_name":"sToP","session_id":"one"}"""),
            ("other event", """{"hook_event_name":"Notification","session_id":"one"}"""),
            ("case insensitive fields", """{"HOOK_EVENT_NAME":"TaskCreated","SESSION_ID":"one","TOOL_INPUT":{"TASKID":42,"SUBJECT":"Step","STATUS":true}}"""),
            ("duplicate exact case last wins", """{"hook_event_name":"PreToolUse","session_id":"one","tool_name":"Read","tool_name":"Edit"}"""),
            ("scalar conversion", """{"hook_event_name":"TaskCreated","session_id":42,"task_id":-7,"task_subject":false,"tool_input":{"status":1.5}}"""),
            ("subject at 240", JsonSerializer.Serialize(new { hook_event_name = "TaskCreated", session_id = "one", task_subject = new string('a', 240) })),
            ("subject above 240", JsonSerializer.Serialize(new { hook_event_name = "TaskCreated", session_id = "one", task_subject = new string('a', 241) })),
            ("tool above 120", JsonSerializer.Serialize(new { hook_event_name = "PreToolUse", session_id = "one", tool_name = new string('b', 121) })),
            ("unicode remains within limit", "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"unicode\",\"task_subject\":\"Пример 🌿 é\"}"),
            ("unicode whitespace", "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"unicode\",\"task_subject\":\"  Первая\\tстрока\\nвторая часть  \"}"),
            ("unicode in all retained fields", "{\"hook_event_name\":\"Évent 🌿\",\"session_id\":\"сессия 🌍\",\"task_id\":\"задача 🚀\",\"task_subject\":\"название 🎨\",\"tool_name\":\"инструмент 🛠\",\"tool_input\":{\"status\":\"статус 🟢\"}}"),
            ("null event", """{"hook_event_name":null,"session_id":"one"}""")
        };
        foreach ((string name, string json) in cases)
        {
            bool accepted = ClaudeHookTranslator.TryTranslate(json, FixedTime, out ClaudeEventRecord? actual);
            Check(accepted && actual is not null, name + ": translator rejected a supported event.");
            LegacyResult old = InvokeLegacy(hook, root, windowsPowerShell, ToAscii(json));
            Check(old.ExitCode == 0 && old.Record is not null, name + ": the legacy hook did not produce a record.");
            Compare(name, old.Record!, actual!);
        }

        const string rawUnicode = "{\"hook_event_name\":\"TaskCreated\",\"session_id\":\"unicode\",\"task_subject\":\"Пример 🌿 é\"}";
        Check(ClaudeHookTranslator.TryTranslate(rawUnicode, FixedTime, out ClaudeEventRecord? unicode) && unicode!.TaskSubject == "Пример 🌿 é",
            "Valid Unicode did not survive the translator.");
        LegacyResult rawOld = InvokeLegacy(hook, root, windowsPowerShell, rawUnicode);
        Check(rawOld.ExitCode == 0 && rawOld.Record is not null, "Legacy direct UTF-8 fixture failed.");
        bool legacyPreserved = rawOld.Record!.RootElement.GetProperty("task_subject").GetString() == unicode!.TaskSubject;
        Console.WriteLine("Direct UTF-8 on this Windows host: legacy Unicode preserved=" + legacyPreserved + "; native Unicode preserved=True.");

        string splitSubject = new string('x', 236) + "🌿" + new string('y', 5);
        string boundary = JsonSerializer.Serialize(new { hook_event_name = "TaskCreated", session_id = "unicode", task_subject = splitSubject });
        Check(ClaudeHookTranslator.TryTranslate(boundary, FixedTime, out ClaudeEventRecord? clipped) && clipped!.TaskSubject.Length <= 240 &&
            ValidUtf16(clipped.TaskSubject) && clipped.TaskSubject == new string('x', 236) + "...", "Clipping split a UTF-16 surrogate pair.");
        LegacyResult splitOld = InvokeLegacy(hook, root, windowsPowerShell, ToAscii(boundary));
        Check(splitOld.ExitCode == 0 && splitOld.Record is not null, "Legacy surrogate-boundary fixture failed.");
        string? oldSubject = splitOld.Record!.RootElement.GetProperty("task_subject").GetString();
        Check(oldSubject != clipped!.TaskSubject, "The expected legacy surrogate-boundary difference was not observed.");
        string splitTool = new string('t', 116) + "🌿" + new string('u', 5);
        string toolBoundary = JsonSerializer.Serialize(new { hook_event_name = "PreToolUse", session_id = "unicode", tool_name = splitTool });
        Check(ClaudeHookTranslator.TryTranslate(toolBoundary, FixedTime, out ClaudeEventRecord? clippedTool) &&
            clippedTool!.ToolName == new string('t', 116) + "..." && ValidUtf16(clippedTool.ToolName),
            "Clipping a tool name split a UTF-16 surrogate pair.");

        string prefix = "{\"hook_event_name\":\"Stop\",\"session_id\":\"s\",\"prompt\":\"";
        const string suffix = "\"}";
        string exact = prefix + new string('x', ClaudeHookTranslator.MaximumInputCodeUnits - prefix.Length - suffix.Length) + suffix;
        bool acceptedExact = ClaudeHookTranslator.TryTranslate(exact, FixedTime, out ClaudeEventRecord? exactRecord);
        Check(exact.Length == ClaudeHookTranslator.MaximumInputCodeUnits && acceptedExact,
            "The exact input limit was rejected.");
        LegacyResult exactOld = InvokeLegacy(hook, root, windowsPowerShell, exact);
        Check(exactOld.ExitCode == 0 && exactOld.Record is not null, "The legacy hook rejected the exact input limit.");
        Compare("exact input limit", exactOld.Record!, exactRecord!);
        string oversized = prefix + new string('x', ClaudeHookTranslator.MaximumInputCodeUnits - prefix.Length - suffix.Length + 1) + suffix;
        Check(!ClaudeHookTranslator.TryTranslate(oversized, FixedTime, out _) && oversized.Length == ClaudeHookTranslator.MaximumInputCodeUnits + 1,
            "An oversized input was accepted.");
        LegacyResult oversizedOld = InvokeLegacy(hook, root, windowsPowerShell, oversized, allowBrokenInput: true);
        Check(oversizedOld.ExitCode == 0 && oversizedOld.Record is null, "The legacy hook did not reject oversized input.");

        const string conflict = """{"hook_event_name":"Stop","session_id":"one","tool_name":"Read","TOOL_NAME":"Edit"}""";
        Check(!ClaudeHookTranslator.TryTranslate(conflict, FixedTime, out _), "Conflicting property casing was accepted.");
        LegacyResult conflictOld = InvokeLegacy(hook, root, windowsPowerShell, conflict);
        Check(conflictOld.Record is null, "The legacy hook unexpectedly accepted conflicting property casing.");
        Check(!ClaudeHookTranslator.TryTranslate("{", FixedTime, out _), "Malformed JSON was accepted.");
        Check(!ClaudeHookTranslator.TryTranslate("[]", FixedTime, out _), "A non-object root was accepted.");
        const string nonScalar = """{"hook_event_name":"TaskCreated","session_id":"one","task_subject":{"prompt":"SYNTHETIC_PRIVATE_SENTINEL"}}""";
        Check(!ClaudeHookTranslator.TryTranslate(nonScalar, FixedTime, out _), "A non-scalar selected field was accepted.");
        LegacyResult nonScalarOld = InvokeLegacy(hook, root, windowsPowerShell, nonScalar);
        Check(nonScalarOld.Record is not null, "The expected legacy non-scalar difference was not observed.");
        string[] nonScalarFields =
        [
            """{"hook_event_name":{"prompt":"SYNTHETIC_PRIVATE_SENTINEL"},"session_id":"one"}""",
            """{"hook_event_name":"Stop","session_id":["SYNTHETIC_PRIVATE_SENTINEL"]}""",
            """{"hook_event_name":"TaskCreated","task_id":{"prompt":"SYNTHETIC_PRIVATE_SENTINEL"}}""",
            """{"hook_event_name":"TaskCreated","tool_input":{"status":["SYNTHETIC_PRIVATE_SENTINEL"]}}""",
            """{"hook_event_name":"PreToolUse","tool_name":{"command":"SYNTHETIC_PRIVATE_SENTINEL"}}"""
        ];
        foreach (string invalid in nonScalarFields)
            Check(!ClaudeHookTranslator.TryTranslate(invalid, FixedTime, out _), "A composite event, session, task, status or tool field was accepted.");
        Check(!ClaudeHookTranslator.TryTranslate("""{"hook_event_name":"TaskCreated","task_subject":"\ud800"}""", FixedTime, out _),
            "An unpaired surrogate was accepted.");
        string rawUnpaired = "{\"hook_event_name\":\"TaskCreated\",\"task_subject\":\"" + '\ud800' + "\"}";
        Check(!ClaudeHookTranslator.TryTranslate(rawUnpaired, FixedTime, out _), "A raw unpaired surrogate was accepted.");
        const string validEscapedPair = """{"hook_event_name":"TaskCreated","task_subject":"\ud83c\udf3f"}""";
        Check(ClaudeHookTranslator.TryTranslate(validEscapedPair, FixedTime, out ClaudeEventRecord? escaped) && escaped!.TaskSubject == "🌿",
            "An escaped supplementary Unicode character was not preserved.");

        Check(ClaudeHookTranslator.TryTranslate(cases[1].Json, FixedTime, out ClaudeEventRecord? privacy), "Privacy fixture failed.");
        string serialized = JsonSerializer.Serialize(privacy);
        Check(!serialized.Contains("SYNTHETIC_PRIVATE_", StringComparison.Ordinal), "A private input field entered the record.");
        Check(privacy!.Timestamp == "2026-11-05T12:30:00.0000000Z", "Injected time was not normalized to UTC.");
        Console.WriteLine($"Claude hook translator: {cases.Count} differential events plus boundaries and privacy; {checks} assertions passed.");
        return 0;
    }

    private static void Compare(string name, JsonDocument legacy, ClaudeEventRecord record)
    {
        using JsonDocument native = JsonDocument.Parse(JsonSerializer.Serialize(record));
        Check(legacy.RootElement.EnumerateObject().Count() == 10 && native.RootElement.EnumerateObject().Count() == 10, name + ": unexpected fields.");
        foreach (string field in Fields)
        {
            JsonElement a = legacy.RootElement.GetProperty(field), b = native.RootElement.GetProperty(field);
            bool same = a.ValueKind == b.ValueKind && (a.ValueKind == JsonValueKind.String ? a.GetString() == b.GetString() : a.GetBoolean() == b.GetBoolean());
            Check(same, name + ": mismatch in " + field + ".");
        }
    }

    private static string ToAscii(string json)
    {
        var builder = new StringBuilder(json.Length);
        foreach (char c in json) { if (c < 128) builder.Append(c); else builder.Append("\\u").Append(((int)c).ToString("x4")); }
        return builder.ToString();
    }
    private static bool ValidUtf16(string value)
    {
        for (int i = 0; i < value.Length; i++)
        {
            if (char.IsHighSurrogate(value[i])) { if (++i >= value.Length || !char.IsLowSurrogate(value[i])) return false; }
            else if (char.IsLowSurrogate(value[i])) return false;
        }
        return true;
    }
    private sealed record LegacyResult(int ExitCode, JsonDocument? Record);

    private static LegacyResult InvokeLegacy(string hook, string root, string shell, string json, bool allowBrokenInput = false)
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
        start.Environment["USERPROFILE"] = home; start.Environment["HOME"] = home; start.Environment["CODEX_HOME"] = Path.Combine(home, "codex-fixture");
        start.Environment["LOCALAPPDATA"] = local; start.Environment["APPDATA"] = appdata; start.Environment["TEMP"] = temp; start.Environment["TMP"] = temp;
        start.Environment["AI_TASK_MONITOR_AUDIT"] = "1"; start.Environment["PSModuleAnalysisCachePath"] = Path.Combine(temp, "ModuleAnalysisCache");
        using Process process = Process.Start(start) ?? throw new InvalidOperationException("The synthetic hook did not start.");
        Task<string> stdout = process.StandardOutput.ReadToEndAsync(), stderr = process.StandardError.ReadToEndAsync();
        try
        {
            byte[] bytes = Encoding.UTF8.GetBytes(json);
            process.StandardInput.BaseStream.Write(bytes); process.StandardInput.Close();
        }
        catch (IOException) when (allowBrokenInput) { process.StandardInput.Close(); }
        if (!process.WaitForExit(15000)) { process.Kill(true); throw new TimeoutException("The synthetic hook timed out."); }
        _ = stdout.GetAwaiter().GetResult(); _ = stderr.GetAwaiter().GetResult();
        string path = Path.Combine(local, "CodexTaskProgress", "claude-events-v2.jsonl");
        if (!File.Exists(path)) return new LegacyResult(process.ExitCode, null);
        string[] lines = File.ReadAllLines(path, Encoding.UTF8);
        Check(lines.Length == 1, "The synthetic hook wrote an unexpected number of records.");
        return new LegacyResult(process.ExitCode, JsonDocument.Parse(lines[0]));
    }
}
