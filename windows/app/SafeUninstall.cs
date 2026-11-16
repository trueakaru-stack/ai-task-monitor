using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace AITaskMonitor.SafeRemoval
{
    // Open parent directories without delete sharing and delete a verified file
    // through the same handle that was hashed. Never follow reparse points.
    public sealed class Guard : IDisposable
    {
        const uint ListDirectory = 1, GenericRead = 0x80000000, Delete = 0x00010000;
        const uint ShareRead = 1, ShareWrite = 2, OpenExisting = 3;
        const uint BackupSemantics = 0x02000000, OpenReparsePoint = 0x00200000;
        const uint DirectoryAttribute = 0x10, ReparseAttribute = 0x400;
        readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();
        readonly HashSet<string> held = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly string root;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security,
            uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Information information);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass,
            ref byte information, uint bufferSize);

        [StructLayout(LayoutKind.Sequential)]
        struct Information
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        public Guard(string installation)
        {
            root = Normalize(installation);
            string drive = Path.GetPathRoot(root);
            if (drive == null || drive.Length != 3 || drive[1] != ':' || drive[2] != '\\')
                throw new IOException("A local absolute installation path is required.");
            try
            {
                string current = drive;
                Hold(current);
                foreach (string part in root.Substring(drive.Length).Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    current = Path.Combine(current, part);
                    Hold(current);
                }
            }
            catch { Dispose(); throw; }
        }

        static string Normalize(string path)
        {
            string full = Path.GetFullPath(path);
            string drive = Path.GetPathRoot(full);
            if (String.IsNullOrEmpty(drive)) throw new IOException("The path has no root.");
            return full.Length == drive.Length ? drive : full.TrimEnd('\\');
        }

        void Hold(string path)
        {
            string full = Normalize(path);
            if (held.Contains(full)) return;
            SafeFileHandle handle = CreateFile(full, ListDirectory, ShareRead | ShareWrite, IntPtr.Zero,
                OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "A removal directory could not be safely opened.");
            }
            Information info;
            if (!GetFileInformationByHandle(handle, out info))
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "A removal directory could not be inspected.");
            }
            if ((info.Attributes & DirectoryAttribute) == 0 || (info.Attributes & ReparseAttribute) != 0)
            {
                handle.Dispose();
                throw new IOException("A removal directory is redirected or is not a directory.");
            }
            handles.Add(handle);
            held.Add(full);
        }

        string Target(string relative)
        {
            if (String.IsNullOrEmpty(relative) || Path.IsPathRooted(relative) || relative.IndexOf('\\') >= 0)
                throw new IOException("Invalid inventory path.");
            string[] components = relative.Split('/');
            foreach (string component in components)
            {
                if (String.IsNullOrWhiteSpace(component) || component == "." || component == ".." ||
                    component.EndsWith(".", StringComparison.Ordinal) || component.EndsWith(" ", StringComparison.Ordinal) ||
                    component.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                    throw new IOException("Invalid inventory path.");
            }
            string current = root;
            for (int i = 0; i < components.Length - 1; i++)
            {
                current = Path.Combine(current, components[i]);
                Hold(current);
            }
            return Path.Combine(current, components[components.Length - 1]);
        }

        static string Hash(Stream stream)
        {
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
        }

        FileStream OpenKnown(string relative, string expected, bool delete)
        {
            if (expected == null || expected.Length != 64) throw new IOException("Invalid file digest.");
            string path = Target(relative);
            SafeFileHandle handle = CreateFile(path, GenericRead | (delete ? Delete : 0), ShareRead,
                IntPtr.Zero, OpenExisting, OpenReparsePoint, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "An owned file could not be opened for removal.");
            }
            try
            {
                Information info;
                if (!GetFileInformationByHandle(handle, out info))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "An owned file could not be inspected.");
                if ((info.Attributes & (DirectoryAttribute | ReparseAttribute)) != 0 ||
                    (((long)info.SizeHigh << 32) | info.SizeLow) > 134217728)
                    throw new IOException("An owned file is redirected or too large.");
                FileStream stream = new FileStream(handle, FileAccess.Read, 4096, false);
                handle = null;
                try
                {
                    if (!String.Equals(Hash(stream), expected, StringComparison.Ordinal))
                        throw new IOException("An owned file has changed.");
                    stream.Position = 0;
                    return stream;
                }
                catch { stream.Dispose(); throw; }
            }
            finally { if (handle != null) handle.Dispose(); }
        }

        // The returned handle prevents replacement while a child process reads it.
        public FileStream HoldVerified(string relative, string expected)
        {
            return OpenKnown(relative, expected, false);
        }

        public string RemoveVerified(string relative, string expected)
        {
            try
            {
                using (FileStream stream = OpenKnown(relative, expected, true))
                {
                    byte disposition = 1;
                    if (!SetFileInformationByHandle(stream.SafeFileHandle, 4, ref disposition, 1))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "An owned file could not be removed.");
                }
                return "removed";
            }
            catch (Win32Exception error)
            {
                return error.NativeErrorCode == 2 || error.NativeErrorCode == 3 ? "missing" : "unavailable";
            }
            catch { return "unavailable"; }
        }

        public void Dispose()
        {
            for (int i = handles.Count - 1; i >= 0; i--) handles[i].Dispose();
            handles.Clear();
            held.Clear();
        }
    }
}
