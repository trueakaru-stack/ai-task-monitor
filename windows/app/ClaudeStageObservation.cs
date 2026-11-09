using System;
using System.Collections.Generic;
using System.Text;
using System.Web.Script.Serialization;

// Built for .NET Framework 4.x. This helper processes one hook payload in
// memory and returns only fields already used by the monitor event log, plus
// bounded phase/status markers. It does not write a log or invoke Claude.
namespace AITaskMonitor.ClaudePhase {
 public sealed class Observation {
  public bool ValidInput;
  public string Session = "", Event = "Unknown", Tool = "", Phase = "", TaskId = "", Subject = "", Status = "", Previous = "";
 }
 public static class StageObservation {
  const int Limit = 1048576;
  static readonly StringComparer Ord = StringComparer.Ordinal;
  static Dictionary<string, object> Dict(object value) { return value as Dictionary<string, object>; }
  static object Value(Dictionary<string, object> data, string key) {
   object value; return data != null && data.TryGetValue(key, out value) ? value : null;
  }
  static string Text(Dictionary<string, object> data, string key) { return Value(data, key) as string; }
  static bool SafeId(string value) {
   if(String.IsNullOrEmpty(value) || value.Length > 128) return false;
   foreach(char c in value) if(!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
   return true;
  }
  static bool SafeSubject(string value) {
   return !String.IsNullOrWhiteSpace(value) && value.Length <= 240;
  }
  static bool StatusOk(string value) { return value == "pending" || value == "in_progress" || value == "completed"; }
  static bool Same(string a, string b) { return Ord.Equals(a, b); }
  static string TaskId(Dictionary<string, object> input) {
   string id = Text(input, "taskId");
   if(!SafeId(id)) return "";
   foreach(string alias in new[] { "id", "task_id" }) {
    object other = Value(input, alias);
    if(input != null && input.ContainsKey(alias) && (!(other is string) || !Same((string)other, id))) return "";
   }
   return id;
  }
  public static Observation Assess(string json) {
   var result = new Observation { Phase = "source_uncertain" };
   if(String.IsNullOrEmpty(json) || json.Length > Limit) return result;
   try {
    new StrictJson(json).Validate();
    var serializer = new JavaScriptSerializer { MaxJsonLength = Limit, RecursionLimit = 32 };
    var root = Dict(serializer.DeserializeObject(json));
    if(root == null) return result;
    string session = Text(root, "session_id"), name = Text(root, "hook_event_name"), tool = Text(root, "tool_name");
    if(!SafeId(session) || String.IsNullOrEmpty(name) || name.Length > 120 || (tool != null && tool.Length > 120)) return result;
    result.ValidInput = true; result.Session = session; result.Event = name; result.Tool = tool ?? ""; result.Phase = "";
    if(Array.IndexOf(new[] { "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "TaskCreated", "TaskCompleted", "SubagentStart", "SubagentStop", "Stop", "SessionEnd", "StopFailure" }, name) < 0) {
     result.Event = "Unknown"; result.Phase = "session_uncertain"; return result;
    }
    // A Stop ends the main reply, not necessarily background work. Keep only
    // a bounded classification; never copy task, cron, prompt or error data.
    if(name == "Stop") {
     result.Tool = "";
     var background = Value(root, "background_tasks") as object[];
     var crons = Value(root, "session_crons") as object[];
     result.Phase = background != null && crons != null && background.Length == 0 && crons.Length == 0
      ? "stop_clear" : "stop_uncertain";
     return result;
    }
    if(name == "StopFailure") { result.Tool = ""; result.Phase = "stop_failure"; return result; }
    if(name == "SessionEnd") { result.Tool = ""; return result; }
    var input = Dict(Value(root, "tool_input"));
    if(name == "TaskCreated" || name == "TaskCompleted") {
     string id = Text(root, "task_id"), subject = Text(root, "task_subject");
     result.Phase = SafeId(id) ? "step_uncertain" : "session_uncertain";
     result.TaskId = SafeId(id) ? id : "";
     if(SafeSubject(subject)) result.Subject = subject;
     return result;
    }
    if(name != "PreToolUse" && name != "PostToolUse" && name != "PostToolUseFailure") return result;
    if(String.IsNullOrEmpty(tool) || (tool != "TaskCreate" && String.Equals(tool, "TaskCreate", StringComparison.OrdinalIgnoreCase)) ||
       (tool != "TaskUpdate" && String.Equals(tool, "TaskUpdate", StringComparison.OrdinalIgnoreCase))) {
     result.Phase = "session_uncertain"; return result;
    }
    if(tool != "TaskCreate" && tool != "TaskUpdate") return result;
    string prefix = tool == "TaskCreate" ? "create" : "update";
    string idFromInput = tool == "TaskUpdate" ? TaskId(input) : "";
    string subjectFromInput = Text(input, "subject"), requestedStatus = Text(input, "status");
    result.TaskId = idFromInput;
    if(tool == "TaskCreate" && SafeSubject(subjectFromInput)) result.Subject = subjectFromInput;
    if(tool == "TaskUpdate" && StatusOk(requestedStatus)) result.Status = requestedStatus;
    if(name == "PreToolUse") { result.Phase = prefix + "_attempt"; return result; }
    if(name == "PostToolUseFailure") { result.Phase = prefix + "_failure"; return result; }
    result.Phase = prefix + "_unknown";
    var response = Dict(Value(root, "tool_response"));
    if(input == null || response == null) return result;
    if(response.ContainsKey("error") && Value(response, "error") != null) return result;
    if(tool == "TaskCreate") {
     if(response.ContainsKey("success") && !(Value(response, "success") is bool && (bool)Value(response, "success"))) return result;
     var task = Dict(Value(response, "task"));
     string id = Text(task, "id"), subject = Text(task, "subject");
     if(!SafeId(id) || !SafeSubject(subject) || !SafeSubject(subjectFromInput) || !Same(subject, subjectFromInput)) return result;
     // TaskCreateOutput supplies identity and subject, not an observed status.
     result.TaskId = id; result.Subject = subject; result.Status = ""; result.Phase = "create_observed";
     return result;
    }
    if(!SafeId(idFromInput) || !StatusOk(requestedStatus) || !Same(idFromInput, Text(response, "taskId")) ||
       !(Value(response, "success") is bool && (bool)Value(response, "success"))) return result;
    var fields = Value(response, "updatedFields") as object[];
    if(fields == null) return result;
    var seen = new HashSet<string>(Ord);
    foreach(object field in fields) if(!(field is string) || !seen.Add((string)field)) return result;
    // A simultaneous rename or other change is not represented by this
    // minimal record. Do not confirm a stale title or incomplete change.
    if(seen.Count != 1 || !seen.Contains("status")) return result;
    var change = Dict(Value(response, "statusChange"));
    string from = Text(change, "from"), to = Text(change, "to");
    if(!StatusOk(from) || !StatusOk(to) || Same(from, to) || !Same(to, requestedStatus)) return result;
    result.Previous = from; result.Phase = "update_observed";
    return result;
   } catch(Exception error) {
    if(error is ArgumentException || error is InvalidOperationException || error is FormatException || error is OverflowException)
     return new Observation { Phase = "source_uncertain" };
    throw;
   }
  }

  // The Framework JSON deserializer silently accepts duplicate object names.
  // Validate before deserializing so ambiguous payloads cannot prove success.
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
 }
}
