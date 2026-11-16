using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

internal static class Program
{
    private const uint DeleteAccess = 0x00010000;
    private const uint ReadAttributes = 0x00000080;
    private const uint ShareReadWrite = 0x00000003;
    private const uint OpenExisting = 3;
    private const uint BackupSemantics = 0x02000000;
    private const uint OpenReparse = 0x00200000;
    private const int FileDispositionInfo = 4;
    private static int checks;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass,
        ref byte value, uint size);

    private static void Check(bool value, string message)
    {
        checks++;
        if (!value) throw new InvalidOperationException(message);
    }

    private static bool Hosted() => OperatingSystem.IsWindows() &&
        Environment.GetEnvironmentVariable("CI") == "true" &&
        Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
        Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted" &&
        Environment.GetEnvironmentVariable("RUNNER_OS") == "Windows" &&
        Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0";

    private static string RequireRoot(string[] args)
    {
        Check(Hosted() && args.Length == 1, "Disposable hosted Windows required.");
        string temp = Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "";
        Check(Path.IsPathFullyQualified(temp) && Path.IsPathFullyQualified(args[0]), "Absolute fixture root required.");
        string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[0]));
        Check(string.Equals(Directory.GetParent(root)?.FullName, Path.TrimEndingDirectorySeparator(Path.GetFullPath(temp)),
                  StringComparison.OrdinalIgnoreCase) &&
              Regex.IsMatch(Path.GetFileName(root), "^aitm-cloud-acl-[0-9a-f]{32}$", RegexOptions.CultureInvariant) &&
              Directory.Exists(root), "Unique runner-temp fixture required.");
        for (DirectoryInfo? item = new(root); item is not null; item = item.Parent)
            Check((item.Attributes & FileAttributes.ReparsePoint) == 0, "Reparse ancestor rejected.");
        string expected = Path.Combine(root, "artifacts", "bin", "CloudWorkspaceExperiment", "release",
            "AITaskMonitor.CloudWorkspaceExperiment.dll");
        Check(string.Equals(Path.GetFullPath(typeof(Program).Assembly.Location), expected, StringComparison.OrdinalIgnoreCase),
            "Synthetic assembly location rejected.");
        return root;
    }

    private static int Child(string root)
    {
        if (!Hosted()) return 21;
        string cwd = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Environment.CurrentDirectory));
        if (!string.Equals(Directory.GetParent(cwd)?.FullName, root, StringComparison.OrdinalIgnoreCase) ||
            !Regex.IsMatch(Path.GetFileName(cwd), "^sandbox-[0-9a-f]{32}$", RegexOptions.CultureInvariant))
            return 22;
        try
        {
            using var output = new FileStream("error.log", FileMode.Append, FileAccess.Write, FileShare.Read);
            output.WriteByte(1);
            return 23;
        }
        catch (UnauthorizedAccessException) { Console.Write("DENIED"); return 0; }
        catch (IOException) { Console.Write("DENIED"); return 0; }
    }

    private static void MainTest(string root)
    {
        string directory = Path.Combine(root, "sandbox-" + Guid.NewGuid().ToString("N"));
        Check(!Directory.Exists(directory) && !File.Exists(directory), "Synthetic workspace must be new.");
        SecurityIdentifier user = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("Identity unavailable.");
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(user);
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.CreateFiles | FileSystemRights.CreateDirectories,
            InheritanceFlags.None, PropagationFlags.None, AccessControlType.Deny));
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.ReadAndExecute | FileSystemRights.Delete,
            InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow));
        security.CreateDirectory(directory); // Experiment only: this API accepts an existing path.
        Check(Directory.Exists(directory) && (File.GetAttributes(directory) & FileAttributes.ReparsePoint) == 0,
            "Synthetic workspace was not a real directory.");
        using SafeFileHandle handle = CreateFileW(directory, DeleteAccess | ReadAttributes, ShareReadWrite, IntPtr.Zero,
            OpenExisting, BackupSemantics | OpenReparse, IntPtr.Zero);
        Check(!handle.IsInvalid, "Could not hold the synthetic workspace.");
        bool moved = false;
        try { Directory.Move(directory, directory + "-moved"); moved = true; }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        Check(!moved && Directory.Exists(directory), "Held workspace could be renamed.");

        string host = Environment.ProcessPath ?? throw new InvalidOperationException("Hosted SDK host missing.");
        var start = new ProcessStartInfo(host)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        start.Environment.Clear();
        foreach (string name in new[] { "SystemRoot", "windir", "PATH", "DOTNET_ROOT", "DOTNET_CLI_HOME",
            "DOTNET_CLI_TELEMETRY_OPTOUT", "DOTNET_GENERATE_ASPNET_CERTIFICATE", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE",
            "DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP",
            "CI", "GITHUB_ACTIONS", "RUNNER_ENVIRONMENT", "RUNNER_OS", "RUNNER_TEMP", "ProgramFiles", "ProgramW6432",
            "ProgramData", "ALLUSERSPROFILE", "SystemDrive", "ComSpec" })
            if (Environment.GetEnvironmentVariable(name) is string value) start.Environment[name] = value;
        start.Environment["DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"] = "0";
        start.ArgumentList.Add(typeof(Program).Assembly.Location);
        start.ArgumentList.Add("--child");
        start.ArgumentList.Add(root);
        using Process child = Process.Start(start) ?? throw new InvalidOperationException("Synthetic child did not start.");
        Task<string> stdout = child.StandardOutput.ReadToEndAsync();
        Task<string> stderr = child.StandardError.ReadToEndAsync();
        if (!child.WaitForExit(15000)) { child.Kill(true); throw new TimeoutException("Synthetic child timed out."); }
        Check(child.ExitCode == 0 && stdout.GetAwaiter().GetResult() == "DENIED" &&
              stderr.GetAwaiter().GetResult().Length == 0, "Synthetic child could append a relative log.");
        Check(!File.Exists(Path.Combine(directory, "error.log")) && Directory.GetFileSystemEntries(directory).Length == 0,
            "Synthetic child left workspace content.");
        byte flag = 1;
        Check(SetFileInformationByHandle(handle, FileDispositionInfo, ref flag, 1), "Empty workspace could not be marked for handle-based removal.");
        handle.Dispose();
        Check(!Directory.Exists(directory), "Synthetic workspace was not removed.");
    }

    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--child")
        {
            try { return Child(RequireRoot(new[] { args[1] })); }
            catch (Exception) { return 20; }
        }
        try
        {
            string root = RequireRoot(args);
            MainTest(root);
            Console.WriteLine($"Synthetic read-only workspace: {checks} checks passed.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Synthetic workspace experiment failed: " + error.GetType().Name + " " + error.Message);
            return 1;
        }
    }
}
