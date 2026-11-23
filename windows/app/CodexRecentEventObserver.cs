using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace AITaskMonitor.CodexObservation
{
    // This is a hint about an observed append, not a lifecycle or liveness result.
    public sealed class RecentEventSnapshot
    {
        public bool HasEvent { get; internal set; }
        public bool BaselineReady { get; internal set; }
        public long CheckCount { get; internal set; }
        public string IdentityToken { get; internal set; }
        public long FileLength { get; internal set; }
        public long LastWriteUtcTicks { get; internal set; }
    }

    // All filesystem access and JSON decoding happen on a single worker.
    // The caller remains responsible for validating discovery, handling source
    // uncertainty and deciding which card to show.
    public sealed class CodexRecentEventObserver : IDisposable
    {
        // The rollout reader exposes at most 768 verified paths per snapshot.
        // Keep at least that many baselines so one extra candidate cannot evict
        // every active session on each UI refresh.
        private const int MaximumEntries = 768;
        private const int EntriesPerPass = 64;
        private const int PriorityPerPass = 8;
        private const int PassDelayMilliseconds = 250;
        private const int IdleSeconds = 30;
        private const int MaximumHeader = 65536;
        private const int MaximumLine = 1048576;
        private const int MaximumAppend = 2097152;
        private const int BytesPerPass = 262144;
        private const int AnchorLength = 256;
        private readonly object gate = new object();
        private readonly string root;
        private readonly WaitHandle fixtureGate;
        private readonly Dictionary<string, Entry> entries = new Dictionary<string, Entry>(StringComparer.Ordinal);
        private Task worker;
        private bool disposed;
        private long generation;
        private string lastVisited = "", lastPriority = "";

        private sealed class Entry
        {
            public string Id, Path;
            public long Generation, Requested, Checked, Checks;
            public Cursor Cursor;
        }

        private sealed class Cursor
        {
            public uint Volume, IndexHigh, IndexLow;
            public long Offset, WriteStamp;
            public byte[] Header, Anchor, Partial;
            public bool SkipBaselinePartial, Observed, PendingEvidence;
            public string IdentityToken;
            public long FileLength, LastWriteUtcTicks;

            public Cursor Copy()
            {
                return (Cursor)MemberwiseClone();
            }
        }

        private sealed class Request
        {
            public string Id, Path;
            public long Generation;
            public Cursor Cursor;
        }

        public CodexRecentEventObserver(string sessionsDirectory) : this(sessionsDirectory, null) { }

        // Used by isolated tests to hold the worker without blocking Snapshot.
        public CodexRecentEventObserver(string sessionsDirectory, WaitHandle fixtureGate)
        {
            root = Path.GetFullPath(sessionsDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            this.fixtureGate = fixtureGate;
        }

        public RecentEventSnapshot Snapshot(string threadId, string journalPath)
        {
            string normalized = "";
            bool valid = ValidId(threadId, 128, false);
            if (valid)
            {
                try
                {
                    normalized = Path.GetFullPath(journalPath);
                    valid = normalized.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) &&
                            normalized.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase);
                }
                catch { valid = false; }
            }
            lock (gate)
            {
                Entry entry;
                if (disposed || !valid)
                {
                    if (!String.IsNullOrEmpty(threadId)) entries.Remove(threadId);
                    return new RecentEventSnapshot();
                }
                long now = Stopwatch.GetTimestamp();
                if (!entries.TryGetValue(threadId, out entry) ||
                    !String.Equals(entry.Path, normalized, StringComparison.OrdinalIgnoreCase))
                {
                    if (!entries.ContainsKey(threadId) && entries.Count >= MaximumEntries) EvictOldest();
                    entry = new Entry { Id = threadId, Path = normalized, Generation = ++generation };
                    entries[threadId] = entry;
                }
                entry.Requested = now;
                Schedule();
                long freshnessSeconds = Math.Max(4, 2 * ((entries.Count + EntriesPerPass - 1) / EntriesPerPass));
                bool fresh = entry.Cursor != null && entry.Checked != 0 &&
                             now - entry.Checked <= freshnessSeconds * Stopwatch.Frequency;
                return new RecentEventSnapshot {
                    BaselineReady = fresh,
                    HasEvent = fresh && entry.Cursor.Observed,
                    CheckCount = entry.Checks,
                    IdentityToken = fresh ? entry.Cursor.IdentityToken : "",
                    FileLength = fresh ? entry.Cursor.FileLength : -1,
                    LastWriteUtcTicks = fresh ? entry.Cursor.LastWriteUtcTicks : 0
                };
            }
        }

        private void EvictOldest()
        {
            string oldest = null;
            long when = Int64.MaxValue;
            foreach (KeyValuePair<string, Entry> pair in entries)
            {
                if (pair.Value.Requested < when) { oldest = pair.Key; when = pair.Value.Requested; }
            }
            if (oldest != null) entries.Remove(oldest);
        }

        private void Schedule()
        {
            if (disposed || (worker != null && !worker.IsCompleted)) return;
            worker = Task.Factory.StartNew(Work, CancellationToken.None, TaskCreationOptions.None, TaskScheduler.Default);
        }

        private void Work()
        {
            while (true)
            {
                List<Request> batch = new List<Request>();
                lock (gate)
                {
                    if (disposed) return;
                    long cutoff = Stopwatch.GetTimestamp() - IdleSeconds * Stopwatch.Frequency;
                    foreach (string id in new List<string>(entries.Keys))
                        if (entries[id].Requested < cutoff) entries.Remove(id);
                    if (entries.Count == 0) { worker = null; return; }
                    List<string> ids = new List<string>(entries.Keys);
                    ids.Sort(StringComparer.Ordinal);
                    List<string> priority = ids.FindAll(delegate(string id) {
                        Cursor cursor = entries[id].Cursor;
                        return cursor != null && (cursor.Observed || cursor.PendingEvidence);
                    });
                    HashSet<string> chosen = new HashSet<string>(StringComparer.Ordinal);
                    int firstPriority = priority.FindIndex(delegate(string value) { return StringComparer.Ordinal.Compare(value, lastPriority) > 0; });
                    if (firstPriority < 0) firstPriority = 0;
                    int priorityCount = Math.Min(PriorityPerPass, priority.Count);
                    for (int i = 0; i < priorityCount; i++)
                    {
                        string id = priority[(firstPriority + i) % priority.Count];
                        AddRequest(batch, entries[id]); chosen.Add(id); lastPriority = id;
                    }
                    int start = ids.FindIndex(delegate(string value) { return StringComparer.Ordinal.Compare(value, lastVisited) > 0; });
                    if (start < 0) start = 0;
                    for (int i = 0; i < ids.Count && batch.Count < EntriesPerPass; i++)
                    {
                        string id = ids[(start + i) % ids.Count];
                        lastVisited = id;
                        if (chosen.Add(id)) AddRequest(batch, entries[id]);
                    }
                }
                foreach (Request request in batch)
                {
                    lock (gate) { if (disposed) return; }
                    Cursor result = null;
                    try
                    {
                        if (fixtureGate != null) fixtureGate.WaitOne();
                        result = Probe(request);
                    }
                    catch { result = null; }
                    lock (gate)
                    {
                        Entry current;
                        if (!disposed && entries.TryGetValue(request.Id, out current) &&
                            current.Generation == request.Generation &&
                            String.Equals(current.Path, request.Path, StringComparison.OrdinalIgnoreCase))
                        {
                            current.Cursor = result;
                            current.Checked = result == null ? 0 : Stopwatch.GetTimestamp();
                            current.Checks++;
                        }
                    }
                }
                Thread.Sleep(PassDelayMilliseconds);
            }
        }

        private static void AddRequest(List<Request> batch, Entry entry)
        {
            batch.Add(new Request { Id = entry.Id, Path = entry.Path, Generation = entry.Generation,
                                    Cursor = entry.Cursor == null ? null : entry.Cursor.Copy() });
        }

        private Cursor Probe(Request request)
        {
            using (SafeFileHandle handle = OpenRead(request.Path))
            using (FileStream file = new FileStream(handle, FileAccess.Read, 4096, false))
            {
                FileIdentity before = Identify(handle, request.Path);
                byte[] header = ReadHeader(file, request.Id);
                Cursor old = request.Cursor;
                if (old == null)
                {
                    byte[] anchor = ReadAnchor(file, before.Length);
                    bool partial = before.Length > 0 && anchor[anchor.Length - 1] != 10;
                    VerifyStillSelected(handle, request.Path, before);
                    return new Cursor { Volume = before.Volume, IndexHigh = before.IndexHigh, IndexLow = before.IndexLow,
                        Offset = before.Length, WriteStamp = before.WriteStamp, Header = header, Anchor = anchor,
                        Partial = new byte[0], SkipBaselinePartial = partial, IdentityToken = MakeIdentityToken(before, header),
                        FileLength = before.Length, LastWriteUtcTicks = DateTime.FromFileTimeUtc(before.WriteStamp).Ticks };
                }
                if (old.Volume != before.Volume || old.IndexHigh != before.IndexHigh || old.IndexLow != before.IndexLow ||
                    before.Length < old.Offset || before.Length - old.Offset > MaximumAppend ||
                    before.WriteStamp < old.WriteStamp || (before.Length == old.Offset && before.WriteStamp != old.WriteStamp) ||
                    !Same(old.Header, header) || !Same(old.Anchor, ReadAnchor(file, old.Offset))) return null;

                long previousOffset = old.Offset;
                byte[] previousAnchor = old.Anchor;
                long available = before.Length - old.Offset;
                int count = (int)Math.Min(available, BytesPerPass);
                byte[] next = new byte[count];
                file.Seek(old.Offset, SeekOrigin.Begin);
                ReadExactly(file, next);
                old.Offset += count;
                old.WriteStamp = before.WriteStamp;
                if (count > 0)
                {
                    // Preserve a prior valid observation while a later append
                    // is partial or the bounded reader is catching up.
                    bool evidence = old.PendingEvidence || old.Observed;
                    List<byte> partial = new List<byte>(old.Partial);
                    foreach (byte value in next)
                    {
                        if (old.SkipBaselinePartial)
                        {
                            if (value == 10) old.SkipBaselinePartial = false;
                            continue;
                        }
                        if (value == 10)
                        {
                            if (partial.Count == 0) return null;
                            byte[] line = partial.ToArray();
                            if (line.Length > 0 && line[line.Length - 1] == 13) Array.Resize(ref line, line.Length - 1);
                            Metadata metadata = Metadata.Parse(line);
                            if (metadata.Type == "event_msg" && metadata.PayloadType == "item_completed" &&
                                String.Equals(metadata.ThreadId, request.Id, StringComparison.Ordinal) &&
                                ValidTurn(metadata.TurnId)) evidence = true;
                            partial.Clear();
                        }
                        else
                        {
                            if (partial.Count >= MaximumLine) return null;
                            partial.Add(value);
                        }
                    }
                    old.Partial = partial.ToArray();
                    old.PendingEvidence = evidence;
                    if (old.SkipBaselinePartial || old.Partial.Length != 0 || old.Offset != before.Length) old.Observed = false;
                    else { old.Observed = old.Observed || old.PendingEvidence; old.PendingEvidence = false; }
                }
                old.Anchor = ReadAnchor(file, old.Offset);
                FileIdentity after = VerifyStillSelected(handle, request.Path, before);
                if (!Same(previousAnchor, ReadAnchor(file, previousOffset)) || !Same(header, ReadHeader(file, request.Id))) return null;
                old.FileLength = after.Length;
                old.LastWriteUtcTicks = DateTime.FromFileTimeUtc(after.WriteStamp).Ticks;
                if (after.Length > before.Length)
                {
                    old.PendingEvidence = old.PendingEvidence || old.Observed;
                    old.Observed = false;
                }
                return old;
            }
        }

        private static byte[] ReadHeader(FileStream file, string id)
        {
            file.Seek(0, SeekOrigin.Begin);
            List<byte> bytes = new List<byte>();
            while (bytes.Count < MaximumHeader)
            {
                int value = file.ReadByte();
                if (value < 0) throw new IOException("Incomplete session header.");
                if (value == 10)
                {
                    byte[] result = bytes.ToArray();
                    Metadata metadata = Metadata.Parse(result);
                    if (metadata.Type != "session_meta" || !String.Equals(metadata.PayloadId, id, StringComparison.Ordinal))
                        throw new IOException("Session header mismatch.");
                    return result;
                }
                bytes.Add((byte)value);
            }
            throw new IOException("Session header too long.");
        }

        private static byte[] ReadAnchor(FileStream file, long offset)
        {
            int count = (int)Math.Min(offset, AnchorLength);
            byte[] data = new byte[count];
            file.Seek(offset - count, SeekOrigin.Begin);
            ReadExactly(file, data);
            return data;
        }

        private static void ReadExactly(FileStream file, byte[] data)
        {
            int offset = 0;
            while (offset < data.Length)
            {
                int count = file.Read(data, offset, data.Length - offset);
                if (count <= 0) throw new IOException("Incomplete read.");
                offset += count;
            }
        }

        private static bool Same(byte[] first, byte[] second)
        {
            if (first == null || second == null || first.Length != second.Length) return false;
            for (int i = 0; i < first.Length; i++) if (first[i] != second[i]) return false;
            return true;
        }

        private static bool ValidId(string value, int maximum, bool colon)
        {
            if (String.IsNullOrEmpty(value) || value.Length > maximum) return false;
            foreach (char c in value)
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                      (c >= '0' && c <= '9') || c == '-' || c == '_' || (colon && c == ':'))) return false;
            return true;
        }

        private static bool ValidTurn(string value)
        {
            if (String.IsNullOrWhiteSpace(value)) return false;
            foreach (char c in value) if (Char.IsControl(c)) return false;
            try { return new UTF8Encoding(false, true).GetByteCount(value) <= 256; }
            catch (EncoderFallbackException) { return false; }
        }

        private const uint GenericRead = 0x80000000;
        private const uint ShareReadWriteDelete = 0x00000007;
        private const uint OpenExisting = 3;
        private const uint OpenReparsePoint = 0x00200000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
                                                        uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleInfo info);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleInfo
        {
            public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        private sealed class FileIdentity
        {
            public uint Volume, IndexHigh, IndexLow;
            public long Length, WriteStamp;
        }

        private static SafeFileHandle OpenRead(string path)
        {
            SafeFileHandle handle = CreateFile(path, GenericRead, ShareReadWriteDelete, IntPtr.Zero, OpenExisting,
                                               OpenReparsePoint, IntPtr.Zero);
            if (handle == null || handle.IsInvalid) { if (handle != null) handle.Dispose(); throw new IOException("Unavailable source."); }
            return handle;
        }

        private static FileIdentity Identify(SafeFileHandle handle, string expectedPath)
        {
            ByHandleInfo info;
            if (!GetFileInformationByHandle(handle, out info) || (info.Attributes & 0x410) != 0 ||
                (info.IndexHigh == 0 && info.IndexLow == 0)) throw new IOException("Unsupported source identity.");
            StringBuilder path = new StringBuilder(32768);
            uint count = GetFinalPathNameByHandle(handle, path, (uint)path.Capacity, 0);
            if (count == 0 || count >= path.Capacity) throw new IOException("Unavailable source path.");
            string final = path.ToString();
            if (final.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) final = @"\\" + final.Substring(8);
            else if (final.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) final = final.Substring(4);
            if (!String.Equals(Path.GetFullPath(final), expectedPath, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Source path changed.");
            ulong length = ((ulong)info.SizeHigh << 32) | info.SizeLow;
            if (length > Int64.MaxValue) throw new IOException("Unsupported source size.");
            return new FileIdentity { Volume = info.Volume, IndexHigh = info.IndexHigh, IndexLow = info.IndexLow,
                Length = (long)length, WriteStamp = unchecked((long)(((ulong)info.WriteHigh << 32) | info.WriteLow)) };
        }

        private static FileIdentity VerifyStillSelected(SafeFileHandle handle, string path, FileIdentity before)
        {
            FileIdentity after = Identify(handle, path);
            if (after.Volume != before.Volume || after.IndexHigh != before.IndexHigh || after.IndexLow != before.IndexLow ||
                after.Length < before.Length || (after.Length == before.Length && after.WriteStamp != before.WriteStamp))
                throw new IOException("Source changed during read.");
            using (SafeFileHandle selected = OpenRead(path))
            {
                FileIdentity actual = Identify(selected, path);
                if (actual.Volume != after.Volume || actual.IndexHigh != after.IndexHigh || actual.IndexLow != after.IndexLow)
                    throw new IOException("Source was replaced.");
            }
            return after;
        }

        public void Dispose() { lock (gate) { disposed = true; entries.Clear(); } }

        // The rollout reader uses this same strict parser before trusting a
        // parent relationship. Duplicate keys make identity ambiguous.
        public static bool HeaderHasUniqueKeys(string json)
        {
            try { Metadata.Parse(new UTF8Encoding(false, true).GetBytes(json)); return true; }
            catch { return false; }
        }

        public static string CaptureHeaderIdentity(string journalPath, string threadId)
        {
            return CaptureMatchingHeaderIdentity(journalPath, threadId, null);
        }

        public static string CaptureMatchingHeaderIdentity(string journalPath, string threadId, byte[] expectedHeader)
        {
            try
            {
                string normalized=Path.GetFullPath(journalPath);
                using (SafeFileHandle handle=OpenRead(normalized))
                using (FileStream file=new FileStream(handle,FileAccess.Read,4096,false))
                {
                    FileIdentity identity=Identify(handle,normalized);
                    byte[] header=ReadHeader(file,threadId);
                    if (expectedHeader != null && !Same(header, expectedHeader)) return "";
                    VerifyStillSelected(handle,normalized,identity);
                    return MakeIdentityToken(identity,header);
                }
            }
            catch { return ""; }
        }

        private static string MakeIdentityToken(FileIdentity identity,byte[] header)
        {
            using (var hash=System.Security.Cryptography.SHA256.Create())
                return identity.Volume.ToString("X8")+identity.IndexHigh.ToString("X8")+identity.IndexLow.ToString("X8")+
                       BitConverter.ToString(hash.ComputeHash(header)).Replace("-","");
        }

        // A strict, bounded JSON reader retains only lifecycle routing fields.
        // It neither returns nor logs arbitrary strings from the journal.
        private sealed class Metadata
        {
            public string Type = "", PayloadType = "", ThreadId = "", TurnId = "", PayloadId = "";
            private bool payloadObject;
            private readonly string text;
            private int at, values;

            private Metadata(string text) { this.text = text; }
            public static Metadata Parse(byte[] data)
            {
                if (data.Length == 0 || data.Length > MaximumLine) throw new FormatException();
                string text = new UTF8Encoding(false, true).GetString(data);
                Metadata parser = new Metadata(text);
                parser.Space(); parser.Object(0, 1); parser.Space();
                if (parser.at != text.Length || String.IsNullOrEmpty(parser.Type)) throw new FormatException();
                if ((parser.Type == "event_msg" || parser.Type == "session_meta") && !parser.payloadObject) throw new FormatException();
                if (parser.Type == "event_msg" && String.IsNullOrEmpty(parser.PayloadType)) throw new FormatException();
                if (parser.Type == "event_msg" && parser.PayloadType == "item_completed" &&
                    (!ValidId(parser.ThreadId, 128, false) || !ValidTurn(parser.TurnId))) throw new FormatException();
                return parser;
            }

            private void Space() { while (at < text.Length && (text[at] == ' ' || text[at] == '\t' || text[at] == '\r' || text[at] == '\n')) at++; }
            private void Require(char expected) { if (at >= text.Length || text[at++] != expected) throw new FormatException(); }
            private void Object(int depth, int scope)
            {
                if (depth > 32) throw new FormatException();
                Require('{'); Space();
                HashSet<string> keys = new HashSet<string>(StringComparer.Ordinal);
                if (at < text.Length && text[at] == '}') { at++; return; }
                while (true)
                {
                    string key = ReadString(true); if (!keys.Add(key)) throw new FormatException();
                    Space(); Require(':'); Space();
                    if (scope == 1 && key == "payload" && at < text.Length && text[at] == '{') { payloadObject = true; Object(depth + 1, 2); }
                    else if (((scope == 1 && key == "type") || (scope == 2 && (key == "type" || key == "thread_id" || key == "turn_id" || key == "id"))) && at < text.Length && text[at] == '"')
                    {
                        string value = ReadString(true);
                        if (scope == 1) Type = value;
                        else if (key == "type") PayloadType = value;
                        else if (key == "thread_id") ThreadId = value;
                        else if (key == "turn_id") TurnId = value;
                        else PayloadId = value;
                    }
                    else Value(depth + 1);
                    Space();
                    if (at < text.Length && text[at] == '}') { at++; return; }
                    Require(','); Space();
                }
            }
            private void Array(int depth)
            {
                if (depth > 32) throw new FormatException();
                Require('['); Space();
                if (at < text.Length && text[at] == ']') { at++; return; }
                while (true) { Value(depth + 1); Space(); if (at < text.Length && text[at] == ']') { at++; return; } Require(','); Space(); }
            }
            private void Value(int depth)
            {
                if (++values > 100000 || depth > 32 || at >= text.Length) throw new FormatException();
                char c = text[at];
                if (c == '{') { Object(depth, 0); return; }
                if (c == '[') { Array(depth); return; }
                if (c == '"') { ReadString(false); return; }
                if (c == 't') { Literal("true"); return; }
                if (c == 'f') { Literal("false"); return; }
                if (c == 'n') { Literal("null"); return; }
                Number();
            }
            private void Literal(string value)
            {
                if (at + value.Length > text.Length || String.CompareOrdinal(text, at, value, 0, value.Length) != 0) throw new FormatException();
                at += value.Length;
            }
            private void Number()
            {
                if (at < text.Length && text[at] == '-') at++;
                if (at >= text.Length) throw new FormatException();
                if (text[at] == '0') at++;
                else { if (text[at] < '1' || text[at] > '9') throw new FormatException(); while (at < text.Length && text[at] >= '0' && text[at] <= '9') at++; }
                if (at < text.Length && text[at] == '.') { at++; Digits(); }
                if (at < text.Length && (text[at] == 'e' || text[at] == 'E')) { at++; if (at < text.Length && (text[at] == '+' || text[at] == '-')) at++; Digits(); }
            }
            private void Digits()
            {
                int start = at; while (at < text.Length && text[at] >= '0' && text[at] <= '9') at++;
                if (at == start) throw new FormatException();
            }
            private string ReadString(bool retain)
            {
                Require('"'); StringBuilder result = retain ? new StringBuilder() : null;
                while (at < text.Length)
                {
                    char c = text[at++];
                    if (c == '"') return retain ? result.ToString() : "";
                    if (c < 32) throw new FormatException();
                    if (c == '\\')
                    {
                        if (at >= text.Length) throw new FormatException();
                        c = text[at++];
                        if (c == 'u')
                        {
                            if (at + 4 > text.Length) throw new FormatException();
                            int code = 0;
                            for (int i = 0; i < 4; i++)
                            {
                                char h = text[at++]; int digit = h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 : h >= 'A' && h <= 'F' ? h - 'A' + 10 : -1;
                                if (digit < 0) throw new FormatException(); code = code * 16 + digit;
                            }
                            c = (char)code;
                        }
                        else if (c == 'b') c = '\b'; else if (c == 'f') c = '\f'; else if (c == 'n') c = '\n';
                        else if (c == 'r') c = '\r'; else if (c == 't') c = '\t';
                        else if (c != '"' && c != '\\' && c != '/') throw new FormatException();
                    }
                    if (retain) { if (result.Length >= 1024) throw new FormatException(); result.Append(c); }
                }
                throw new FormatException();
            }
        }
    }
}
