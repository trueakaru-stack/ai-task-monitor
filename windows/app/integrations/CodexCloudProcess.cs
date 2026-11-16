using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace AITaskMonitor.CodexCloud
{
    // Runs the CLI without reading credentials or retaining its output in logs.
    public sealed class Command : IDisposable
    {
        private readonly object gate = new object();
        private readonly Task<Result> work;
        private Process process;
        private bool cancelled;

        public sealed class Result
        {
            public bool Ok { get; internal set; }
            public string Json { get; internal set; }
        }

        public Command(string executable, string cursor, int timeoutMilliseconds)
        {
            if (String.IsNullOrEmpty(executable) || timeoutMilliseconds < 1 || timeoutMilliseconds > 120000)
                throw new ArgumentException("Invalid command configuration.");
            work = Task.Run(() => Execute(executable, cursor, timeoutMilliseconds));
        }

        public bool Completed { get { return work.IsCompleted; } }

        public Result GetResult()
        {
            if (!work.IsCompleted) return null;
            try { return work.GetAwaiter().GetResult(); }
            catch { return new Result { Ok = false, Json = null }; }
        }

        public void Cancel()
        {
            lock (gate)
            {
                cancelled = true;
                Stop(process);
            }
        }

        public void Dispose() { Cancel(); }

        private Result Execute(string executable, string cursor, int timeoutMilliseconds)
        {
            Process child = null;
            bool started = false;
            CloudWorkingDirectory workspace = null;
            try
            {
                workspace = CloudWorkingDirectory.Create();
                string arguments = "cloud list --json --limit 20";
                if (!String.IsNullOrEmpty(cursor)) arguments += " --cursor " + QuoteArgument(cursor);
                var start = new ProcessStartInfo(executable, arguments) {
                    UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
                    WorkingDirectory = workspace.Path
                };
                child = new Process { StartInfo = start };
                lock (gate)
                {
                    if (cancelled) return new Result { Ok = false };
                    if (!child.Start()) return new Result { Ok = false };
                    started = true;
                    process = child;
                }
                child.StandardInput.Close();
                Task<byte[]> output = ReadBounded(child.StandardOutput.BaseStream, child, 1048576, true);
                Task<byte[]> errors = ReadBounded(child.StandardError.BaseStream, child, 65536, false);
                if (!child.WaitForExit(timeoutMilliseconds)) { Stop(child); return new Result { Ok = false }; }
                if (!Task.WaitAll(new Task[] { output, errors }, 2000)) { Stop(child); return new Result { Ok = false }; }
                lock (gate) { if (cancelled) return new Result { Ok = false }; }
                if (child.ExitCode != 0) return new Result { Ok = false };
                return new Result { Ok = true, Json = new UTF8Encoding(false, true).GetString(output.Result) };
            }
            catch { Stop(child); return new Result { Ok = false }; }
            finally
            {
                lock (gate) { process = null; }
                if (started && workspace != null)
                {
                    try { if (!child.WaitForExit(2000)) workspace.PreventFurtherRuns(); }
                    catch { workspace.PreventFurtherRuns(); }
                }
                if (child != null) child.Dispose();
                if (workspace != null) workspace.Dispose();
            }
        }

        private static async Task<byte[]> ReadBounded(Stream stream, Process child, int maximum, bool keep)
        {
            using (var buffer = new MemoryStream())
            {
                var bytes = new byte[8192];
                int total = 0;
                while (true)
                {
                    int count = await stream.ReadAsync(bytes, 0, bytes.Length).ConfigureAwait(false);
                    if (count == 0) break;
                    total += count;
                    if (total > maximum) { Stop(child); throw new InvalidDataException(); }
                    if (keep) buffer.Write(bytes, 0, count);
                }
                return buffer.ToArray();
            }
        }

        private static void Stop(Process child)
        {
            try { if (child != null && !child.HasExited) child.Kill(); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }

        private static string QuoteArgument(string value)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append('"'); }
                else { result.Append('\\', slashes); result.Append(c); }
                slashes = 0;
            }
            result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }
    }
    // A one-use, non-writable working directory for the child CLI. File handles
    // pin each ancestor, so a path component cannot be renamed after validation.
    // The directory is removed only by its own handle and only if it is empty.
    internal sealed class CloudWorkingDirectory : IDisposable
    {
        private const uint DeleteAccess = 0x00010000;
        private const uint ReadAttributes = 0x00000080;
        private const uint Synchronize = 0x00100000;
        private const uint ShareReadWrite = 0x00000003;
        private const uint OpenExisting = 3;
        private const uint BackupSemantics = 0x02000000;
        private const uint OpenReparse = 0x00200000;
        private const int AccessDenied = 5;
        private readonly System.Collections.Generic.List<Microsoft.Win32.SafeHandles.SafeFileHandle> ancestors =
            new System.Collections.Generic.List<Microsoft.Win32.SafeHandles.SafeFileHandle>();
        private Microsoft.Win32.SafeHandles.SafeFileHandle directory;
        private bool disposed;
        private bool ownsLease;
        private bool blockFurtherRuns;
        // 0: available, 1: workspace in use, 2: cleanup or exit unconfirmed.
        private static int workspaceLease;

        private CloudWorkingDirectory() { }
        internal string Path { get; private set; }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct UnicodeString
        {
            internal ushort Length, MaximumLength;
            internal IntPtr Buffer;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct ObjectAttributes
        {
            internal int Length;
            internal IntPtr RootDirectory, ObjectName;
            internal uint Attributes;
            internal IntPtr SecurityDescriptor, SecurityQualityOfService;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct IoStatusBlock
        {
            internal IntPtr Status;
            internal UIntPtr Information;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        private struct HandleFileInfo
        {
            internal uint Attributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        private static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        private static extern uint GetDriveTypeW(string root);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle, out HandleFileInfo info);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle,
            int infoClass, ref byte value, uint size);

        [System.Runtime.InteropServices.DllImport("ntdll.dll")]
        private static extern int NtCreateFile(out Microsoft.Win32.SafeHandles.SafeFileHandle handle, uint access,
            ref ObjectAttributes attributes, out IoStatusBlock status, IntPtr allocationSize, uint fileAttributes,
            uint sharing, uint disposition, uint options, IntPtr eaBuffer, uint eaLength);

        [System.Runtime.InteropServices.DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);

        internal static CloudWorkingDirectory Create()
        {
            var result = new CloudWorkingDirectory();
            if (System.Threading.Interlocked.CompareExchange(ref workspaceLease, 1, 0) != 0)
                throw new IOException("The cloud workspace is busy or unavailable.");
            result.ownsLease = true;
            try
            {
                result.Initialize();
                return result;
            }
            catch
            {
                result.Dispose();
                throw;
            }
        }

        private void Initialize()
        {
            string temp = System.IO.Path.GetFullPath(System.IO.Path.GetTempPath()).TrimEnd('\\');
            if (temp.Length < 3 || temp[1] != ':' || temp[2] != '\\' ||
                !((temp[0] >= 'A' && temp[0] <= 'Z') || (temp[0] >= 'a' && temp[0] <= 'z')))
                throw new IOException("A local temporary directory is required.");
            string volumeRoot = System.IO.Path.GetPathRoot(temp);
            if (GetDriveTypeW(volumeRoot) != 3)
                throw new IOException("The temporary directory must be on a fixed local drive.");

            var pathChain = new System.Collections.Generic.List<string>();
            for (var item = new DirectoryInfo(temp); item != null; item = item.Parent)
                pathChain.Add(item.FullName);
            pathChain.Reverse();

            for (int i = 0; i < pathChain.Count; i++)
            {
                uint access = ReadAttributes;
                if (i == pathChain.Count - 1) access |= 0x4 | Synchronize; // FILE_ADD_SUBDIRECTORY
                var handle = CreateFileW(pathChain[i], access, ShareReadWrite, IntPtr.Zero,
                    OpenExisting, BackupSemantics | OpenReparse, IntPtr.Zero);
                if (handle.IsInvalid)
                {
                    int error = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                    handle.Dispose();
                    throw new System.ComponentModel.Win32Exception(error);
                }
                ancestors.Add(handle);
                HandleFileInfo info;
                if (!GetFileInformationByHandle(handle, out info) || (info.Attributes & 0x10) == 0 ||
                    (info.Attributes & 0x400) != 0)
                    throw new IOException("Temporary directory ancestry is not a plain directory.");
            }

            System.Security.Principal.SecurityIdentifier user;
            using (var identity = System.Security.Principal.WindowsIdentity.GetCurrent()) { user = identity.User; }
            if (user == null) throw new IOException("Current user is unavailable.");
            var security = new System.Security.AccessControl.DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(user);
            security.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(user,
                System.Security.AccessControl.FileSystemRights.CreateFiles | System.Security.AccessControl.FileSystemRights.CreateDirectories,
                System.Security.AccessControl.InheritanceFlags.None, System.Security.AccessControl.PropagationFlags.None,
                System.Security.AccessControl.AccessControlType.Deny));
            security.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(user,
                System.Security.AccessControl.FileSystemRights.ReadAndExecute | System.Security.AccessControl.FileSystemRights.Delete,
                System.Security.AccessControl.InheritanceFlags.None, System.Security.AccessControl.PropagationFlags.None,
                System.Security.AccessControl.AccessControlType.Allow));

            string name = "aitm-cloud-" + Guid.NewGuid().ToString("N");
            Path = System.IO.Path.Combine(temp, name);
            directory = CreateChild(ancestors[ancestors.Count - 1], name, security);
            HandleFileInfo childInfo;
            if (!GetFileInformationByHandle(directory, out childInfo) || (childInfo.Attributes & 0x10) == 0 ||
                (childInfo.Attributes & 0x400) != 0)
                throw new IOException("New workspace is not a plain directory.");

            using (var byName = CreateFileW(Path, ReadAttributes, 7, IntPtr.Zero,
                OpenExisting, BackupSemantics | OpenReparse, IntPtr.Zero))
            {
                HandleFileInfo namedInfo;
                if (byName.IsInvalid || !GetFileInformationByHandle(byName, out namedInfo) ||
                    namedInfo.Volume != childInfo.Volume || namedInfo.IndexHigh != childInfo.IndexHigh ||
                    namedInfo.IndexLow != childInfo.IndexLow)
                    throw new IOException("Workspace path no longer identifies its directory.");
            }
            RequireDenied(0x2); // FILE_ADD_FILE
            RequireDenied(0x4); // FILE_ADD_SUBDIRECTORY
        }

        private void RequireDenied(uint access)
        {
            using (var probe = CreateFileW(Path, access, 7, IntPtr.Zero,
                OpenExisting, BackupSemantics | OpenReparse, IntPtr.Zero))
            {
                if (!probe.IsInvalid)
                    throw new IOException("Workspace permits file creation.");
                int error = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                if (error != AccessDenied)
                    throw new System.ComponentModel.Win32Exception(error);
            }
        }

        private static Microsoft.Win32.SafeHandles.SafeFileHandle CreateChild(
            Microsoft.Win32.SafeHandles.SafeFileHandle parent, string name,
            System.Security.AccessControl.DirectorySecurity security)
        {
            byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
            var pinned = new System.Runtime.InteropServices.GCHandle();
            IntPtr text = IntPtr.Zero;
            IntPtr unicodePtr = IntPtr.Zero;
            try
            {
                pinned = System.Runtime.InteropServices.GCHandle.Alloc(descriptor, System.Runtime.InteropServices.GCHandleType.Pinned);
                text = System.Runtime.InteropServices.Marshal.StringToHGlobalUni(name);
                unicodePtr = System.Runtime.InteropServices.Marshal.AllocHGlobal(
                    System.Runtime.InteropServices.Marshal.SizeOf(typeof(UnicodeString)));
                var unicode = new UnicodeString {
                    Length = checked((ushort)(name.Length * 2)),
                    MaximumLength = checked((ushort)((name.Length + 1) * 2)),
                    Buffer = text
                };
                System.Runtime.InteropServices.Marshal.StructureToPtr(unicode, unicodePtr, false);
                var attributes = new ObjectAttributes {
                    Length = System.Runtime.InteropServices.Marshal.SizeOf(typeof(ObjectAttributes)),
                    RootDirectory = parent.DangerousGetHandle(), ObjectName = unicodePtr,
                    Attributes = 0x40, SecurityDescriptor = pinned.AddrOfPinnedObject()
                };
                Microsoft.Win32.SafeHandles.SafeFileHandle handle;
                IoStatusBlock status;
                int code = NtCreateFile(out handle, DeleteAccess | ReadAttributes | 0x20 | Synchronize,
                    ref attributes, out status, IntPtr.Zero, 0x10, ShareReadWrite, 2, 1 | 0x20 | OpenReparse,
                    IntPtr.Zero, 0);
                if (code < 0)
                {
                    if (handle != null) handle.Dispose();
                    throw new System.ComponentModel.Win32Exception(unchecked((int)RtlNtStatusToDosError(code)));
                }
                return handle;
            }
            finally
            {
                System.Runtime.InteropServices.Marshal.FreeHGlobal(unicodePtr);
                System.Runtime.InteropServices.Marshal.FreeHGlobal(text);
                if (pinned.IsAllocated) pinned.Free();
            }
        }

        internal void PreventFurtherRuns() { blockFurtherRuns = true; }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            try
            {
                if (directory != null)
                {
                    byte delete = 1;
                    // The operation fails rather than recursively removing unexpected contents.
                    try
                    {
                        if (!SetFileInformationByHandle(directory, 4, ref delete, 1)) blockFurtherRuns = true;
                    }
                    catch { blockFurtherRuns = true; throw; }
                    finally { directory.Dispose(); }
                }
            }
            finally
            {
                try { for (int i = ancestors.Count - 1; i >= 0; i--) ancestors[i].Dispose(); }
                catch { blockFurtherRuns = true; throw; }
                finally
                {
                    if (ownsLease)
                        System.Threading.Interlocked.Exchange(ref workspaceLease, blockFurtherRuns ? 2 : 0);
                }
            }
        }
    }

}
