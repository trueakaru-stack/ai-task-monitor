using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("ClaudeFileIdentity.Tests")]

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
