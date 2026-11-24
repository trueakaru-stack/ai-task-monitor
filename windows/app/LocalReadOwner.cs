using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Management.Automation;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace AITaskMonitor.LocalReadOwner {
    public sealed class PollResult {
        internal PollResult(bool success, object value, Guid generation) {
            Success = success; Value = value; Generation = generation;
        }
        public bool Success { get; private set; }
        public object Value { get; private set; }
        public Guid Generation { get; private set; }
    }

    // This transport is not connected to production sources yet. Its worker
    // must not write source data, spawn processes, or print source content.
    // The UI owns this object; all process, pipe and serialization work stays
    // on a background thread. The protocol accepts only bounded string arrays;
    // the owner copies them before another thread can read them.
    public sealed class Owner : IDisposable {
        private const int MaximumFrame = 16777216;
        private readonly object gate = new object();
        private readonly AutoResetEvent pendingSignal = new AutoResetEvent(false);
        private readonly ManualResetEvent closingSignal = new ManualResetEvent(false);
        private readonly string workerPath;
        private readonly string[] configuration;
        private readonly bool rejectAssignment;
        private readonly Thread thread;
        private Guid generation = Guid.NewGuid();
        private string[] pending;
        private PollResult latest;
        private bool hasPending, busy, closed, exited, broken, cleanupStarted, cleanupFinished, cleanupFailed;
        private string pipeName;
        private int ownedProcessId;
        private NamedPipeServerStream pipe;
        private Process process;
        private SafeFileHandle job;

        public Owner(string workerPath, string[] configuration) : this(workerPath, configuration, false) { }

        // This failure injection can only reject an assignment, never bypass it.
        public Owner(string workerPath, string[] configuration, bool rejectAssignment) {
            if (String.IsNullOrWhiteSpace(workerPath)) throw new ArgumentException("A worker path is required.", "workerPath");
            this.workerPath = Path.GetFullPath(workerPath);
            if (this.workerPath.IndexOf('"') >= 0) throw new ArgumentException("Invalid worker path.", "workerPath");
            this.configuration = CopyArguments(configuration);
            this.rejectAssignment = rejectAssignment;
            thread = new Thread(Work);
            thread.IsBackground = true;
            thread.Name = "AI Task Monitor local source owner";
            thread.Start();
        }

        public bool Request(string[] request) {
            string[] copy = CopyArguments(request);
            lock (gate) {
                if (closed || broken || exited) return false;
                pending = copy;
                hasPending = true;
                if (latest == null) pendingSignal.Set();
                return true;
            }
        }

        public void Invalidate() {
            lock (gate) {
                if (closed) return;
                generation = Guid.NewGuid();
                hasPending = false;
                pending = null;
                latest = null;
            }
        }

        public PollResult TryReceive() {
            lock (gate) {
                if (closed) return null;
                PollResult value = latest;
                latest = null;
                if (value != null && hasPending && !broken) pendingSignal.Set();
                return value;
            }
        }

        public bool IsPolling { get { lock (gate) return busy; } }
        public bool HasPendingRequest { get { lock (gate) return hasPending; } }
        public bool HasExited { get { lock (gate) return exited && cleanupFinished; } }
        public bool CleanupFailed { get { lock (gate) return cleanupFailed; } }
        public bool HasResult { get { lock (gate) return latest != null; } }
        public int OwnedProcessId { get { lock (gate) return ownedProcessId; } }
        public Guid Generation { get { lock (gate) return generation; } }

        public void Dispose() {
            lock (gate) {
                if (closed) return;
                closed = true;
                generation = Guid.NewGuid();
                pending = null;
                latest = null;
                hasPending = false;
                if (!exited) { closingSignal.Set(); pendingSignal.Set(); }
            }
            // Closing a pipe or job can block. Never perform it on the caller.
            ThreadPool.QueueUserWorkItem(delegate { CloseOwnedResources(); });
        }

        private void Work() {
            try {
                lock (gate) { if (closed) return; }
                StartWorker();
                while (true) {
                    int signalled = WaitHandle.WaitAny(new WaitHandle[] { closingSignal, pendingSignal });
                    if (signalled == 0) return;
                    string[] input;
                    Guid requestGeneration;
                    lock (gate) {
                        if (closed) return;
                        if (!hasPending || latest != null) continue;
                        input = pending;
                        pending = null;
                        hasPending = false;
                        busy = true;
                        requestGeneration = generation;
                    }
                    object result = Exchange(input);
                    lock (gate) {
                        busy = false;
                        if (closed) return;
                        if (requestGeneration == generation) latest = new PollResult(true, result, requestGeneration);
                        if (hasPending && latest == null) pendingSignal.Set();
                    }
                }
            } catch (Exception) {
                // Do not expose paths, source data, or exception messages.
                lock (gate) {
                    busy = false;
                    broken = true;
                    hasPending = false;
                    pending = null;
                    if (!closed) latest = new PollResult(false, null, generation);
                }
            } finally {
                CloseOwnedResources();
                lock (gate) { exited = true; pendingSignal.Dispose(); closingSignal.Dispose(); }
            }
        }

        private void StartWorker() {
            string name = "AITaskMonitorLocalRead-" + Guid.NewGuid().ToString("N");
            var security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
            SecurityIdentifier current;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) current = identity.User;
            if (current == null) throw new InvalidOperationException("Current user unavailable.");
            security.AddAccessRule(new PipeAccessRule(current, PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize, AccessControlType.Allow));
            var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous, 4096, 4096, security);
            SafeFileHandle ownedJob = null;
            Process child = null;
            bool transferred = false;
            try {
                ownedJob = Native.CreateJob();
                var start = new ProcessStartInfo();
                start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
                start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + workerPath + "\" -PipeName \"" + name + "\" -ParentId " + Process.GetCurrentProcess().Id.ToString(System.Globalization.CultureInfo.InvariantCulture);
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.WindowStyle = ProcessWindowStyle.Hidden;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                child = Process.Start(start);
                if (child == null) throw new InvalidOperationException("Worker could not start.");
                lock (gate) {
                    if (closed) throw new InvalidOperationException("Owner is closed.");
                    pipe = server; job = ownedJob; process = child;
                    pipeName = name;
                    ownedProcessId = child.Id;
                    transferred = true;
                }
                StartDrain(child.StandardOutput);
                StartDrain(child.StandardError);
                // No configuration or source paths are sent before job assignment.
                if (rejectAssignment || !Native.AssignProcessToJobObject(ownedJob, child.Handle))
                    throw new InvalidOperationException("Worker job assignment failed.");
                IAsyncResult wait = server.BeginWaitForConnection(null, null);
                int ready = WaitHandle.WaitAny(new WaitHandle[] { closingSignal, wait.AsyncWaitHandle }, 10000);
                if (ready != 1) throw new InvalidOperationException("Worker connection unavailable.");
                server.EndWaitForConnection(wait);
                uint client;
                if (!Native.GetNamedPipeClientProcessId(server.SafePipeHandle, out client) || client != (uint)child.Id)
                    throw new InvalidOperationException("Unexpected worker identity.");
            } finally {
                if (!transferred) {
                    try { server.Dispose(); } catch (Exception) { }
                    if (ownedJob != null) { try { ownedJob.Dispose(); } catch (Exception) { } }
                    if (child != null) { try { if (!child.HasExited) child.Kill(); } catch (Exception) { } child.Dispose(); }
                }
            }
        }

        private object Exchange(string[] input) {
            NamedPipeServerStream active;
            lock (gate) { if (closed) throw new InvalidOperationException("Owner is closed."); active = pipe; }
            var envelope = new PSObject();
            envelope.Properties.Add(new PSNoteProperty("Configuration", configuration));
            envelope.Properties.Add(new PSNoteProperty("Request", input));
            string xml = PSSerializer.Serialize(envelope, 24);
            byte[] bytes = new UTF8Encoding(false, true).GetBytes(xml);
            if (bytes.Length <= 0 || bytes.Length > MaximumFrame) throw new InvalidOperationException("Request too large.");
            byte[] length = BitConverter.GetBytes(bytes.Length);
            active.Write(length, 0, length.Length);
            active.Write(bytes, 0, bytes.Length);
            active.Flush();
            byte[] header = ReadExact(active, 4);
            int count = BitConverter.ToInt32(header, 0);
            if (count <= 0 || count > MaximumFrame) throw new InvalidOperationException("Invalid result size.");
            byte[] payload = ReadExact(active, count);
            string response = new UTF8Encoding(false, true).GetString(payload);
            return PSSerializer.Deserialize(response);
        }

        private static byte[] ReadExact(Stream input, int count) {
            byte[] bytes = new byte[count];
            int read = 0;
            while (read < count) {
                int next = input.Read(bytes, read, count - read);
                if (next <= 0) throw new EndOfStreamException();
                read += next;
            }
            return bytes;
        }

        private static void StartDrain(StreamReader stream) {
            ThreadPool.QueueUserWorkItem(delegate {
                try { char[] buffer = new char[1024]; while (stream.Read(buffer, 0, buffer.Length) > 0) { } }
                catch (Exception) { }
            });
        }

        private void CloseOwnedResources() {
            NamedPipeServerStream ownedPipe;
            SafeFileHandle ownedJob;
            Process ownedProcess;
            lock (gate) {
                if (cleanupStarted) return;
                cleanupStarted = true;
                ownedPipe = pipe; pipe = null; ownedJob = job; job = null; ownedProcess = process; process = null;
            }
            bool failed = false;
            if (ownedJob != null) { try { ownedJob.Dispose(); } catch (Exception) { failed = true; } }
            if (ownedPipe != null) { try { ownedPipe.Dispose(); } catch (Exception) { failed = true; } }
            if (ownedProcess != null) {
                try {
                    if (!ownedProcess.HasExited) ownedProcess.Kill();
                    if (!ownedProcess.HasExited && !ownedProcess.WaitForExit(5000)) failed = true;
                } catch (Exception) {
                    try { if (!ownedProcess.HasExited) failed = true; } catch (Exception) { failed = true; }
                }
                try { ownedProcess.Dispose(); } catch (Exception) { failed = true; }
            }
            lock (gate) { cleanupFailed = failed; cleanupFinished = true; }
        }

        private static string[] CopyArguments(string[] values) {
            if (values == null) return new string[0];
            if (values.Length > 32) throw new ArgumentException("Too many arguments.");
            string[] copy = new string[values.Length];
            for (int index = 0; index < values.Length; index++) {
                string value = values[index] ?? "";
                if (value.Length > 32768) throw new ArgumentException("An argument is too long.");
                copy[index] = value;
            }
            return copy;
        }
    }

    internal static class Native {
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits {
            public BasicLimits BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref ExtendedLimits info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)]
        internal static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)]
        internal static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
        internal static SafeFileHandle CreateJob() {
            SafeFileHandle handle = CreateJobObject(IntPtr.Zero, null);
            if (handle.IsInvalid) { handle.Dispose(); throw new InvalidOperationException("Job unavailable."); }
            var info = new ExtendedLimits();
            info.BasicLimitInformation.LimitFlags = 0x00002000;
            if (!SetInformationJobObject(handle, 9, ref info, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) {
                handle.Dispose(); throw new InvalidOperationException("Job policy unavailable.");
            }
            return handle;
        }
    }
}
