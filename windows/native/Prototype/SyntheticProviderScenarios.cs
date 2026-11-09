using System.Diagnostics;
using System.Globalization;
using AITaskMonitor.ExternalProviders;

namespace AITaskMonitor.Prototype;

// Only the fixed scenarios below can supply events. This is not a provider channel.
internal sealed class SyntheticProviderScenarios
{
    private readonly StateStore store = new();
    private readonly DateTimeOffset start = new(2026, 11, 5, 15, 9, 0, TimeSpan.Zero);
    private int second;
    private int multiStep;
    private long lastHermesTick;
    private readonly string scenario;
    private const string Scope = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string HermesSession = Scope + "_synthetic";

    private const string DeepSeekStart = """{"version":1,"provider":"deepseek","session":"shared","kind":"started","turn":"one"}""";
    private const string DeepSeekPlan = """{"version":1,"provider":"deepseek","session":"shared","kind":"plan","steps":[{"title":"Синхронизировать список задач","status":"done"},{"title":"Восстановить карточки планов","status":"done"},{"title":"Исправить прокрутку этапов","status":"done"},{"title":"Применить системный акцент","status":"done"},{"title":"Проверить скругления и фокус","status":"active"},{"title":"Снять тёмный и светлый экран","status":"pending"},{"title":"Провести финальную проверку","status":"pending"},{"title":"Опубликовать исходники","status":"pending"}]}""";

    public static readonly string[] Names =
    [
        "state-kimi", "state-plan", "state-wait", "state-unknown", "state-gap", "state-old-plan", "state-end",
        "state-multi", "state-hermes", "state-hermes-wait", "state-hermes-unknown"
    ];

    public SyntheticProviderScenarios(string scenario)
    {
        if (!Names.Contains(scenario, StringComparer.Ordinal)) throw new ArgumentOutOfRangeException(nameof(scenario));
        this.scenario = scenario;
        switch (scenario)
        {
            case "state-kimi":
                Apply("""{"version":1,"provider":"kimi","session":"synthetic","kind":"started","turn":"one"}""");
                Apply("""{"version":1,"provider":"kimi","session":"synthetic","kind":"completed","turn":"one"}""");
                break;
            case "state-plan": case "state-wait": case "state-unknown": case "state-gap": case "state-old-plan": case "state-end":
                Apply(DeepSeekStart);
                Apply(DeepSeekPlan);
                if (scenario is "state-wait" or "state-unknown")
                    Apply("""{"version":1,"provider":"deepseek","session":"shared","kind":"waiting"}""");
                if (scenario == "state-unknown")
                    Apply("""{"version":1,"provider":"deepseek","session":"shared","kind":"unknown"}""");
                if (scenario == "state-gap")
                    Apply("""{"version":1,"provider":"deepseek","session":"shared","kind":"gap"}""");
                if (scenario == "state-old-plan")
                {
                    Apply("""{"version":1,"provider":"deepseek","session":"shared","kind":"completed"}""");
                    Apply("""{"version":1,"provider":"deepseek","session":"shared","kind":"started","turn":"two"}""");
                }
                if (scenario == "state-end")
                    Apply("""{"version":1,"provider":"deepseek","session":"shared","kind":"completed"}""");
                break;
            case "state-multi":
                Apply(DeepSeekStart);
                Apply("""{"version":1,"provider":"opencode","session":"shared","kind":"started","turn":"one"}""");
                Apply("""{"version":1,"provider":"deepseek","session":"second","kind":"started","turn":"one"}""");
                break;
            default:
                SetUpHermes(scenario);
                break;
        }
    }

    public TaskState[] Snapshot() => store.Snapshot(start.AddSeconds(second));

    // An in-process test may advance this fixed sequence. No external event or path is accepted.
    internal void AdvanceMulti()
    {
        if (scenario != "state-multi") throw new InvalidOperationException("The fixed multi-session scenario is required.");
        switch (multiStep++)
        {
            case 0: Apply("""{"version":1,"provider":"opencode","session":"shared","kind":"tool_started","call":"c1","action":"read"}"""); break;
            case 1: Apply("""{"version":1,"provider":"opencode","session":"shared","kind":"completed"}"""); break;
            case 2: Apply("""{"version":1,"provider":"opencode","session":"new","kind":"started","turn":"two"}"""); break;
            default: throw new InvalidOperationException("The fixed sequence is finished.");
        }
    }

    private void SetUpHermes(string name)
    {
        store.RetainProviders(["hermes"]);
        store.RetainSessionScopes("hermes", [Scope]);
        long oldEpoch = Next(Clock());
        ApplyHermes("started", oldEpoch, "old");
        store.RetainProviders([]);
        store.RetainProviders(["hermes"]);
        store.RetainSessionScopes("hermes", [Scope]);
        Require(!ApplyHermes("started", oldEpoch, "late", expected: false), "An old observer was accepted.");
        long epoch = Next(Clock());
        ApplyHermes("started", epoch, "previous");
        ApplyHermes("started", epoch, "current");
        Require(!ApplyHermes("idle", oldEpoch, "old", expected: false), "An old observer closed the new generation.");
        Require(!ApplyHermes("gap", oldEpoch, "old", expected: false), "An old observer invalidated the new generation.");
        ApplyHermes("idle", epoch, "previous");
        Require(!ApplyHermes("started", epoch, "previous", expected: false), "A closed turn restarted.");
        Require(Snapshot().Single().Status == "active", "A late terminal changed the current turn.");
        if (name is "state-hermes-wait" or "state-hermes-unknown")
        {
            ApplyHermes("waiting", epoch, "current", "approval_a");
            ApplyHermes("waiting", epoch, "current", "approval_b");
            ApplyHermes("unknown", epoch, "current", "approval_a");
            Require(Snapshot().Single().Status == "waiting", "An open approval was lost.");
            if (name == "state-hermes-unknown") ApplyHermes("unknown", epoch, "current", "approval_b");
        }
    }

    private bool ApplyHermes(string kind, long epoch, string turn, string? request = null, bool expected = true)
    {
        long tick = Next(Math.Max(epoch, lastHermesTick));
        lastHermesTick = tick;
        string requestPart = request is null ? "" : ",\"request\":\"" + request + "\"";
        string json = FormattableString.Invariant($"{{\"version\":1,\"provider\":\"hermes\",\"session\":\"{HermesSession}\",\"kind\":\"{kind}\",\"tick\":{tick},\"epoch\":{epoch},\"turn\":\"{turn}\"{requestPart}}}");
        bool accepted = Apply(json, requireAccepted: expected);
        return accepted;
    }

    private bool Apply(string json, bool requireAccepted = true)
    {
        Event parsed = EventParser.Parse(json) ?? throw new InvalidOperationException("A built-in event was rejected by the parser.");
        bool accepted = store.Apply(parsed, start.AddSeconds(second++));
        if (requireAccepted) Require(accepted, "A built-in event was rejected by the state store.");
        return accepted;
    }

    private static long Clock()
    {
        long ticks = Stopwatch.GetTimestamp(), frequency = Stopwatch.Frequency;
        return (ticks / frequency) * 1_000_000_000L + (long)((ticks % frequency) * (1_000_000_000.0 / frequency));
    }

    private static long Next(long minimum)
    {
        long value;
        int attempts = 0;
        do
        {
            value = Clock();
            if (++attempts > 1_000_000) throw new InvalidOperationException("The monotonic clock did not advance.");
        } while (value <= minimum);
        return value;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

internal static class ProviderPresentation
{
    public static SampleTask Map(TaskState state, string language)
    {
        string name = state.Provider switch
        {
            "kimi" => "Kimi Code", "deepseek" => "DeepSeek Harness", "hermes" => "Hermes Agent",
            "opencode" => "OpenCode", _ => throw new ArgumentOutOfRangeException(nameof(state))
        };
        bool english = language == "en";
        string title = english ? name + " task" : "Задача " + name;
        string activity = state.Status switch
        {
            "unknown" => english ? "Status unconfirmed" : "Статус не подтверждён",
            "waiting" => english ? "Waiting for confirmation" : "Ожидает подтверждения",
            "active" when state.LongRunning => english ? "Running for a long time · agent reachable" : "Долго выполняется · связь с агентом есть",
            "active" => Activity(state.Activity, english),
            _ => throw new ArgumentOutOfRangeException(nameof(state))
        };
        var steps = state.Steps.Select(step => new SampleStep(step.title, step.status)).ToArray();
        int? progress = steps.Length == 0 ? null : (int)Math.Round(100.0 * steps.Count(step => step.Status == "done") / steps.Length, MidpointRounding.AwayFromZero);
        return new SampleTask(state.Provider + ":" + state.Session, state.Provider, name, title, activity,
            state.Status, progress, steps, state.PlanConfirmed,
            state.Updated == DateTimeOffset.MinValue ? "" : state.Updated.LocalDateTime.ToString("HH:mm", CultureInfo.InvariantCulture), state.Updated,
            string.IsNullOrEmpty(state.StartKey) ? "" : state.Provider + ":" + state.Session + ":" + state.StartKey, state.Started);
    }

    private static string Activity(string action, bool english) => action switch
    {
        "command" => english ? "Running a command" : "Выполняет команду",
        "read" => english ? "Reading a file" : "Читает файл",
        "edit" => english ? "Editing a file" : "Изменяет файл",
        "search" => english ? "Searching" : "Выполняет поиск",
        "other" => english ? "Running an action" : "Выполняет действие",
        _ => english ? "Working" : "Выполняется"
    };
}

internal sealed record SampleStep(string Title, string Status);
internal sealed record SampleTask(string Id, string Provider, string ProviderName, string Title, string Activity,
    string Status, int? Progress, SampleStep[] Steps, bool PlanConfirmed, string UpdatedText,
    DateTimeOffset Updated, string StartKey, DateTimeOffset Started, bool RetainedPlanIncomplete = false)
{
    public bool Active => Status == "active";
}
