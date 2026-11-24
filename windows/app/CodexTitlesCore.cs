using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace AITaskMonitor.CodexTitles {
 public sealed class Reader : IDisposable {
  private readonly object gate = new object();
  private readonly CancellationTokenSource stop = new CancellationTokenSource();
  private Task<Dictionary<string,string>> pending;
  private Dictionary<string,string> cache = new Dictionary<string,string>(StringComparer.Ordinal);
  private string requestedHome = "";
  private string pendingHome = "";
  private long nextScan;

  // This method only observes a completed worker and schedules another worker.
  // SQLite and filesystem operations never run on the UI thread.
  public Dictionary<string,string> Snapshot(string home, string[] ids) {
   lock (gate) {
    if (!String.Equals(requestedHome,home,StringComparison.OrdinalIgnoreCase)) {
     requestedHome=home; cache.Clear(); nextScan=0;
    }
    if (pending != null && pending.IsCompleted) {
     try {
      Dictionary<string,string> value=pending.Result;
      if (String.Equals(pendingHome,requestedHome,StringComparison.OrdinalIgnoreCase)) cache=value;
     } catch { cache.Clear(); }
     pending=null;
    }
    long now=Stopwatch.GetTimestamp();
    if (!stop.IsCancellationRequested && pending == null && ids != null && ids.Length > 0 && now >= nextScan) {
     string capturedHome=home;
     string[] capturedIds=(string[])ids.Clone();
     pendingHome=capturedHome;
     nextScan=now+5*Stopwatch.Frequency;
     CancellationToken token=stop.Token;
     pending=Task.Factory.StartNew(() => ReadNow(capturedHome,capturedIds,token),token,TaskCreationOptions.None,TaskScheduler.Default);
    }
    return new Dictionary<string,string>(cache,StringComparer.Ordinal);
   }
  }

  public static Dictionary<string,string> ReadNow(string home, string[] ids) {
   return ReadNow(home,ids,CancellationToken.None);
  }
  private static Dictionary<string,string> ReadNow(string home, string[] ids, CancellationToken stop) {
   Dictionary<string,string> result=new Dictionary<string,string>(StringComparer.Ordinal);
   if (String.IsNullOrWhiteSpace(home) || ids == null || ids.Length == 0 || stop.IsCancellationRequested) return result;
   try {
    string root=Path.GetFullPath(home);
    string database=Path.Combine(root,"state_5.sqlite");
    // Skip if sidecars are absent at this check. SQLite may recreate them if
    // they disappear concurrently; it uses SHM for normal read coordination.
    if (!SafeFile(database) || !SafeFile(database+"-wal") || !SafeFile(database+"-shm") ||
        !SafeParents(root) || !CanShareRead(database) || !CanShareRead(database+"-wal") || !CanShareRead(database+"-shm")) return result;
    using (var sqlite=new Native()) {
     if (sqlite.Version() < 3031000) return result;
     IntPtr db=IntPtr.Zero, query=IntPtr.Zero;
     Native.ProgressFn progress=null;
     try {
      int rc=sqlite.Open(Utf8(database),out db,0x00000001 | 0x00008000 | 0x01000000,IntPtr.Zero);
      if (rc != 0 || db == IntPtr.Zero || sqlite.ReadOnly(db,Utf8("main")) != 1) return result;
      sqlite.BusyTimeout(db,0);
      sqlite.Limit(db,0,65536);
      var clock=Stopwatch.StartNew();
      progress=unused => stop.IsCancellationRequested || clock.ElapsedMilliseconds >= 80 ? 1 : 0;
      sqlite.SetProgress(db,1000,progress,IntPtr.Zero);
      // The id is bound, not interpolated. Only name metadata is read.
      rc=sqlite.Prepare(db,Utf8("SELECT name,title,history_mode FROM main.threads WHERE id=?1 LIMIT 2"),-1,out query,IntPtr.Zero);
      if (rc != 0 || query == IntPtr.Zero || sqlite.StatementReadOnly(query) != 1) return result;
      var seen=new HashSet<string>(StringComparer.Ordinal);
      foreach (string id in ids) {
       if (stop.IsCancellationRequested || seen.Count >= 256 || clock.ElapsedMilliseconds >= 80) break;
       if (String.IsNullOrEmpty(id) || id.Length > 128 || !seen.Add(id)) continue;
       sqlite.Reset(query); sqlite.ClearBindings(query);
       byte[] key=Utf8(id);
       if (sqlite.BindText(query,1,key,key.Length-1,new IntPtr(-1)) != 0) { result.Clear(); break; }
       rc=sqlite.Step(query);
       if (rc == 101) continue;
       if (rc != 100) { result.Clear(); break; }
       string name=sqlite.Column(query,0), title=sqlite.Column(query,1), mode=sqlite.Column(query,2);
       if (sqlite.Step(query) != 101) { result.Clear(); break; }
       string display=String.Equals(mode,"paginated",StringComparison.Ordinal) ? name :
                      String.Equals(mode,"legacy",StringComparison.Ordinal) ? title : null;
       if (!String.IsNullOrWhiteSpace(display) && display.Length <= 4096 && display.IndexOf('\0') < 0)
        result[id]=display.Trim();
      }
     } finally { if (query != IntPtr.Zero) sqlite.Finalize(query); if (db != IntPtr.Zero) sqlite.Close(db); GC.KeepAlive(progress); }
    }
   } catch { result.Clear(); }
   return result;
  }
  internal static byte[] Utf8(string value) { return Encoding.UTF8.GetBytes(value+"\0"); }
  internal static bool SafeFile(string path) {
   try { var a=File.GetAttributes(path); return (a & (FileAttributes.Directory|FileAttributes.ReparsePoint)) == 0; }
   catch { return false; }
  }
  internal static bool CanShareRead(string path) {
   try { using(FileStream stream=File.Open(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) return true; }
   catch { return false; }
  }
  internal static bool SafeParents(string path) {
   try { for (DirectoryInfo d=new DirectoryInfo(path); d != null; d=d.Parent) {
     FileAttributes a=d.Attributes;
     if ((a & FileAttributes.Directory)==0 || (a & FileAttributes.ReparsePoint)!=0) return false;
    }
    return true;
   } catch { return false; }
  }
  public void Dispose() { stop.Cancel(); }

  internal sealed class Native : IDisposable {
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int VersionFn();
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int OpenFn(byte[] p,out IntPtr db,int f,IntPtr v);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int DbFn(IntPtr db);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int ReadOnlyFn(IntPtr db,byte[] name);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int TimeoutFn(IntPtr db,int ms);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int LimitFn(IntPtr db,int id,int value);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int PrepareFn(IntPtr db,byte[] sql,int bytes,out IntPtr stmt,IntPtr tail);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int BindFn(IntPtr stmt,int index,byte[] bytes,int length,IntPtr destroy);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int ProgressFn(IntPtr ignored);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void ProgressHandlerFn(IntPtr db,int operations,ProgressFn callback,IntPtr context);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr TextFn(IntPtr stmt,int column);
   [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int BytesFn(IntPtr stmt,int column);
   [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryEx(string name,IntPtr file,uint flags);
   [DllImport("kernel32.dll",CharSet=CharSet.Ansi,SetLastError=true)] static extern IntPtr GetProcAddress(IntPtr module,string name);
   [DllImport("kernel32.dll",SetLastError=true)] static extern bool FreeLibrary(IntPtr module);
   private IntPtr library;
   public VersionFn Version; public OpenFn Open; public DbFn Close; public ReadOnlyFn ReadOnly;
   public TimeoutFn BusyTimeout; public LimitFn Limit; public PrepareFn Prepare; public DbFn StatementReadOnly;
   public DbFn Step, Reset, ClearBindings, Finalize; public BindFn BindText; private TextFn text; private BytesFn bytes;
   public ProgressHandlerFn SetProgress; private BytesFn type;
   private T Get<T>(string name) where T:class {
    IntPtr p=GetProcAddress(library,name);
    if (p == IntPtr.Zero) throw new InvalidOperationException("SQLite function unavailable.");
    return Marshal.GetDelegateForFunctionPointer(p,typeof(T)) as T;
   }
   public Native() {
    string path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"winsqlite3.dll");
    library=LoadLibraryEx(path,IntPtr.Zero,0x00000800);
    if (library==IntPtr.Zero) throw new InvalidOperationException("SQLite unavailable.");
    try {
     Version=Get<VersionFn>("sqlite3_libversion_number"); Open=Get<OpenFn>("sqlite3_open_v2");
     Close=Get<DbFn>("sqlite3_close_v2"); ReadOnly=Get<ReadOnlyFn>("sqlite3_db_readonly");
     BusyTimeout=Get<TimeoutFn>("sqlite3_busy_timeout"); Limit=Get<LimitFn>("sqlite3_limit");
     Prepare=Get<PrepareFn>("sqlite3_prepare_v2"); StatementReadOnly=Get<DbFn>("sqlite3_stmt_readonly");
     Step=Get<DbFn>("sqlite3_step"); Reset=Get<DbFn>("sqlite3_reset"); ClearBindings=Get<DbFn>("sqlite3_clear_bindings");
     Finalize=Get<DbFn>("sqlite3_finalize"); BindText=Get<BindFn>("sqlite3_bind_text");
     SetProgress=Get<ProgressHandlerFn>("sqlite3_progress_handler"); type=Get<BytesFn>("sqlite3_column_type");
     text=Get<TextFn>("sqlite3_column_text"); bytes=Get<BytesFn>("sqlite3_column_bytes");
    } catch { Dispose(); throw; }
   }
   public string Column(IntPtr stmt,int column) {
    if(type(stmt,column)!=3) return null;
    IntPtr p=text(stmt,column); if(p==IntPtr.Zero) return null;
    int count=bytes(stmt,column); if(count<0 || count>16384) return null;
    byte[] buffer=new byte[count]; Marshal.Copy(p,buffer,0,count);
    return new UTF8Encoding(false,true).GetString(buffer);
   }
   public void Dispose() { if(library!=IntPtr.Zero){FreeLibrary(library);library=IntPtr.Zero;} }
  }
 }

 public sealed class CodexParentReference {
  public string ParentThreadId,AgentNickname,IdentityToken;
  public bool Conflict,IsRoot;
 }
 public sealed class RolloutSnapshot {
  public bool Success;
  public long StartedTicks;
  public Dictionary<string,string> Paths=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
  public Dictionary<string,long> CheckedTicks=new Dictionary<string,long>(StringComparer.OrdinalIgnoreCase);
  public Dictionary<string,CodexParentReference> ParentReferences=new Dictionary<string,CodexParentReference>(StringComparer.OrdinalIgnoreCase);
 }

 // SQLite and rollout-header reads are restricted to a bounded background worker.
 public sealed class RolloutReader : IDisposable {
  private sealed class Entry { public string Revision,Path; public long StartedTicks; public CodexParentReference Parent; }
  private readonly object gate=new object();
  private readonly CancellationTokenSource stop=new CancellationTokenSource();
  private readonly Dictionary<string,Entry> entries=new Dictionary<string,Entry>(StringComparer.OrdinalIgnoreCase);
  private readonly Dictionary<string,long> attempts=new Dictionary<string,long>(StringComparer.OrdinalIgnoreCase);
  private Dictionary<string,string> wanted=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
  private Dictionary<string,string> pendingIds;
  private Task<RolloutSnapshot> pending,abandoned;
  private string home="",pendingHome="";
  private long pendingStarted;

  public RolloutSnapshot Snapshot(string requestedHome,string[] ids) { return Snapshot(requestedHome,ids,null); }
  public RolloutSnapshot Snapshot(string requestedHome,string[] ids,string[] revisions) {
   lock(gate) {
    if(!String.Equals(home,requestedHome,StringComparison.OrdinalIgnoreCase)) {
     home=requestedHome; entries.Clear(); attempts.Clear();
    }
    var next=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    if(ids!=null) for(int i=0;i<ids.Length && i<768;i++) {
     string id=ids[i]; if(String.IsNullOrEmpty(id) || id.Length>128)continue;
     next[id]=revisions!=null && i<revisions.Length ? (revisions[i] ?? "") : "";
    }
    foreach(var old in new List<string>(entries.Keys)) {
     string revision;
     if(!next.TryGetValue(old,out revision) || !String.Equals(entries[old].Revision,revision,StringComparison.Ordinal)) entries.Remove(old);
    }
    foreach(var item in next) {
     string prior;
     if(wanted.TryGetValue(item.Key,out prior) && !String.Equals(prior,item.Value,StringComparison.Ordinal)) attempts.Remove(item.Key);
    }
    wanted=next;
    long now=Stopwatch.GetTimestamp();
    if(pending!=null && !pending.IsCompleted && (now-pendingStarted)>=4*Stopwatch.Frequency && (abandoned==null || abandoned.IsCompleted)) {
     abandoned=pending; pending=null;
    }
    if(pending!=null && pending.IsCompleted) {
     try {
      RolloutSnapshot value=pending.Result;
      if(String.Equals(home,pendingHome,StringComparison.OrdinalIgnoreCase)) foreach(var item in pendingIds) {
       string current,path;
       if(!wanted.TryGetValue(item.Key,out current) || !String.Equals(current,item.Value,StringComparison.Ordinal)) continue;
       value.Paths.TryGetValue(item.Key,out path);
       CodexParentReference parent=null;
       if(value.Success)value.ParentReferences.TryGetValue(item.Key,out parent);
       entries[item.Key]=new Entry {Revision=current,Path=value.Success ? path : null,StartedTicks=value.StartedTicks,Parent=parent};
      }
     } catch { }
     pending=null;
    }
    if(!stop.IsCancellationRequested && pending==null && wanted.Count>0) {
     var due=new List<string>();
     foreach(var item in wanted) {
      long last;
      if(!attempts.TryGetValue(item.Key,out last) || now-last>=5*Stopwatch.Frequency || !entries.ContainsKey(item.Key)) due.Add(item.Key);
     }
     due.Sort((a,b) => { long x,y; attempts.TryGetValue(a,out x); attempts.TryGetValue(b,out y); int c=x.CompareTo(y); return c!=0 ? c : StringComparer.OrdinalIgnoreCase.Compare(a,b); });
     if(due.Count>0) {
      if(due.Count>64)due.RemoveRange(64,due.Count-64);
      pendingIds=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
      foreach(string id in due) {pendingIds[id]=wanted[id];attempts[id]=now;}
      if(attempts.Count>4096) {
       var expired=new List<string>();
       foreach(string id in attempts.Keys)if(!wanted.ContainsKey(id))expired.Add(id);
       expired.Sort((a,b) => attempts[a].CompareTo(attempts[b]));
       foreach(string id in expired){if(attempts.Count<=4096)break;attempts.Remove(id);}
      }
      string capturedHome=home; string[] capturedIds=due.ToArray(); CancellationToken token=stop.Token;
      pendingHome=capturedHome; pendingStarted=now;
      pending=Task.Factory.StartNew(() => ReadNow(capturedHome,capturedIds,token),token,TaskCreationOptions.None,TaskScheduler.Default);
     }
    }
    var result=new RolloutSnapshot {Success=true};
    foreach(var item in entries) {
     if(!String.IsNullOrEmpty(item.Value.Path))result.Paths[item.Key]=item.Value.Path;
     if(item.Value.Parent!=null)result.ParentReferences[item.Key]=item.Value.Parent;
     result.CheckedTicks[item.Key]=item.Value.StartedTicks;
    }
    return result;
   }
  }
  public void RefreshSoon(string id) {lock(gate){if(!String.IsNullOrEmpty(id))attempts.Remove(id);}}
  public static RolloutSnapshot ReadNow(string home,string[] ids) {return ReadNow(home,ids,CancellationToken.None);}
  private static RolloutSnapshot ReadNow(string home,string[] ids,CancellationToken stop) {
   var result=new RolloutSnapshot {StartedTicks=Stopwatch.GetTimestamp()};
   try {
    string root=NormalizeLocal(home), database=Path.Combine(root,"state_5.sqlite");
    if(ids==null || ids.Length==0 || !Reader.SafeParents(root) || !Reader.SafeFile(database) ||
       !Reader.SafeFile(database+"-wal") || !Reader.SafeFile(database+"-shm") || !Reader.CanShareRead(database) ||
       !Reader.CanShareRead(database+"-wal") || !Reader.CanShareRead(database+"-shm")) return result;
    using(var sqlite=new Reader.Native()) {
     if(sqlite.Version()<3031000)return result;
     IntPtr db=IntPtr.Zero,query=IntPtr.Zero; Reader.Native.ProgressFn progress=null;
     try {
      int rc=sqlite.Open(Reader.Utf8(database),out db,0x00000001|0x00008000|0x01000000,IntPtr.Zero);
      if(rc!=0 || db==IntPtr.Zero || sqlite.ReadOnly(db,Reader.Utf8("main"))!=1)return result;
      sqlite.BusyTimeout(db,0);sqlite.Limit(db,0,65536);
      var clock=Stopwatch.StartNew();progress=unused => stop.IsCancellationRequested || clock.ElapsedMilliseconds>=1500 ? 1 : 0;
      sqlite.SetProgress(db,1000,progress,IntPtr.Zero);
      rc=sqlite.Prepare(db,Reader.Utf8("SELECT rollout_path,history_mode,CAST(archived AS TEXT) FROM main.threads WHERE id=?1 LIMIT 2"),-1,out query,IntPtr.Zero);
      if(rc!=0 || query==IntPtr.Zero || sqlite.StatementReadOnly(query)!=1)return result;
      foreach(string id in ids) {
       if(stop.IsCancellationRequested || clock.ElapsedMilliseconds>=1500)return result;
       if(String.IsNullOrEmpty(id) || id.Length>128)continue;
       sqlite.Reset(query);sqlite.ClearBindings(query);byte[] key=Reader.Utf8(id);
       if(sqlite.BindText(query,1,key,key.Length-1,new IntPtr(-1))!=0)return result;
       rc=sqlite.Step(query);if(rc==101)continue;if(rc!=100)return result;
       string path=sqlite.Column(query,0),mode=sqlite.Column(query,1),archived=sqlite.Column(query,2);
       if(sqlite.Step(query)!=101)return result;
       CodexParentReference parent;
       if(archived=="0" && (mode=="paginated" || mode=="legacy") && ValidatePath(root,id,path,out parent)){
        result.Paths[id]=NormalizeLocal(path);if(parent!=null)result.ParentReferences[id]=parent;
       }
      }
      result.Success=true;
     } finally {if(query!=IntPtr.Zero)sqlite.Finalize(query);if(db!=IntPtr.Zero)sqlite.Close(db);GC.KeepAlive(progress);}
    }
   } catch {result.Paths.Clear();result.ParentReferences.Clear();result.Success=false;}
   finally {if(!result.Success){result.Paths.Clear();result.ParentReferences.Clear();}}
   return result;
  }
  private static string NormalizeLocal(string path) {
   if(String.IsNullOrWhiteSpace(path))throw new ArgumentException("Missing local path.");
   if(path.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))path=path.Substring(4);
   if(path.Length<3 || !Char.IsLetter(path[0]) || path[1]!=':' || (path[2]!='\\' && path[2]!='/'))throw new ArgumentException("Expected local drive path.");
   return Path.GetFullPath(path);
  }
  private static bool ValidatePath(string home,string id,string path,out CodexParentReference parent) {
   parent=null;
   try {
    string root=NormalizeLocal(Path.Combine(home,"sessions")).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar)+Path.DirectorySeparatorChar;
    string full=NormalizeLocal(path);
    if(!full.StartsWith(root,StringComparison.OrdinalIgnoreCase))return false;
    string name=Path.GetFileName(full),prefix="-"+id; int position=name.LastIndexOf(prefix,StringComparison.OrdinalIgnoreCase);
    if(!name.StartsWith("rollout-",StringComparison.OrdinalIgnoreCase) || position<0)return false;
    string suffix=name.Substring(position+prefix.Length);Guid rolloutId;
    if(!String.Equals(suffix,".jsonl",StringComparison.OrdinalIgnoreCase) && !(suffix.Length==43 && suffix[0]=='_' && suffix.EndsWith(".jsonl",StringComparison.OrdinalIgnoreCase) && Guid.TryParseExact(suffix.Substring(1,36),"D",out rolloutId)))return false;
    for(DirectoryInfo dir=new DirectoryInfo(Path.GetDirectoryName(full));dir!=null;dir=dir.Parent) {
     string current=dir.FullName.TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar)+Path.DirectorySeparatorChar;
     if(!current.StartsWith(root,StringComparison.OrdinalIgnoreCase))return false;
     FileAttributes a=dir.Attributes;if((a&FileAttributes.Directory)==0 || (a&FileAttributes.ReparsePoint)!=0)return false;
     if(String.Equals(current,root,StringComparison.OrdinalIgnoreCase))break;
    }
    if(!Reader.SafeFile(full))return false;
    byte[] buffer=new byte[65536],headerBytes=null;string line=null;
    using(FileStream file=File.Open(full,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) using(var header=new MemoryStream()) {
     while(header.Length<=1048576) {
      int n=file.Read(buffer,0,buffer.Length);if(n<=0)break;int end=Array.IndexOf(buffer,(byte)10,0,n);int take=end<0?n:end;
      if(header.Length+take>1048576)return false;header.Write(buffer,0,take);
      if(end>=0){headerBytes=header.ToArray();line=new UTF8Encoding(false,true).GetString(headerBytes).TrimStart('\uFEFF').TrimEnd('\r');break;}
     }
    }
    if(line==null)return false;
    Type type=Type.GetType("System.Web.Script.Serialization.JavaScriptSerializer, System.Web.Extensions, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35",true);
    var record=type.GetMethod("DeserializeObject").Invoke(Activator.CreateInstance(type),new object[]{line}) as IDictionary<string,object>;
    object kind,payload,recorded; if(record==null || !record.TryGetValue("type",out kind) || !(kind is string) || (string)kind!="session_meta" || !record.TryGetValue("payload",out payload))return false;
    var meta=payload as IDictionary<string,object>;
    if(meta==null || !meta.TryGetValue("id",out recorded) || !(recorded is string) || !String.Equals((string)recorded,id,StringComparison.OrdinalIgnoreCase))return false;
    parent=ReadParent(meta,id);
    if(parent!=null && !parent.Conflict && !UniqueParentHeader(line))parent=new CodexParentReference {Conflict=true};
    if(parent!=null && !parent.Conflict)parent.IdentityToken=CaptureParentIdentity(full,id,headerBytes);
    return true;
   } catch {return false;}
  }
  private static IDictionary<string,object> Object(IDictionary<string,object> source,string key) {
   object value;return source!=null && source.TryGetValue(key,out value) ? value as IDictionary<string,object> : null;
  }
  private static bool UniqueParentHeader(string json) {
   try {
    Type observer=null;
    foreach(var assembly in AppDomain.CurrentDomain.GetAssemblies()) {
     observer=assembly.GetType("AITaskMonitor.CodexObservation.CodexRecentEventObserver",false);
     if(observer!=null)break;
    }
    var check=observer==null ? null : observer.GetMethod("HeaderHasUniqueKeys",System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.Static);
    return check!=null && (bool)check.Invoke(null,new object[]{json});
   } catch {return false;}
  }
  private static string CaptureParentIdentity(string path,string id,byte[] expectedHeader) {
   try {
    Type observer=null;
    foreach(var assembly in AppDomain.CurrentDomain.GetAssemblies()) {
     observer=assembly.GetType("AITaskMonitor.CodexObservation.CodexRecentEventObserver",false);
     if(observer!=null)break;
    }
    var check=observer==null ? null : observer.GetMethod("CaptureMatchingHeaderIdentity",System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.Static);
    return check==null ? "" : (string)check.Invoke(null,new object[]{path,id,expectedHeader});
   } catch {return "";}
  }
  private static string StringValue(IDictionary<string,object> source,string key) {
   object value;return source!=null && source.TryGetValue(key,out value) ? value as string : null;
  }
  private static CodexParentReference ReadParent(IDictionary<string,object> meta,string id) {
   var source=Object(meta,"source");
   var spawn=Object(Object(source,"subagent"),"thread_spawn");
   string parent=StringValue(meta,"parent_thread_id"),name=StringValue(meta,"agent_nickname"),path=StringValue(meta,"agent_path");
   bool hasHint=meta.ContainsKey("parent_thread_id") || meta.ContainsKey("agent_nickname") || meta.ContainsKey("agent_path") ||
                (source!=null && source.ContainsKey("subagent"));
   if(!hasHint) {
    string origin=StringValue(meta,"source"),threadSource=StringValue(meta,"thread_source");
    bool knownOrigin=origin=="cli" || origin=="vscode" || origin=="exec" || origin=="mcp";
    bool knownThread=threadSource=="user" || threadSource=="agent_created_thread";
    return knownOrigin && knownThread ? new CodexParentReference {IsRoot=true} : new CodexParentReference {Conflict=true};
   }
   Guid parentId,childId;
   object threadKind;
   if((meta.TryGetValue("thread_source",out threadKind) && threadKind!=null && !String.Equals(threadKind as string,"subagent",StringComparison.Ordinal)) ||
      spawn==null || !Guid.TryParseExact(parent,"D",out parentId) || !Guid.TryParseExact(id,"D",out childId) || parentId==childId ||
      String.IsNullOrWhiteSpace(name) || name.Length>256 || name.IndexOfAny(new char[]{'\r','\n','\0'})>=0 ||
      !String.Equals(parent,StringValue(spawn,"parent_thread_id"),StringComparison.Ordinal) ||
      !String.Equals(name,StringValue(spawn,"agent_nickname"),StringComparison.Ordinal) ||
      !String.Equals(path,StringValue(spawn,"agent_path"),StringComparison.Ordinal) ||
      String.IsNullOrEmpty(path) || Encoding.UTF8.GetByteCount(path)>1024 ||
      !System.Text.RegularExpressions.Regex.IsMatch(path,@"^/root/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$"))return new CodexParentReference {Conflict=true};
   foreach(char c in name)if(c<32 || c==127)return new CodexParentReference {Conflict=true};
   return new CodexParentReference {ParentThreadId=parent,AgentNickname=name.Trim()};
  }
  public void Dispose(){stop.Cancel();}
 }
}