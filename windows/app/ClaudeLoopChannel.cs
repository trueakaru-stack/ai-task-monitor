using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace AITaskMonitor.ClaudeLoop
{
    public sealed class LoopEvent
    {
        public string SessionId { get; internal set; }
        public string ToolId { get; internal set; }
        public string Kind { get; internal set; }
        public string Fingerprint { get; internal set; }
        public int? ExitCode { get; internal set; }
        public DateTimeOffset Time { get; internal set; }
    }

    public sealed class LoopBatch
    {
        public bool Gap { get; internal set; }
        public LoopEvent[] Events { get; internal set; }
    }

    // The pipe is local and user-restricted. The hook sends only a fingerprint;
    // commands, working directories and error output never enter the channel.
    public sealed class Channel : IDisposable
    {
        private const int MaximumBytes = 4096;
        private const int MaximumQueued = 2048;
        private static readonly Regex SafeId = new Regex("^[A-Za-z0-9_-]{1,128}$", RegexOptions.CultureInvariant);
        private static readonly Regex SafePipe = new Regex("^[A-Za-z0-9_.-]{1,120}$", RegexOptions.CultureInvariant);
        private readonly object gate = new object();
        private readonly Queue<LoopEvent> events = new Queue<LoopEvent>();
        private readonly byte[] key = new byte[32];
        private readonly string name;
        private readonly PipeSecurity security;
        private readonly Mutex ownership;
        private readonly Thread worker;
        private readonly ManualResetEvent ready = new ManualResetEvent(false);
        private NamedPipeServerStream active;
        private Exception startupError;
        private bool stopping;
        private bool gap;
        private bool disposed;

        public static string UserPipeName()
        {
            string sid = WindowsIdentity.GetCurrent().User.Value;
            using (SHA256 sha = SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(sid));
                return "AITaskMonitor.ClaudeLoop." + BitConverter.ToString(hash, 0, 12).Replace("-", "").ToLowerInvariant();
            }
        }

        public Channel(string pipeName)
        {
            name = String.IsNullOrEmpty(pipeName) ? UserPipeName() : pipeName;
            if (!SafePipe.IsMatch(name)) throw new ArgumentException("Invalid local channel name.");
            SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
            security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier("S-1-5-18"), PipeAccessRights.FullControl, AccessControlType.Allow));
            bool created;
            ownership = new Mutex(true, "Local\\" + name + ".owner", out created);
            if (!created) { ownership.Dispose(); throw new InvalidOperationException("The local channel is already in use."); }
            using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(key);
            worker = new Thread(Serve);
            worker.IsBackground = true;
            worker.Name = "AI Task Monitor Claude loop channel";
            worker.Start();
            if (!ready.WaitOne(2000) || startupError != null)
            {
                Dispose();
                throw new InvalidOperationException("The local channel could not start.", startupError);
            }
        }

        public LoopBatch Drain()
        {
            lock (gate)
            {
                LoopBatch batch = new LoopBatch { Gap = gap, Events = events.ToArray() };
                gap = false;
                events.Clear();
                return batch;
            }
        }

        public bool IsStopped { get { return !worker.IsAlive; } }

        private void Serve()
        {
            bool started = false;
            while (true)
            {
                NamedPipeServerStream pipe = null;
                try
                {
                    lock (gate) { if (stopping) break; }
                    pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous, 4096, 4096, security, HandleInheritability.None);
                    lock (gate)
                    {
                        if (stopping) { pipe.Dispose(); break; }
                        active = pipe;
                    }
                    if (!started) { started = true; ready.Set(); }
                    pipe.WaitForConnection();
                    if (!WriteBounded(pipe, key)) { MarkGap(); continue; }
                    byte[] size = ReadBounded(pipe, 4);
                    if (size == null) { MarkGap(); continue; }
                    int length = BitConverter.ToInt32(size, 0);
                    if (length < 2 || length > MaximumBytes) { MarkGap(); continue; }
                    byte[] payload = ReadBounded(pipe, length);
                    if (payload == null) { MarkGap(); continue; }
                    LoopEvent entry = Parse(payload);
                    Array.Clear(payload, 0, payload.Length);
                    if (entry == null) { MarkGap(); continue; }
                    lock (gate)
                    {
                        if (events.Count >= MaximumQueued) { events.Clear(); gap = true; }
                        events.Enqueue(entry);
                    }
                }
                catch (Exception error)
                {
                    lock (gate)
                    {
                        if (!started && !stopping) startupError = error;
                        else if (!stopping) { events.Clear(); gap = true; }
                        if (!started) ready.Set();
                        if (!started || stopping) break;
                    }
                    // Avoid spinning if the OS repeatedly refuses to recreate the pipe.
                    Thread.Sleep(25);
                }
                finally
                {
                    lock (gate) { if (Object.ReferenceEquals(active, pipe)) active = null; }
                    if (pipe != null) pipe.Dispose();
                }
            }
        }

        private static byte[] ReadBounded(Stream stream, int length)
        {
            byte[] result = new byte[length];
            int offset = 0;
            while (offset < length)
            {
                IAsyncResult pending = stream.BeginRead(result, offset, length - offset, null, null);
                using (WaitHandle completed = pending.AsyncWaitHandle)
                {
                    if (!completed.WaitOne(500)) return null;
                    int count = stream.EndRead(pending);
                    if (count <= 0) return null;
                    offset += count;
                }
            }
            return result;
        }

        private static bool WriteBounded(Stream stream, byte[] data)
        {
            IAsyncResult pending = stream.BeginWrite(data, 0, data.Length, null, null);
            using (WaitHandle completed = pending.AsyncWaitHandle)
            {
                if (!completed.WaitOne(500)) return false;
                stream.EndWrite(pending);
                return true;
            }
        }

        private LoopEvent Parse(byte[] payload)
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaximumBytes;
            Dictionary<string, object> value;
            try { value = serializer.DeserializeObject(Encoding.UTF8.GetString(payload)) as Dictionary<string, object>; }
            catch { return null; }
            if (value == null) return null;
            foreach (string field in value.Keys)
                if (field != "session" && field != "tool" && field != "kind" && field != "fingerprint" && field != "exitCode") return null;
            string session = StringField(value, "session");
            string kind = StringField(value, "kind");
            string tool = StringField(value, "tool");
            if (!SafeId.IsMatch(session) || !new[] { "start", "failed", "success", "edit", "stop", "reset" }.ContainsValue(kind)) return null;
            bool commandEvent = kind == "start" || kind == "failed" || kind == "success";
            if (commandEvent && !SafeId.IsMatch(tool)) return null;
            string fingerprint = "";
            int? code = null;
            if (commandEvent)
            {
                fingerprint = StringField(value, "fingerprint");
                if (!Regex.IsMatch(fingerprint, "^[a-f0-9]{64}$", RegexOptions.CultureInvariant)) return null;
                if (kind == "failed")
                {
                    object rawCode;
                    if (!value.TryGetValue("exitCode", out rawCode) || !(rawCode is int) || (int)rawCode == 0) return null;
                    code = (int)rawCode;
                }
            }
            return new LoopEvent { SessionId = session, ToolId = tool, Kind = kind, Fingerprint = fingerprint, ExitCode = code, Time = DateTimeOffset.UtcNow };
        }

        private static string StringField(Dictionary<string, object> value, string name)
        {
            object result;
            return value.TryGetValue(name, out result) && result is string ? (string)result : "";
        }

        private void MarkGap() { lock (gate) { events.Clear(); gap = true; } }

        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
                stopping = true;
                if (active != null) active.Dispose();
            }
            if (worker != null) worker.Join(2000);
            Array.Clear(key, 0, key.Length);
            try { ownership.ReleaseMutex(); } catch (ApplicationException) { }
            ownership.Dispose();
            ready.Dispose();
        }
    }

    internal static class ArrayExtensions
    {
        internal static bool ContainsValue(this string[] values, string value)
        {
            foreach (string item in values) if (String.Equals(item, value, StringComparison.Ordinal)) return true;
            return false;
        }
    }
}
