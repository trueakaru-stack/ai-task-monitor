using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace AITaskMonitor.Claude {
 public static class Retention {
  private sealed class Item {
   internal int Source, Order, Bytes;
   internal long Time;
   internal string Line;
  }
  private sealed class Source : IDisposable {
   internal string Path;
   internal FileStream Stream;
   internal byte[] Hash;
   internal int Count;
   public void Dispose(){if(Stream!=null)Stream.Dispose();}
  }
  private static readonly object Gate=new object();
  private static Task<string> worker;
  private static string status="ok";
  private static int generation,configuredDays;
  private static long configuredMaximum;
  private static readonly Regex BackupName=new Regex(@"^settings\.json\.codex-tasks-backup-\d{8}-\d{6}-\d{7}$",RegexOptions.CultureInvariant);

  public static void Schedule(string directory,string backupDirectory,int days,long maximumBytes) {
   lock(Gate){
    if(configuredDays!=days || configuredMaximum!=maximumBytes){configuredDays=days;configuredMaximum=maximumBytes;generation++;}
    if(worker!=null && !worker.IsCompleted)return;
    int requestedGeneration=generation;
    worker=Task.Run(() => {
     string result;
     try { result=CleanInternal(directory,backupDirectory,DateTimeOffset.UtcNow,days,maximumBytes,"Local\\CodexTasksClaudeEvents",requestedGeneration); }
     catch(OperationCanceledException) { result="cancelled"; }
     catch { result="error"; }
     lock(Gate){status=result;}
     return result;
    });
   }
  }
  public static string Status { get { lock(Gate){return status;} } }
  public static void Invalidate() { lock(Gate){generation++;configuredDays=0;configuredMaximum=0;} }
  public static void WaitForStop(int milliseconds) {
   Task<string> current;
   lock(Gate){current=worker;}
   if(current!=null)try{current.Wait(milliseconds);}catch(AggregateException){}
  }

  public static string Clean(string directory,string backupDirectory,DateTimeOffset now,int days,long maximumBytes,string mutexName) {
   return CleanInternal(directory,backupDirectory,now,days,maximumBytes,mutexName,null);
  }
  private static string CleanInternal(string directory,string backupDirectory,DateTimeOffset now,int days,long maximumBytes,string mutexName,int? expectedGeneration) {
   if(days<1 || days>30 || maximumBytes<1000000 || maximumBytes>100000000)throw new ArgumentOutOfRangeException();
   bool busy=false;
   if(Directory.Exists(directory)) {
    AssertOrdinaryDirectory(directory);
    using(var mutex=new Mutex(false,mutexName)) {
     bool owned=false;
     try {
      try { owned=mutex.WaitOne(0); } catch(AbandonedMutexException) { owned=true; }
      if(owned)CleanEvents(directory,now.AddDays(-days),maximumBytes,expectedGeneration);
      else busy=true;
     } finally { if(owned)mutex.ReleaseMutex(); }
    }
   }
   CleanBackups(backupDirectory,now.AddDays(-30),expectedGeneration);
   return busy?"busy":"ok";
  }

  private static void CleanEvents(string directory,DateTimeOffset cutoff,long maximumBytes,int? expectedGeneration) {
   var sources=new List<Source>();
   var temporary=new List<string>();
   try {
    foreach(string name in new[]{"claude-events.jsonl","claude-events-v2.jsonl"}) {
     string path=Path.Combine(directory,name);
     if(!File.Exists(path))continue;
     AssertOrdinaryFile(path);
     var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete);
     var source=new Source{Path=path,Stream=stream};
     sources.Add(source);
     using(var sha=SHA256.Create())source.Hash=sha.ComputeHash(stream);
     if(stream.Length>0){stream.Seek(-1,SeekOrigin.End);if(stream.ReadByte()!=10)throw new InvalidDataException("Incomplete event file.");}
     stream.Seek(0,SeekOrigin.Begin);
    }
    if(sources.Count==0)return;
    var heap=new List<Item>();
    long used=0;
    bool changed=false;
    var serializer=new JavaScriptSerializer{MaxJsonLength=1048576,RecursionLimit=100};
    for(int sourceIndex=0;sourceIndex<sources.Count;sourceIndex++) {
     Source source=sources[sourceIndex];
     using(var reader=new StreamReader(source.Stream,new UTF8Encoding(false,true),true,8192,true)) {
      string line;
      while((line=reader.ReadLine())!=null) {
       if(String.IsNullOrWhiteSpace(line))continue;
       source.Count++;
       if(line.Length>1048576)throw new InvalidDataException("Event too large.");
       var obj=serializer.DeserializeObject(line) as Dictionary<string,object>;
       object raw;
       DateTimeOffset stamp;
       if(obj==null || !obj.TryGetValue("timestamp",out raw) || raw==null ||
          !DateTimeOffset.TryParse(Convert.ToString(raw,CultureInfo.InvariantCulture),CultureInfo.InvariantCulture,DateTimeStyles.AssumeUniversal,out stamp))
        throw new InvalidDataException("Unrecognized event.");
       if(stamp<cutoff){changed=true;continue;}
       int bytes=Encoding.UTF8.GetByteCount(line)+1;
       if(bytes>maximumBytes)throw new InvalidDataException("Event exceeds configured limit.");
       var item=new Item{Source=sourceIndex,Order=source.Count,Bytes=bytes,Time=stamp.UtcDateTime.Ticks,Line=line};
       Push(heap,item);used+=bytes;
       while(used>maximumBytes){used-=Pop(heap).Bytes;changed=true;}
      }
     }
    }
    if(!changed)return;
    foreach(Source source in sources) {
     AssertOrdinaryFile(source.Path);
     using(var current=new FileStream(source.Path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete))
     using(var sha=SHA256.Create())
      if(!source.Hash.SequenceEqual(sha.ComputeHash(current)))throw new IOException("Event file changed during cleanup.");
    }
    for(int i=0;i<sources.Count;i++) {
     Source source=sources[i];
     var retained=heap.Where(item=>item.Source==i).OrderBy(item=>item.Order).ToArray();
     if(retained.Length==source.Count)continue;
     string path=Path.Combine(directory,".aitm-retention-"+Guid.NewGuid().ToString("N")+".tmp");
     temporary.Add(path);
     using(var output=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None))
     using(var writer=new StreamWriter(output,new UTF8Encoding(false))) {
      writer.NewLine="\n";
      foreach(Item item in retained)writer.WriteLine(item.Line);
      writer.Flush();output.Flush(true);
     }
     AssertOrdinaryFile(source.Path);
     using(var current=new FileStream(source.Path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete))
     using(var sha=SHA256.Create())
      if(!source.Hash.SequenceEqual(sha.ComputeHash(current)))throw new IOException("Event file changed before cleanup.");
     Commit(expectedGeneration,()=>File.Replace(path,source.Path,null));
    }
   } finally {
    foreach(Source source in sources)source.Dispose();
    foreach(string path in temporary)try{if(File.Exists(path))File.Delete(path);}catch{}
   }
  }

  private static void CleanBackups(string directory,DateTimeOffset cutoff,int? expectedGeneration) {
   if(String.IsNullOrEmpty(directory) || !Directory.Exists(directory))return;
   AssertOrdinaryDirectory(directory);
   var backups=new List<FileInfo>();
   foreach(string path in Directory.EnumerateFiles(directory,"settings.json.codex-tasks-backup-*")) {
    if(!BackupName.IsMatch(Path.GetFileName(path)))continue;
    try { AssertOrdinaryFile(path);backups.Add(new FileInfo(path)); }
    catch(IOException) { }
   }
   backups=backups.OrderByDescending(file=>file.LastWriteTimeUtc).ThenByDescending(file=>file.Name,StringComparer.Ordinal).ToList();
   foreach(FileInfo file in backups.Skip(1)) {
    if(new DateTimeOffset(file.LastWriteTimeUtc)>=cutoff)continue;
    AssertOrdinaryFile(file.FullName);
    var current=new FileInfo(file.FullName);
    if(current.Length!=file.Length || current.LastWriteTimeUtc!=file.LastWriteTimeUtc)throw new IOException("Backup changed during cleanup.");
    Commit(expectedGeneration,()=>File.Delete(file.FullName));
   }
  }

  private static void Commit(int? expectedGeneration,Action action) {
   if(!expectedGeneration.HasValue){action();return;}
   lock(Gate){if(expectedGeneration.Value!=generation)throw new OperationCanceledException();action();}
  }

  private static void AssertOrdinaryDirectory(string path) {
   var attributes=File.GetAttributes(path);
   if((attributes&FileAttributes.Directory)==0 || (attributes&FileAttributes.ReparsePoint)!=0)throw new IOException("Unsafe data directory.");
  }
  private static void AssertOrdinaryFile(string path) {
   var attributes=File.GetAttributes(path);
   if((attributes&(FileAttributes.Directory|FileAttributes.ReparsePoint))!=0)throw new IOException("Unsafe data file.");
  }
  private static bool Less(Item left,Item right) {
   return left.Time<right.Time || (left.Time==right.Time && (left.Source<right.Source || (left.Source==right.Source && left.Order<right.Order)));
  }
  private static void Push(List<Item> heap,Item item) {
   int index=heap.Count;heap.Add(item);
   while(index>0){int parent=(index-1)/2;if(!Less(heap[index],heap[parent]))break;Item swap=heap[index];heap[index]=heap[parent];heap[parent]=swap;index=parent;}
  }
  private static Item Pop(List<Item> heap) {
   Item result=heap[0];int last=heap.Count-1;heap[0]=heap[last];heap.RemoveAt(last);int index=0;
   while(index<heap.Count){int left=index*2+1;if(left>=heap.Count)break;int right=left+1;int child=right<heap.Count&&Less(heap[right],heap[left])?right:left;if(!Less(heap[child],heap[index]))break;Item swap=heap[index];heap[index]=heap[child];heap[child]=swap;index=child;}
   return result;
  }
 }
}
