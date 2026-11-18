using System;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

internal static class TestSafeInstallSwap
{
    private static string root;
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static string Install(string local) { return Path.Combine(local, "AITaskMonitor"); }
    private static string TextAt(string directory, string name) { return File.ReadAllText(Path.Combine(directory, name)); }
    private static void Write(string directory, string name, string value)
    {
        Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, name), value);
    }
    private static string NewCase(string name)
    {
        string path = Path.Combine(root, name);
        Check(!Directory.Exists(path), "Test case already exists.");
        Directory.CreateDirectory(path);
        return path;
    }
    private static string Stage(SafeInstallSwap swap, string id, string text)
    {
        string stage = swap.StagePath(id);
        Write(stage, "program.txt", text);
        return SafeInstallSwap.ReadStageIdentity(stage);
    }
    private static void SetupOld(string local)
    {
        Write(Install(local), "program.txt", "old");
        Write(Install(local), "foreign.txt", "keep");
        Write(Path.Combine(local, "CodexTaskProgress"), "settings.json", "preferences");
    }
    private static void CheckOld(string local)
    {
        Check(TextAt(Install(local), "program.txt") == "old", "Previous program was not restored.");
        Check(TextAt(Install(local), "foreign.txt") == "keep", "Foreign data was not restored.");
        Check(TextAt(Path.Combine(local, "CodexTaskProgress"), "settings.json") == "preferences", "Preferences changed.");
    }
    private static void ExistingAndRepeated()
    {
        string local = NewCase("existing"), target = Install(local); SetupOld(local);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new");
            swap.Commit(id, identity);
            Check(swap.Updated && TextAt(target, "program.txt") == "new", "Existing installation was not updated.");
            Check(TextAt(swap.BackupDirectory, "program.txt") == "old" && TextAt(swap.BackupDirectory, "foreign.txt") == "keep", "Full backup was not preserved.");
            Check(TextAt(Path.Combine(local, "CodexTaskProgress"), "settings.json") == "preferences", "Preferences changed.");
        }
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new again");
            swap.Commit(id, identity);
            Check(TextAt(target, "program.txt") == "new again" && TextAt(swap.BackupDirectory, "program.txt") == "new", "Repeated update failed.");
        }
        Check(Directory.GetDirectories(local, "AITaskMonitor.backup-*").Length == 2, "Repeated updates did not retain both backups.");
    }
    private static void Fresh()
    {
        string local = NewCase("fresh"), target = Install(local);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "fresh");
            swap.Commit(id, identity);
            Check(!swap.Updated && swap.BackupDirectory == null && TextAt(target, "program.txt") == "fresh", "Fresh installation failed.");
        }
    }
    private static void Busy()
    {
        string local = NewCase("busy"), target = Install(local); SetupOld(local);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new");
            bool refused = false;
            using (FileStream busy = new FileStream(Path.Combine(target, "program.txt"), FileMode.Open, FileAccess.Read, FileShare.None))
            {
                try { swap.Commit(id, identity); } catch (IOException) { refused = true; }
                Check(refused, "An open file did not block the switch.");
            }
            CheckOld(local);
            swap.Commit(id, identity);
            Check(TextAt(target, "program.txt") == "new", "Retry after releasing a file failed.");
        }
    }
    private static void RunningProcess()
    {
        string local = NewCase("running"), target = Install(local); SetupOld(local);
        ProcessStartInfo start = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--cwd-child");
        start.WorkingDirectory = target; start.UseShellExecute = false; start.CreateNoWindow = true;
        start.RedirectStandardInput = true; start.RedirectStandardOutput = true;
        using (Process child = Process.Start(start))
        {
            try
            {
                Check(child.StandardOutput.ReadLine() == "READY" && !child.HasExited, "The fixture process did not enter its working directory.");
                using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
                using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
                {
                    string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new");
                    bool refused = false;
                    try { swap.Commit(id, identity); } catch (IOException) { refused = true; }
                    Check(refused, "An active process in the installation directory did not block the switch.");
                }
                CheckOld(local);
            }
            finally { child.StandardInput.Close(); if (!child.WaitForExit(5000)) { child.Kill(); child.WaitForExit(); } }
        }
    }
    private static void RunningPowerShellMonitor()
    {
        string local = NewCase("powershell-monitor"), target = Install(local); SetupOld(local);
        string script = Path.Combine(target, "CodexProgress.ps1");
        File.WriteAllText(script, "[Console]::Out.WriteLine('READY'); [Console]::Out.Flush(); $null = [Console]::In.ReadLine()\n");
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        ProcessStartInfo start = new ProcessStartInfo(powershell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\"");
        start.WorkingDirectory = local; start.UseShellExecute = false; start.CreateNoWindow = true;
        start.RedirectStandardInput = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
        start.EnvironmentVariables["DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"] = "0";
        using (Process child = Process.Start(start))
        {
            try
            {
                Check(child.StandardOutput.ReadLine() == "READY", "The isolated PowerShell monitor did not start.");
                using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
                using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
                {
                    string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new");
                    bool refused = false;
                    try { swap.Commit(id, identity); }
                    catch (IOException error) { refused = error.Message.Contains("работает") || error.Message.Contains("running"); }
                    Check(refused, "The active PowerShell monitor was not detected by its exact script path.");
                }
                CheckOld(local);
            }
            finally { child.StandardInput.Close(); if (!child.WaitForExit(5000)) { child.Kill(); child.WaitForExit(); } }
        }
    }
    private static void OtherProcessInspection()
    {
        string script = @"C:\synthetic\AITaskMonitor\CodexProgress.ps1";
        string hook = @"C:\synthetic\AITaskMonitor\ClaudeTaskHook.ps1";
        Check(!MonitorProcessCheck.RelevantOwner("S-1-5-18", "S-1-5-21-42"), "Another user's process was treated as current-user process.");
        Check(!MonitorProcessCheck.MatchesPowerShell(null, script, hook), "An inaccessible unrelated command was treated as a running monitor.");
        Check(MonitorProcessCheck.MatchesPowerShell("powershell.exe -NoProfile -File \"" + script + "\"", script, hook), "The monitor command was not recognized.");
        string encoded = Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes("& '" + hook + "'"));
        Check(MonitorProcessCheck.MatchesPowerShell("powershell.exe -EncodedCommand " + encoded, script, hook), "The encoded hook was not recognized.");
    }
    private static void Rollback()
    {
        string local = NewCase("rollback"), target = Install(local); SetupOld(local);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target, delegate(string checkpoint)
        { if (checkpoint == "after-backup") throw new IOException("synthetic failure"); }))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new"); bool refused = false;
            try { swap.Commit(id, identity); } catch (IOException) { refused = true; }
            Check(refused && Directory.Exists(swap.StagePath(id)), "The simulated failure did not retain staging.");
        }
        CheckOld(local);
    }
    private static void CrashChild(string local, string phase)
    {
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, Install(local), delegate(string point)
        { if (point == phase) Environment.Exit(73); }))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new");
            swap.Commit(id, identity);
        }
        throw new Exception("The crash checkpoint was not reached.");
    }
    private static void CrashRecovery(string name, string phase, bool expectNew)
    {
        string local = NewCase(name), target = Install(local); SetupOld(local);
        string exe = Process.GetCurrentProcess().MainModule.FileName;
        ProcessStartInfo start = new ProcessStartInfo(exe, "--crash \"" + local + "\" " + phase);
        start.UseShellExecute = false; start.CreateNoWindow = true; start.WorkingDirectory = local;
        using (Process child = Process.Start(start))
            Check(child.WaitForExit(15000) && child.ExitCode == 73, "The abrupt-termination fixture did not reach its checkpoint.");
        Check(Directory.GetDirectories(local, "AITaskMonitor.backup-*").Length == 1, "Interrupted installation lost its backup.");
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target)) { }
        if (expectNew)
        {
            Check(TextAt(target, "program.txt") == "new", "Completed switch was not recognized after interruption.");
            string backup = Directory.GetDirectories(local, "AITaskMonitor.backup-*")[0];
            Check(TextAt(backup, "foreign.txt") == "keep", "Interrupted switch lost foreign data.");
        }
        else CheckOld(local);
        Check(TextAt(Path.Combine(local, "CodexTaskProgress"), "settings.json") == "preferences", "Interrupted switch changed preferences.");
    }
    private static void CrashDuringJournalCreation()
    {
        string local = NewCase("crash-journal"), target = Install(local); SetupOld(local);
        string exe = Process.GetCurrentProcess().MainModule.FileName;
        ProcessStartInfo start = new ProcessStartInfo(exe, "--crash \"" + local + "\" journal-partial-header");
        start.UseShellExecute = false; start.CreateNoWindow = true; start.WorkingDirectory = local;
        using (Process child = Process.Start(start))
            Check(child.WaitForExit(15000) && child.ExitCode == 73, "The journal-creation interruption did not occur.");
        Check(!File.Exists(Path.Combine(local, "AITaskMonitor.update-journal")), "An incomplete journal was published.");
        CheckOld(local);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new");
            swap.Commit(id, identity);
            Check(TextAt(target, "program.txt") == "new" && TextAt(swap.BackupDirectory, "foreign.txt") == "keep", "Retry after interrupted journal creation failed.");
        }
    }
    private static void UnknownJournal()
    {
        string local = NewCase("unknown-journal"), target = Install(local); SetupOld(local);
        string journal = Path.Combine(local, "AITaskMonitor.update-journal");
        foreach (string content in new[] { "", "AITM-UPG", "unrelated user data", "AITM-UPGRADE-1\nforeign bytes", "AITM-UPGRADE-1\n\nOP|broken" })
        {
            File.WriteAllText(journal, content); byte[] before = File.ReadAllBytes(journal); bool blocked = false;
            try { using (SafeInstallSwap swap = new SafeInstallSwap(local, target)) { } } catch (IOException) { blocked = true; }
            Check(blocked && Convert.ToBase64String(File.ReadAllBytes(journal)) == Convert.ToBase64String(before), "An unknown journal was overwritten or accepted.");
            CheckOld(local);
        }
    }
    private static void PartialJournalPreserved()
    {
        string local = NewCase("partial-journal"), target = Install(local); SetupOld(local);
        string journal = Path.Combine(local, "AITaskMonitor.update-journal");
        byte[] original = System.Text.Encoding.UTF8.GetBytes("AITM-UPGRADE-1\nOP|");
        File.WriteAllBytes(journal, original);
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            Check(!String.IsNullOrEmpty(swap.PreservedJournalPath) && File.Exists(swap.PreservedJournalPath), "The original journal was not preserved.");
            Check(Convert.ToBase64String(File.ReadAllBytes(swap.PreservedJournalPath)) == Convert.ToBase64String(original), "The preserved journal differs from the original bytes.");
        }
        CheckOld(local);
    }
    private static void PartialJournalBackupDenied()
    {
        string local = NewCase("partial-journal-backup-denied"), target = Install(local); SetupOld(local);
        string journal = Path.Combine(local, "AITaskMonitor.update-journal");
        byte[] original = System.Text.Encoding.UTF8.GetBytes("AITM-UPGRADE-1\nOP|"); File.WriteAllBytes(journal, original);
        DirectorySecurity previous = Directory.GetAccessControl(local);
        DirectorySecurity restricted = Directory.GetAccessControl(local);
        SecurityIdentifier sid = WindowsIdentity.GetCurrent().User;
        restricted.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.CreateFiles, AccessControlType.Deny));
        try
        {
            Directory.SetAccessControl(local, restricted);
            bool blocked = false;
            try { using (SafeInstallSwap swap = new SafeInstallSwap(local, target)) { } } catch (IOException) { blocked = true; }
            Check(blocked && Convert.ToBase64String(File.ReadAllBytes(journal)) == Convert.ToBase64String(original), "A journal was changed when its backup could not be created.");
            CheckOld(local);
        }
        finally { Directory.SetAccessControl(local, previous); }
    }
    private static void ChangedStage()
    {
        string local = NewCase("changed-stage"), target = Install(local); SetupOld(local);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new"), stage = swap.StagePath(id);
            Directory.Move(stage, stage + "-preserved"); Write(stage, "program.txt", "different");
            bool refused = false; try { swap.Commit(id, identity); } catch (IOException) { refused = true; }
            Check(refused && TextAt(stage, "program.txt") == "different", "Changed stage was accepted or modified.");
        }
        CheckOld(local);
    }
    private static void Collision()
    {
        string local = NewCase("collision"), target = Install(local); SetupOld(local);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target, delegate(string point)
        { if (point == "after-backup") { Write(target, "foreign.txt", "newcomer"); throw new IOException("collision"); } }))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new"); bool refused = false;
            try { swap.Commit(id, identity); } catch (IOException) { refused = true; }
            Check(refused && TextAt(target, "foreign.txt") == "newcomer", "The foreign collision was overwritten.");
            string[] backups = Directory.GetDirectories(local, "AITaskMonitor.backup-*");
            Check(backups.Length == 1 && TextAt(backups[0], "program.txt") == "old", "The old installation was lost on collision.");
        }
        bool blocked = false;
        try { using (SafeInstallSwap recovery = new SafeInstallSwap(local, target)) { } } catch (IOException) { blocked = true; }
        Check(blocked && TextAt(target, "foreign.txt") == "newcomer", "Recovery overwrote a foreign collision.");
    }
    private static void ConcurrentAndFile()
    {
        string local = NewCase("concurrent"), target = Install(local); SetupOld(local);
        using (SafeInstallSwap first = new SafeInstallSwap(local, target))
        {
            bool blocked = false; try { using (SafeInstallSwap other = new SafeInstallSwap(local, target)) { } } catch (IOException) { blocked = true; }
            Check(blocked, "A parallel installer was not blocked.");
        }
        string otherLocal = NewCase("file-target"), otherTarget = Install(otherLocal);
        File.WriteAllText(otherTarget, "unrelated file");
        using (SafeInstallSwap swap = new SafeInstallSwap(otherLocal, otherTarget))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new"); bool blocked = false;
            try { swap.Commit(id, identity); } catch (IOException) { blocked = true; }
            Check(blocked && File.ReadAllText(otherTarget) == "unrelated file", "A file at the installation path was modified.");
        }
    }
    private static void Junction(string link, string destination)
    {
        string cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
        ProcessStartInfo start = new ProcessStartInfo(cmd, "/d /q /c mklink /J \"" + link + "\" \"" + destination + "\"");
        start.UseShellExecute = false; start.CreateNoWindow = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
        using (Process process = Process.Start(start))
        {
            string output = process.StandardOutput.ReadToEnd(); string errors = process.StandardError.ReadToEnd();
            Check(process.WaitForExit(10000) && process.ExitCode == 0, "Could not create a fixture junction: " + output + errors);
        }
        Check((File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0, "The fixture is not a junction.");
    }
    private static void Junctions()
    {
        string local = NewCase("root-junction"), target = Install(local), outside = Path.Combine(local, "outside");
        Write(outside, "sentinel.txt", "outside"); Junction(target, outside);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new"); bool blocked = false;
            try { swap.Commit(id, identity); } catch (IOException) { blocked = true; }
            Check(blocked && TextAt(outside, "sentinel.txt") == "outside", "A root junction was followed or modified.");
        }
        local = NewCase("nested-junction"); target = Install(local); SetupOld(local);
        outside = Path.Combine(local, "outside"); Write(outside, "sentinel.txt", "outside");
        Junction(Path.Combine(target, "linked"), outside);
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        using (SafeInstallSwap swap = new SafeInstallSwap(local, target))
        {
            string id = SafeInstallSwap.NewId(), identity = Stage(swap, id, "new"); swap.Commit(id, identity);
            Check((File.GetAttributes(Path.Combine(swap.BackupDirectory, "linked")) & FileAttributes.ReparsePoint) != 0 &&
                TextAt(outside, "sentinel.txt") == "outside", "A nested junction or its external target was changed.");
        }
    }
    private static void PreparedFileLinks()
    {
        string local = NewCase("prepared-file-links"), stage = Path.Combine(local, "stage"), outside = Path.Combine(local, "outside.txt");
        File.WriteAllText(outside, "outside");
        using (SafeInstallPaths guard = SafeInstallPaths.OpenExisting(local))
        {
            guard.CreateChild(stage);
            string good = Path.Combine(stage, "good.txt"); File.WriteAllText(good, "prepared");
            using (StreamReader reader = new StreamReader(guard.OpenPreparedFile(good))) Check(reader.ReadToEnd() == "prepared", "A normal prepared file could not be verified.");
            string link = Path.Combine(stage, "linked.txt");
            string cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
            ProcessStartInfo start = new ProcessStartInfo(cmd, "/d /q /c mklink /H \"" + link + "\" \"" + outside + "\"");
            start.UseShellExecute = false; start.CreateNoWindow = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
            using (Process process = Process.Start(start))
            {
                string output = process.StandardOutput.ReadToEnd(), errors = process.StandardError.ReadToEnd();
                Check(process.WaitForExit(10000) && process.ExitCode == 0, "Could not create a fixture hard link: " + output + errors);
            }
            bool blocked = false;
            try { using (FileStream file = guard.OpenPreparedFile(link)) { } } catch (IOException) { blocked = true; }
            Check(blocked && File.ReadAllText(outside) == "outside", "A linked prepared file was accepted or its target changed.");
        }
    }
    private static void Shortcuts()
    {
        string local = NewCase("shortcuts"), programs = Path.Combine(local, "programs"), install = Path.Combine(local, "app");
        Directory.CreateDirectory(programs); Directory.CreateDirectory(install);
        string launcher = Path.Combine(install, "AI task monitor.exe"), icon = Path.Combine(install, "icon.ico");
        File.WriteAllText(launcher, "fixture"); File.WriteAllText(icon, "fixture");
        string shortcut = Path.Combine(programs, "AI task monitor.lnk"), alternate = Path.Combine(programs, "AI task monitor (new).lnk");
        Check(SafeShortcut.TryCreate(shortcut, launcher, install, icon), "Could not create a fixture shortcut.");
        byte[] original = File.ReadAllBytes(shortcut);
        Check(SafeShortcut.TargetsCurrentLauncher(shortcut, launcher), "An existing matching shortcut was not recognized.");
        Check(!SafeShortcut.TargetsCurrentLauncher(shortcut, Path.Combine(install, "different.exe")), "A foreign shortcut was incorrectly accepted.");
        Check(!SafeShortcut.TryCreate(shortcut, launcher, install, icon), "A pre-existing shortcut was overwritten.");
        Check(Convert.ToBase64String(original) == Convert.ToBase64String(File.ReadAllBytes(shortcut)), "A pre-existing shortcut changed.");
        Check(SafeShortcut.TryCreate(alternate, launcher, install, icon) && SafeShortcut.TargetsCurrentLauncher(alternate, launcher), "The alternate shortcut was not recognized.");
        string withArguments = Path.Combine(programs, "shortcut-with-arguments.lnk");
        Type shellType = Type.GetTypeFromProgID("WScript.Shell"); object shell = Activator.CreateInstance(shellType);
        object link = shellType.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { withArguments });
        try
        {
            Type linkType = link.GetType();
            linkType.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, link, new object[] { launcher });
            linkType.InvokeMember("Arguments", System.Reflection.BindingFlags.SetProperty, null, link, new object[] { "--foreign" });
            linkType.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, link, null);
        }
        finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(link); System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell); }
        Check(!SafeShortcut.TargetsCurrentLauncher(withArguments, launcher), "A shortcut with foreign arguments was accepted.");
    }
    private static void ClaudeDiscovery()
    {
        string root = NewCase("claude-discovery"), profile = Path.Combine(root, "profile"), roaming = Path.Combine(root, "roaming"), local = Path.Combine(root, "local");
        string desktop = Path.Combine(local, @"Programs\Claude"), bin = Path.Combine(root, "custom-bin");
        Directory.CreateDirectory(Path.Combine(profile, ".claude")); Write(desktop, "Claude.exe", "desktop fixture");
        Check(!CodexProgressInstaller.ClaudeCommandFound(profile, roaming, local, desktop), "A stale profile or Claude Desktop was incorrectly confirmed as Claude Code.");
        string marker = Path.Combine(root, "executed.txt");
        Write(bin, "claude.cmd", "@echo invoked > \"" + marker + "\"\r\n");
        Check(CodexProgressInstaller.ClaudeCommandFound(profile, roaming, local, bin) && !File.Exists(marker), "Claude discovery failed or executed the candidate command.");
    }
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--cwd-child") { Console.WriteLine("READY"); Console.In.ReadLine(); return 0; }
            if (args.Length == 3 && args[0] == "--crash") { CrashChild(args[1], args[2]); return 2; }
            root = Path.Combine(Path.GetTempPath(), "aitm-swap-regression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            Fresh(); ExistingAndRepeated(); Busy(); RunningProcess(); RunningPowerShellMonitor(); OtherProcessInspection(); Rollback();
            CrashDuringJournalCreation(); UnknownJournal(); PartialJournalPreserved(); PartialJournalBackupDenied();
            CrashRecovery("crash-before-switch", "after-backup", false);
            CrashRecovery("crash-after-switch", "after-stage", true);
            ChangedStage(); Collision(); ConcurrentAndFile(); Junctions(); PreparedFileLinks(); Shortcuts(); ClaudeDiscovery();
            Console.WriteLine("PASS: installation, update, busy processes/files, recovery and journal preservation, collisions, links and shortcuts.");
            Console.WriteLine("Fixture root: " + root);
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
