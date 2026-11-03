$script:DiagnosticHeader = '{"format":"ai-task-monitor-diagnostics","version":1}'

# Keep large journals responsive without accepting arbitrary fields into storage.
if(-not ("AITaskMonitor.Diagnostics.Policy" -as [type])){
 Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Management.Automation;
using System.Text;
using System.Text.RegularExpressions;

namespace AITaskMonitor.Diagnostics {
 public sealed class Record {
  public int version { get; private set; }
  public string time { get; private set; }
  public string source { get; private set; }
  public string task { get; private set; }
  public string type { get; private set; }
  public string id { get; private set; }
  internal bool Validated;
  internal Record(string timeValue, string sourceValue, string taskValue, string typeValue, string idValue, bool validated) {
   version=1; time=timeValue; source=sourceValue; task=taskValue; type=typeValue; id=idValue; Validated=validated;
  }
 }
 public sealed class Result {
  public Record[] Events { get; set; }
  public long Bytes { get; set; }
 }
 public sealed class TaskReference {
  public string Key { get; set; }
  public string Provider { get; set; }
 }
 public sealed class Row {
  public string TimeLabel { get; set; }
  public string SourceLabel { get; set; }
  public string EventLabel { get; set; }
 }
 public static class Policy {
  static readonly Regex Canonical = new Regex("^\\{\"version\":1,\"time\":\"([^\"\\\\]*)\",\"source\":\"([^\"\\\\]*)\",\"task\":\"([^\"\\\\]*)\",\"type\":\"([^\"\\\\]*)\",\"id\":\"([^\"\\\\]*)\"\\}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
  static readonly HashSet<string> Allowed = new HashSet<string>(new string[] {"task_observed","task_started","task_completed","task_interrupted","task_unconfirmed","source_unavailable","source_recovered","tool_started","tool_finished","tool_failed"}, StringComparer.Ordinal);
  static object Property(object value, string name) {
   if(value == null) return null;
   Record record = value as Record;
   if(record == null && value is PSObject) record = ((PSObject)value).BaseObject as Record;
   if(record != null) {
    switch(name) {
     case "version": return record.version;
     case "time": return record.time;
     case "source": return record.source;
     case "task": return record.task;
     case "type": return record.type;
     case "id": return record.id;
    }
   }
   PSPropertyInfo property = PSObject.AsPSObject(value).Properties[name];
   return property == null ? null : property.Value;
  }
  static string StringValue(object value) { return value == null ? "" : Convert.ToString(value, CultureInfo.InvariantCulture); }
  static bool IsLowerHex64(string value) {
   if(value == null || value.Length != 64) return false;
   foreach(char ch in value) if(!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return false;
   return true;
  }
  static bool Timestamp(object value, out DateTimeOffset result) {
   result=DateTimeOffset.MinValue;
   if(value is DateTimeOffset) { result=((DateTimeOffset)value).ToUniversalTime(); return true; }
   if(value is DateTime) {
    DateTime date=(DateTime)value;
    if(date.Kind == DateTimeKind.Unspecified) return false;
    result=new DateTimeOffset(date).ToUniversalTime(); return true;
   }
   string text=value as string;
   if(text == null || !DateTimeOffset.TryParseExact(text, "o", CultureInfo.InvariantCulture, DateTimeStyles.None, out result)) return false;
   result=result.ToUniversalTime(); return true;
  }
  public static Record ParseCanonical(string line) {
   Match match=Canonical.Match(line);
   if(!match.Success) return null;
   return new Record(match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value, match.Groups[4].Value, match.Groups[5].Value, false);
  }
  public static bool IsRecognized(Record record) {
   if(record == null || (record.source != "codex" && record.source != "claude") ||
      !Allowed.Contains(record.type) || !IsLowerHex64(record.id)) return false;
   if(record.type.StartsWith("source_",StringComparison.Ordinal)) {
    if(record.task != "") return false;
   } else if(!IsLowerHex64(record.task)) return false;
   DateTimeOffset timestamp;
   return Timestamp(record.time,out timestamp);
  }
  static string Format(Record record) {
   if(!record.Validated) throw new InvalidOperationException("Cannot serialize an unvalidated diagnostic record.");
   return "{\"version\":1,\"time\":\""+record.time+"\",\"source\":\""+record.source+"\",\"task\":\""+record.task+"\",\"type\":\""+record.type+"\",\"id\":\""+record.id+"\"}";
  }
  public static Result Limit(object[] events, DateTimeOffset now, int retentionDays, long maximumBytes, string header) {
   DateTimeOffset cutoff=now.ToUniversalTime().AddDays(-retentionDays);
   HashSet<string> seen=new HashSet<string>(StringComparer.Ordinal);
   List<Record> valid=new List<Record>();
   foreach(object item in events) {
    if(StringValue(Property(item,"version")) != "1") continue;
    string source=StringValue(Property(item,"source")), type=StringValue(Property(item,"type"));
    string id=StringValue(Property(item,"id")), task=StringValue(Property(item,"task"));
    if((source != "codex" && source != "claude") || !Allowed.Contains(type) || !IsLowerHex64(id)) continue;
    if(type.StartsWith("source_",StringComparison.Ordinal)) task="";
    else if(!IsLowerHex64(task)) continue;
    DateTimeOffset timestamp;
    if(!Timestamp(Property(item,"time"),out timestamp) || timestamp < cutoff || !seen.Add(id)) continue;
    valid.Add(new Record(timestamp.ToString("o",CultureInfo.InvariantCulture),source,task,type,id,true));
   }
   List<Record> ordered=valid.OrderBy(x => x.time, StringComparer.Ordinal).ToList();
   List<Record> retained=new List<Record>();
   long used=Encoding.UTF8.GetByteCount(header+"\n");
   if(used > maximumBytes) throw new InvalidOperationException("The diagnostic size limit cannot fit its format header.");
   for(int index=ordered.Count-1;index>=0;index--) {
    Record item=ordered[index];
    long length=Encoding.UTF8.GetByteCount(Format(item))+1;
    if(used+length > maximumBytes) break;
    retained.Add(item); used+=length;
   }
   retained.Reverse();
   return new Result { Events=retained.ToArray(), Bytes=used };
  }
  public static string Serialize(object[] events, string header) {
   StringBuilder text=new StringBuilder();
   text.Append(header).Append('\n');
   foreach(object item in events) {
    Record record=item as Record;
    if(record == null && item is PSObject) record=((PSObject)item).BaseObject as Record;
    if(record == null) throw new InvalidOperationException("Cannot serialize an unvalidated diagnostic record.");
    text.Append(Format(record)).Append('\n');
   }
   return text.ToString();
  }
  static Record RequireRecord(object item) {
   Record record=item as Record;
   if(record == null && item is PSObject) record=((PSObject)item).BaseObject as Record;
   if(record == null || !record.Validated) throw new InvalidOperationException("Cannot display an unvalidated diagnostic record.");
   return record;
  }
  public static TaskReference[] DistinctTasks(object[] events) {
   HashSet<string> seen=new HashSet<string>(StringComparer.Ordinal);
   List<TaskReference> tasks=new List<TaskReference>();
   foreach(object item in events) {
    Record record=RequireRecord(item);
    if(record.task.Length != 0 && seen.Add(record.task)) tasks.Add(new TaskReference { Key=record.task, Provider=record.source });
   }
   return tasks.ToArray();
  }
  public static Row[] MakeRows(object[] events, string taskKey, System.Collections.IDictionary labels) {
   List<Row> rows=new List<Row>();
   foreach(object item in events) {
    Record record=RequireRecord(item);
    if(!String.IsNullOrEmpty(taskKey) && !String.Equals(record.task,taskKey,StringComparison.Ordinal)) continue;
    DateTimeOffset time=DateTimeOffset.ParseExact(record.time,"o",CultureInfo.InvariantCulture,DateTimeStyles.None);
    object label=labels[record.type];
    rows.Add(new Row {
     TimeLabel=time.ToLocalTime().ToString("dd.MM HH:mm:ss",CultureInfo.InvariantCulture),
     SourceLabel=record.source == "claude" ? "Claude Code" : "Codex",
     EventLabel=label == null ? "" : label.ToString()
    });
   }
   return rows.ToArray();
  }
 }
}
'@
}

function Get-DiagnosticProperty($value,[string]$name,$fallback=$null) {
 if($null -ne $value -and $null -ne $value.PSObject.Properties[$name]){return $value.$name}
 return $fallback
}

function Get-DiagnosticTimestamp($Value,[bool]$CanonicalOnly=$false) {
 if($Value -is [DateTimeOffset]){return $Value.ToUniversalTime()}
 if($Value -is [DateTime]){
  if($Value.Kind -eq [DateTimeKind]::Unspecified){return $null}
  return ([DateTimeOffset]$Value).ToUniversalTime()
 }
 if($Value -isnot [string]){return $null}
 $timestamp=[DateTimeOffset]::MinValue
 if($CanonicalOnly){$valid=[DateTimeOffset]::TryParseExact($Value,"o",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$timestamp)}
 else{$valid=[DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$timestamp)}
 if(-not $valid){return $null}
 return $timestamp.ToUniversalTime()
}

function Select-DiagnosticEvents {
 param([AllowEmptyCollection()][object[]]$Events=@(),[AllowEmptyString()][string]$TaskKey="")
 foreach($event in $Events){
  if(-not $TaskKey -or [string](Get-DiagnosticProperty $event "task" "") -ceq $TaskKey){$event}
 }
}

function Get-DiagnosticTaskKey {
 param(
  [Parameter(Mandatory=$true)][ValidateSet("codex","claude")][string]$Provider,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]{1,128}$')][string]$TaskId,
  [Parameter(Mandatory=$true)][byte[]]$Key
 )
 if($Key.Length -lt 32){throw "The diagnostic key must contain at least 32 bytes."}
 $Provider=$Provider.ToLowerInvariant()
 $hmac=[Security.Cryptography.HMACSHA256]::new($Key)
 try{
  $bytes=[Text.Encoding]::UTF8.GetBytes($Provider+"`0"+$TaskId)
  return [BitConverter]::ToString($hmac.ComputeHash($bytes)).Replace("-","").ToLowerInvariant()
 }finally{$hmac.Dispose()}
}

function Get-DiagnosticEventKey {
 param(
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$TaskKey,
  [Parameter(Mandatory=$true)][ValidateSet("task_observed","task_started","task_completed","task_interrupted","task_unconfirmed","source_unavailable","source_recovered","tool_started","tool_finished","tool_failed")][string]$Type,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]{1,128}$')][string]$Reference,
  [Parameter(Mandatory=$true)][DateTimeOffset]$Time,
  [Parameter(Mandatory=$true)][byte[]]$Key
 )
 if($Key.Length -lt 32){throw "The diagnostic key must contain at least 32 bytes."}
 $hmac=[Security.Cryptography.HMACSHA256]::new($Key)
 try{
  $value="event`0"+$TaskKey+"`0"+$Type.ToLowerInvariant()+"`0"+$Reference+"`0"+$Time.ToUniversalTime().ToString("o")
  return [BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($value))).Replace("-","").ToLowerInvariant()
 }finally{$hmac.Dispose()}
}

function Convert-CodexToolEvents {
 param(
  [AllowEmptyCollection()][object[]]$Records=@(),
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$TaskKey,
  [Parameter(Mandatory=$true)][byte[]]$Key,
  [Parameter(Mandatory=$true)][DateTimeOffset]$Since,
  [hashtable]$Calls=@{}
 )
 foreach($record in $Records){
  $recordType=[string](Get-DiagnosticProperty $record "type" "")
  $payload=Get-DiagnosticProperty $record "payload"
  $kind=[string](Get-DiagnosticProperty $payload "type" "")
  if($recordType -ceq "event_msg" -and $kind -ceq "item_completed"){
   $item=Get-DiagnosticProperty $payload "item"
   $exitCode=Get-DiagnosticProperty $item "exit_code"
   $reference=[string](Get-DiagnosticProperty $item "id" "")
   $timestamp=Get-DiagnosticTimestamp (Get-DiagnosticProperty $record "timestamp")
   if([string](Get-DiagnosticProperty $item "type" "") -ceq "CommandExecution" -and
      [string](Get-DiagnosticProperty $item "status" "") -ceq "failed" -and
      ($exitCode -is [int] -or $exitCode -is [long]) -and $exitCode -ne 0 -and
      $reference -cmatch '^[A-Za-z0-9_-]{1,128}$' -and $null -ne $timestamp -and $timestamp -ge $Since){
    $timestamp=$timestamp.ToUniversalTime()
    $eventId=Get-DiagnosticEventKey -TaskKey $TaskKey -Type "tool_failed" -Reference $reference -Time $timestamp -Key $Key
    [PSCustomObject][ordered]@{version=1;time=$timestamp.ToString("o");source="codex";task=$TaskKey;type="tool_failed";id=$eventId}
   }
   continue
  }
  if($recordType -cne "response_item"){continue}
  $reference=[string](Get-DiagnosticProperty $payload "call_id" "")
  if($reference -cnotmatch '^[A-Za-z0-9_-]{1,128}$'){continue}
  $timestamp=Get-DiagnosticTimestamp (Get-DiagnosticProperty $record "timestamp")
  if($null -eq $timestamp){continue}
  $type=""
  if($kind -cin @("function_call","custom_tool_call")){
   $name=[string](Get-DiagnosticProperty $payload "name" "")
   if($name -cnotmatch '^[A-Za-z0-9_.:-]{1,128}$' -or $name -in @("update_plan","request_user_input","request_user_input_async","request_permissions")){[void]$Calls.Remove($reference);continue}
   if($Calls.Count -lt 4096 -or $Calls.ContainsKey($reference)){$Calls[$reference]=$true}
   $type="tool_started"
  }elseif($kind -cin @("function_call_output","custom_tool_call_output") -and $Calls.ContainsKey($reference)){$type="tool_finished";[void]$Calls.Remove($reference)}
  if(-not $type -or $timestamp -lt $Since){continue}
  $timestamp=$timestamp.ToUniversalTime()
  $eventId=Get-DiagnosticEventKey -TaskKey $TaskKey -Type $type -Reference $reference -Time $timestamp -Key $Key
  [PSCustomObject][ordered]@{version=1;time=$timestamp.ToString("o");source="codex";task=$TaskKey;type=$type;id=$eventId}
 }
}

function Limit-DiagnosticEvents {
 param(
  [AllowEmptyCollection()][object[]]$Events=@(),
  [Parameter(Mandatory=$true)][DateTimeOffset]$Now,
  [ValidateRange(1,7)][int]$RetentionDays=7,
  [ValidateRange(1,10000000)][long]$MaximumBytes=10000000
 )
 return [AITaskMonitor.Diagnostics.Policy]::Limit($Events,$Now,$RetentionDays,$MaximumBytes,$script:DiagnosticHeader)
}
