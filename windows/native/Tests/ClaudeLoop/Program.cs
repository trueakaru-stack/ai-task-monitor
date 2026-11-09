using AITaskMonitor.ClaudeLoop;
int checks=0;
void Check(bool ok,string description){checks++; if(!ok) throw new Exception(description); Console.WriteLine("PASS " + description);}
DateTimeOffset now=DateTimeOffset.UtcNow;
string hash=new('a',64);
SessionObservation Item(string session,string kind,string tool,DateTimeOffset at,long? code=null) => new(session,new LoopObservation(at,kind,tool,hash,code));
SessionObservation[] Failures(string session,string prefix,int count,DateTimeOffset at){var items=new List<SessionObservation>(); for(int i=0;i<count;i++){items.Add(Item(session,"start",prefix+i,at));items.Add(Item(session,"failed",prefix+i,at,7));} return items.ToArray();}
var r=new ClaudeLoopRegistry();
var both=Failures("one","a",5,now).Concat(Failures("two","b",3,now)).ToArray();
Check(r.Apply(false,both,5,10,now),"two sessions accepted");
Check(r.GetStatus("one") is {Warning:true,FailureCount:5} && r.GetStatus("two") is {Warning:false,FailureCount:3},"independent warning states");
Check(r.Dismiss("one") && r.GetStatus("one")!.Dismissed && !r.Dismiss("two"),"dismissal isolated");
Check(!r.Apply(true,both,5,10,now) && r.Count==0,"gap clears both and discards batch");
Check(r.Apply(false,Failures("one","fresh",5,now),5,10,now) && r.GetStatus("one")!.Warning,"five fresh failures recover after gap");
Check(!r.Apply(false,Failures("two","old",3,now),3,10,now) && r.Count==0,"setting change discards current batch");
Check(r.Apply(false,Array.Empty<SessionObservation>(),3,10,now) && r.Count==0,"empty batch keeps changed setting clear");
DateTimeOffset old=now.AddMinutes(-1);
Check(r.Apply(false,Failures("delayed","late",3,old),3,10,now) && r.GetStatus("delayed")!.Warning,"LIMIT: delayed pre-change events can warn under new threshold");
r.Clear();
Check(r.Apply(false,both,5,10,now),"setup for stop and isolation");
Check(r.Apply(false,[Item("one","stop","unused",now)],5,10,now) && r.GetStatus("one")==null && r.GetStatus("two") is {FailureCount:3},"stop removes only its session");
Check(r.Apply(false,[Item("missing","stop","unused",now)],5,10,now) && r.GetStatus("missing")==null,"unknown stop creates no state");
Check(!r.Apply(false,[Item("bad session","start","id",now)],5,10,now) && r.Count==0,"invalid session fails closed");
var exact=Enumerable.Range(0,1024).SelectMany(i=>new[]{Item("same","start","id"+i,now),Item("same","failed","id"+i,now,7)}).ToArray();
Check(r.Apply(false,exact,5,10,now) && r.GetStatus("same")!.Warning,"2048 events accepted");
Check(!r.Apply(false,exact.Append(Item("same","start","overflow",now)).ToArray(),5,10,now) && r.Count==0,"2049 events clear state");
var sessions=new List<SessionObservation>();
for(int i=0;i<256;i++) sessions.AddRange(Failures("s"+i.ToString("000"),"f",i==0?5:1,now));
Check(r.Apply(false,sessions,5,10,now) && r.Count==256 && r.GetStatus("s000")!.Warning,"256 active sessions including warning");
var late=Item("late","start","late",now.AddMinutes(-31));
Check(r.Apply(false,[late],5,10,now) && r.Count==256 && r.GetStatus("s000") is {Warning:true,FailureCount:5} && r.GetStatus("s001")!=null && r.GetStatus("late")==null,"fixed: stale new session preserves live warning and neighbor");

var invalidStarts=new[]{
 new SessionObservation("no-time",new LoopObservation(null,"start","tool",hash,null)),
 new SessionObservation("future",new LoopObservation(now.AddMinutes(5).AddTicks(1),"start","tool",hash,null)),
 new SessionObservation("old",new LoopObservation(now.AddMinutes(-30).AddTicks(-1),"start","tool",hash,null)),
 new SessionObservation("bad-tool",new LoopObservation(now,"start","bad tool",hash,null)),
 new SessionObservation("empty-tool",new LoopObservation(now,"start","",hash,null)),
 new SessionObservation("tool-129",new LoopObservation(now,"start",new string('a',129),hash,null)),
 new SessionObservation("hash-upper",new LoopObservation(now,"start","tool",new string('A',64),null)),
 new SessionObservation("hash-short",new LoopObservation(now,"start","tool",new string('a',63),null)),
 new SessionObservation("hash-null",new LoopObservation(now,"start","tool",null,null))};
foreach(var bad in invalidStarts){Check(r.Apply(false,[bad],5,10,now) && r.Count==256 && r.GetStatus("s000") is {Warning:true,FailureCount:5} && r.GetStatus(bad.SessionId)==null,"invalid start preserves full registry: "+bad.SessionId);}
Check(r.Apply(false,[Item("valid-new","start","valid",now)],5,10,now) && r.Count==256 && r.GetStatus("s000")==null && r.GetStatus("valid-new")!=null,"valid fresh start still evicts oldest at capacity");
r.Clear();
Check(r.Apply(false,[Item("edge-old","start","e",now.AddMinutes(-30)),Item("edge-future","start","f",now.AddMinutes(5))],5,30,now) && r.GetStatus("edge-old")!=null && r.GetStatus("edge-future") is {InFlightCount:1},"30-minute and plus-5-minute boundaries are inclusive");
r.Clear();
Check(r.Apply(false,[Item("min","start","e",DateTimeOffset.MinValue)],5,10,DateTimeOffset.MinValue) && r.GetStatus("min")!=null,"minimum time saturates without underflow");
r.Clear();
Check(r.Apply(false,[Item("max","start","e",DateTimeOffset.MaxValue)],5,10,DateTimeOffset.MaxValue) && r.GetStatus("max") is {InFlightCount:1},"maximum time saturates without overflow");

r.Clear();
Check(r.Apply(false,Failures("one","h",5,now),5,10,now) && r.GetStatus("one")!.Warning,"setup stopped channel");
using(var channel=new Channel("AITM.Test.NativeIndependent."+Guid.NewGuid().ToString("N"))){channel.Dispose();Check(!r.Poll(channel,5,10,now) && r.Count==0,"stopped channel clears warning");}

string Json(string session,string kind,string tool,int? exit=null){var d=new Dictionary<string,object>{{"session",session},{"kind",kind},{"tool",tool},{"fingerprint",hash}};if(exit.HasValue)d["exitCode"]=exit.Value;return System.Text.Json.JsonSerializer.Serialize(d);}
void WriteMessage(System.IO.Pipes.NamedPipeClientStream stream,string msg){byte[] bytes=System.Text.Encoding.UTF8.GetBytes(msg);stream.Write(BitConverter.GetBytes(bytes.Length));stream.Write(bytes);stream.Flush();}
System.IO.Pipes.NamedPipeClientStream Connect(string pipe){var s=new System.IO.Pipes.NamedPipeClientStream(".",pipe,System.IO.Pipes.PipeDirection.InOut);s.Connect(5000);byte[] key=new byte[32];s.ReadExactly(key);return s;}
void Send(string pipe,string msg){using var s=Connect(pipe);WriteMessage(s,msg);}
r.Clear(); Check(r.Apply(false,Failures("one","g",5,now),5,10,now) && r.GetStatus("one")!.Warning,"real gap setup");
string actualPipe="AITM.Test.NativeGap."+Guid.NewGuid().ToString("N");
using(var channel=new Channel(actualPipe)){
 Send(actualPipe,Json("first","start","x"));
 Send(actualPipe,Json("invalid session","start","x"));
 Send(actualPipe,Json("after-gap","start","x"));
 using var barrier=Connect(actualPipe);
 Check(!r.Poll(channel,5,10,DateTimeOffset.UtcNow) && r.Count==0,"actual malformed channel frame drops gap batch and existing warning");
}
r.Clear(); Check(r.Apply(false,Failures("one","h",5,now),5,10,now),"real changed-setting setup");
actualPipe="AITM.Test.NativeSettings."+Guid.NewGuid().ToString("N");
using(var channel=new Channel(actualPipe)){
 for(int i=0;i<3;i++){Send(actualPipe,Json("queued","start","x"+i));Send(actualPipe,Json("queued","failed","x"+i,7));}
 using(var barrier=Connect(actualPipe)){
  Check(!r.Poll(channel,3,10,DateTimeOffset.UtcNow) && r.Count==0,"actual queued batch discarded after setting change");
  WriteMessage(barrier,Json("ignored","stop","unused"));
 }
 for(int i=0;i<3;i++){Send(actualPipe,Json("late","start","y"+i));Send(actualPipe,Json("late","failed","y"+i,7));}
 using var end=Connect(actualPipe);
 Check(r.Poll(channel,3,10,DateTimeOffset.UtcNow) && r.GetStatus("late") is { Warning:true, FailureCount:3 },"LIMIT: actual later arrivals cannot be identified as pre-change");
}

Console.WriteLine("Independent: "+checks+" checks passed");
