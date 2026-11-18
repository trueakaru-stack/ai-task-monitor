using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32.SafeHandles;

internal static class InstallerLanguage
{
    private static bool isRussian = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru";

    internal static void Initialize()
    {
        isRussian = Resolve(Environment.GetEnvironmentVariable("LOCALAPPDATA"));
    }

    internal static bool IsRussian { get { return isRussian; } }
    internal static string Text(string russian, string english) { return isRussian ? russian : english; }

    internal static bool Resolve(string localDirectory)
    {
        bool fallback = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru";
        try
        {
            if (String.IsNullOrEmpty(localDirectory) || !Path.IsPathRooted(localDirectory)) return fallback;
            string local = Path.GetFullPath(localDirectory);
            string folder = Path.Combine(local, "CodexTaskProgress");
            string path = Path.Combine(folder, "settings.json");
            foreach (string part in new[] { local, folder, path })
            {
                FileAttributes attributes = File.GetAttributes(part);
                if ((attributes & FileAttributes.ReparsePoint) != 0) return fallback;
                if (part == path ? (attributes & FileAttributes.Directory) != 0 : (attributes & FileAttributes.Directory) == 0) return fallback;
            }
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                byte[] bytes = new byte[65537];
                int total = 0, count;
                while (total < bytes.Length && (count = stream.Read(bytes, total, bytes.Length - total)) > 0) total += count;
                if (total > 65536) return fallback;
                string json = new UTF8Encoding(false, true).GetString(bytes, 0, total).TrimStart('\uFEFF');
                JavaScriptSerializer serializer = new JavaScriptSerializer { MaxJsonLength = 65536, RecursionLimit = 64 };
                Dictionary<string, object> settings = serializer.DeserializeObject(json) as Dictionary<string, object>;
                object language;
                if (settings == null || !settings.TryGetValue("language", out language)) return fallback;
                string selected = language as string;
                if (String.Equals(selected, "ru", StringComparison.Ordinal)) return true;
                if (String.Equals(selected, "en", StringComparison.Ordinal)) return false;
            }
        }
        catch { }
        return fallback;
    }
}

internal sealed class SafeInstallPaths : IDisposable
{
    private const uint ListDirectory = 0x01;
    private const uint GenericRead = 0x80000000;
    private const uint ShareRead = 1;
    private const uint ShareWrite = 2;
    private const uint OpenExistingDisposition = 3;
    private const uint BackupSemantics = 0x02000000;
    private const uint OpenReparsePoint = 0x00200000;
    private const uint DirectoryAttribute = 0x10;
    private const uint ReparseAttribute = 0x400;
    private readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();
    private readonly HashSet<string> directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectory(string path, IntPtr security);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInfo
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    private SafeInstallPaths() { }

    internal static SafeInstallPaths OpenExisting(string path)
    {
        string full = Normalize(path);
        string root = Path.GetPathRoot(full);
        if (root == null || root.Length != 3 || root[1] != ':' || root[2] != '\\')
            throw new IOException(InstallerLanguage.Text("Путь установки должен находиться на локальном диске.", "The installation path must be on a local drive."));
        SafeInstallPaths guard = new SafeInstallPaths();
        try
        {
            string current = root;
            guard.Hold(current);
            string tail = full.Substring(root.Length);
            foreach (string part in tail.Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
            {
                current = Path.Combine(current, part);
                guard.Hold(current);
            }
            return guard;
        }
        catch { guard.Dispose(); throw; }
    }

    internal static string ExistingInstallMessage(string path)
    {
        if (InstallerLanguage.IsRussian)
            return "Папка установки уже существует. Полностью закройте AI task monitor, Claude Code и другие подключённые программы и их фоновые процессы. Перенесите папку " + path + " в безопасное место, затем повторите установку. Данные в папке CodexTaskProgress не изменяются.";
        return "The installation folder already exists. Quit AI task monitor, Claude Code, other connected programs and their background processes. Move " + path + " to a safe location, then run the installer again. Data in CodexTaskProgress will not be changed.";
    }

    internal static string ClaudeSetupMayHaveChangedMessage()
    {
        if (InstallerLanguage.IsRussian)
            return "\n\nНастройки подключения Claude Code могли измениться. Перед переносом или удалением папки проверьте и отключите подключение AI task monitor в Claude Code.";
        return "\n\nClaude Code connection settings may have changed. Before moving or removing the folder, review and disconnect the AI task monitor integration in Claude Code.";
    }

    internal static string PartialInstallMessage(string path)
    {
        if (InstallerLanguage.IsRussian)
            return "\n\nУстановка могла остаться незавершённой. Проверьте папку " + path + " и при необходимости перенесите её в безопасное место перед повтором.";
        return "\n\nInstallation may be incomplete. Review " + path + " and, if needed, move it to a safe location before retrying.";
    }

    internal void CreateChild(string path)
    {
        string full = Normalize(path);
        RequireHeldParent(full);
        if (!CreateDirectory(full, IntPtr.Zero))
        {
            int error = Marshal.GetLastWin32Error();
            if (error == 80 || error == 183)
                throw new IOException(ExistingInstallMessage(full));
            throw new Win32Exception(error, InstallerLanguage.Text("Не удалось создать новую папку установки.", "Unable to create a new installation folder."));
        }
        Hold(full);
    }

    internal FileStream CreateNewFile(string path)
    {
        string full = Normalize(path);
        RequireHeldParent(full);
        return new FileStream(full, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    }

    internal FileStream OpenPreparedFile(string path)
    {
        string full = Normalize(path);
        RequireHeldParent(full);
        SafeFileHandle handle = CreateFile(full, GenericRead, ShareRead, IntPtr.Zero,
            OpenExistingDisposition, OpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error(); handle.Dispose();
            throw new Win32Exception(error, "Could not verify a prepared installation file.");
        }
        try
        {
            FileInfo info;
            if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if ((info.Attributes & (DirectoryAttribute | ReparseAttribute)) != 0 || info.Links != 1)
                throw new IOException("A prepared installation file is linked or is not a regular file.");
            return new FileStream(handle, FileAccess.Read);
        }
        catch { handle.Dispose(); throw; }
    }

    private void RequireHeldParent(string full)
    {
        string parent = Path.GetDirectoryName(full);
        if (String.IsNullOrEmpty(parent) || !directories.Contains(Normalize(parent)))
            throw new IOException(InstallerLanguage.Text("Родительская папка не защищена для установки.", "The parent directory is not held for the installation."));
    }

    private void Hold(string path)
    {
        string full = Normalize(path);
        SafeFileHandle handle = CreateFile(full, ListDirectory, ShareRead | ShareWrite, IntPtr.Zero,
            OpenExistingDisposition, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, InstallerLanguage.Text("Не удалось безопасно открыть папку установки.", "Unable to open the installation folder safely."));
        }
        FileInfo info;
        if (!GetFileInformationByHandle(handle, out info))
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, InstallerLanguage.Text("Не удалось проверить папку установки.", "Unable to verify the installation folder."));
        }
        if ((info.Attributes & DirectoryAttribute) == 0 || (info.Attributes & ReparseAttribute) != 0)
        {
            handle.Dispose();
            throw new IOException(InstallerLanguage.Text("Путь установки содержит перенаправленную папку. Установка остановлена без перезаписи файлов.", "The installation path contains a redirected folder. Setup stopped without overwriting files."));
        }
        handles.Add(handle);
        directories.Add(full);
    }

    private static string Normalize(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path)) throw new IOException(InstallerLanguage.Text("Путь установки должен быть абсолютным.", "The path is not absolute."));
        string sourceRoot = Path.GetPathRoot(path);
        if (sourceRoot == null || sourceRoot.Length != 3 || sourceRoot[1] != ':' || (sourceRoot[2] != '\\' && sourceRoot[2] != '/'))
            throw new IOException(InstallerLanguage.Text("Путь должен находиться на локальном диске.", "The path must be on a local drive."));
        string full = Path.GetFullPath(path);
        string root = Path.GetPathRoot(full);
        if (String.IsNullOrEmpty(root)) throw new IOException(InstallerLanguage.Text("Путь установки должен быть абсолютным.", "The installation path is not absolute."));
        return full.Length == root.Length ? root : full.TrimEnd('\\');
    }

    public void Dispose()
    {
        for (int i = handles.Count - 1; i >= 0; i--) handles[i].Dispose();
        handles.Clear();
        directories.Clear();
    }
}

internal static class SafeShortcut
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath();
        void GetIDList();
        void SetIDList();
        void GetDescription();
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetWorkingDirectory();
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetArguments();
        void SetArguments();
        void GetHotkey();
        void SetHotkey();
        void GetShowCmd();
        void SetShowCmd();
        void GetIconLocation();
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath();
        void Resolve();
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string value);
    }

    [ComImport, Guid("00000109-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistStream
    {
        void GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.Interface)] IStream stream);
        void Save([MarshalAs(UnmanagedType.Interface)] IStream stream, [MarshalAs(UnmanagedType.Bool)] bool clearDirty);
        void GetSizeMax(out long size);
    }

    [DllImport("ole32.dll")]
    private static extern int CreateStreamOnHGlobal(IntPtr memory, [MarshalAs(UnmanagedType.Bool)] bool deleteOnRelease, out IStream stream);

    internal static byte[] Create(string target, string workingDirectory, string icon)
    {
        object instance = new ShellLink();
        IStream stream = null;
        try
        {
            IShellLinkW link = (IShellLinkW)instance;
            link.SetPath(target);
            link.SetWorkingDirectory(workingDirectory);
            link.SetIconLocation(icon, 0);
            link.SetDescription("AI task monitor");
            Marshal.ThrowExceptionForHR(CreateStreamOnHGlobal(IntPtr.Zero, true, out stream));
            ((IPersistStream)instance).Save(stream, true);
            System.Runtime.InteropServices.ComTypes.STATSTG info;
            stream.Stat(out info, 1);
            if (info.cbSize <= 0 || info.cbSize > 1024 * 1024) throw new IOException("Invalid shortcut length.");
            byte[] data = new byte[(int)info.cbSize];
            stream.Seek(0, 0, IntPtr.Zero);
            IntPtr read = Marshal.AllocHGlobal(sizeof(int));
            try
            {
                stream.Read(data, data.Length, read);
                if (Marshal.ReadInt32(read) != data.Length) throw new IOException("Incomplete shortcut.");
            }
            finally { Marshal.FreeHGlobal(read); }
            return data;
        }
        finally
        {
            if (stream != null) Marshal.FinalReleaseComObject(stream);
            Marshal.FinalReleaseComObject(instance);
        }
    }

    internal static bool TryCreate(string path, string target, string workingDirectory, string icon)
    {
        try
        {
            using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(Path.GetDirectoryName(path)))
            {
                byte[] content = Create(target, workingDirectory, icon);
                using (FileStream file = guard.CreateNewFile(path)) file.Write(content, 0, content.Length);
            }
            return true;
        }
        catch { return false; }
    }
}
