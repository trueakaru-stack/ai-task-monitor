using System.Globalization;
using AITaskMonitor.Claude;

namespace AITaskMonitor.Prototype;

// This fixture accepts no path, external event or agent connection.
internal sealed class SyntheticClaudeScenario
{
    private readonly DateTime started = new(2026, 11, 5, 15, 9, 0, DateTimeKind.Utc);
    private readonly List<string> records =
    [
        """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00Z","event":"UserPromptSubmit","active":true}""",
        """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00.100Z","event":"PostToolUse","active":true,"tool_name":"TaskCreate","task_id":"1","task_subject":"Мой реальный этап","stage_phase":"create_observed","stage_version":1}""",
        """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00.200Z","event":"PostToolUse","active":true,"tool_name":"TaskUpdate","task_id":"1","task_status":"in_progress","stage_phase":"update_observed","stage_version":1,"stage_previous_status":"pending"}""",
        """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00.300Z","event":"PostToolUse","active":true,"tool_name":"TaskUpdate","task_id":"1","task_status":"pending","stage_phase":"update_observed","stage_version":1,"stage_previous_status":"in_progress"}""",
        """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00.400Z","event":"PostToolUse","active":true,"tool_name":"TaskCreate","task_id":"2","task_subject":"Второй реальный этап","stage_phase":"create_observed","stage_version":1}""",
        """{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00.500Z","event":"PostToolUse","active":true,"tool_name":"TaskUpdate","task_id":"2","task_status":"in_progress","stage_phase":"update_observed","stage_version":1,"stage_previous_status":"pending"}"""
    ];
    private DateTime now = new(2026, 11, 5, 15, 9, 3, DateTimeKind.Utc);
    private int stage;

    public List<SampleTask> Snapshot(string language) =>
        Reader.Read(string.Join("\n", records), "", now, started)
            .Select(state => ClaudePresentation.Map(state, language)).ToList();

    public void Advance()
    {
        switch (stage++)
        {
            case 0:
                records.Add("""{"session_id":"synthetic","timestamp":"2026-11-05T15:09:04Z","event":"PostToolUse","active":true,"tool_name":"TaskUpdate","task_id":"1","task_status":"completed","stage_phase":"update_observed","stage_version":1,"stage_previous_status":"pending"}""");
                now = started.AddSeconds(5);
                break;
            case 1:
                records.Add("""{"session_id":"synthetic","timestamp":"2026-11-05T15:09:06Z","event":"PostToolUse","active":true,"tool_name":"Мой инструмент"}""");
                now = started.AddSeconds(7);
                break;
            case 2:
                now = started.AddMinutes(121);
                break;
            case 3:
                records.Add("""{"session_id":"synthetic","timestamp":"2026-11-05T17:10:01Z","event":"Stop","active":false,"stage_phase":"stop_clear","stage_version":1}""");
                now = started.AddMinutes(121).AddSeconds(2);
                break;
            default: throw new InvalidOperationException("The synthetic sequence is finished.");
        }
    }
}

// Converts the reader's generated labels while preserving source-provided text.
internal static class ClaudePresentation
{
    public static SampleTask Map(AITaskMonitor.Claude.Task state, string language)
    {
        if (language is not ("ru" or "en")) throw new ArgumentOutOfRangeException(nameof(language));
        bool english = language == "en";
        var steps = state.Steps.Select(step => new SampleStep(
            english && step.generated ? "Step " + step.id : step.title, step.status)).ToArray();
        int? progress = steps.Length == 0 || !state.PlanConfirmed ? null : (int)Math.Round(100.0 * steps.Count(step => step.Status == "done") / steps.Length);
        string activity = state.Unconfirmed ? (english ? "Status unconfirmed" : "Статус не подтверждён")
            : english ? TranslateGeneratedActivity(state.Activity) : state.Activity;
        var updated = new DateTimeOffset(DateTime.SpecifyKind(state.Updated, DateTimeKind.Utc));
        var started = new DateTimeOffset(DateTime.SpecifyKind(state.Started, DateTimeKind.Utc));
        return new SampleTask("claude:" + state.Id, "claude", "Claude Code",
            english ? "Claude Code task" : "Задача Claude Code", activity,
            state.Unconfirmed ? "unknown" : "active", progress, steps, state.PlanConfirmed,
            updated.LocalDateTime.ToString("HH:mm", CultureInfo.InvariantCulture), updated,
            string.IsNullOrEmpty(state.StartKey) ? "" : "claude:" + state.Id + ":" + state.StartKey, started,
            RetainedPlanIncomplete: state.RetainedPlanIncomplete);
    }

    private static string TranslateGeneratedActivity(string activity)
    {
        var pairs = new (string Russian, string English)[]
        {
            ("Выполняет: ", "Running: "), ("Завершено: ", "Completed: "),
            ("Ошибка: ", "Error: "), ("Добавлен этап: ", "Step added: "),
            ("Завершён этап: ", "Step completed: ")
        };
        foreach (var pair in pairs)
            if (activity.StartsWith(pair.Russian, StringComparison.Ordinal))
                return pair.English + activity[pair.Russian.Length..];
        return activity switch
        {
            "Обрабатывает новый запрос" => "Processing a new request",
            "Выполняет действие" => "Running an action",
            "Действие завершено" => "Action completed",
            "Ошибка действия" => "Action failed",
            "Добавлен этап" => "Step added",
            "Этап завершён" => "Step completed",
            "Запущен дополнительный агент" => "Subagent started",
            "Дополнительный агент завершён" => "Subagent completed",
            _ => activity
        };
    }
}
