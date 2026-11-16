using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("ClaudeFileIdentity.Tests")]
[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("AI Task Monitor")]

namespace AITaskMonitor.Claude;

// The complete 128-bit file ID and 64-bit volume identifier are compared
// only while both file handles are open. They are never emitted or persisted.
internal readonly record struct ClaudeFileIdentity(ulong Volume, ulong First, ulong Second)
{
    internal bool IsUsable => (First != 0 || Second != 0) &&
        (First != ulong.MaxValue || Second != ulong.MaxValue);
}

internal static class ClaudeFileIdentityReader
{
    private const int FileIdInfo = 18;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInformation
    {
        internal ulong Volume;
        internal ulong First;
        internal ulong Second;
    }

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int informationClass,
        out FileIdInformation information, uint size);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        internal uint Attributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeFileHandle ReOpenFile(SafeFileHandle handle, uint access, uint share, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);

    // Metadata-only anchors do not request data read access and permit all
    // sharing. Final symlinks/reparse points and directories are refused.
    internal static SafeFileHandle OpenAnchor(string path)
    {
        if (!OperatingSystem.IsWindows()) throw new IOException("Event source identity is unavailable.");
        SafeFileHandle handle = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (error == 2) throw new FileNotFoundException("Event source not found.");
            if (error == 3) throw new DirectoryNotFoundException("Event source directory not found.");
            if (error == 5) throw new UnauthorizedAccessException("Event source access denied.");
            throw new IOException("Event source metadata could not be opened.");
        }
        try
        {
            if (!GetFileInformationByHandle(handle, out ByHandleFileInformation info) ||
                (info.Attributes & (0x10 | 0x400)) != 0)
                throw new IOException("Event source is not a plain file.");
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }

    // Read the same file object referred to by the metadata anchor. This
    // avoids following a substituted final path between metadata and read.
    internal static FileStream OpenRead(SafeFileHandle anchor)
    {
        SafeFileHandle file = ReOpenFile(anchor, 0x80000000, 7, 0x08000000);
        if (file.IsInvalid)
        {
            file.Dispose();
            throw new IOException("Event source could not be reopened for reading.");
        }
        try { return new FileStream(file, FileAccess.Read, 4096, false); }
        catch { file.Dispose(); throw; }
    }

    internal static ClaudeFileIdentity? Read(SafeFileHandle file)
    {
        if (!OperatingSystem.IsWindows() || file.IsClosed || file.IsInvalid) return null;
        try
        {
            if (!GetFileInformationByHandleEx(file, FileIdInfo, out FileIdInformation result,
                (uint)Marshal.SizeOf<FileIdInformation>())) return null;
            return new ClaudeFileIdentity(result.Volume, result.First, result.Second);
        }
        catch (Exception) { return null; }
    }
}
