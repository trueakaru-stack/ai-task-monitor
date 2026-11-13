using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace AITaskMonitor.Claude {
 public sealed class Step {
  public string title { get; set; }
  public string status { get; set; }
  public string id { get; set; }
  public bool generated { get; set; }
  internal string RetainedIdentity { get; set; }
 }
 public sealed class Task {
  public string Id { get; set; }
  public string Activity { get; set; }
  public DateTime Updated { get; set; }
  public DateTime Started { get; set; }
  public string StartKey { get; set; }
  public Step[] Steps { get; set; }
  public bool Unconfirmed { get; set; }
  public bool PlanConfirmed { get; set; }
  public int KnownStepCount { get; set; }
  public int KnownDoneCount { get; set; }
  public int UnknownStepCount { get; set; }
  public bool SessionEvidenceUncertain { get; set; }
  public bool PlanEvidenceUncertain { get; set; }
  public bool RetainedPlanIncomplete { get; set; }
 }
 internal sealed class Event {
  internal DateTimeOffset Time;
  internal int Source;
  internal int Order;
  internal string Id, Name, Tool, Subject, TaskId, TaskStatus, Phase, PreviousStatus;
  internal bool? Active;
 }
 internal sealed class State {
  internal string Id, Activity = "", StartKey = "";
  internal bool Active, Observed;
  internal bool PlanConfirmed = true;
  internal bool PromptSeen, SessionUncertain;
  internal bool StopUncertain, RetainAfterEnd, ProvenStopClear;
  internal DateTimeOffset Updated, Started;
  internal readonly Dictionary<string, Step> Steps = new Dictionary<string, Step>(StringComparer.Ordinal);
  internal readonly List<string> StepOrder = new List<string>();
  internal readonly List<Step> TitleHistory = new List<Step>();
  internal bool TitleHistoryTruncated;
  internal readonly Dictionary<string, StepTrust> Trust = new Dictionary<string, StepTrust>(StringComparer.Ordinal);
  internal readonly Dictionary<string, int> CreateAttempts = new Dictionary<string, int>(StringComparer.Ordinal);
  internal readonly HashSet<string> UncertainCreates = new HashSet<string>(StringComparer.Ordinal);
 }
 internal sealed class StepTrust {
  internal bool Confirmed, Created, Ambiguous, FailedOrUnknown;
  internal string LastKnown = "", ObservedTitle = "";
  internal int Pending, PendingCreations, PendingCompletions;
  internal readonly Dictionary<string, int> PendingStatuses = new Dictionary<string, int>(StringComparer.Ordinal);
 }
 public static class Reader {
  // The installed hook accepts at most 128 UTF-16 units for a session ID.
  // Never truncate: distinct long IDs could otherwise become one task.
  private const int MaximumSessionId = 128;
  private sealed class StepMoment {
   internal Event First;
   internal bool Multiple;
  }
  private static bool SameStepEvent(Event left, Event right) {
   return left.Name == right.Name && left.Tool == right.Tool && left.TaskStatus == right.TaskStatus &&
          left.Subject == right.Subject && left.Phase == right.Phase && left.PreviousStatus == right.PreviousStatus;
  }
  private static void RememberStep(Dictionary<string, Dictionary<string, Event>> source, Event item) {
   Dictionary<string, Event> session;
   if(!source.TryGetValue(item.Id, out session)) {
    session = new Dictionary<string, Event>(StringComparer.Ordinal); source.Add(item.Id, session);
   }
   Event prior;
   if(!session.TryGetValue(item.TaskId, out prior) || item.Time >= prior.Time) session[item.TaskId] = item;
  }
  private static void MarkReversedSteps(Dictionary<string, Dictionary<string, Event>> legacy,
                                        Dictionary<string, Dictionary<string, Event>> current,
                                        HashSet<string> uncertain) {
   foreach(var session in legacy) {
    Dictionary<string, Event> currentSteps;
    if(!current.TryGetValue(session.Key, out currentSteps)) continue;
    foreach(var step in session.Value) {
     Event present;
     if(currentSteps.TryGetValue(step.Key, out present) && step.Value.Time > present.Time)
      uncertain.Add(session.Key);
    }
   }
  }
  private static string Value(Dictionary<string, object> data, string name) {
   object value;
   return data.TryGetValue(name, out value) && value is string ? (string)value : "";
  }
  sealed class StrictJson {
   readonly string s; int i;
   internal StrictJson(string value) { s = value; }
   void Bad() { throw new FormatException("Unsupported JSON input."); }
   void Ws() { while(i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++; }
   bool Eat(char c) { Ws(); if(i < s.Length && s[i] == c) { i++; return true; } return false; }
   internal void Validate() { Ws(); ParseValue(0); Ws(); if(i != s.Length) Bad(); }
   void ParseValue(int depth) {
    if(depth > 32) Bad(); Ws(); if(i >= s.Length) { Bad(); return; }
    char c = s[i];
    if(c == '{') { Object(depth + 1); return; }
    if(c == '[') { Array(depth + 1); return; }
    if(c == '"') { StringValue(); return; }
    if(c == 't') { Literal("true"); return; }
    if(c == 'f') { Literal("false"); return; }
    if(c == 'n') { Literal("null"); return; }
    Number();
   }
   void Object(int depth) {
    i++; var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    if(Eat('}')) return;
    do {
     Ws(); if(i >= s.Length || s[i] != '"') Bad();
     string name = StringValue(); if(!names.Add(name)) Bad();
     if(!Eat(':')) Bad(); ParseValue(depth);
     if(Eat('}')) return;
     if(!Eat(',')) Bad();
    } while(true);
   }
   void Array(int depth) {
    i++; if(Eat(']')) return;
    do { ParseValue(depth); if(Eat(']')) return; if(!Eat(',')) Bad(); } while(true);
   }
   void Literal(string value) {
    if(i + value.Length > s.Length || String.CompareOrdinal(s, i, value, 0, value.Length) != 0) Bad();
    i += value.Length;
   }
   static bool Digit(char c) { return c >= '0' && c <= '9'; }
   void Number() {
    if(i < s.Length && s[i] == '-') i++;
    if(i >= s.Length) { Bad(); return; }
    if(s[i] == '0') i++;
    else { if(s[i] < '1' || s[i] > '9') Bad(); while(i < s.Length && Digit(s[i])) i++; }
    if(i < s.Length && s[i] == '.') { i++; if(i >= s.Length || !Digit(s[i])) Bad(); while(i < s.Length && Digit(s[i])) i++; }
    if(i < s.Length && (s[i] == 'e' || s[i] == 'E')) {
     i++; if(i < s.Length && (s[i] == '+' || s[i] == '-')) i++;
     if(i >= s.Length || !Digit(s[i])) Bad(); while(i < s.Length && Digit(s[i])) i++;
    }
   }
   string StringValue() {
    if(i >= s.Length || s[i++] != '"') { Bad(); return ""; }
    var result = new StringBuilder(); bool closed = false;
    while(i < s.Length) {
     char c = s[i++]; if(c == '"') { closed = true; break; }
     if(c < 32) Bad();
     if(c != '\\') { result.Append(c); continue; }
     if(i >= s.Length) Bad(); c = s[i++];
     switch(c) {
      case '"': case '\\': case '/': result.Append(c); break;
      case 'b': result.Append('\b'); break; case 'f': result.Append('\f'); break;
      case 'n': result.Append('\n'); break; case 'r': result.Append('\r'); break; case 't': result.Append('\t'); break;
      case 'u':
       if(i + 4 > s.Length) Bad(); int n = 0;
       for(int j=0;j<4;j++) { char h=s[i++]; int d=h>='0'&&h<='9'?h-'0':h>='a'&&h<='f'?h-'a'+10:h>='A'&&h<='F'?h-'A'+10:-1; if(d<0) Bad(); n=n*16+d; }
       result.Append((char)n); break;
      default: Bad(); break;
     }
    }
    if(!closed) Bad(); string value=result.ToString();
    for(int j=0;j<value.Length;j++) {
     if(Char.IsHighSurrogate(value[j])) { if(++j >= value.Length || !Char.IsLowSurrogate(value[j])) Bad(); }
     else if(Char.IsLowSurrogate(value[j])) Bad();
    }
    return value;
   }
  }
  private static bool ValidStatus(string value) { return value == "pending" || value == "in_progress" || value == "completed"; }
  private static string DisplayStatus(string value) { return value == "completed" ? "done" : value == "in_progress" ? "active" : "pending"; }
  private static void ConsumePending(StepTrust trust, string status) {
   int count;
   if(trust.PendingStatuses.TryGetValue(status, out count) && count > 0) {
    trust.PendingStatuses[status] = count - 1; trust.Pending--;
   }
  }
  private static string PhaseKey(Event item) {
   var key = new StringBuilder();
   foreach(string part in new[] { item.Id, item.Time.UtcDateTime.Ticks.ToString(CultureInfo.InvariantCulture), item.Name,
                                  item.Tool, item.Subject, item.TaskId, item.TaskStatus, item.Phase, item.PreviousStatus,
                                  item.Active.HasValue ? (item.Active.Value ? "1" : "0") : "?" })
    key.Append(part.Length.ToString(CultureInfo.InvariantCulture)).Append(':').Append(part);
   return key.ToString();
  }
  private static List<Event> Parse(string input, int source, HashSet<string> permitted, ref bool sourceUncertain) {
   var events = new List<Event>();
   if (String.IsNullOrEmpty(input)) return events;
   var serializer = new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 32 };
   using (var lines = new StringReader(input)) {
    string line;
    int order = 0;
    while ((line = lines.ReadLine()) != null) {
     if (line.Length == 0) continue;
     if (line.Length > 1048576) { sourceUncertain = true; continue; }
     Dictionary<string, object> data;
     try { new StrictJson(line).Validate(); data = serializer.DeserializeObject(line) as Dictionary<string, object>; }
     catch (ArgumentException) { sourceUncertain = true; continue; }
     catch (InvalidOperationException) { sourceUncertain = true; continue; }
     catch (FormatException) { sourceUncertain = true; continue; }
     if (data == null) { sourceUncertain = true; continue; }
     string phase = Value(data, "stage_phase");
     object version;
     if(phase.Length > 0 && (!data.TryGetValue("stage_version", out version) || !(version is int) || (int)version != 1)) {
      sourceUncertain = true; phase = "session_uncertain";
     }
     if (phase == "source_uncertain") sourceUncertain = true;
     string id = Value(data, "session_id");
     DateTimeOffset time;
     if (String.IsNullOrEmpty(id)) {
      if (phase != "source_uncertain") sourceUncertain = true;
      else if(DateTimeOffset.TryParse(Value(data, "timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out time))
       events.Add(new Event { Time=time.ToUniversalTime(), Source=source, Order=order++, Id="", Name="", Tool="", Subject="",
        TaskId="", TaskStatus="", Phase="source_uncertain", PreviousStatus="", Active=null });
      continue;
     }
     if (id.Length > MaximumSessionId) { sourceUncertain = true; continue; }
     if (permitted != null && !permitted.Contains(id)) continue;
     if (!DateTimeOffset.TryParse(Value(data, "timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out time)) { sourceUncertain = true; continue; }
     object active;
     bool? isActive = data.TryGetValue("active", out active) && active is bool ? (bool?)active : null;
     events.Add(new Event {
      Time=time.ToUniversalTime(), Source=source, Order=order++, Id=id, Active=isActive,
      Name=Value(data, "event"), Tool=Value(data, "tool_name"), Subject=Value(data, "task_subject"),
      TaskId=(phase == "created_notice" || phase == "completed_notice" || phase == "update_attempt" || phase == "update_failure" || phase == "update_unknown") ? Value(data, "stage_task_id") : Value(data, "task_id"),
      TaskStatus=(phase == "update_attempt" || phase == "update_failure" || phase == "update_unknown") ? Value(data, "stage_requested_status") : Value(data, "task_status"), Phase=phase,
      PreviousStatus=Value(data, "stage_previous_status")
     });
    }
   }
   return events;
  }
  private static string Activity(Event item) {
   switch(item.Name) {
    case "UserPromptSubmit": return "Обрабатывает новый запрос";
    case "PreToolUse": return item.Tool.Length > 0 ? "Выполняет: " + item.Tool : "Выполняет действие";
    case "PostToolUse":
     if((item.Tool == "TaskCreate" || item.Tool == "TaskUpdate") && item.Phase != "create_observed" && item.Phase != "update_observed") return "Выполняет действие";
     return item.Tool.Length > 0 ? "Завершено: " + item.Tool : "Действие завершено";
    case "PostToolUseFailure": return item.Tool.Length > 0 ? "Ошибка: " + item.Tool : "Ошибка действия";
    case "TaskCreated": return "Выполняет действие";
    case "TaskCompleted": return "Выполняет действие";
    case "StageNotice": return "Выполняет действие";
    case "SubagentStart": return "Запущен дополнительный агент";
    case "SubagentStop": return "Дополнительный агент завершён";
    default: return "";
   }
  }
  public static Task[] Read(string current, string legacy, DateTime utcNow) {
   return Read(current, legacy, utcNow, DateTime.MinValue);
  }
  public static Task[] Read(string current, string legacy, DateTime utcNow, DateTime observedSinceUtc) {
   bool ignored;
   return ReadWithSourceLoss(current, legacy, utcNow, observedSinceUtc, false, out ignored, null, null, null, null);
  }
  internal static Task[] ReadWithSourceLoss(string current, string legacy, DateTime utcNow, DateTime observedSinceUtc, bool priorLoss, out bool observedLoss,
                                           HashSet<string> sessionEvidence, HashSet<string> planEvidence, HashSet<string> cleanlyStopped, HashSet<string> nameEvidence) {
   bool sourceUncertain = priorLoss;
   List<Event> recent = Parse(current, 1, null, ref sourceUncertain);
   var ids = new HashSet<string>(recent.Where(item => item.Id.Length > 0).Select(item => item.Id), StringComparer.Ordinal);
   // Inspect the legacy source for loss even when no current IDs exist. The
   // empty permitted set still prevents legacy-only cards from being created.
   List<Event> all = Parse(legacy, 0, ids, ref sourceUncertain);
   all.AddRange(recent);
   observedLoss = sourceUncertain;
   // Retain evidence of a substantial backwards clock jump before sorting the
   // events. A later Stop must not be hidden by an earlier, future-dated event.
   // Rotated and current files may overlap; their order relative to each other
   // does not establish a clock jump, so compare within each source only.
   var latestWritten = new[] { new Dictionary<string, Event>(StringComparer.Ordinal),
                               new Dictionary<string, Event>(StringComparer.Ordinal) };
   var latestActiveWritten = new[] { new Dictionary<string, Event>(StringComparer.Ordinal),
                                     new Dictionary<string, Event>(StringComparer.Ordinal) };
   var latestPlanWritten = new[] { new Dictionary<string, Event>(StringComparer.Ordinal),
                                   new Dictionary<string, Event>(StringComparer.Ordinal) };
   var latestStatusWritten = new[] { new Dictionary<string, Dictionary<string, Event>>(StringComparer.Ordinal),
                                     new Dictionary<string, Dictionary<string, Event>>(StringComparer.Ordinal) };
   var latestSubjectWritten = new[] { new Dictionary<string, Dictionary<string, Event>>(StringComparer.Ordinal),
                                      new Dictionary<string, Dictionary<string, Event>>(StringComparer.Ordinal) };
   var legacyMoments = new Dictionary<string, Dictionary<string, Dictionary<DateTimeOffset, StepMoment>>>(StringComparer.Ordinal);
   var activeMoments = new[] { new Dictionary<string, Dictionary<DateTimeOffset, int>>(StringComparer.Ordinal),
                               new Dictionary<string, Dictionary<DateTimeOffset, int>>(StringComparer.Ordinal) };
   var prompts = new[] { new Dictionary<string, HashSet<DateTimeOffset>>(StringComparer.Ordinal),
                         new Dictionary<string, HashSet<DateTimeOffset>>(StringComparer.Ordinal) };
   var stepsAtTime = new[] { new Dictionary<string, HashSet<DateTimeOffset>>(StringComparer.Ordinal),
                             new Dictionary<string, HashSet<DateTimeOffset>>(StringComparer.Ordinal) };
   var timeUncertain = new HashSet<string>(StringComparer.Ordinal);
   var planUncertain = new HashSet<string>(StringComparer.Ordinal);
   foreach(Event item in all) {
    if(item.Id.Length == 0 && item.Phase == "source_uncertain") continue;
    Event latest;
    var sourceLatest = latestWritten[item.Source];
    if(sourceLatest.TryGetValue(item.Id, out latest)) {
     double backwards = (latest.Time-item.Time).TotalMinutes;
     if(backwards > 1 || (backwards > 0 && latest.Active.HasValue && item.Active.HasValue && latest.Active != item.Active))
      timeUncertain.Add(item.Id);
     if(item.Time >= latest.Time) sourceLatest[item.Id] = item;
    } else sourceLatest[item.Id] = item;
    if(item.Active.HasValue) {
     // Same-time contradictory active states are unordered even within one
     // file. Keep every observed moment, not just the most recent one.
     int activeBit = item.Active.Value ? 1 : 2;
     Dictionary<DateTimeOffset, int> moments;
     var ownMoments = activeMoments[item.Source];
     if(!ownMoments.TryGetValue(item.Id, out moments)) {
      moments = new Dictionary<DateTimeOffset, int>(); ownMoments.Add(item.Id, moments);
     }
     int existing;
     moments.TryGetValue(item.Time, out existing);
     if((existing & (item.Active.Value ? 2 : 1)) != 0) timeUncertain.Add(item.Id);
     moments[item.Time] = existing | activeBit;
     if(item.Source == 1 && activeMoments[0].TryGetValue(item.Id, out moments)) {
      if(moments.TryGetValue(item.Time, out existing) && (existing & (item.Active.Value ? 2 : 1)) != 0)
       timeUncertain.Add(item.Id);
     }
     Event latestActive;
     var sourceActive = latestActiveWritten[item.Source];
     if(sourceActive.TryGetValue(item.Id, out latestActive)) {
      if(item.Time < latestActive.Time && item.Active != latestActive.Active) timeUncertain.Add(item.Id);
      if(item.Time >= latestActive.Time) sourceActive[item.Id] = item;
     } else sourceActive[item.Id] = item;
    }
    bool isPrompt = item.Name == "UserPromptSubmit" && item.Active != false;
    bool isStep = item.TaskId.Length != 0;
    if(isPrompt || isStep) {
     Event priorPlan;
     var sourcePlan = latestPlanWritten[item.Source];
     if(sourcePlan.TryGetValue(item.Id, out priorPlan)) {
      if(item.Time < priorPlan.Time) planUncertain.Add(item.Id);
      if(item.Time >= priorPlan.Time) sourcePlan[item.Id] = item;
     } else sourcePlan[item.Id] = item;
     if(isPrompt) {
      HashSet<DateTimeOffset> sessionTimes;
      if(!prompts[item.Source].TryGetValue(item.Id, out sessionTimes)) {
       sessionTimes = new HashSet<DateTimeOffset>(); prompts[item.Source].Add(item.Id, sessionTimes);
      }
      sessionTimes.Add(item.Time);
     }
     if(isStep) {
      HashSet<DateTimeOffset> sessionTimes;
      if(!stepsAtTime[item.Source].TryGetValue(item.Id, out sessionTimes)) {
       sessionTimes = new HashSet<DateTimeOffset>(); stepsAtTime[item.Source].Add(item.Id, sessionTimes);
      }
      sessionTimes.Add(item.Time);
     }
    }
    if(isStep) {
     if(item.Name == "TaskCreated" || item.Name == "TaskCompleted" ||
        item.TaskStatus == "pending" || item.TaskStatus == "in_progress" || item.TaskStatus == "completed")
      RememberStep(latestStatusWritten[item.Source], item);
     if(item.Name == "TaskCreated" || item.Subject.Length != 0)
      RememberStep(latestSubjectWritten[item.Source], item);
     Dictionary<string, Dictionary<DateTimeOffset, StepMoment>> session;
     Dictionary<DateTimeOffset, StepMoment> moments;
     if(item.Source == 0) {
      if(!legacyMoments.TryGetValue(item.Id, out session)) {
       session = new Dictionary<string, Dictionary<DateTimeOffset, StepMoment>>(StringComparer.Ordinal);
       legacyMoments.Add(item.Id, session);
      }
      if(!session.TryGetValue(item.TaskId, out moments)) {
       moments = new Dictionary<DateTimeOffset, StepMoment>(); session.Add(item.TaskId, moments);
      }
      StepMoment moment;
      if(!moments.TryGetValue(item.Time, out moment)) moments.Add(item.Time, new StepMoment { First=item });
      else if(!SameStepEvent(moment.First, item)) moment.Multiple = true;
     } else if(legacyMoments.TryGetValue(item.Id, out session) && session.TryGetValue(item.TaskId, out moments)) {
      StepMoment moment;
      if(moments.TryGetValue(item.Time, out moment) && (moment.Multiple || !SameStepEvent(moment.First, item)))
       planUncertain.Add(item.Id);
     }
    }
   }
   // A legacy event later than the most recent current event may reflect
   // a delayed writer or clock change; the two files lack a common sequence.
   foreach(var prior in latestWritten[0]) {
    Event currentEvent;
    if(latestWritten[1].TryGetValue(prior.Key, out currentEvent) &&
       (prior.Value.Time > currentEvent.Time || (prior.Value.Time == currentEvent.Time &&
        prior.Value.Active.HasValue && currentEvent.Active.HasValue && prior.Value.Active != currentEvent.Active)))
     timeUncertain.Add(prior.Key);
   }
   foreach(var prior in latestActiveWritten[0]) {
    Event currentEvent;
    if(latestActiveWritten[1].TryGetValue(prior.Key, out currentEvent) &&
       prior.Value.Time >= currentEvent.Time && prior.Value.Active != currentEvent.Active)
     timeUncertain.Add(prior.Key);
   }
   // The files have no common sequence. Identical records may overlap, but a
   // conflicting step at the same time or a later legacy step is ambiguous.
   MarkReversedSteps(latestStatusWritten[0], latestStatusWritten[1], planUncertain);
   MarkReversedSteps(latestSubjectWritten[0], latestSubjectWritten[1], planUncertain);
   for(int source = 0; source < 2; source++) {
    foreach(var session in prompts[source]) {
     HashSet<DateTimeOffset> otherSteps;
     if(stepsAtTime[1-source].TryGetValue(session.Key, out otherSteps) && session.Value.Overlaps(otherSteps))
      planUncertain.Add(session.Key);
    }
   }
   all.Sort((a,b) => { int ordering = a.Time.CompareTo(b.Time); if(ordering != 0) return ordering; ordering = a.Source.CompareTo(b.Source); return ordering != 0 ? ordering : a.Order.CompareTo(b.Order); });
   var states = new Dictionary<string, State>(StringComparer.Ordinal);
   var phaseEvents = new HashSet<string>(StringComparer.Ordinal);
   DateTimeOffset observedSince = new DateTimeOffset(DateTime.SpecifyKind(observedSinceUtc, DateTimeKind.Utc));
   foreach(Event item in all) {
    if(item.Id.Length == 0 && item.Phase == "source_uncertain") {
     // A marker cannot identify its session. Preserve only sessions observed
     // active at this point; do not recreate already inactive sessions.
     foreach(State active in states.Values) if(active.Observed && active.Active) {
      active.StopUncertain = true; active.RetainAfterEnd = true;
     }
     continue;
    }
    if(item.Phase.Length > 0 && !phaseEvents.Add(PhaseKey(item))) { planUncertain.Add(item.Id); continue; }
    State state;
    if(!states.TryGetValue(item.Id, out state)) { state = new State { Id=item.Id }; states.Add(item.Id, state); }
    if(item.Source == 1 && item.Active == true && item.Time >= observedSince) state.Observed = true;
    if((item.Name == "UserPromptSubmit" && item.Active != false) || (item.Active == true && !state.Active)) {
     if(item.Name == "UserPromptSubmit" && state.Steps.Count > 0) state.PlanConfirmed = false;
     if(item.Name == "UserPromptSubmit" && item.Active != false) state.PromptSeen = true;
     state.Started = item.Time;
     state.StartKey = "event:" + item.Time.ToString("o", CultureInfo.InvariantCulture);
    }
    state.Updated = item.Time;
    string activity = Activity(item);
    if(activity.Length > 0) state.Activity = activity;
    // Legacy or ambiguous Stop cannot prove background work stopped. Do not
    // resurrect an already inactive session, but preserve an observed one.
    bool clearStop = item.Name == "Stop" && item.Phase == "stop_clear" && item.Active == false;
    bool unknownStop = (item.Name == "Stop" && !clearStop) || item.Name == "StopFailure";
    // An ambiguous later event alone cannot undo an observed clear stop.
    // Only subsequent observed activity can make this session active again.
    if(item.Active == true) state.ProvenStopClear = false;
    if(unknownStop) {
     state.StopUncertain = true;
     if(state.Active) state.RetainAfterEnd = true;
    } else if(!(item.Name == "SessionEnd" && state.RetainAfterEnd) && item.Active.HasValue) state.Active = item.Active.Value;
    if(clearStop) { state.StopUncertain = false; state.RetainAfterEnd = false; state.ProvenStopClear = true; }
    if(item.Phase == "session_uncertain" || item.Phase == "source_uncertain") state.SessionUncertain = true;
    bool createAttempt = item.Phase == "create_attempt" && item.Name == "PreToolUse" && item.Tool == "TaskCreate";
    bool createFailed = (item.Phase == "create_failure" && item.Name == "PostToolUseFailure" && item.Tool == "TaskCreate") ||
                        (item.Phase == "create_unknown" && item.Name == "PostToolUse" && item.Tool == "TaskCreate");
    // Older v1 hooks wrote an inferred pending value; it is not proof either.
    bool created = item.Phase == "create_observed" && item.Name == "PostToolUse" && item.Tool == "TaskCreate" &&
                   item.TaskId.Length > 0 && item.Subject.Length > 0 && (item.TaskStatus.Length == 0 || item.TaskStatus == "pending");
    bool updateAttempt = item.Phase == "update_attempt" && item.Name == "PreToolUse" && item.Tool == "TaskUpdate";
    bool updateFailed = (item.Phase == "update_failure" && item.Name == "PostToolUseFailure" && item.Tool == "TaskUpdate") ||
                        (item.Phase == "update_unknown" && item.Name == "PostToolUse" && item.Tool == "TaskUpdate");
    bool updated = item.Phase == "update_observed" && item.Name == "PostToolUse" && item.Tool == "TaskUpdate" &&
                   item.TaskId.Length > 0 && ValidStatus(item.TaskStatus) && ValidStatus(item.PreviousStatus) && item.TaskStatus != item.PreviousStatus;
    bool stepUncertain = item.Name == "StageNotice" && (item.Phase == "created_notice" || item.Phase == "completed_notice");
    if(item.Phase.Length > 0 && !createAttempt && !createFailed && !created && !updateAttempt && !updateFailed && !updated && !stepUncertain &&
       item.Phase != "session_uncertain" && item.Phase != "source_uncertain" &&
       !(item.Name == "Stop" && (item.Phase == "stop_clear" || item.Phase == "stop_uncertain")) &&
       !(item.Name == "StopFailure" && item.Phase == "stop_failure")) state.SessionUncertain = true;
    if(createAttempt || createFailed || created) {
     if(item.Subject.Length == 0) state.SessionUncertain = true;
     else {
      int pending; state.CreateAttempts.TryGetValue(item.Subject, out pending);
      if(createAttempt) { if(pending > 0) state.SessionUncertain = true; state.CreateAttempts[item.Subject] = pending + 1; }
      else {
       if(pending > 0) state.CreateAttempts[item.Subject] = pending - 1;
       if(createFailed) state.UncertainCreates.Add(item.Subject);
      }
     }
    }
    if(item.TaskId.Length == 0) {
     if(updateAttempt || updateFailed || stepUncertain || (item.Phase.Length == 0 && (item.Name == "TaskCreated" || item.Name == "TaskCompleted")))
      state.SessionUncertain = true;
     continue;
    }
    Step step;
    StepTrust trust;
    if(!state.Steps.TryGetValue(item.TaskId, out step)) {
     step = new Step { id=item.TaskId, generated=item.Subject.Length == 0, title=item.Subject.Length > 0 ? item.Subject : "Этап " + item.TaskId, status="unknown" };
     state.Steps.Add(item.TaskId, step); state.StepOrder.Add(item.TaskId);
     trust = new StepTrust(); state.Trust.Add(item.TaskId, trust);
    } else trust = state.Trust[item.TaskId];
    if(item.Subject.Length > 0 && (created || stepUncertain || item.Name == "TaskCreated" || item.Name == "TaskCompleted")) {
     if(!state.TitleHistory.Any(previous => previous.id == item.TaskId && previous.title == item.Subject)) {
      if(state.TitleHistory.Count == 128) { state.TitleHistory.RemoveAt(0); state.TitleHistoryTruncated = true; }
      state.TitleHistory.Add(new Step { id=item.TaskId, title=item.Subject, generated=false, status="unknown" });
     }
     if((!step.generated && step.title != item.Subject) ||
        (trust.ObservedTitle.Length > 0 && trust.ObservedTitle != item.Subject)) planUncertain.Add(item.Id);
     step.title = item.Subject;
     step.generated = false;
    }
    if(updateAttempt) {
     int pending; trust.PendingStatuses.TryGetValue(item.TaskStatus, out pending);
     if(trust.Pending > 0) trust.Ambiguous = true;
     trust.PendingStatuses[item.TaskStatus] = pending + 1; trust.Pending++; trust.Confirmed = false; step.status = "unknown";
    }
    else if(updateFailed) { ConsumePending(trust, item.TaskStatus); trust.FailedOrUnknown = true; trust.Confirmed = false; step.status = "unknown"; }
    else if(created) {
     if(trust.LastKnown.Length > 0) planUncertain.Add(item.Id);
     if(trust.PendingCreations > 0) trust.PendingCreations--;
     trust.Created = true; trust.ObservedTitle = item.Subject;
     trust.Confirmed = false; step.status = "unknown";
    } else if(updated) {
     if(trust.LastKnown.Length > 0 && trust.LastKnown != item.PreviousStatus) planUncertain.Add(item.Id);
     ConsumePending(trust, item.TaskStatus);
     if(item.TaskStatus == "completed" && trust.PendingCompletions > 0) trust.PendingCompletions--;
     trust.LastKnown = item.TaskStatus;
     trust.Confirmed = trust.Created && !trust.Ambiguous && !trust.FailedOrUnknown && trust.Pending == 0 && trust.PendingCreations == 0 && trust.PendingCompletions == 0;
     step.status = trust.Confirmed ? DisplayStatus(item.TaskStatus) : "unknown";
    } else {
     // Old records and blockable TaskCreated/TaskCompleted contain no proof.
     if(stepUncertain && item.Phase == "created_notice") { if(trust.PendingCreations > 0) trust.Ambiguous = true; trust.PendingCreations++; }
     if(stepUncertain && item.Phase == "completed_notice") { if(trust.PendingCompletions > 0) trust.Ambiguous = true; trust.PendingCompletions++; }
     trust.Confirmed = false; step.status = "unknown";
    }
   }
   var result = new List<Task>();
   DateTimeOffset now = new DateTimeOffset(DateTime.SpecifyKind(utcNow, DateTimeKind.Utc));
   foreach(State state in states.Values) {
    if(!state.Observed) continue;
    double age = (now-state.Updated).TotalMinutes;
    // A future terminal event must not hide an already observed task, even
    // within the small clock tolerance accepted for active observations.
    bool timeAnomaly = age < -1 || (!state.Active && age < 0) || timeUncertain.Contains(state.Id);
    bool sessionEvidenceUncertain = state.SessionUncertain || state.StopUncertain || timeUncertain.Contains(state.Id);
    bool allStepsObserved = state.StepOrder.Count > 0 && state.StepOrder.All(id => state.Trust[id].Confirmed && state.Trust[id].Created);
    bool pendingCreate = state.CreateAttempts.Values.Any(count => count > 0) || state.UncertainCreates.Count > 0;
    bool unresolved = state.Trust.Values.Any(item => item.Pending > 0 || item.PendingCreations > 0 || item.PendingCompletions > 0 || item.Ambiguous || item.FailedOrUnknown);
    bool stoppedUnresolved = !state.Active && (pendingCreate || unresolved || (state.StepOrder.Count > 0 && !allStepsObserved));
    bool planEvidenceUncertain = !state.PlanConfirmed || planUncertain.Contains(state.Id) || state.UncertainCreates.Count > 0 || state.Trust.Values.Any(item => item.Ambiguous || item.FailedOrUnknown) || stoppedUnresolved;
    // Preserve evidence even when a valid Stop hides the card in this same
    // snapshot. Otherwise retention/cleanup can silently remove the evidence.
    if(sessionEvidence != null && sessionEvidenceUncertain) sessionEvidence.Add(state.Id);
    if(planEvidence != null && planEvidenceUncertain) planEvidence.Add(state.Id);
    if(nameEvidence != null && state.SessionUncertain) nameEvidence.Add(state.Id);
    if(!state.Active && !timeAnomaly) {
     if(cleanlyStopped != null && state.ProvenStopClear) cleanlyStopped.Add(state.Id);
     continue;
    }
    bool unconfirmed = age >= 120 || timeAnomaly || sourceUncertain || state.SessionUncertain || state.StopUncertain;
    bool knownEvidence = state.PlanConfirmed && state.PromptSeen && !pendingCreate && !unresolved && !state.SessionUncertain && !sourceUncertain && !unconfirmed && !planUncertain.Contains(state.Id);
    int known = knownEvidence ? state.StepOrder.Count(id => state.Trust[id].Confirmed && state.Trust[id].Created) : 0;
    int done = knownEvidence ? state.StepOrder.Count(id => state.Trust[id].Confirmed && state.Trust[id].Created && state.Steps[id].status == "done") : 0;
    bool retainNames = sourceUncertain || state.SessionUncertain;
    bool titlesIncomplete = retainNames && state.TitleHistoryTruncated;
    var displayed = new List<Step>();
    Action<Step> append = delegate(Step candidate) {
     if(retainNames && candidate.generated && displayed.Any(existing => existing.id == candidate.id && !existing.generated)) return;
     if(retainNames && displayed.Any(existing => existing.id == candidate.id && existing.title == candidate.title)) return;
     if(retainNames && displayed.Count == 128) { displayed.RemoveAt(0); titlesIncomplete = true; }
     displayed.Add(retainNames ? new Step { id=candidate.id, title=candidate.title, generated=candidate.generated, status="unknown" } : candidate);
    };
    if(retainNames) foreach(Step oldName in state.TitleHistory) append(oldName);
    foreach(string id in state.StepOrder) append(state.Steps[id]);
    result.Add(new Task { Id=state.Id, Activity=state.Activity, Updated=state.Updated.UtcDateTime, Started=state.Started.UtcDateTime, StartKey=state.StartKey, Steps=displayed.ToArray(), Unconfirmed=unconfirmed, PlanConfirmed=state.PlanConfirmed && state.PromptSeen && allStepsObserved && !pendingCreate && !state.SessionUncertain && !sourceUncertain && !unconfirmed && !planUncertain.Contains(state.Id), KnownStepCount=known, KnownDoneCount=done, UnknownStepCount=displayed.Count-known, SessionEvidenceUncertain=sessionEvidenceUncertain, PlanEvidenceUncertain=planEvidenceUncertain, RetainedPlanIncomplete=titlesIncomplete });
   }
   return result.ToArray();
  }
 }

 // One instance belongs to one monitor source for the lifetime of the
 // monitor. A missing prefix cannot erase loss already observed by it.
 public sealed class SessionReader {
  internal const int MaximumRetained = 256;
  // Hooks limit titles to 240 and identifiers to 128 UTF-16 code units.
  // Cap retained data as well for old or independently produced records.
  private const int MaximumRetainedSteps = 128;
  private const int MaximumRetainedTitle = 240;
  private const int MaximumRetainedStepId = 128;
  private readonly object gate = new object();
  private readonly Dictionary<string, Task> retained = new Dictionary<string, Task>(StringComparer.Ordinal);
  private readonly HashSet<string> uncertainSessions = new HashSet<string>(StringComparer.Ordinal);
  private readonly HashSet<string> uncertainPlans = new HashSet<string>(StringComparer.Ordinal);
  private readonly HashSet<string> nameHistorySessions = new HashSet<string>(StringComparer.Ordinal);
  private bool sourceLoss, overflow;
  public bool SourceUncertain { get { lock(gate) return sourceLoss; } }
  public bool RetentionOverflow { get { lock(gate) return overflow; } }

  // The caller uses this after an externally visible source-read failure.
  public void MarkSourceLoss() { lock(gate) sourceLoss = true; }

  private static string BoundTitle(string title, ref bool incomplete) {
   if(title == null) return "";
   if(title.Length <= MaximumRetainedTitle) return title;
   int count = MaximumRetainedTitle - 1;
   if(count > 0 && Char.IsHighSurrogate(title[count - 1]) && Char.IsLowSurrogate(title[count])) count--;
   incomplete = true;
   return title.Substring(0, count) + "\u2026";
  }

  internal static Task Freeze(Task item, Task previous, bool preserveConflictingNames) {
   bool incomplete = item.RetainedPlanIncomplete || (previous != null && previous.RetainedPlanIncomplete);
   var steps = new List<Step>();
   // Earlier titles are useful when the readable suffix contains only part of
   // the last plan. Newer observations replace the same bounded identifier.
   Action<Step> append = delegate(Step input) {
    if(input == null) { incomplete = true; return; }
    string id = input.id ?? "";
    bool generated = input.generated;
    string identity = input.RetainedIdentity;
    if(id.Length > MaximumRetainedStepId) {
     identity = "long:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id)));
     id = ""; generated = false; incomplete = true;
    }
    string title = BoundTitle(input.title, ref incomplete);
    if(identity == null) {
     if(id.Length == 0) { identity = "missing:" + title; incomplete = true; }
     else identity = "id:" + id;
    }
    var copy = new Step { id=id, title=title, generated=generated, status="unknown", RetainedIdentity=identity };
    if(identity.Length > 0) {
     int position = steps.FindIndex(step => String.Equals(step.RetainedIdentity, identity, StringComparison.Ordinal) &&
      (!preserveConflictingNames || copy.generated || step.generated || String.Equals(step.title, copy.title, StringComparison.Ordinal)));
     if(position >= 0) {
      // A status-only suffix synthesizes a label; it is not a newer
      // observation of the title and must not erase a real known name.
      if(copy.generated && !steps[position].generated) {
       copy.title = steps[position].title;
       copy.generated = false;
      }
      steps[position] = copy; return;
     }
    }
    if(steps.Count == MaximumRetainedSteps) { steps.RemoveAt(0); incomplete = true; }
    steps.Add(copy);
   };
   if(previous != null && previous.Steps != null) foreach(Step step in previous.Steps) append(step);
   if(item.Steps != null) foreach(Step step in item.Steps) append(step);
   return new Task { Id=item.Id, Activity="", Updated=item.Updated, Started=item.Started,
    StartKey=item.StartKey, Steps=steps.ToArray(), Unconfirmed=true, PlanConfirmed=false,
    KnownStepCount=0, KnownDoneCount=0, UnknownStepCount=steps.Count,
    SessionEvidenceUncertain=item.SessionEvidenceUncertain, PlanEvidenceUncertain=item.PlanEvidenceUncertain,
    RetainedPlanIncomplete=incomplete };
  }

  public Task[] Read(string current, string legacy, DateTime utcNow, DateTime observedSinceUtc) {
   lock(gate) {
    bool prior = sourceLoss, observed;
    var sessionEvidence = new HashSet<string>(StringComparer.Ordinal);
    var planEvidence = new HashSet<string>(StringComparer.Ordinal);
    var cleanlyStopped = new HashSet<string>(StringComparer.Ordinal);
    var nameEvidence = new HashSet<string>(StringComparer.Ordinal);
    Task[] tasks = Reader.ReadWithSourceLoss(current, legacy, utcNow, observedSinceUtc, prior, out observed, sessionEvidence, planEvidence, cleanlyStopped, nameEvidence);
    sourceLoss |= observed;
    foreach(string id in sessionEvidence) if(!uncertainSessions.Contains(id)) {
     if(uncertainSessions.Count < MaximumRetained) uncertainSessions.Add(id);
     else { overflow = true; sourceLoss = true; }
    }
    foreach(string id in planEvidence) if(!uncertainPlans.Contains(id)) {
     if(uncertainPlans.Count < MaximumRetained) uncertainPlans.Add(id);
     else { overflow = true; sourceLoss = true; }
    }
    foreach(string id in nameEvidence) if(!nameHistorySessions.Contains(id)) {
     if(nameHistorySessions.Count < MaximumRetained) nameHistorySessions.Add(id);
     else { overflow = true; sourceLoss = true; }
    }
    foreach(Task item in tasks) if(sourceLoss || uncertainSessions.Contains(item.Id)) {
     item.Unconfirmed=true; item.PlanConfirmed=false; item.KnownStepCount=0; item.KnownDoneCount=0; item.UnknownStepCount=item.Steps.Length;
    }
    else if(uncertainPlans.Contains(item.Id)) { item.PlanConfirmed=false; item.KnownStepCount=0; item.KnownDoneCount=0; item.UnknownStepCount=item.Steps.Length; }
    // Do not re-create a card solely because its stopped session has stored
    // evidence. On a prior source-wide loss, retain the previous fallback.
    if(!sourceLoss) foreach(string id in cleanlyStopped) retained.Remove(id);
    // Do not revive stopped/absent sessions on the first source-loss marker.
    // For a still-visible session, keep its previous titles when the new
    // readable suffix carries only part of the plan.
    var visible = new HashSet<string>(tasks.Select(item => item.Id), StringComparer.Ordinal);
    if(!prior) foreach(string id in retained.Keys.Where(id => !uncertainSessions.Contains(id) &&
        !((sourceLoss || uncertainPlans.Contains(id)) && visible.Contains(id))).ToArray()) retained.Remove(id);
    for(int index = 0; index < tasks.Length; index++) {
     Task item = tasks[index];
     if(sourceLoss || uncertainSessions.Contains(item.Id) || uncertainPlans.Contains(item.Id) || item.Unconfirmed) {
      Task previous; retained.TryGetValue(item.Id, out previous);
      Task safe = Freeze(item, previous, sourceLoss || nameHistorySessions.Contains(item.Id));
      safe.Unconfirmed = item.Unconfirmed;
      safe.Activity = item.Unconfirmed ? "" : item.Activity;
      tasks[index] = safe;
     }
    }
    var result = new List<Task>(tasks);
    foreach(var entry in retained) if((prior || uncertainSessions.Contains(entry.Key)) && !visible.Contains(entry.Key)) result.Add(Freeze(entry.Value, null, sourceLoss || nameHistorySessions.Contains(entry.Key)));
    foreach(Task item in tasks) {
     Task frozen = Freeze(item, null, sourceLoss || nameHistorySessions.Contains(item.Id));
     if(retained.ContainsKey(item.Id)) retained[item.Id] = frozen;
     else if(retained.Count < MaximumRetained) retained.Add(item.Id, frozen);
     else overflow = true;
    }
    return result.ToArray();
   }
  }
 }
}
