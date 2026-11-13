using System.Reflection;
using System.Text.Json;
using AITaskMonitor.ExternalProviders;

var now = new DateTimeOffset(2026, 11, 4, 10, 0, 0, TimeSpan.Zero);
int checks = 0;
void Check(bool value, string message)
{
    checks++;
    if (!value) throw new InvalidOperationException(message);
}
Event Frame(string provider, string session, string kind) =>
    EventParser.Parse(JsonSerializer.Serialize(new { version = 1, provider, session, kind }))
    ?? throw new InvalidOperationException("A synthetic frame was rejected.");
Event Plan(string provider, string session, string title) =>
    EventParser.Parse(JsonSerializer.Serialize(new
    {
        version = 1, provider, session, kind = "plan", steps = new[] { new { title, status = "active" } }
    })) ?? throw new InvalidOperationException("A synthetic plan was rejected.");
void Apply(StateStore store, Event frame) => Check(store.Apply(frame, now), "A synthetic frame was not applied.");
TaskState Task(StateStore store, string provider, string session) => store.Snapshot(now)
    .Single(item => item.Provider == provider && item.Session == session);
void Active(StateStore store, string provider, string session) =>
    Check(Task(store, provider, session).Status == "active", "An independent task lost its confirmed status.");
void Unknown(StateStore store, string provider, string session)
{
    TaskState state = Task(store, provider, session);
    Check(state.Status == "unknown" && !state.PlanConfirmed && state.Steps.Length == 0 &&
        state.Activity == "" && !state.LongRunning, "An uncertain task exposed a confirmed status or plan.");
}
void Hidden(StateStore store, string provider, string session) =>
    Check(store.Snapshot(now).All(item => item.Provider != provider || item.Session != session),
        "A terminal frame created or removed the wrong task.");

string scopeA = new('a', 32), scopeB = new('b', 32), reconnectedScope = new('c', 32);
string sessionA = scopeA + "_one", sessionB = scopeB + "_two", sessionNew = reconnectedScope + "_new";
var beforeBaseline = new StateStore();
beforeBaseline.RetainProviders(["deepseek", "opencode"]);
Apply(beforeBaseline, Frame("deepseek", sessionA, "active"));
Apply(beforeBaseline, Frame("opencode", "unrelated", "active"));
Unknown(beforeBaseline, "deepseek", sessionA); Active(beforeBaseline, "opencode", "unrelated");
beforeBaseline.RetainSessionScopes("deepseek", [scopeA, scopeB]);
Apply(beforeBaseline, Frame("deepseek", sessionA, "active"));
Apply(beforeBaseline, Frame("deepseek", sessionB, "active"));
Unknown(beforeBaseline, "deepseek", sessionA); Active(beforeBaseline, "deepseek", sessionB);
Active(beforeBaseline, "opencode", "unrelated");

var beforeBaselineOverflow = new StateStore();
for (int i = 0; i < 257; i++)
    Apply(beforeBaselineOverflow, Frame("deepseek", i.ToString("x32") + "_terminal", "completed"));
beforeBaselineOverflow.RetainSessionScopes("deepseek", [scopeB]);
Apply(beforeBaselineOverflow, Frame("deepseek", sessionB, "active"));
Apply(beforeBaselineOverflow, Frame("opencode", "other", "active"));
Unknown(beforeBaselineOverflow, "deepseek", sessionB); Active(beforeBaselineOverflow, "opencode", "other");

var store = new StateStore();
store.RetainProviders(["opencode", "deepseek"]);
store.RetainSessionScopes("deepseek", [scopeA, scopeB]);
Apply(store, Frame("opencode", "open", "active"));
Apply(store, Frame("deepseek", sessionA, "active"));
Apply(store, Frame("deepseek", sessionB, "active"));
Apply(store, Plan("deepseek", sessionB, "Healthy plan"));
Active(store, "opencode", "open"); Active(store, "deepseek", sessionA); Active(store, "deepseek", sessionB);

// Model an already-drained v1 frame, then an observed reconnect, then Apply.
Event detached = Frame("opencode", "open", "active");
store.RetainProviders(["deepseek"]);
store.RetainProviders(["deepseek", "opencode"]);
Apply(store, detached);
Apply(store, Plan("opencode", "open", "Unverified plan"));
Unknown(store, "opencode", "open"); Active(store, "deepseek", sessionA); Active(store, "deepseek", sessionB);
Apply(store, Frame("opencode", "open", "completed"));
Unknown(store, "opencode", "open");
Apply(store, Frame("opencode", "never_seen", "completed"));
Hidden(store, "opencode", "never_seen");

store.RetainSessionScopes("deepseek", [scopeB]);
store.RetainSessionScopes("deepseek", [scopeB, reconnectedScope]);
Apply(store, Frame("deepseek", sessionNew, "active"));
Apply(store, Plan("deepseek", sessionNew, "Unverified profile plan"));
Unknown(store, "deepseek", sessionNew); Active(store, "deepseek", sessionB);
Check(Task(store, "deepseek", sessionB).PlanConfirmed && Task(store, "deepseek", sessionB).Steps.Length == 1,
    "A neighboring profile lost its plan.");
Apply(store, Frame("deepseek", sessionNew, "completed"));
Unknown(store, "deepseek", sessionNew); Active(store, "deepseek", sessionB);
store.RetainSessionScopes("deepseek", [scopeA, scopeB, reconnectedScope]);
Apply(store, Frame("deepseek", sessionA, "active"));
Unknown(store, "deepseek", sessionA); Active(store, "deepseek", sessionB);

var scopeLoss = new StateStore();
scopeLoss.RetainProviders(["deepseek", "opencode"]);
scopeLoss.RetainSessionScopes("deepseek", [scopeA, scopeB]);
Apply(scopeLoss, Frame("deepseek", sessionA, "active"));
Apply(scopeLoss, Frame("deepseek", sessionB, "active"));
Apply(scopeLoss, Frame("opencode", "other", "active"));
Apply(scopeLoss, Frame("deepseek", sessionA, "gap"));
Apply(scopeLoss, Frame("deepseek", sessionA, "active"));
Unknown(scopeLoss, "deepseek", sessionA); Active(scopeLoss, "deepseek", sessionB); Active(scopeLoss, "opencode", "other");
scopeLoss.MarkSessionScopesGap("deepseek", [scopeB]);
Apply(scopeLoss, Frame("deepseek", sessionB, "active"));
Unknown(scopeLoss, "deepseek", sessionB); Active(scopeLoss, "opencode", "other");

var bounded = new StateStore();
string[] manyScopes = Enumerable.Range(0, 300).Select(i => i.ToString("x32")).ToArray();
bounded.RetainSessionScopes("deepseek", manyScopes);
FieldInfo trustedField = typeof(StateStore).GetField("trustedDeepSeekScopes", BindingFlags.Instance | BindingFlags.NonPublic)
    ?? throw new InvalidOperationException("Synthetic scope accounting is unavailable.");
var trusted = (HashSet<string>)(trustedField.GetValue(bounded) ?? throw new InvalidOperationException());
Check(trusted.Count <= 256, "Trusted scope accounting grew past its bound.");

var capacity = new StateStore();
capacity.RetainProviders(["deepseek", "opencode"]);
capacity.RetainSessionScopes("deepseek", [scopeB]);
for (int i = 0; i < 256; i++) Apply(capacity, Frame("deepseek", scopeB + "_s" + i, "active"));
capacity.RetainProviders(["deepseek"]);
capacity.RetainProviders(["deepseek", "opencode"]);
Check(!capacity.Apply(Frame("opencode", "overflow", "active"), now), "Uncertain capacity loss was not reported by Apply.");
Check(capacity.Snapshot(now).Length == 256 && capacity.Snapshot(now).All(item => item.Status == "active"),
    "Capacity loss altered unrelated confirmed tasks.");

// Known counterexample: the inherited eviction policy can silently remove an
// earlier uncertain card when a confirmed neighboring source adds a task.
// This documents a blocker; it is not an acceptance test for product use.
var silentEviction = new StateStore();
silentEviction.RetainProviders(["deepseek", "opencode"]);
silentEviction.RetainSessionScopes("deepseek", [scopeB]);
Apply(silentEviction, Frame("opencode", "unconfirmed", "active"));
silentEviction.MarkProviderGap("opencode");
Unknown(silentEviction, "opencode", "unconfirmed");
for (int i = 0; i < 255; i++) Apply(silentEviction, Frame("deepseek", scopeB + "_e" + i, "active"));
Check(silentEviction.Snapshot(now).Length == 256, "The eviction fixture did not reach capacity.");
Check(silentEviction.Apply(Frame("deepseek", scopeB + "_extra", "active"), now),
    "The documented successful admission counterexample changed.");
Hidden(silentEviction, "opencode", "unconfirmed");
Check(silentEviction.Snapshot(now).Length == 256, "The capacity counterexample has an unexpected size.");

Console.WriteLine($"Provider confidence: {checks} in-memory checks passed, including a known silent-eviction counterexample.");
