using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace AITaskMonitor.ExternalProviders
{
    public sealed class Step
    {
        public string title { get; internal set; }
        public string status { get; internal set; }
    }

    public sealed class Event
    {
        public string Provider { get; internal set; }
        public string Session { get; internal set; }
        public string Kind { get; internal set; }
        public string Turn { get; internal set; }
        public string Call { get; internal set; }
        public string Action { get; internal set; }
        public Step[] Steps { get; internal set; }
        // Local receipt time, never accepted from the sender's JSON.
        public DateTimeOffset ObservedAt { get; internal set; }
    }

    public sealed class TaskState
    {
        public string Provider { get; internal set; }
        public string Session { get; internal set; }
        public string Status { get; internal set; }
        public string StartKey { get; internal set; }
        public DateTimeOffset Started { get; internal set; }
        public DateTimeOffset Updated { get; internal set; }
        public Step[] Steps { get; internal set; }
        public bool PlanConfirmed { get; internal set; }
        public string Activity { get; internal set; }
        public bool LongRunning { get; internal set; }
        internal string Turn;
        internal DateTimeOffset? LastHeartbeat;
        internal readonly List<KeyValuePair<string, string>> Calls = new List<KeyValuePair<string, string>>();
    }

    // This parser accepts only the sanitized observer protocol, not agent payloads.
    public static class EventParser
    {
        private static readonly Regex SafeId = new Regex("^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant);
        private static readonly HashSet<string> Providers = new HashSet<string>(new[] { "kimi", "deepseek", "hermes", "opencode" }, StringComparer.Ordinal);
        private static readonly HashSet<string> Kinds = new HashSet<string>(new[] { "started", "active", "waiting", "unknown", "idle", "completed", "failed", "interrupted", "plan", "gap", "tool_started", "tool_finished", "heartbeat" }, StringComparer.Ordinal);
        private static readonly HashSet<string> Fields = new HashSet<string>(new[] { "version", "provider", "session", "kind", "turn", "steps", "call", "action" }, StringComparer.Ordinal);

        public static Event Parse(string json)
        {
            if (String.IsNullOrEmpty(json) || json.Length > 65536) return null;
            IDictionary<string, object> data;
            try
            {
                data = new JavaScriptSerializer { MaxJsonLength = 65536, RecursionLimit = 12 }.DeserializeObject(json) as IDictionary<string, object>;
            }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
            if (data == null || data.Keys.Any(key => !Fields.Contains(key))) return null;
            object version;
            if (!data.TryGetValue("version", out version) || !(version is int) || (int)version != 1) return null;
            string provider = StringField(data, "provider"), session = StringField(data, "session"), kind = StringField(data, "kind");
            if (!Providers.Contains(provider) || !SafeId.IsMatch(session) || !Kinds.Contains(kind)) return null;
            string turn = StringField(data, "turn");
            if (data.ContainsKey("turn") && !SafeId.IsMatch(turn)) return null;
            if (kind == "heartbeat" && data.Count != 4) return null;
            if (kind != "plan" && data.ContainsKey("steps")) return null;
            bool toolEvent = kind == "tool_started" || kind == "tool_finished";
            string call = StringField(data, "call"), action = StringField(data, "action");
            if (toolEvent && !SafeId.IsMatch(call)) return null;
            if (!toolEvent && (data.ContainsKey("call") || data.ContainsKey("action"))) return null;
            if (kind == "tool_started" && !new[] { "command", "read", "edit", "search", "other" }.Contains(action)) return null;
            if (kind == "tool_finished" && data.ContainsKey("action")) return null;
            Step[] steps = null;
            if (kind == "plan")
            {
                object value;
                if (!data.TryGetValue("steps", out value) || !(value is IList)) return null;
                IList list = (IList)value;
                if (list.Count > 100) return null;
                var parsed = new List<Step>();
                foreach (object entry in list)
                {
                    var item = entry as IDictionary<string, object>;
                    if (item == null || item.Count != 2 || !item.ContainsKey("title") || !item.ContainsKey("status")) return null;
                    string title = StringField(item, "title"), status = StringField(item, "status");
                    if (String.IsNullOrWhiteSpace(title) || title.Length > 512 ||
                        (status != "pending" && status != "active" && status != "done")) return null;
                    parsed.Add(new Step { title = title, status = status });
                }
                steps = parsed.ToArray();
            }
            return new Event { Provider = provider, Session = session, Kind = kind, Turn = turn, Call = call, Action = action, Steps = steps };
        }

        private static string StringField(IDictionary<string, object> data, string key)
        {
            object value;
            return data.TryGetValue(key, out value) && value is string ? (string)value : "";
        }
    }

    // State is bounded and exists only while the monitor process is running.
    public sealed class StateStore
    {
        private readonly Dictionary<string, TaskState> states = new Dictionary<string, TaskState>(StringComparer.Ordinal);
        private long sequence;
        private const int MaximumSessions = 256;
        private static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(30);
        private static readonly TimeSpan HeartbeatLifetime = TimeSpan.FromMinutes(3);

        public bool Apply(Event input, DateTimeOffset now)
        {
            if (input == null) return false;
            if (input.Kind == "gap") { MarkProviderGap(input.Provider); return true; }
            string key = input.Provider + ":" + input.Session;
            TaskState state;
            // A heartbeat is only evidence about a previously observed session.
            // It cannot create a task after the monitor starts or revive one after a gap.
            if (input.Kind == "heartbeat")
            {
                if (states.TryGetValue(key, out state))
                {
                    Expire(state, now);
                    if (state.Status == "active" || state.Status == "waiting") state.LastHeartbeat = now;
                }
                return true;
            }
            if (!states.TryGetValue(key, out state))
            {
                if (states.Count >= MaximumSessions)
                {
                    var oldest = states.Where(pair => pair.Value.Status != "active" && pair.Value.Status != "waiting")
                        .OrderBy(pair => pair.Value.Updated).FirstOrDefault();
                    if (oldest.Key == null) { MarkGap(); return false; }
                    states.Remove(oldest.Key);
                }
                state = new TaskState { Provider = input.Provider, Session = input.Session, Status = "unknown",
                    Steps = new Step[0], StartKey = "", Turn = "", PlanConfirmed = true, Updated = now };
                states.Add(key, state);
            }
            Expire(state, now);
            if (input.Kind == "started")
            {
                bool newTurn = state.Status != "active" || String.IsNullOrEmpty(input.Turn) || input.Turn != state.Turn;
                if (newTurn) Start(state, now, input.Turn);
                state.Status = "active";
            }
            else if (input.Kind == "active")
            {
                if (state.Status == "idle" || state.Status == "completed" || state.Status == "failed" ||
                    state.Status == "interrupted" || String.IsNullOrEmpty(state.StartKey)) Start(state, now, "");
                state.Status = "active";
            }
            else if (input.Kind == "plan")
            {
                state.Steps = CopySteps(input.Steps);
                state.PlanConfirmed = true;
            }
            else if (input.Kind == "tool_started")
            {
                if (state.Status == "idle" || state.Status == "completed" || state.Status == "failed" ||
                    state.Status == "interrupted" || String.IsNullOrEmpty(state.StartKey)) Start(state, now, "");
                if (state.Status != "waiting") state.Status = "active";
                state.Calls.RemoveAll(item => item.Key == input.Call);
                if (state.Calls.Count >= 32) state.Calls.Clear();
                state.Calls.Add(new KeyValuePair<string, string>(input.Call, input.Action));
            }
            else if (input.Kind == "tool_finished") state.Calls.RemoveAll(item => item.Key == input.Call);
            else if (input.Kind == "waiting")
            {
                if (state.Status == "idle" || state.Status == "completed" || state.Status == "failed" ||
                    state.Status == "interrupted" || String.IsNullOrEmpty(state.StartKey)) Start(state, now, "");
                state.Status = "waiting";
                state.Calls.Clear();
            }
            else
            {
                state.Status = input.Kind;
                if (state.Status != "active") state.Calls.Clear();
                if (state.Status != "waiting") state.LastHeartbeat = null;
            }
            state.Updated = now;
            return true;
        }

        // An overflow or broken transport invalidates activity claims, never invents completion.
        public void MarkGap()
        {
            MarkProviderGap(null);
        }

        private void MarkProviderGap(string provider)
        {
            foreach (TaskState state in states.Values)
            {
                if (provider != null && state.Provider != provider) continue;
                if (state.Steps.Length > 0) state.PlanConfirmed = false;
                if (state.Status == "active" || state.Status == "waiting") { state.Status = "unknown"; state.Calls.Clear(); }
                state.LastHeartbeat = null;
            }
        }

        // Disconnecting a source removes its in-memory tasks instead of
        // allowing them to reappear if that source is later re-enabled.
        public void RetainProviders(string[] providers)
        {
            var allowed = new HashSet<string>(providers ?? new string[0], StringComparer.Ordinal);
            foreach (string key in states.Where(pair => !allowed.Contains(pair.Value.Provider)).Select(pair => pair.Key).ToArray())
                states.Remove(key);
        }

        public TaskState[] Snapshot(DateTimeOffset now)
        {
            return states.Values.Where(state => state.Status == "active" || state.Status == "waiting" || state.Status == "unknown")
                .Select(state => new TaskState {
                    Provider = state.Provider, Session = state.Session,
                    Status = IsStale(state, now) ? "unknown" : state.Status,
                    StartKey = state.StartKey, Started = state.Started, Updated = state.Updated,
                    Steps = CopySteps(state.Steps), PlanConfirmed = state.PlanConfirmed && (state.Steps.Length == 0 ||
                        (now - state.Updated < StaleAfter || ((state.Status == "active" || state.Status == "waiting") && HasFreshHeartbeat(state, now)))),
                    Activity = state.Status == "active" && !IsStale(state, now) && state.Calls.Count > 0 ? state.Calls[state.Calls.Count - 1].Value : "",
                    LongRunning = state.Status == "active" && now - state.Updated >= StaleAfter && HasFreshHeartbeat(state, now)
                }).ToArray();
        }

        private static bool HasFreshHeartbeat(TaskState state, DateTimeOffset now)
        {
            if (!state.LastHeartbeat.HasValue) return false;
            TimeSpan age = now - state.LastHeartbeat.Value;
            return age >= TimeSpan.Zero && age <= HeartbeatLifetime;
        }

        private static bool IsStale(TaskState state, DateTimeOffset now)
        {
            return (state.Status == "active" || state.Status == "waiting") &&
                now - state.Updated >= StaleAfter && !HasFreshHeartbeat(state, now);
        }

        private static void Expire(TaskState state, DateTimeOffset now)
        {
            if (!IsStale(state, now)) return;
            state.Status = "unknown";
            state.Calls.Clear();
            state.LastHeartbeat = null;
            if (state.Steps.Length > 0) state.PlanConfirmed = false;
        }

        private void Start(TaskState state, DateTimeOffset now, string turn)
        {
            state.Started = now;
            state.StartKey = (++sequence).ToString(System.Globalization.CultureInfo.InvariantCulture);
            state.Turn = turn ?? "";
            state.Calls.Clear();
            state.LastHeartbeat = null;
            if (state.Steps.Length > 0) state.PlanConfirmed = false;
        }

        private static Step[] CopySteps(Step[] steps)
        {
            return steps.Select(step => new Step { title = step.title, status = step.status }).ToArray();
        }
    }
}
