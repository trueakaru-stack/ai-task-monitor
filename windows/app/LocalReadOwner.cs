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
        internal PollResult(bool success, object value, Guid generation, long requestStamp, bool hasRequestStamp) {
            Success = success; Value = value; Generation = generation;
            RequestStamp = requestStamp; HasRequestStamp = hasRequestStamp;
        }
        public bool Success { get; private set; }
        public object Value { get; private set; }
        public Guid Generation { get; private set; }
        public long RequestStamp { get; private set; }
        public bool HasRequestStamp { get; private set; }
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
        private readonly bool rejectAssignment, holdBeforeResume;
        private readonly Thread thread;
        private Guid generation = Guid.NewGuid();
        private string[] pending;
        private long pendingStamp;
        private PollResult latest;
        private bool hasPending, busy, closed, exited, broken, cleanupStarted, cleanupFinished, cleanupFailed, beforeResume;
        private int cleanupFailureCode;
        private string pipeName;
        private int ownedProcessId;
        private NamedPipeServerStream pipe;
        private Worker process;
        private SafeFileHandle job;

        public Owner(string workerPath, string[] configuration) : this(workerPath, configuration, false, false) { }

        // Failure injection can only prevent startup, never bypass job checks.
        public Owner(string workerPath, string[] configuration, bool rejectAssignment) : this(workerPath, configuration, rejectAssignment, false) { }
        public Owner(string workerPath, string[] configuration, bool rejectAssignment, bool holdBeforeResume) {
            if (String.IsNullOrWhiteSpace(workerPath)) throw new ArgumentException("A worker path is required.", "workerPath");
            this.workerPath = Path.GetFullPath(workerPath);
            if (this.workerPath.IndexOf('"') >= 0) throw new ArgumentException("Invalid worker path.", "workerPath");
            this.configuration = CopyArguments(configuration);
            this.rejectAssignment = rejectAssignment;
            this.holdBeforeResume = holdBeforeResume;
            thread = new Thread(Work);
            thread.IsBackground = true;
            thread.Name = "AI Task Monitor local source owner";
            thread.Start();
        }

        public bool Request(string[] request) { return Request(request, 0); }

        public bool Request(string[] request, long stamp) {
            string[] copy = CopyArguments(request);
            lock (gate) {
                if (closed || broken || exited) return false;
                pending = copy;
                pendingStamp = stamp;
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
                pendingStamp = 0;
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
        public int CleanupFailureCode { get { lock (gate) return cleanupFailureCode; } }
        public bool CanReplace { get { lock (gate) return exited && cleanupFinished && !cleanupFailed; } }
        public bool HasResult { get { lock (gate) return latest != null; } }
        public bool IsBeforeResume { get { lock (gate) return beforeResume; } }
        public int OwnedProcessId { get { lock (gate) return ownedProcessId; } }
        public Guid Generation { get { lock (gate) return generation; } }

        public void Dispose() {
            lock (gate) {
                if (closed) return;
                closed = true;
                generation = Guid.NewGuid();
                pending = null;
                pendingStamp = 0;
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
                    long inputStamp;
                    Guid requestGeneration;
                    lock (gate) {
                        if (closed) return;
                        if (!hasPending || latest != null) continue;
                        input = pending;
                        inputStamp = pendingStamp;
                        pending = null;
                        pendingStamp = 0;
                        hasPending = false;
                        busy = true;
                        requestGeneration = generation;
                    }
                    object result = Exchange(input);
                    lock (gate) {
                        busy = false;
                        if (closed) return;
                        if (requestGeneration == generation) latest = new PollResult(true, result, requestGeneration, inputStamp, true);
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
                    pendingStamp = 0;
                    if (!closed) latest = new PollResult(false, null, generation, 0, false);
                }
            } finally {
                CloseOwnedResources();
                lock (gate) { beforeResume = false; exited = true; pendingSignal.Dispose(); closingSignal.Dispose(); }
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
            Worker child = null;
            bool transferred = false;
            try {
                ownedJob = Native.CreateJob();
                // STARTUPINFOEX places the initially suspended worker into the
                // kill-on-close job before its first instruction can execute.
                try { child = Native.StartWorker(ownedJob, workerPath, name); }
                catch (WorkerStartupException error) {
                    if (error.CleanupUnconfirmed) { lock (gate) { cleanupFailed = true; cleanupFailureCode = 6000; } }
                    throw;
                }
                lock (gate) {
                    // Keep the identifier even if close wins before handoff,
                    // so cleanup and its tests can observe this worker.
                    ownedProcessId = child.Id;
                    if (closed) throw new InvalidOperationException("Owner is closed.");
                    pipe = server; job = ownedJob; process = child;
                    pipeName = name;
                    transferred = true;
                }
                bool assigned;
                if (rejectAssignment || !Native.IsProcessInJob(child.ProcessHandle, ownedJob, out assigned) || !assigned)
                    throw new InvalidOperationException("Worker job assignment failed.");
                lock (gate) { if (closed) throw new InvalidOperationException("Owner is closed."); beforeResume = true; }
                if (holdBeforeResume) {
                    closingSignal.WaitOne();
                    throw new InvalidOperationException("Synthetic suspended worker closed.");
                }
                if (Native.ResumeThread(child.ThreadHandle) != 1)
                    throw new InvalidOperationException("Worker resume failed.");
                lock (gate) { beforeResume = false; }
                IAsyncResult wait = server.BeginWaitForConnection(null, null);
                int ready = WaitHandle.WaitAny(new WaitHandle[] { closingSignal, wait.AsyncWaitHandle }, 10000);
                if (ready != 1) throw new InvalidOperationException("Worker connection unavailable.");
                server.EndWaitForConnection(wait);
                uint client;
                if (!Native.GetNamedPipeClientProcessId(server.SafePipeHandle, out client) || client != (uint)child.Id)
                    throw new InvalidOperationException("Unexpected worker identity.");
            } finally {
                if (!transferred) {
                    bool failed = false;
                    try { server.Dispose(); } catch (Exception) { failed = true; }
                    if (ownedJob != null) { try { ownedJob.Dispose(); } catch (Exception) { failed = true; } }
                    int processFailure;
                    if (child != null && !StopOwnedProcess(child, out processFailure)) { failed = true; lock (gate) cleanupFailureCode = processFailure; }
                    if (failed) { lock (gate) cleanupFailed = true; }
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

        private void CloseOwnedResources() {
            NamedPipeServerStream ownedPipe;
            SafeFileHandle ownedJob;
            Worker ownedProcess;
            lock (gate) {
                if (cleanupStarted) return;
                cleanupStarted = true;
                ownedPipe = pipe; pipe = null; ownedJob = job; job = null; ownedProcess = process; process = null;
            }
            bool failed = false;
            if (ownedJob != null) { try { ownedJob.Dispose(); } catch (Exception) { failed = true; cleanupFailureCode = -1; } }
            if (ownedPipe != null) { try { ownedPipe.Dispose(); } catch (Exception) { failed = true; cleanupFailureCode = -2; } }
            int processFailure;
            if (ownedProcess != null && !StopOwnedProcess(ownedProcess, out processFailure)) { failed = true; cleanupFailureCode = processFailure; }
            lock (gate) { cleanupFailed |= failed; cleanupFinished = true; }
        }

        private static bool StopOwnedProcess(Worker ownedProcess, out int failure) {
            bool stopped = false;
            failure = 0;
            try {
                uint state = Native.WaitForSingleObject(ownedProcess.ProcessHandle, 0);
                if (state == 0) stopped = true;
                else if (state == 0x102) {
                    bool terminated = Native.TerminateProcess(ownedProcess.ProcessHandle, 1);
                    int terminateError = terminated ? 0 : Marshal.GetLastWin32Error();
                    // Closing the job can already be terminating this process,
                    // in which case TerminateProcess may return access denied
                    // before the process handle becomes signalled.
                    uint final = Native.WaitForSingleObject(ownedProcess.ProcessHandle, 5000);
                    stopped = final == 0;
                    if (!stopped) failure = terminated ? 2000 + (int)final : 1000 + terminateError;
                } else failure = 3000 + Marshal.GetLastWin32Error();
            } catch (Exception) {
                failure = 4000;
                try { stopped = Native.WaitForSingleObject(ownedProcess.ProcessHandle, 0) == 0; } catch (Exception) { }
            }
            try { ownedProcess.Dispose(); } catch (Exception) { stopped = false; failure = 5000; }
            return stopped;
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

    internal sealed class WorkerStartupException : Exception {
        internal readonly bool CleanupUnconfirmed;
        internal WorkerStartupException(bool cleanupUnconfirmed) : base("Worker startup failed.") { CleanupUnconfirmed = cleanupUnconfirmed; }
    }

    internal sealed class Worker : IDisposable {
        internal readonly int Id;
        internal readonly SafeFileHandle ProcessHandle, ThreadHandle;
        internal Worker(int id, SafeFileHandle process, SafeFileHandle thread) {
            Id = id; ProcessHandle = process; ThreadHandle = thread;
        }
        public void Dispose() {
            try { ThreadHandle.Dispose(); } finally { ProcessHandle.Dispose(); }
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
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct StartupInfo {
            public int Size;
            public string Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XCharacters, YCharacters, Fill, Flags;
            public ushort Show, ReservedSize;
            public IntPtr ReservedPointer, StandardInput, StandardOutput, StandardError;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct StartupInfoEx {
            public StartupInfo Startup;
            public IntPtr Attributes;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo {
            public IntPtr Process, Thread;
            public uint ProcessId, ThreadId;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref ExtendedLimits info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)]
        internal static extern bool IsProcessInJob(SafeFileHandle process, SafeFileHandle job, out bool result);
        [DllImport("kernel32.dll", SetLastError=true)]
        internal static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
        [DllImport("kernel32.dll", SetLastError=true)]
        internal static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll", SetLastError=true)]
        internal static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError=true)]
        internal static extern bool TerminateProcess(SafeFileHandle process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
            bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInfo process);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool CloseHandle(IntPtr handle);
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
        internal static Worker StartWorker(SafeFileHandle job, string workerPath, string pipeName) {
            string executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            string command = "\"" + executable + "\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + workerPath +
                "\" -PipeName \"" + pipeName + "\" -ParentId " + Process.GetCurrentProcess().Id.ToString(System.Globalization.CultureInfo.InvariantCulture);
            IntPtr size = IntPtr.Zero, list = IntPtr.Zero, jobs = IntPtr.Zero;
            bool initialized = false;
            try {
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                if (size == IntPtr.Zero) throw new InvalidOperationException("Process attributes unavailable.");
                list = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(list, 1, 0, ref size))
                    throw new InvalidOperationException("Process attributes unavailable.");
                initialized = true;
                jobs = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobs, job.DangerousGetHandle());
                if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x0002000d), jobs, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                    throw new InvalidOperationException("Creation-time job unavailable.");
                var startup = new StartupInfoEx();
                startup.Startup.Size = Marshal.SizeOf(typeof(StartupInfoEx));
                startup.Attributes = list;
                ProcessInfo child;
                // No handles are inherited. No visible console is created.
                if (!CreateProcessW(executable, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false,
                    0x00080000 | 0x08000000 | 0x00000004, IntPtr.Zero, null, ref startup, out child))
                    throw new InvalidOperationException("Worker could not start in the job.");
                SafeFileHandle processHandle = null, threadHandle = null;
                try {
                    if (child.Process == IntPtr.Zero || child.Thread == IntPtr.Zero || child.ProcessId == 0 || child.ProcessId > Int32.MaxValue)
                        throw new InvalidOperationException("Invalid worker process.");
                    processHandle = new SafeFileHandle(child.Process, true);
                    threadHandle = new SafeFileHandle(child.Thread, true);
                    return new Worker((int)child.ProcessId, processHandle, threadHandle);
                } catch {
                    bool confirmed = false;
                    if (child.Process != IntPtr.Zero) {
                        TerminateProcess(child.Process, 1);
                        confirmed = WaitForSingleObject(child.Process, 5000) == 0;
                        if (processHandle != null) processHandle.Dispose(); else CloseHandle(child.Process);
                    }
                    if (child.Thread != IntPtr.Zero) {
                        if (threadHandle != null) threadHandle.Dispose(); else CloseHandle(child.Thread);
                    }
                    throw new WorkerStartupException(!confirmed);
                }
            } finally {
                if (initialized) DeleteProcThreadAttributeList(list);
                if (list != IntPtr.Zero) Marshal.FreeHGlobal(list);
                if (jobs != IntPtr.Zero) Marshal.FreeHGlobal(jobs);
            }
        }
    }
}
