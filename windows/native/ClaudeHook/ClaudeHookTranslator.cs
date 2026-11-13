using System.Globalization;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using AITaskMonitor.ClaudePhase;

namespace AITaskMonitor.ClaudeHook;

// Only the bounded, sanitized event fields are retained; the full hook input
// and its tool response are never included in the output record.
public sealed record ClaudeEventRecord(
    [property: JsonPropertyName("timestamp")] string Timestamp,
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("session_id")] string SessionId,
    [property: JsonPropertyName("event")] string Event,
    [property: JsonPropertyName("active")] bool? Active,
    [property: JsonPropertyName("activity")] string Activity,
    [property: JsonPropertyName("task_id")] string TaskId,
    [property: JsonPropertyName("task_subject")] string TaskSubject,
    [property: JsonPropertyName("task_status")] string TaskStatus,
    [property: JsonPropertyName("tool_name")] string ToolName,
    [property: JsonPropertyName("stage_phase"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? StagePhase = null,
    [property: JsonPropertyName("stage_version"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? StageVersion = null,
    [property: JsonPropertyName("stage_previous_status"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? StagePreviousStatus = null,
    [property: JsonPropertyName("stage_requested_status"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? StageRequestedStatus = null,
    [property: JsonPropertyName("stage_task_id"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? StageTaskId = null);

public static class ClaudeHookTranslator
{
    public const int MaximumInputCodeUnits = 1_048_576;
    private static readonly Regex Whitespace = new(@"\s+", RegexOptions.CultureInvariant);

    // A caller must enforce the input bound while reading. A false result is
    // not evidence that an event did not occur: use SourceUncertain when the
    // caller can safely publish a loss marker.
    public static bool TryTranslate(string? json, DateTimeOffset timestamp, out ClaudeEventRecord? record)
    {
        record = null;
        if (string.IsNullOrEmpty(json) || json.Length > MaximumInputCodeUnits) return false;
        Observation observation = StageObservation.Assess(json);
        if (!observation.ValidInput) return false;

        string eventName = observation.Event;
        string phase = observation.Phase;
        string taskId = observation.TaskId;
        string taskStatus = observation.Status;
        if (phase == "step_uncertain")
        {
            phase = eventName == "TaskCreated" ? "created_notice" : "completed_notice";
            eventName = "StageNotice";
        }

        string? stageTaskId = null, requestedStatus = null;
        if (phase is "created_notice" or "completed_notice" or "update_attempt" or "update_failure" or "update_unknown")
        {
            stageTaskId = EmptyToNull(taskId);
            taskId = "";
        }
        if (phase is "update_attempt" or "update_failure" or "update_unknown")
        {
            requestedStatus = EmptyToNull(taskStatus);
            taskStatus = "";
        }

        string subject = Clip(observation.Subject, 240);
        string tool = Clip(observation.Tool, 120);
        string activity = eventName switch
        {
            "UserPromptSubmit" => "New request",
            "PreToolUse" => tool.Length == 0 ? "Running tool" : "Running: " + tool,
            "PostToolUse" when phase is "create_unknown" or "update_unknown" => "Status unconfirmed",
            "PostToolUse" => tool.Length == 0 ? "Tool completed" : "Completed: " + tool,
            "PostToolUseFailure" => tool.Length == 0 ? "Tool failed" : "Failed: " + tool,
            "StageNotice" => "Running an action",
            "SubagentStart" => "Subagent started",
            "SubagentStop" => "Subagent stopped",
            "Stop" => "Waiting for the next request",
            "SessionEnd" => "Session ended",
            _ => eventName
        };
        bool? active = phase is "source_uncertain" or "session_uncertain" or "stop_uncertain" or "stop_failure"
            ? null : eventName is not ("Stop" or "SessionEnd" or "StopFailure");
        record = new ClaudeEventRecord(Format(timestamp), "claude", observation.Session, eventName, active,
            activity, taskId, subject, taskStatus, tool, EmptyToNull(phase), phase.Length == 0 ? null : 1,
            EmptyToNull(observation.Previous), requestedStatus, stageTaskId);
        return true;
    }

    // Matches the current hook's fallback when input cannot be trusted. The
    // future process boundary must publish this marker on failed decoding,
    // truncation, unsupported input, or translation failure when possible.
    public static ClaudeEventRecord SourceUncertain(DateTimeOffset timestamp) =>
        new(Format(timestamp), "claude", "", "Unknown", null, "Unknown", "", "", "", "", "source_uncertain", 1);

    private static string Format(DateTimeOffset timestamp) => timestamp.UtcDateTime.ToString("o", CultureInfo.InvariantCulture);
    private static string? EmptyToNull(string value) => value.Length == 0 ? null : value;
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
