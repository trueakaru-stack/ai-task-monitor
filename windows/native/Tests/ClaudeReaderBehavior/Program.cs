// This same in-memory fixture is compiled once with the PowerShell embedded
// reader and once with the native reader. It accepts no input paths.
using System;
using System.Globalization;
using System.Linq;
using AITaskMonitor.Claude;

internal static class Program
{
    private static int checks;
    private static void Check(bool condition, string description)
    {
        checks++;
        if (!condition) throw new InvalidOperationException(description);
    }

    private static string Event(string id, string name, DateTime time, bool active, string extra)
    {
        return String.Format(CultureInfo.InvariantCulture,
            "{{\"session_id\":\"{0}\",\"timestamp\":\"{1:o}\",\"event\":\"{2}\",\"active\":{3}{4}}}",
            id, time, name, active ? "true" : "false", extra);
    }

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 1 || (args[0] != "embedded" && args[0] != "native"))
                throw new ArgumentException("Choose the embedded or native synthetic reader.");
            bool native = args[0] == "native";
            DateTime now = new DateTime(2026, 11, 5, 12, 0, 0, DateTimeKind.Utc);
            DateTime boundary = now.AddMinutes(-1), start = now.AddSeconds(-10);
            string prompt = Event("observed", "UserPromptSubmit", start, true, "");
            string action = Event("observed", "PreToolUse", start.AddSeconds(1), true,
                ",\"tool_name\":\"Read\",\"activity\":\"SYNTHETIC_SECRET_NOT_FOR_DISPLAY\"");
            Task first = Reader.Read(prompt, "", now, boundary).Single();
            Task next = Reader.Read(prompt + "\n" + action, "", now, boundary).Single();
            Check(first.Id == "observed" && !first.Unconfirmed && !next.Unconfirmed,
                "Observed current session was not active.");
            Check(!String.IsNullOrEmpty(first.StartKey) && first.StartKey == next.StartKey && first.Started == next.Started,
                "An ordinary action changed the prompt identity.");
            Check(!next.Activity.Contains("SYNTHETIC_SECRET_NOT_FOR_DISPLAY"), "Raw activity leaked into the view.");
            Check(Reader.Read(prompt, "", now, now.AddSeconds(1)).Length == 0,
                "An event from before monitor startup appeared as current.");
            Check(Reader.Read("", Event("ghost", "UserPromptSubmit", start, true, ""), now, boundary).Length == 0,
                "A legacy-only session created a current card.");
            string oldTitle = Event("observed", "TaskCreated", start.AddSeconds(-1), true,
                ",\"task_id\":\"legacy-step\",\"task_subject\":\"Synthetic legacy step\",\"task_status\":\"in_progress\"");
            string oldGhost = Event("ghost", "UserPromptSubmit", start.AddSeconds(-1), true, "");
            Task resumed = Reader.Read(action, oldTitle + "\n" + oldGhost, now, boundary).Single();
            Check(resumed.Id == "observed" && resumed.Steps.Length == 1 &&
                resumed.Steps[0].title == "Synthetic legacy step" && !resumed.Steps[0].generated &&
                resumed.Steps[0].status == "unknown",
                "A current session lost its legacy step name or confirmed an inferred status.");
            string later = Event("observed", "UserPromptSubmit", start.AddSeconds(2), true, "");
            Task continued = Reader.Read(prompt + "\n" + action + "\n" + later, "", now, boundary).Single();
            Check(continued.StartKey != first.StartKey && continued.Started > first.Started,
                "A later prompt did not receive a new identity.");

            string quiet = Event("quiet", "PreToolUse", now.AddHours(-3), true, ",\"tool_name\":\"Read\"");
            Check(Reader.Read(quiet, "", now, now.AddHours(-4)).Single().Unconfirmed,
                "A quiet observed session did not remain unconfirmed.");
            string quietResumed = Event("quiet", "PostToolUse", now, true, ",\"tool_name\":\"Read\"");
            Check(!Reader.Read(quiet + "\n" + quietResumed, "", now, now.AddHours(-4)).Single().Unconfirmed,
                "A later clean activity event did not restore a quiet session.");
            Task damaged = Reader.Read(prompt + "\n{broken", "", now, boundary).Single();
            Check(damaged.Unconfirmed && !damaged.PlanConfirmed,
                "A damaged current journal produced a confirmed task.");
            string oldStep = Event("observed", "TaskCreated", start.AddSeconds(1), true,
                ",\"task_id\":\"old-step\",\"task_subject\":\"Synthetic step\",\"task_status\":\"in_progress\"");
            Task uncertainStep = Reader.Read(prompt + "\n" + oldStep, "", now, boundary).Single();
            Check(uncertainStep.Steps.Length == 1 && uncertainStep.Steps[0].status == "unknown",
                "An old inferred step was treated as confirmed.");
            string unnamed = Event("unnamed", "TaskCreated", start, true,
                ",\"task_id\":\"step-id\",\"task_subject\":\"\",\"task_status\":\"pending\"");
            Step generated = Reader.Read(unnamed, "", now, boundary).Single().Steps.Single();
            Check(generated.generated && generated.id == "step-id" && generated.status == "unknown",
                "An unnamed legacy step lost its generated identity or gained a confirmed status.");
            string laterStop = Event("observed", "Stop", start.AddSeconds(3), false,
                ",\"stage_version\":1,\"stage_phase\":\"stop_clear\"");
            Check(Reader.Read(prompt + "\n" + laterStop, "", now, boundary).Length == 0,
                "An unambiguous later clear stop did not hide the session.");

            string stop = Event("observed", "Stop", start, false,
                ",\"stage_version\":1,\"stage_phase\":\"stop_clear\"");
            Task[] tied = Reader.Read(prompt + "\n" + stop, "", now, boundary);
            Check(native ? tied.Length == 1 && tied[0].Unconfirmed : tied.Length == 0,
                "The documented same-file simultaneous-event difference changed.");
            Console.WriteLine(native
                ? "Difference: native retains a same-time active/stop conflict as unconfirmed."
                : "Difference: embedded reader hides the same-time active/stop conflict.");

            var stateful = new SessionReader();
            Check(stateful.Read("", "{broken", now, boundary).Length == 0,
                "An invalid legacy-only record created a card.");
            Check(stateful.SourceUncertain == native,
                "The documented legacy-only corruption difference changed.");
            Task afterLoss = stateful.Read(prompt, "", now, boundary).Single();
            Check(afterLoss.Unconfirmed == native,
                "A later card did not reflect the documented loss difference.");
            Console.WriteLine(native
                ? "Difference: native remembers malformed legacy-only input as source loss."
                : "Difference: embedded reader does not inspect malformed legacy-only input without current IDs.");

            string longId = new String('x', 129);
            Task[] oversize = Reader.Read(Event(longId, "UserPromptSubmit", start, true, ""), "", now, boundary);
            Check(native ? oversize.Length == 0 : oversize.Length == 1 && oversize[0].Id.Length == 129,
                "The documented session-ID length difference changed.");
            var longIdState = new SessionReader();
            longIdState.Read(Event(longId, "UserPromptSubmit", start, true, ""), "", now, boundary);
            Check(longIdState.SourceUncertain == native && longIdState.Read(prompt, "", now, boundary).Single().Unconfirmed == native,
                "The session-ID rejection did not preserve source uncertainty.");
            Console.WriteLine(native
                ? "Difference: native rejects a 129-unit session ID."
                : "Difference: embedded reader accepts a 129-unit session ID.");

            // The readers also differ after a known step is cleanly stopped
            // and a later truncated history reports loss before the next turn.
            var stoppedHistory = new SessionReader();
            Task beforeStop = stoppedHistory.Read(prompt + "\n" + oldStep, "", now, boundary).Single();
            Check(beforeStop.Steps.Any(step => step.title == "Synthetic step"), "The initial synthetic step name was not observed.");
            Check(stoppedHistory.Read(prompt + "\n" + oldStep + "\n" + laterStop, "", now, boundary).Length == 0,
                "The synthetic session did not stop before the history gap.");
            string loss = "{\"session_id\":\"\",\"timestamp\":\"" + start.AddSeconds(4).ToString("o", CultureInfo.InvariantCulture) +
                "\",\"event\":\"Unknown\",\"active\":null,\"stage_version\":1,\"stage_phase\":\"source_uncertain\"}";
            string newTurn = Event("observed", "UserPromptSubmit", start.AddSeconds(5), true, "");
            Task afterStopLoss = stoppedHistory.Read(loss + "\n" + newTurn, "", now, boundary).Single();
            bool oldName = afterStopLoss.Steps.Any(step => step.title == "Synthetic step");
            Check(afterStopLoss.Unconfirmed, "A session after history loss was not marked unconfirmed.");
            if (!native)
            {
                Check(oldName, "The embedded reader lost the stopped step name in the synthetic scenario.");
                Console.WriteLine("Observed: embedded reader retains the stopped step name after a later history loss.");
            }
            else if (!oldName)
                Console.WriteLine("OPEN DEFECT: native reader loses the stopped step name after a later history loss.");
            else
                Console.WriteLine("Observed: native reader retains the stopped step name; re-evaluate the documented open defect.");

            string bulk = Event("bulk", "PreToolUse", start, true, ",\"tool_name\":\"Read\"");
            string events = String.Join("\n", Enumerable.Repeat(bulk, 5000));
            Check(Reader.Read(events, events, now, boundary).Length == 1,
                "The 10,000-event synthetic fixture lost its session.");
            Console.WriteLine("Claude reader behavior (" + args[0] + "): " + checks + " synthetic checks passed.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Synthetic Claude reader behavior failed: " + error.Message);
            return 1;
        }
    }
}
