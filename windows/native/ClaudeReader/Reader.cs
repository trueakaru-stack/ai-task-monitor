using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace AITaskMonitor.Claude {
 public sealed class Step {
  public string title { get; set; }
  public string status { get; set; }
  public string id { get; set; }
  public bool generated { get; set; }
 }
 public sealed class Task {
  public string Id { get; set; }
  public string Activity { get; set; }
  public DateTime Updated { get; set; }
  public DateTime Started { get; set; }
  public string StartKey { get; set; }
  public Step[] Steps { get; set; }
  public bool Unconfirmed { get; set; }
 }
 internal sealed class Event {
  internal DateTimeOffset Time;
  internal int Source;
  internal int Order;
  internal string Id, Name, Tool, Subject, TaskId, TaskStatus;
  internal bool? Active;
 }
 internal sealed class State {
  internal string Id, Activity = "", StartKey = "";
  internal bool Active, Observed;
  internal DateTimeOffset Updated, Started;
  internal readonly Dictionary<string, Step> Steps = new Dictionary<string, Step>(StringComparer.Ordinal);
  internal readonly List<string> StepOrder = new List<string>();
 }
 public static class Reader {
  private static string Value(Dictionary<string, object> data, string name) {
   object value;
   return data.TryGetValue(name, out value) && value is string ? (string)value : "";
  }
  private static List<Event> Parse(string input, int source, HashSet<string> permitted) {
   var events = new List<Event>();
   if (String.IsNullOrEmpty(input)) return events;
   var serializer = new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 32 };
   using (var lines = new StringReader(input)) {
    string line;
    int order = 0;
    while ((line = lines.ReadLine()) != null) {
     if (line.Length == 0 || line.Length > 1048576) continue;
     Dictionary<string, object> data;
     try { data = serializer.DeserializeObject(line) as Dictionary<string, object>; }
     catch (ArgumentException) { continue; }
     catch (InvalidOperationException) { continue; }
     if (data == null) continue;
     string id = Value(data, "session_id");
     DateTimeOffset time;
     if (String.IsNullOrEmpty(id) || (permitted != null && !permitted.Contains(id)) ||
         !DateTimeOffset.TryParse(Value(data, "timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out time)) continue;
     object active;
     bool? isActive = data.TryGetValue("active", out active) && active is bool ? (bool?)active : null;
     events.Add(new Event {
      Time=time.ToUniversalTime(), Source=source, Order=order++, Id=id, Active=isActive,
      Name=Value(data, "event"), Tool=Value(data, "tool_name"), Subject=Value(data, "task_subject"),
      TaskId=Value(data, "task_id"), TaskStatus=Value(data, "task_status")
     });
    }
   }
   return events;
  }
  private static string Activity(Event item) {
   switch(item.Name) {
    case "UserPromptSubmit": return "Обрабатывает новый запрос";
    case "PreToolUse": return item.Tool.Length > 0 ? "Выполняет: " + item.Tool : "Выполняет действие";
    case "PostToolUse": return item.Tool.Length > 0 ? "Завершено: " + item.Tool : "Действие завершено";
    case "PostToolUseFailure": return item.Tool.Length > 0 ? "Ошибка: " + item.Tool : "Ошибка действия";
    case "TaskCreated": return item.Subject.Length > 0 ? "Добавлен этап: " + item.Subject : "Добавлен этап";
    case "TaskCompleted": return item.Subject.Length > 0 ? "Завершён этап: " + item.Subject : "Этап завершён";
    case "SubagentStart": return "Запущен дополнительный агент";
    case "SubagentStop": return "Дополнительный агент завершён";
    default: return "";
   }
  }
  public static Task[] Read(string current, string legacy, DateTime utcNow) {
   return Read(current, legacy, utcNow, DateTime.MinValue);
  }
  public static Task[] Read(string current, string legacy, DateTime utcNow, DateTime observedSinceUtc) {
   List<Event> recent = Parse(current, 1, null);
   var ids = new HashSet<string>(recent.Select(item => item.Id), StringComparer.Ordinal);
   List<Event> all = ids.Count == 0 ? new List<Event>() : Parse(legacy, 0, ids);
   all.AddRange(recent);
   all.Sort((a,b) => { int ordering = a.Time.CompareTo(b.Time); if(ordering != 0) return ordering; ordering = a.Source.CompareTo(b.Source); return ordering != 0 ? ordering : a.Order.CompareTo(b.Order); });
   var states = new Dictionary<string, State>(StringComparer.Ordinal);
   DateTimeOffset observedSince = new DateTimeOffset(DateTime.SpecifyKind(observedSinceUtc, DateTimeKind.Utc));
   foreach(Event item in all) {
    State state;
    if(!states.TryGetValue(item.Id, out state)) { state = new State { Id=item.Id }; states.Add(item.Id, state); }
    if(item.Source == 1 && item.Active == true && item.Time >= observedSince) state.Observed = true;
    if((item.Name == "UserPromptSubmit" && item.Active != false) || (item.Active == true && !state.Active)) {
     state.Started = item.Time;
     state.StartKey = "event:" + item.Time.ToString("o", CultureInfo.InvariantCulture);
    }
    state.Updated = item.Time;
    string activity = Activity(item);
    if(activity.Length > 0) state.Activity = activity;
    if(item.Active.HasValue) state.Active = item.Active.Value;
    if(item.TaskId.Length == 0) continue;
    Step step;
    if(!state.Steps.TryGetValue(item.TaskId, out step)) {
     step = new Step { id=item.TaskId, generated=item.Subject.Length == 0, title=item.Subject.Length > 0 ? item.Subject : "Этап " + item.TaskId, status="pending" };
     state.Steps.Add(item.TaskId, step); state.StepOrder.Add(item.TaskId);
    } else if(item.Name == "TaskCreated") {
     step.title = item.Subject.Length > 0 ? item.Subject : "Этап " + item.TaskId;
     step.generated = item.Subject.Length == 0;
     step.status = "pending";
    }
    if(item.Name == "TaskCompleted" || item.TaskStatus == "completed") step.status = "done";
    else if(item.TaskStatus == "in_progress") step.status = "active";
    else if(item.TaskStatus == "pending") step.status = "pending";
   }
   var result = new List<Task>();
   DateTimeOffset now = new DateTimeOffset(DateTime.SpecifyKind(utcNow, DateTimeKind.Utc));
   foreach(State state in states.Values) {
    if(!state.Active || !state.Observed) continue;
    result.Add(new Task { Id=state.Id, Activity=state.Activity, Updated=state.Updated.UtcDateTime, Started=state.Started.UtcDateTime, StartKey=state.StartKey, Steps=state.StepOrder.Select(id => state.Steps[id]).ToArray(), Unconfirmed=(now-state.Updated).TotalMinutes >= 120 });
   }
   return result.ToArray();
  }
 }
}
