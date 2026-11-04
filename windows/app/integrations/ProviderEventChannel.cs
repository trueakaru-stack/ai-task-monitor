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

namespace AITaskMonitor.ExternalProviders
{
    public sealed class EventBatch
    {
        public bool Gap { get; internal set; }
        public Event[] Events { get; internal set; }
    }

    // Local, user-restricted and in-memory. It accepts only sanitized protocol frames.
    public sealed class EventChannel : IDisposable
    {
        private const int MaximumFrameBytes = 65536;
        private const int MaximumQueued = 1024;
        private static readonly Regex SafeName = new Regex("^[A-Za-z0-9_.-]{1,120}$", RegexOptions.CultureInvariant);
        private readonly object gate = new object();
        private readonly Queue<Event> events = new Queue<Event>();
        private readonly Dictionary<string, long> allowed = new Dictionary<string, long>(StringComparer.Ordinal);
        private static readonly HashSet<string> KnownProviders = new HashSet<string>(new[] { "kimi", "deepseek", "hermes", "opencode" }, StringComparer.Ordinal);
        private long permissionSequence;
        private readonly string name;
        private readonly PipeSecurity security;
        private readonly Mutex ownership;
        private readonly Thread worker;
        private readonly ManualResetEvent ready = new ManualResetEvent(false);
        private NamedPipeServerStream active;
        private Exception startupError;
        private bool stopping;
        private bool disposed;
        private bool gap;
        private long acceptedCount, parsedCount, rejectedCount, queuedCount, invalidCount;

        public static string UserPipeName()
        {
            string profile = Environment.GetEnvironmentVariable("USERPROFILE");
            if (String.IsNullOrEmpty(profile)) throw new InvalidOperationException("The user profile is unavailable.");
            using (SHA256 hash = SHA256.Create())
            {
                byte[] digest = hash.ComputeHash(Encoding.UTF8.GetBytes(profile));
                return "AITaskMonitor.ProviderEvents." + BitConverter.ToString(digest, 0, 12).Replace("-", "").ToLowerInvariant();
            }
        }

        public EventChannel(string pipeName)
        {
            name = String.IsNullOrEmpty(pipeName) ? UserPipeName() : pipeName;
            if (!SafeName.IsMatch(name)) throw new ArgumentException("Invalid local channel name.");
            var user = WindowsIdentity.GetCurrent().User;
            security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier("S-1-5-18"), PipeAccessRights.FullControl, AccessControlType.Allow));
            bool created;
            ownership = new Mutex(true, "Local\\" + name + ".owner", out created);
            if (!created) { ownership.Dispose(); throw new InvalidOperationException("The local channel is already in use."); }
            worker = new Thread(Serve) { IsBackground = true, Name = "AI Task Monitor provider event channel" };
            worker.Start();
            if (!ready.WaitOne(2000) || startupError != null)
            {
                Dispose();
                throw new InvalidOperationException("The local channel could not start.", startupError);
            }
        }

        // Keep authorization at the receiving boundary, not only when a batch is consumed.
        // A new generation prevents an in-flight event from an earlier connection from
        // being accepted after that provider is disconnected and reconnected.
        public void SetAllowedProviders(string[] providers)
        {
            var requested = new HashSet<string>(providers ?? new string[0], StringComparer.Ordinal);
            requested.IntersectWith(KnownProviders);
            lock (gate)
            {
                foreach (string provider in new List<string>(allowed.Keys))
                    if (!requested.Contains(provider)) allowed.Remove(provider);
                foreach (string provider in requested)
                    if (!allowed.ContainsKey(provider)) allowed.Add(provider, ++permissionSequence);
                int queued = events.Count;
                for (int i = 0; i < queued; i++)
                {
                    Event entry = events.Dequeue();
                    if (allowed.ContainsKey(entry.Provider)) events.Enqueue(entry);
                }
            }
        }

        public EventBatch Drain()
        {
            lock (gate)
            {
                var batch = new EventBatch { Gap = gap, Events = events.ToArray() };
                events.Clear();
                gap = false;
                return batch;
            }
        }

        public bool IsStopped { get { return !worker.IsAlive; } }
        public string DiagnosticCounts
        {
            get { return String.Format("accepted={0}, parsed={1}, rejected={2}, queued={3}, invalid={4}",
                Interlocked.Read(ref acceptedCount), Interlocked.Read(ref parsedCount), Interlocked.Read(ref rejectedCount),
                Interlocked.Read(ref queuedCount), Interlocked.Read(ref invalidCount)); }
        }

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
                    Dictionary<string, long> allowedAtAccept;
                    lock (gate) { allowedAtAccept = new Dictionary<string, long>(allowed, StringComparer.Ordinal); }
                    Interlocked.Increment(ref acceptedCount);
                    byte[] header = ReadBounded(pipe, 4);
                    if (header == null) { MarkGap(); continue; }
                    int length = BitConverter.ToInt32(header, 0);
                    if (length < 2 || length > MaximumFrameBytes) { MarkGap(); continue; }
                    byte[] payload = ReadBounded(pipe, length);
                    if (payload == null) { MarkGap(); continue; }
                    Event entry;
                    try { entry = EventParser.Parse(new UTF8Encoding(false, true).GetString(payload)); }
                    catch (DecoderFallbackException) { entry = null; }
                    Array.Clear(payload, 0, payload.Length);
                    if (entry == null) { MarkGap(); continue; }
                    Interlocked.Increment(ref parsedCount);
                    entry.ObservedAt = DateTimeOffset.UtcNow;
                    bool queued = false;
                    lock (gate)
                    {
                        long acceptedGeneration, currentGeneration;
                        if (!allowedAtAccept.TryGetValue(entry.Provider, out acceptedGeneration) ||
                            !allowed.TryGetValue(entry.Provider, out currentGeneration) ||
                            acceptedGeneration != currentGeneration) Interlocked.Increment(ref rejectedCount);
                        else
                        {
                            if (events.Count >= MaximumQueued) { events.Clear(); gap = true; }
                            events.Enqueue(entry);
                            queued = true;
                            Interlocked.Increment(ref queuedCount);
                        }
                    }
                    // A successful write alone does not prove that the server
                    // received the frame; acknowledge only after processing it.
                    try { pipe.WriteByte(0x06); pipe.Flush(); }
                    catch (IOException) { if (queued) MarkGap(); }
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
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(500);
            while (offset < length)
            {
                IAsyncResult pending = stream.BeginRead(result, offset, length - offset, null, null);
                using (WaitHandle completed = pending.AsyncWaitHandle)
                {
                    TimeSpan remaining = deadline - DateTime.UtcNow;
                    if (remaining <= TimeSpan.Zero || !completed.WaitOne(remaining)) return null;
                    int count = stream.EndRead(pending);
                    if (count <= 0) return null;
                    offset += count;
                }
            }
            return result;
        }

        private void MarkGap() { Interlocked.Increment(ref invalidCount); lock (gate) { events.Clear(); gap = true; } }

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
            try { ownership.ReleaseMutex(); } catch (ApplicationException) { }
            ownership.Dispose();
            ready.Dispose();
        }
    }
}
