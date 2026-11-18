using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

// The journal and directory handles are deliberately kept until cutover ends.
// Existing program files are never deleted; the complete old tree is retained.
internal sealed class SafeInstallSwap : IDisposable
{
    private const uint ReadAttributes = 0x80, Delete = 0x10000;
    private const uint GenericRead = 0x80000000, GenericWrite = 0x40000000;
    private const uint ShareRead = 1, ShareWrite = 2, CreateNew = 1, OpenExisting = 3;
    private const uint BackupSemantics = 0x02000000, OpenReparsePoint = 0x00200000;
    private const uint DirectoryAttribute = 0x10, ReparseAttribute = 0x400;
    private const int FileRenameInfo = 3;
    private const string Header = "AITM-UPGRADE-1";
    private readonly string localDirectory;
    private readonly string installDirectory;
    private readonly FileStream journal;
    private readonly Action<string> checkpoint;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation info);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, IntPtr data, uint size);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
        public uint VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    private sealed class DirectoryHandle : IDisposable
    {
        internal readonly SafeFileHandle Handle;
        internal readonly string Id;
        internal DirectoryHandle(SafeFileHandle handle, FileInformation info)
        {
            Handle = handle;
            Id = info.VolumeSerial.ToString("X8") + info.IndexHigh.ToString("X8") + info.IndexLow.ToString("X8");
        }
        public void Dispose() { Handle.Dispose(); }
    }

    internal string BackupDirectory { get; private set; }
    internal bool Updated { get; private set; }

    internal SafeInstallSwap(string local, string install) : this(local, install, null) { }

    // The optional callback is available to isolated regression harnesses only;
    // the released entry point always uses the constructor above.
    internal SafeInstallSwap(string local, string install, Action<string> testCheckpoint)
    {
        checkpoint = testCheckpoint;
        localDirectory = Path.GetFullPath(local).TrimEnd('\\');
        installDirectory = Path.GetFullPath(install).TrimEnd('\\');
        if (!String.Equals(Path.GetDirectoryName(installDirectory), localDirectory, StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(Path.GetFileName(installDirectory), "AITaskMonitor", StringComparison.Ordinal))
            throw new IOException("Invalid installation directory.");

        string journalPath = Path.Combine(localDirectory, "AITaskMonitor.update-journal");
        SafeFileHandle handle = CreateFile(journalPath, GenericRead | GenericWrite, 0, IntPtr.Zero,
            OpenExisting, OpenReparsePoint, IntPtr.Zero);
        int error = Marshal.GetLastWin32Error();
        bool created = false;
        if (handle.IsInvalid && error == 2)
        {
            handle.Dispose();
            string temporary = Path.Combine(localDirectory, "AITaskMonitor.journal-staging-" + NewId());
            handle = CreateFile(temporary, GenericRead | GenericWrite | Delete, 0, IntPtr.Zero,
                CreateNew, OpenReparsePoint, IntPtr.Zero);
            error = Marshal.GetLastWin32Error();
            created = !handle.IsInvalid;
        }
        if (handle.IsInvalid) { handle.Dispose(); throw BusyError(error); }
        try
        {
            FileInformation info = Information(handle);
            if ((info.Attributes & (DirectoryAttribute | ReparseAttribute)) != 0 || info.Links != 1)
                throw new IOException(InstallerLanguage.Text("Служебный файл обновления недоступен или является ссылкой.", "The update journal is unavailable or is a link."));
            journal = new FileStream(handle, FileAccess.ReadWrite, 4096, false);
            handle = null;
            if (created)
            {
                byte[] header = new UTF8Encoding(false, true).GetBytes(Header + "\n");
                journal.Write(header, 0, 3); journal.Flush(true);
                if (checkpoint != null) checkpoint("journal-partial-header");
                journal.Write(header, 3, header.Length - 3); journal.Flush(true);
                RenameHandle(journal.SafeFileHandle, journalPath);
            }
            Recover();
        }
        catch
        {
            if (handle != null) handle.Dispose();
            if (journal != null) journal.Dispose();
            throw;
        }
    }

    internal static string NewId() { return Guid.NewGuid().ToString("N"); }
    internal string StagePath(string id) { return Path.Combine(localDirectory, "AITaskMonitor.stage-" + id); }
    private string BackupPath(string id) { return Path.Combine(localDirectory, "AITaskMonitor.backup-" + id); }

    // Used while the staging directory is already protected by SafeInstallPaths.
    internal static string ReadStageIdentity(string path)
    {
        using (DirectoryHandle directory = OpenDirectory(path, false, false)) return directory.Id;
    }

    internal void Commit(string id, string expectedStageIdentity)
    {
        if (!ValidId(id) || !ValidIdentity(expectedStageIdentity)) throw new IOException("Invalid update identity.");
        string stage = StagePath(id), backup = BackupPath(id);
        using (DirectoryHandle previous = OpenDirectory(installDirectory, true, true))
        using (DirectoryHandle candidate = OpenDirectory(stage, true, false))
        {
            if (!String.Equals(candidate.Id, expectedStageIdentity, StringComparison.Ordinal))
                throw new IOException(InstallerLanguage.Text("Подготовленная папка установки изменилась; обновление остановлено.", "The prepared installation changed; setup stopped."));
            using (DirectoryHandle existingBackup = OpenDirectory(backup, false, true))
                if (existingBackup != null) throw new IOException("The backup destination already exists.");
            string oldId = previous == null ? "-" : previous.Id;
            Append("OP|" + id + "|" + oldId + "|" + candidate.Id);
            bool movedOld = false, movedStage = false;
            try
            {
                if (previous != null) MonitorProcessCheck.EnsureNotRunning(installDirectory);
                if (previous != null) { Rename(previous, backup); movedOld = true; }
                if (checkpoint != null) checkpoint("after-backup");
                Rename(candidate, installDirectory);
                movedStage = true;
                if (checkpoint != null) checkpoint("after-stage");
            }
            catch (Exception failure)
            {
                if (movedOld || movedStage)
                {
                    try
                    {
                        if (movedStage) Rename(candidate, stage);
                        if (movedOld) Rename(previous, installDirectory);
                    }
                    catch (Exception restore)
                    {
                        throw new IOException(InstallerLanguage.Text(
                            "Не удалось завершить установку или автоматически восстановить её состояние. Проверьте папки: ",
                            "Setup could not finish or automatically restore its previous state. Check these folders: ") + installDirectory + "; " + backup + "; " + stage, new AggregateException(failure, restore));
                    }
                }
                Append("DONE|" + id);
                if (!movedOld && !movedStage && failure is IOException) throw;
                throw new IOException(InstallerLanguage.Text(
                    "Не удалось обновить приложение: файлы заняты или недоступны. Закройте AI task monitor и повторите попытку. Прежние файлы сохранены.",
                    "Could not update the app because files are in use or unavailable. Close AI task monitor and try again. Previous files were preserved."), failure);
            }
            Updated = previous != null;
            BackupDirectory = previous == null ? null : backup;
            Append("DONE|" + id);
        }
    }

    private void Recover()
    {
        if (journal.Length > 4 * 1024 * 1024) throw new IOException("The update journal is too large.");
        journal.Position = 0;
        byte[] data = new byte[(int)journal.Length];
        int n = 0, read;
        while (n < data.Length && (read = journal.Read(data, n, data.Length - n)) > 0) n += read;
        if (n != data.Length) throw new IOException("The update journal could not be read.");
        string text = new UTF8Encoding(false, true).GetString(data);
        int lastNewline = text.LastIndexOf('\n');
        if (lastNewline < 0) throw new IOException("The update journal is incomplete.");
        string complete = text.Substring(0, lastNewline + 1);
        string[] lines = complete.Split('\n');
        if (lines.Length == 0 || lines[0] != Header) throw new IOException("The update journal is not recognized.");
        string id = null, oldId = null, stageId = null;
        for (int i = 1; i < lines.Length - 1; i++)
        {
            string[] fields = lines[i].Split('|');
            if (fields.Length == 4 && fields[0] == "OP" && id == null && ValidId(fields[1]) &&
                (fields[2] == "-" || ValidIdentity(fields[2])) && ValidIdentity(fields[3]))
            { id = fields[1]; oldId = fields[2]; stageId = fields[3]; }
            else if (fields.Length == 2 && fields[0] == "DONE" && fields[1] == id)
            { id = null; oldId = null; stageId = null; }
            else throw new IOException("The update journal is not recognized.");
        }
        string tail = text.Substring(lastNewline + 1);
        if (tail.Length != 0)
        {
            bool partial = id == null ? ValidPartialOperation(tail) : ("DONE|" + id).StartsWith(tail, StringComparison.Ordinal);
            if (!partial) throw new IOException("The update journal contains unrecognized data.");
            // A partial operation record cannot have preceded a filesystem move;
            // a partial DONE record still leaves its complete OP for recovery.
            journal.SetLength(new UTF8Encoding(false, true).GetByteCount(complete));
            journal.Flush(true);
        }
        if (id == null) return;
        string backup = BackupPath(id);
        using (DirectoryHandle current = OpenDirectory(installDirectory, true, true))
        using (DirectoryHandle previous = OpenDirectory(backup, true, true))
        {
            if (oldId == "-")
            {
                if (previous != null || (current != null && current.Id != stageId)) throw RecoveryError(backup);
            }
            else if (current != null && current.Id == oldId && previous == null)
            {
                // The previous installation was never moved, or was restored.
            }
            else if (previous != null && previous.Id == oldId && current == null)
            {
                try { MonitorProcessCheck.EnsureNotRunning(installDirectory); Rename(previous, installDirectory); }
                catch (Exception error) { throw RecoveryError(backup, error); }
            }
            else if (!(previous != null && previous.Id == oldId && current != null && current.Id == stageId))
                throw RecoveryError(backup);
        }
        Append("DONE|" + id);
    }

    private void Append(string line)
    {
        byte[] bytes = new UTF8Encoding(false, true).GetBytes(line + "\n");
        journal.Position = journal.Length;
        journal.Write(bytes, 0, bytes.Length);
        journal.Flush(true);
    }

    private static bool ValidId(string value)
    {
        if (value == null || value.Length != 32) return false;
        foreach (char c in value) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    }
    private static bool ValidPartialOperation(string tail)
    {
        if ("OP|".StartsWith(tail, StringComparison.Ordinal)) return true;
        if (!tail.StartsWith("OP|", StringComparison.Ordinal)) return false;
        string[] parts = tail.Split('|');
        if (parts.Length < 2 || parts.Length > 4 || parts[0] != "OP") return false;
        if (!HexPrefix(parts[1], 32, false) || (parts.Length > 2 && parts[1].Length != 32)) return false;
        if (parts.Length > 2)
        {
            if (parts[2] != "-" && !HexPrefix(parts[2], 24, true)) return false;
            if (parts.Length > 3 && parts[2] != "-" && parts[2].Length != 24) return false;
        }
        return parts.Length < 4 || HexPrefix(parts[3], 24, true);
    }
    private static bool HexPrefix(string value, int maximum, bool uppercase)
    {
        if (value.Length > maximum) return false;
        foreach (char c in value)
            if (!((c >= '0' && c <= '9') || (uppercase ? c >= 'A' && c <= 'F' : c >= 'a' && c <= 'f'))) return false;
        return true;
    }
    private static bool ValidIdentity(string value)
    {
        if (value == null || value.Length != 24) return false;
        foreach (char c in value) if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
        return true;
    }
    private static FileInformation Information(SafeFileHandle handle)
    {
        FileInformation info;
        if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return info;
    }
    private static DirectoryHandle OpenDirectory(string path, bool rename, bool missingAllowed)
    {
        SafeFileHandle handle = CreateFile(path, ReadAttributes | (rename ? Delete : 0), ShareRead | ShareWrite,
            IntPtr.Zero, OpenExisting, BackupSemantics | OpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error(); handle.Dispose();
            if (missingAllowed && (error == 2 || error == 3)) return null;
            throw BusyError(error);
        }
        try
        {
            FileInformation info = Information(handle);
            if ((info.Attributes & DirectoryAttribute) == 0 || (info.Attributes & ReparseAttribute) != 0)
                throw new IOException(InstallerLanguage.Text("Путь установки не является обычной папкой; файлы не изменены.", "The installation path is not an ordinary folder; files were not changed."));
            return new DirectoryHandle(handle, info);
        }
        catch { handle.Dispose(); throw; }
    }
    private static void Rename(DirectoryHandle source, string destination)
    {
        RenameHandle(source.Handle, destination);
    }
    private static void RenameHandle(SafeFileHandle source, string destination)
    {
        byte[] name = Encoding.Unicode.GetBytes(destination);
        int rootOffset = IntPtr.Size == 8 ? 8 : 4;
        int lengthOffset = rootOffset + IntPtr.Size, nameOffset = lengthOffset + 4;
        int size = Math.Max(IntPtr.Size == 8 ? 24 : 12, nameOffset + name.Length + 2);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            for (int i = 0; i < size; i++) Marshal.WriteByte(buffer, i, 0);
            Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
            Marshal.WriteInt32(buffer, lengthOffset, name.Length);
            Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
            if (!SetFileInformationByHandle(source, FileRenameInfo, buffer, (uint)size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static IOException BusyError(int error)
    {
        return new IOException(InstallerLanguage.Text("Не удалось подготовить установку: файлы заняты или недоступны. Закройте AI task monitor и повторите попытку.",
            "Could not prepare setup because files are in use or unavailable. Close AI task monitor and try again."), new Win32Exception(error));
    }
    private static IOException RecoveryError(string backup, Exception inner = null)
    {
        return new IOException(InstallerLanguage.Text("Не удалось автоматически восстановить прежнюю установку. Проверьте сохранённую папку: ",
            "Could not automatically restore the previous installation. Check the preserved folder: ") + backup, inner);
    }
    public void Dispose() { journal.Dispose(); }
}
