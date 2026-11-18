using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

internal static class MonitorProcessCheck
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    internal static void EnsureNotRunning(string directory)
    {
        string script = Path.GetFullPath(Path.Combine(directory, "CodexProgress.ps1"));
        string hook = Path.GetFullPath(Path.Combine(directory, "ClaudeTaskHook.ps1"));
        string launcher = Path.GetFullPath(Path.Combine(directory, "AI task monitor.exe"));
        try
        {
            int session, ownId;
            using (Process self = Process.GetCurrentProcess()) { session = self.SessionId; ownId = self.Id; }
            string userSid;
            using (WindowsIdentity user = WindowsIdentity.GetCurrent()) userSid = user.User.Value;
            using (ManagementObjectSearcher search = new ManagementObjectSearcher(
                "SELECT ProcessId, Name, CommandLine, ExecutablePath, SessionId FROM Win32_Process WHERE SessionId=" + session +
                " AND (Name='powershell.exe' OR Name='pwsh.exe' OR Name='AI task monitor.exe')"))
            using (ManagementObjectCollection processes = search.Get())
            {
                foreach (ManagementObject process in processes)
                using (process)
                {
                    int id = Convert.ToInt32(process["ProcessId"]);
                    if (id == ownId) continue;
                    string owner = OwnerSid(process);
                    if (!RelevantOwner(owner, userSid)) continue;
                    string name = process["Name"] as string;
                    string command = process["CommandLine"] as string;
                    string executable = process["ExecutablePath"] as string;
                    if (String.Equals(name, "AI task monitor.exe", StringComparison.OrdinalIgnoreCase))
                    {
                        if (SamePath(executable, launcher)) throw Running();
                        continue;
                    }
                    if (MatchesPowerShell(command, script, hook)) throw Running();
                }
            }
        }
        catch (IOException) { throw; }
        catch (Exception error) { throw CannotInspect(error); }
    }

    internal static bool RelevantOwner(string owner, string currentUser)
    {
        return owner == null || String.Equals(owner, currentUser, StringComparison.OrdinalIgnoreCase);
    }
    internal static bool MatchesPowerShell(string command, string script, string hook)
    {
        if (String.IsNullOrEmpty(command)) return false;
        string[] args = Split(command);
        for (int i = 1; i + 1 < args.Length; i++)
        {
            if ((EqualsOption(args[i], "file") || EqualsOption(args[i], "f")) && SamePath(args[i + 1], script)) return true;
            if (EqualsOption(args[i], "encodedcommand") || EqualsOption(args[i], "enc"))
            {
                string decoded = Decode(args[i + 1]);
                string expectedHook = "& '" + hook.Replace("'", "''") + "'";
                if (String.Equals(decoded, expectedHook, StringComparison.OrdinalIgnoreCase)) return true;
            }
        }
        return false;
    }

    private static string OwnerSid(ManagementObject process)
    {
        try
        {
            using (ManagementBaseObject result = process.InvokeMethod("GetOwnerSid", null, null))
                return Convert.ToUInt32(result["ReturnValue"]) == 0 ? result["Sid"] as string : null;
        }
        catch { return null; }
    }
    private static bool EqualsOption(string value, string option)
    {
        return String.Equals(value, "-" + option, StringComparison.OrdinalIgnoreCase) ||
            String.Equals(value, "/" + option, StringComparison.OrdinalIgnoreCase);
    }
    private static bool SamePath(string candidate, string expected)
    {
        if (String.IsNullOrEmpty(candidate)) return false;
        try { return Path.IsPathRooted(candidate) && String.Equals(Path.GetFullPath(candidate), expected, StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }
    private static string Decode(string encoded)
    {
        try
        {
            if (encoded.Length > 131072) return null;
            return new UnicodeEncoding(false, false, true).GetString(Convert.FromBase64String(encoded)).Trim();
        }
        catch { return null; }
    }
    private static string[] Split(string command)
    {
        int count; IntPtr pointer = CommandLineToArgvW(command, out count);
        if (pointer == IntPtr.Zero) throw new IOException("Could not inspect a process command line.");
        try
        {
            if (count < 1 || count > 32768) throw new IOException("Invalid process command line.");
            string[] result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, i * IntPtr.Size));
            return result;
        }
        finally { LocalFree(pointer); }
    }
    private static IOException Running()
    {
        return new IOException(InstallerLanguage.Text("AI task monitor или его активное подключение ещё работает. Закройте его и повторите установку; файлы сохранены.",
            "AI task monitor or an active connection is still running. Close it and try setup again; files were preserved."));
    }
    private static IOException CannotInspect(Exception inner = null)
    {
        return new IOException(InstallerLanguage.Text("Не удалось проверить работающие процессы. Установка остановлена, файлы сохранены.",
            "Setup could not check running processes. Setup stopped and files were preserved."), inner);
    }
}
