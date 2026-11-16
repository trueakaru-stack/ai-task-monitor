using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace AITaskMonitor.CodexHookTransport;

// .NET's named-pipe constructor does not expose PIPE_REJECT_REMOTE_CLIENTS.
// Create one first-instance pipe with an explicit current-user DACL instead.
internal static class LocalPipe
{
    private const uint PipeAccessInbound = 0x00000001;
    private const uint FirstPipeInstance = 0x00080000;
    private const uint FileFlagOverlapped = 0x40000000;
    private const uint RejectRemoteClients = 0x00000008;
    private const uint SddlRevision = 1;

    internal static NamedPipeServerStream Create(string pipeName)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        if (!HookWire.IsValidPipeName(pipeName)) throw new ArgumentException("Invalid pipe name.", nameof(pipeName));
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        string user = identity.User?.Value ?? throw new InvalidOperationException("The current user SID is unavailable.");
        string sddl = $"O:{user}D:P(A;;GA;;;{user})";
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, SddlRevision,
                out IntPtr descriptor, out _))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var attributes = new SecurityAttributes
            {
                Length = Marshal.SizeOf<SecurityAttributes>(),
                SecurityDescriptor = descriptor,
                InheritHandle = false
            };
            SafePipeHandle handle = CreateNamedPipe(@"\\.\pipe\" + pipeName,
                PipeAccessInbound | FirstPipeInstance | FileFlagOverlapped,
                RejectRemoteClients, 1, 0, HookWire.MaximumFrameBytes + 4, 0, ref attributes);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            try { return new NamedPipeServerStream(PipeDirection.In, true, false, handle); }
            catch { handle.Dispose(); throw; }
        }
        finally { _ = LocalFree(descriptor); }
    }

    // Check the actual owner SID before sending metadata. The .NET
    // CurrentUserOnly client compares token owner SIDs, which can be a group
    // rather than the user SID for elevated tokens.
    internal static bool HasCurrentUserOwner(SafePipeHandle handle)
    {
        if (!OperatingSystem.IsWindows()) return false;
        const uint SeKernelObject = 6, OwnerInformation = 1;
        uint result = GetSecurityInfo(handle, SeKernelObject, OwnerInformation,
            out IntPtr owner, out _, out _, out _, out IntPtr descriptor);
        if (result != 0 || descriptor == IntPtr.Zero || owner == IntPtr.Zero)
        {
            if (descriptor != IntPtr.Zero) _ = LocalFree(descriptor);
            return false;
        }
        try
        {
            using WindowsIdentity identity = WindowsIdentity.GetCurrent();
            return identity.User is not null && identity.User.Equals(new SecurityIdentifier(owner));
        }
        finally { _ = LocalFree(descriptor); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr SecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true,
        EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
        string descriptor, uint revision, out IntPtr securityDescriptor, out uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true,
        EntryPoint = "CreateNamedPipeW")]
    private static extern SafePipeHandle CreateNamedPipe(string name, uint openMode,
        uint pipeMode, uint maximumInstances, uint outputBufferSize, int inputBufferSize,
        uint defaultTimeout, ref SecurityAttributes securityAttributes);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint GetSecurityInfo(SafePipeHandle handle, uint objectType, uint securityInformation,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr securityDescriptor);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
