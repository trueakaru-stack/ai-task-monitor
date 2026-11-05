using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.RegularExpressions;
#if NET10_0_OR_GREATER
using JavaScriptSerializer = AITaskMonitor.ExternalProviders.SafeJsonDeserializer;
#else
using System.Web.Script.Serialization;
#endif

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
        public long Tick { get; internal set; }
        public long Epoch { get; internal set; }
        public string Request { get; internal set; }
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
        internal long HermesTick;
        internal long HermesEpoch;
        internal long HermesTerminalEpoch;
        internal long HermesAmbiguousEpoch;
        internal long HermesResolvedTick;
        internal string HermesOrdinaryStatus;
        internal bool HermesUncertain;
        internal readonly Dictionary<string, HermesRequest> HermesRequests = new Dictionary<string, HermesRequest>(StringComparer.Ordinal);
        internal readonly Dictionary<string, long> HermesTerminalTurns = new Dictionary<string, long>(StringComparer.Ordinal);
        internal readonly List<KeyValuePair<string, string>> Calls = new List<KeyValuePair<string, string>>();
    }

    internal sealed class HermesRequest
    {
        internal long Tick;
        internal bool Open;
    }

    // This parser accepts only the sanitized observer protocol, not agent payloads.
    public static class EventParser
    {
        private static readonly Regex SafeId = new Regex("^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant);
        private static readonly HashSet<string> Providers = new HashSet<string>(new[] { "kimi", "deepseek", "hermes", "opencode" }, StringComparer.Ordinal);
        private static readonly HashSet<string> Kinds = new HashSet<string>(new[] { "started", "active", "waiting", "unknown", "idle", "completed", "failed", "interrupted", "plan", "gap", "tool_started", "tool_finished", "heartbeat" }, StringComparer.Ordinal);
        private static readonly HashSet<string> Fields = new HashSet<string>(new[] { "version", "provider", "session", "kind", "turn", "steps", "call", "action", "tick", "epoch", "request" }, StringComparer.Ordinal);

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
            long tick = 0;
            object tickValue;
            if (data.TryGetValue("tick", out tickValue))
            {
                if (provider != "hermes" || (!(tickValue is int) && !(tickValue is long))) return null;
                tick = Convert.ToInt64(tickValue);
                if (tick <= 0) return null;
            }
            long epoch = 0;
            object epochValue;
            if (data.TryGetValue("epoch", out epochValue))
            {
                if (provider != "hermes" || (!(epochValue is int) && !(epochValue is long))) return null;
                epoch = Convert.ToInt64(epochValue);
                if (epoch <= 0 || epoch > tick) return null;
            }
            string request = StringField(data, "request");
            if (data.ContainsKey("request") && (provider != "hermes" || tick == 0 ||
                (kind != "waiting" && kind != "unknown") || !SafeId.IsMatch(request))) return null;
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
            return new Event { Provider = provider, Session = session, Kind = kind, Turn = turn, Call = call, Action = action, Steps = steps, Tick = tick, Epoch = epoch, Request = request };
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
        private long hermesBarrier;
        private bool hermesAllowed;
        private readonly Dictionary<string, long> hermesScopeBarriers = new Dictionary<string, long>(StringComparer.Ordinal);
        private HashSet<string> hermesScopes = new HashSet<string>(StringComparer.Ordinal);
        private HashSet<string> hermesUncertainScopes = new HashSet<string>(StringComparer.Ordinal);
        private const int MaximumSessions = 256;
        private static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(30);
        private static readonly TimeSpan HeartbeatLifetime = TimeSpan.FromMinutes(3);

        public bool Apply(Event input, DateTimeOffset now)
        {
            if (input == null) return false;
            if (input.Provider == "hermes" && (input.Tick == 0 || input.Epoch == 0)) return false;
            if (input.Provider == "hermes" && (input.Tick <= hermesBarrier || input.Epoch <= hermesBarrier)) return false;
            string scope = SessionScope(input.Session);
            long scopeBarrier;
            if (input.Provider == "hermes" && hermesScopeBarriers.TryGetValue(scope, out scopeBarrier) &&
                (input.Tick <= scopeBarrier || input.Epoch <= scopeBarrier)) return false;
            if (input.Provider == "hermes" && input.Tick > 0 && input.Tick > MonotonicNanoseconds() + 2000000000L)
            { MarkProviderGap("hermes"); return false; }
            if (input.Kind == "gap")
            {
                if (input.Provider == "hermes" && scope.Length == 32 && scope.All(c => (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9')))
                { MarkHermesScopeGap(scope); return true; }
                MarkProviderGap(input.Provider); return true;
            }
            string key = input.Provider + ":" + input.Session;
            TaskState state;
            bool created = false;
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
                    if (oldest.Value.Provider == "hermes") MarkProviderGap("hermes");
                    states.Remove(oldest.Key);
                }
                state = new TaskState { Provider = input.Provider, Session = input.Session, Status = "unknown",
                    Steps = new Step[0], StartKey = "", Turn = "", PlanConfirmed = true, Updated = now,
                    HermesUncertain = input.Provider == "hermes" && hermesBarrier > 0 };
                states.Add(key, state);
                created = true;
            }
            Expire(state, now);
            if (input.Provider == "hermes") return ApplyHermes(state, input, now, created);
            if (input.Provider == "kimi")
            {
                // Kimi's passive hooks can arrive late or be lost, and do not
                // reliably report a successful turn end. Never claim a state.
                if (input.Kind == "started" && (String.IsNullOrEmpty(state.StartKey) || input.Turn != state.Turn))
                    Start(state, now, input.Turn);
                state.Status = "unknown";
                state.Steps = new Step[0];
                state.PlanConfirmed = false;
                state.Calls.Clear();
                state.LastHeartbeat = null;
                state.Updated = now;
                return true;
            }
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

        public void MarkProviderGap(string provider)
        {
            if (provider == null || provider == "hermes") hermesBarrier = Math.Max(hermesBarrier, MonotonicNanoseconds());
            foreach (TaskState state in states.Values)
            {
                if (provider != null && state.Provider != provider) continue;
                if (state.Provider == "hermes") { state.HermesUncertain = true; state.HermesRequests.Clear(); }
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
            bool nowAllowed = allowed.Contains("hermes");
            if (nowAllowed != hermesAllowed)
            {
                hermesBarrier = Math.Max(hermesBarrier, MonotonicNanoseconds());
            }
            if (!nowAllowed && hermesAllowed)
            {
                hermesScopeBarriers.Clear();
                hermesScopes.Clear();
                hermesUncertainScopes.Clear();
            }
            hermesAllowed = nowAllowed;
            foreach (string key in states.Where(pair => !allowed.Contains(pair.Value.Provider)).Select(pair => pair.Key).ToArray())
                states.Remove(key);
        }

        public void RetainSessionScopes(string provider, string[] scopes)
        {
            var allowed = new HashSet<string>(scopes ?? new string[0], StringComparer.Ordinal);
            if (provider == "hermes")
            {
                UpdateHermesScopeBarriers(hermesScopes.Except(allowed).Concat(allowed.Except(hermesScopes)));
                hermesScopes = allowed;
            }
            foreach (string key in states.Where(pair => pair.Value.Provider == provider && !allowed.Contains(SessionScope(pair.Value.Session)))
                .Select(pair => pair.Key).ToArray()) states.Remove(key);
        }

        public void MarkSessionScopesGap(string provider, string[] scopes)
        {
            var uncertain = new HashSet<string>(scopes ?? new string[0], StringComparer.Ordinal);
            if (provider == "hermes")
            {
                UpdateHermesScopeBarriers(hermesUncertainScopes.Except(uncertain).Concat(uncertain.Except(hermesUncertainScopes)));
                hermesUncertainScopes = uncertain;
            }
            foreach (TaskState state in states.Values)
            {
                if (state.Provider != provider || !uncertain.Contains(SessionScope(state.Session))) continue;
                if (provider == "hermes") { state.HermesUncertain = true; state.HermesRequests.Clear(); }
                if (state.Steps.Length > 0) state.PlanConfirmed = false;
                if (state.Status == "active" || state.Status == "waiting") { state.Status = "unknown"; state.Calls.Clear(); }
                state.LastHeartbeat = null;
            }
        }

        private void MarkHermesScopeGap(string scope)
        {
            UpdateHermesScopeBarriers(new[] { scope });
            foreach (TaskState state in states.Values)
            {
                if (state.Provider != "hermes" || SessionScope(state.Session) != scope) continue;
                state.HermesUncertain = true; state.HermesRequests.Clear();
                if (state.Steps.Length > 0) state.PlanConfirmed = false;
                if (state.Status == "active" || state.Status == "waiting") { state.Status = "unknown"; state.Calls.Clear(); }
                state.LastHeartbeat = null;
            }
        }

        private static string SessionScope(string session)
        {
            return session != null && session.Length > 32 && session[32] == '_' ? session.Substring(0, 32) : "";
        }

        private static long MonotonicNanoseconds()
        {
            long ticks = Stopwatch.GetTimestamp(), frequency = Stopwatch.Frequency;
            // The same OS monotonic clock used by Python's monotonic_ns().
            return (ticks / frequency) * 1000000000L + (long)((ticks % frequency) * (1000000000.0 / frequency));
        }

        private void UpdateHermesScopeBarriers(IEnumerable<string> changedScopes)
        {
            long barrier = MonotonicNanoseconds();
            foreach (string scope in changedScopes)
            {
                if (hermesScopeBarriers.Count >= MaximumSessions && !hermesScopeBarriers.ContainsKey(scope))
                {
                    // A global barrier safely bounds accumulated removed-profile history.
                    MarkProviderGap("hermes");
                    hermesScopeBarriers.Clear();
                }
                hermesScopeBarriers[scope] = barrier;
            }
        }

        private bool ApplyHermes(TaskState state, Event input, DateTimeOffset now, bool created)
        {
            if (state.HermesEpoch > input.Epoch) return false;
            bool terminal = input.Kind == "idle" || input.Kind == "completed" || input.Kind == "failed" || input.Kind == "interrupted";
            if (terminal)
            {
                if (String.IsNullOrEmpty(input.Turn))
                {
                    if (state.HermesTerminalEpoch == input.Epoch &&
                        (state.Status == "idle" || state.Status == "completed" || state.Status == "failed" || state.Status == "interrupted"))
                        return false;
                    state.HermesAmbiguousEpoch = Math.Max(state.HermesAmbiguousEpoch, input.Epoch);
                    state.HermesEpoch = Math.Max(state.HermesEpoch, input.Epoch);
                    state.HermesUncertain = true;
                    state.Status = "unknown";
                    state.Updated = now;
                    return true;
                }
                long closedEpoch;
                if (state.HermesTerminalTurns.TryGetValue(input.Turn, out closedEpoch) && closedEpoch >= input.Epoch) return false;
                if (!state.HermesTerminalTurns.ContainsKey(input.Turn) && state.HermesTerminalTurns.Count >= 64)
                {
                    state.HermesAmbiguousEpoch = Math.Max(state.HermesAmbiguousEpoch, input.Epoch);
                    state.HermesUncertain = true;
                    state.Status = "unknown";
                    state.Updated = now;
                    return true;
                }
                state.HermesTerminalTurns[input.Turn] = input.Epoch;
                state.HermesEpoch = Math.Max(state.HermesEpoch, input.Epoch);
                if (!String.IsNullOrEmpty(state.Turn) && state.Turn != input.Turn) return true;
                if (String.IsNullOrEmpty(state.Turn)) state.Turn = input.Turn;
                state.HermesTick = Math.Max(state.HermesTick, input.Tick);
                bool pending = state.HermesRequests.Values.Any(item => item.Open);
                if (created && !pending)
                { state.Status = input.Kind; state.HermesTerminalEpoch = input.Epoch; }
                else if (pending || state.HermesUncertain || state.HermesAmbiguousEpoch >= input.Epoch)
                { state.HermesUncertain = true; state.Status = "unknown"; }
                else { state.Status = input.Kind; state.HermesTerminalEpoch = input.Epoch; }
                state.Updated = now;
                return true;
            }
            long terminalEpoch;
            if (!String.IsNullOrEmpty(input.Turn) && state.HermesTerminalTurns.TryGetValue(input.Turn, out terminalEpoch) &&
                input.Epoch <= terminalEpoch) return false;
            if (state.HermesAmbiguousEpoch >= input.Epoch || (String.IsNullOrEmpty(input.Turn) &&
                state.HermesTerminalTurns.Values.Any(epoch => epoch >= input.Epoch)))
            {
                if (state.Status == "idle" || state.Status == "completed" || state.Status == "failed" || state.Status == "interrupted") return false;
                state.HermesUncertain = true;
                state.Status = "unknown";
                state.Updated = now;
                return true;
            }
            if (!String.IsNullOrEmpty(input.Request))
            {
                if (!String.IsNullOrEmpty(input.Turn) && !String.IsNullOrEmpty(state.Turn) && input.Turn != state.Turn &&
                    (state.Status == "active" || state.Status == "waiting")) state.HermesUncertain = true;
                if (input.Kind == "waiting" && input.Epoch > state.HermesEpoch && state.HermesUncertain &&
                    !state.HermesRequests.Values.Any(item => item.Open))
                { state.HermesUncertain = false; state.HermesRequests.Clear(); }
                HermesRequest request;
                if (!state.HermesRequests.TryGetValue(input.Request, out request))
                {
                    if (state.HermesRequests.Count >= 64)
                    {
                        state.HermesUncertain = true;
                        state.Status = "unknown";
                        state.Updated = now;
                        return true;
                    }
                    request = new HermesRequest();
                    state.HermesRequests.Add(input.Request, request);
                }
                if (input.Tick <= request.Tick) return false;
                state.HermesEpoch = Math.Max(state.HermesEpoch, input.Epoch);
                request.Tick = input.Tick;
                request.Open = input.Kind == "waiting";
                if (!request.Open) state.HermesResolvedTick = Math.Max(state.HermesResolvedTick, input.Tick);
                if (request.Open && String.IsNullOrEmpty(state.StartKey)) Start(state, now, "");
                bool pending = state.HermesRequests.Values.Any(item => item.Open);
                if (state.HermesUncertain) state.Status = "unknown";
                else if (pending) state.Status = "waiting";
                else if (state.HermesTick > state.HermesResolvedTick && state.HermesOrdinaryStatus == "active") state.Status = "active";
                else state.Status = "unknown";
                state.Updated = now;
                return true;
            }
            if (input.Tick <= state.HermesTick) return false;
            if (input.Kind == "plan")
            {
                state.HermesTick = input.Tick;
                state.Steps = CopySteps(input.Steps);
                state.PlanConfirmed = !state.HermesUncertain;
                state.Updated = now;
                return true;
            }
            if (input.Kind == "active" && !String.IsNullOrEmpty(input.Turn) && !String.IsNullOrEmpty(state.Turn) &&
                input.Turn != state.Turn && (state.Status == "active" || state.Status == "waiting"))
            { state.HermesUncertain = true; state.Status = "unknown"; state.Updated = now; return true; }
            bool newTurn = (input.Kind == "started" || input.Kind == "active") &&
                !String.IsNullOrEmpty(input.Turn) && input.Turn != state.Turn;
            bool newObserver = input.Kind == "started" && input.Epoch > state.HermesEpoch;
            bool waiting = state.HermesRequests.Values.Any(item => item.Open);
            if (((newTurn && input.Kind == "started") || newObserver) && state.HermesUncertain && !waiting && input.Epoch > state.HermesAmbiguousEpoch)
            { state.HermesUncertain = false; state.HermesRequests.Clear(); }
            state.HermesEpoch = Math.Max(state.HermesEpoch, input.Epoch);
            state.HermesTick = input.Tick;
            if (newTurn || String.IsNullOrEmpty(state.StartKey)) Start(state, now, input.Turn);
            string status = input.Kind == "started" ? "active" : input.Kind;
            state.HermesOrdinaryStatus = status;
            if (state.HermesUncertain) state.Status = "unknown";
            else if (waiting && (status == "unknown" || status == "idle" || status == "failed" || status == "interrupted"))
            { state.HermesUncertain = true; state.Status = "unknown"; }
            else if (!waiting && status == "active" && state.HermesResolvedTick >= input.Tick) state.Status = "unknown";
            else state.Status = waiting ? "waiting" : status;
            if (!state.HermesUncertain && !waiting)
            {
                if (status == "idle" || status == "failed" || status == "interrupted" || status == "completed")
                    state.HermesTerminalEpoch = input.Epoch;
                else if (status == "active") state.HermesTerminalEpoch = 0;
            }
            state.Updated = now;
            return true;
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
