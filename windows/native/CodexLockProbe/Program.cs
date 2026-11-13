using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

// Research fixture only. This program is not referenced by the monitor.
internal static class Program
{
    private const int SharingViolation = 32;
    private const int HandleEof = 38;
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(15);
    private static string stage = "initialization";

    public static async Task<int> Main(string[] args)
    {
        try
        {
            Require(OperatingSystem.IsWindows());
            Require(string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase));
            Require(string.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase));
            Require(string.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"), "github-hosted", StringComparison.OrdinalIgnoreCase));
            Require(string.Equals(Environment.GetEnvironmentVariable("RUNNER_OS"), "Windows", StringComparison.OrdinalIgnoreCase));
            Require(Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0");

            if (args.Length == 2 && args[0] == "--fixture")
            {
                stage = "fixture validation";
                string root = ValidateRoot(args[1], mustExist: false);
                if (!Native.CreateDirectory(root, IntPtr.Zero)) throw new InvalidOperationException();
                stage = "fixture creation";
                CreateFixture(root, "empty", 0);
                CreateFixture(root, "one", 1);
                await Run(root);
                return 0;
            }

            if (args.Length == 5 && args[0] == "--worker")
            {
                string root = ValidateRoot(args[2], mustExist: true);
                Require(args[1] is "writer" or "observer");
                Require(args[3] is "empty" or "one");
                Require(args[4] is "sync" or "async" or "legacy");
                await RunWorker(args[1], root, args[3], args[4]);
                return 0;
            }
            throw new InvalidOperationException();
        }
        catch
        {
            // Avoid including file paths, command lines or fixture contents in logs.
            Console.Error.WriteLine($"Synthetic probe failed during {stage}; details omitted.");
            return 1;
        }
    }

    private static async Task Run(string root)
    {
        foreach (string sample in new[] { "empty", "one" })
        foreach (string mode in new[] { "sync", "async" })
        {
            stage = $"{sample} {mode} baseline";
            string baseline;
            await using (Worker reader = await Worker.Start("observer", root, sample, mode))
            {
                Require(await reader.Read() == "OPEN");
                baseline = await reader.Command("read");
                Require(IsExpectedBaseline(sample, baseline));
            }

            // An open writer handle alone is not a byte-range lock.
            stage = $"{sample} {mode} writer-first";
            await using (Worker writer = await Worker.Start("writer", root, sample, "sync"))
            {
                Require(await writer.Read() == "OPEN");
                await using (Worker reader = await Worker.Start("observer", root, sample, mode))
                {
                    Require(await reader.Read() == "OPEN");
                    Require(await reader.Command("read") == baseline);
                }

                Require(await writer.Command("lock") == "LOCK_OK");
                await using (Worker reader = await Worker.Start("observer", root, sample, mode))
                {
                    Require(await reader.Read() == "OPEN");
                    Require(await writer.Command("held") == "HELD");
                    string lockedRead = await reader.Command("read");
                    Require(await writer.Command("held") == "HELD");
                    Require(IsReadResult(lockedRead));
                    // Microsoft documents overlapping reads of a locked nonempty range fail.
                    if (sample == "one") Require(lockedRead.StartsWith("READ_ERR ", StringComparison.Ordinal));
                    Console.WriteLine($"{sample} {mode} with-lock {lockedRead}");
                }
            }

            // Read first and keep the observer handle open across writer open and try-lock.
            stage = $"{sample} {mode} observer-first";
            await using (Worker reader = await Worker.Start("observer", root, sample, mode))
            {
                Require(await reader.Read() == "OPEN");
                Require(await reader.Command("read") == baseline);
                await using (Worker writer = await Worker.Start("writer", root, sample, "sync"))
                {
                    Require(await writer.Read() == "OPEN");
                    Require(await writer.Command("lock") == "LOCK_OK");
                    Require(await writer.Command("held") == "HELD");
                    string lockedRead = await reader.Command("read");
                    Require(await writer.Command("held") == "HELD");
                    Require(IsReadResult(lockedRead));
                    if (sample == "one") Require(lockedRead.StartsWith("READ_ERR ", StringComparison.Ordinal));
                    Console.WriteLine($"{sample} {mode} observer-first {lockedRead}");
                }
                Require(await reader.Command("read") == baseline);
            }

            // Stress attempt: the read loop may be scheduled around, not during, writer startup.
            stage = $"{sample} {mode} concurrent reads";
            await using (Worker reader = await Worker.Start("observer", root, sample, mode))
            {
                Require(await reader.Read() == "OPEN");
                Require(await reader.Command("race") == "RACE_READY");
                await using (Worker writer = await Worker.Start("writer", root, sample, "sync"))
                {
                    Require(await writer.Read() == "OPEN");
                    Require(await writer.Command("lock") == "LOCK_OK");
                    Require(await writer.Command("held") == "HELD");
                    Require(await reader.Command("stop-race") == "RACE_OK");
                    Require(await writer.Command("held") == "HELD");
                }
            }
        }

        // Control: the old reader denies write sharing, so writer open must fail.
        stage = "legacy sharing control";
        await using (Worker reader = await Worker.Start("observer", root, "empty", "legacy"))
        {
            Require(await reader.Read() == "OPEN");
            await using Worker writer = await Worker.Start("writer", root, "empty", "sync");
            Require(await writer.Read() == $"OPEN_ERR {SharingViolation}");
        }
        Console.WriteLine("Synthetic controls passed. Empty-file observations are not a lock-state guarantee.");
    }

    private static bool IsExpectedBaseline(string sample, string result) => sample switch
    {
        "empty" => result == "READ_OK 0" || result == $"READ_ERR {HandleEof}",
        "one" => result == "READ_OK 1",
        _ => false
    };

    private static bool IsReadResult(string result) =>
        result.StartsWith("READ_OK ", StringComparison.Ordinal) ||
        result.StartsWith("READ_ERR ", StringComparison.Ordinal);

    private static async Task RunWorker(string role, string root, string sample, string mode)
    {
        string path = FixturePath(root, sample);
        uint access = role == "writer" ? Native.GenericRead | Native.GenericWrite : Native.GenericRead;
        uint share = Native.ShareRead | Native.ShareDelete;
        if (mode != "legacy") share |= Native.ShareWrite;
        uint flags = Native.OpenReparsePoint | (mode == "async" ? Native.Overlapped : 0);
        using SafeFileHandle handle = Native.CreateFile(path, access, share, IntPtr.Zero, Native.OpenExisting, flags, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            Console.WriteLine($"OPEN_ERR {Marshal.GetLastWin32Error()}");
            return;
        }
        Require(Native.GetFileInformationByHandle(handle, out Native.FileInformation info));
        Require((info.Attributes & Native.ReparsePoint) == 0 && info.NumberOfLinks == 1);
        Require(info.FileSizeHigh == 0 && info.FileSizeLow == (sample == "one" ? 1u : 0u));
        Console.WriteLine("OPEN");
        bool locked = false;
        CancellationTokenSource? raceStop = null;
        Task<long>? race = null;
        try
        {
            while (await Console.In.ReadLineAsync() is string command)
            {
                if (command == "close") break;
                if (command == "lock" && role == "writer" && !locked)
                {
                    Native.OverlappedData range = default;
                    locked = Native.LockFileEx(handle, Native.LockExclusive | Native.LockImmediately, 0, uint.MaxValue, uint.MaxValue, ref range);
                    Console.WriteLine(locked ? "LOCK_OK" : $"LOCK_ERR {Marshal.GetLastWin32Error()}");
                }
                else if (command == "held" && role == "writer" && locked)
                {
                    Require(!handle.IsClosed && !handle.IsInvalid);
                    Require(Native.GetFileInformationByHandle(handle, out _));
                    Console.WriteLine("HELD");
                }
                else if (command == "read" && role == "observer" && race is null)
                {
                    Console.WriteLine(ReadOne(handle, mode == "async"));
                }
                else if (command == "race" && role == "observer" && race is null)
                {
                    raceStop = new CancellationTokenSource();
                    CancellationToken stop = raceStop.Token;
                    var started = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    race = Task.Run(() =>
                    {
                        long count = 0;
                        try
                        {
                            do
                            {
                                _ = ReadOne(handle, mode == "async");
                                count++;
                                started.TrySetResult(true);
                            } while (!stop.IsCancellationRequested);
                            return count;
                        }
                        catch (Exception error) { started.TrySetException(error); throw; }
                    });
                    await started.Task;
                    Console.WriteLine("RACE_READY");
                }
                else if (command == "stop-race" && race is not null && raceStop is not null)
                {
                    raceStop.Cancel();
                    Require(await race > 0);
                    raceStop.Dispose();
                    raceStop = null;
                    race = null;
                    Console.WriteLine("RACE_OK");
                }
                else throw new InvalidOperationException();
            }
        }
        finally
        {
            if (raceStop is not null) raceStop.Cancel();
            if (race is not null) await race;
            raceStop?.Dispose();
        }
        // Closing a writer handle releases its synthetic lock.
    }

    private static string ReadOne(SafeFileHandle handle, bool asynchronous)
    {
        IntPtr buffer = Marshal.AllocHGlobal(1);
        try
        {
            if (!asynchronous)
            {
                Require(Native.SetFilePointerEx(handle, 0, out _, 0));
                bool success = Native.ReadFileSync(handle, buffer, 1, out uint count, IntPtr.Zero);
                return success ? $"READ_OK {count}" : $"READ_ERR {Marshal.GetLastWin32Error()}";
            }

            using SafeWaitHandle signal = Native.CreateEvent(IntPtr.Zero, true, false, null);
            Require(!signal.IsInvalid);
            Native.OverlappedData operation = new() { Event = signal.DangerousGetHandle() };
            bool started = Native.ReadFileAsync(handle, buffer, 1, IntPtr.Zero, ref operation);
            int startError = started ? 0 : Marshal.GetLastWin32Error();
            if (!started && startError != Native.IoPending) return $"READ_ERR {startError}";
            bool complete = Native.GetOverlappedResult(handle, ref operation, out uint bytes, true);
            return complete ? $"READ_OK {bytes}" : $"READ_ERR {Marshal.GetLastWin32Error()}";
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static string ValidateRoot(string input, bool mustExist)
    {
        string tempInput = Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? throw new InvalidOperationException();
        Require(!string.IsNullOrWhiteSpace(tempInput) && Path.IsPathFullyQualified(tempInput));
        Require(Path.IsPathFullyQualified(input));
        string temp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(tempInput));
        string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(input));
        Require(string.Equals(Path.GetDirectoryName(root), temp, StringComparison.OrdinalIgnoreCase));
        const string prefix = "aitm-lock-probe-";
        string name = Path.GetFileName(root);
        Require(name.StartsWith(prefix, StringComparison.Ordinal) &&
            Guid.TryParseExact(name[prefix.Length..], "N", out _));
        Require(new DriveInfo(Path.GetPathRoot(root)!).DriveType == DriveType.Fixed);

        foreach (Environment.SpecialFolder special in new[] {
            Environment.SpecialFolder.UserProfile, Environment.SpecialFolder.ApplicationData,
            Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolder.Windows,
            Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.CommonApplicationData })
        {
            string protectedRoot = Environment.GetFolderPath(special);
            if (!string.IsNullOrEmpty(protectedRoot)) Require(!Inside(root, Path.GetFullPath(protectedRoot)));
        }
        string? codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (!string.IsNullOrWhiteSpace(codexHome) && Path.IsPathFullyQualified(codexHome))
            Require(!Inside(root, Path.GetFullPath(codexHome)));
        for (DirectoryInfo? part = new(temp); part is not null; part = part.Parent)
            Require((part.Attributes & FileAttributes.ReparsePoint) == 0);
        if (mustExist) Require((File.GetAttributes(root) & FileAttributes.ReparsePoint) == 0);
        return root;
    }

    private static bool Inside(string candidate, string parent)
    {
        string prefix = Path.TrimEndingDirectorySeparator(parent) + Path.DirectorySeparatorChar;
        return string.Equals(candidate, Path.TrimEndingDirectorySeparator(parent), StringComparison.OrdinalIgnoreCase) ||
            candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static string FixturePath(string root, string sample) =>
        Path.Combine(root, $"synthetic-{sample}-{Path.GetFileName(root)["aitm-lock-probe-".Length..]}.lock");

    private static void CreateFixture(string root, string sample, int size)
    {
        using var file = new FileStream(FixturePath(root, sample), FileMode.CreateNew, FileAccess.Write,
            FileShare.ReadWrite | FileShare.Delete);
        if (size == 1) file.WriteByte(0x53);
    }

    private static void Require(bool value)
    {
        if (!value) throw new InvalidOperationException();
    }

    private sealed class Worker : IAsyncDisposable
    {
        private readonly Process process;
        private Worker(Process process) => this.process = process;

        public static Task<Worker> Start(string role, string root, string sample, string mode)
        {
            string executable = Environment.ProcessPath ?? throw new InvalidOperationException();
            var start = new ProcessStartInfo(executable)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
            };
            if (string.Equals(Path.GetFileNameWithoutExtension(executable), "dotnet", StringComparison.OrdinalIgnoreCase))
                start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
            foreach (string argument in new[] { "--worker", role, root, sample, mode }) start.ArgumentList.Add(argument);
            start.Environment["DOTNET_ADD_GLOBAL_TOOLS_TO_PATH"] = "0";
            return Task.FromResult(new Worker(Process.Start(start) ?? throw new InvalidOperationException()));
        }

        public async Task<string> Read() => await process.StandardOutput.ReadLineAsync().WaitAsync(Timeout)
            ?? throw new InvalidOperationException();

        public async Task<string> Command(string command)
        {
            await process.StandardInput.WriteLineAsync(command);
            return await Read();
        }

        public async ValueTask DisposeAsync()
        {
            try
            {
                bool timedOut = false;
                if (!process.HasExited)
                {
                    try { await process.StandardInput.WriteLineAsync("close"); }
                    catch (Exception error) when (error is IOException or InvalidOperationException) { }
                    try { await process.WaitForExitAsync().WaitAsync(Timeout); }
                    catch (TimeoutException)
                    {
                        timedOut = true;
                        process.Kill(entireProcessTree: true);
                        await process.WaitForExitAsync().WaitAsync(Timeout);
                    }
                }
                Require(!timedOut && process.ExitCode == 0);
            }
            finally { process.Dispose(); }
        }
    }

    private static class Native
    {
        public const uint GenericRead = 0x80000000, GenericWrite = 0x40000000;
        public const uint ShareRead = 1, ShareWrite = 2, ShareDelete = 4, OpenExisting = 3;
        public const uint OpenReparsePoint = 0x00200000, Overlapped = 0x40000000, ReparsePoint = 0x400;
        public const uint LockImmediately = 1, LockExclusive = 2;
        public const int IoPending = 997;

        [StructLayout(LayoutKind.Sequential)]
        public struct OverlappedData { public nuint Internal, InternalHigh; public uint Offset, OffsetHigh; public IntPtr Event; }

        [StructLayout(LayoutKind.Sequential)]
        public struct FileInformation
        {
            public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            public uint VolumeSerial, FileSizeHigh, FileSizeLow, NumberOfLinks, IndexHigh, IndexLow;
        }

        [DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CreateDirectory(string path, IntPtr securityAttributes);

        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr securityAttributes,
            uint creationDisposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool LockFileEx(SafeFileHandle file, uint flags, uint reserved,
            uint lengthLow, uint lengthHigh, ref OverlappedData overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetFilePointerEx(SafeFileHandle file, long distance, out long position, uint moveMethod);

        [DllImport("kernel32.dll", EntryPoint = "ReadFile", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ReadFileSync(SafeFileHandle file, IntPtr buffer, uint count, out uint read, IntPtr overlapped);

        [DllImport("kernel32.dll", EntryPoint = "ReadFile", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ReadFileAsync(SafeFileHandle file, IntPtr buffer, uint count, IntPtr read, ref OverlappedData overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetOverlappedResult(SafeFileHandle file, ref OverlappedData overlapped, out uint read,
            [MarshalAs(UnmanagedType.Bool)] bool wait);

        [DllImport("kernel32.dll", EntryPoint = "CreateEventW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeWaitHandle CreateEvent(IntPtr securityAttributes, [MarshalAs(UnmanagedType.Bool)] bool manualReset,
            [MarshalAs(UnmanagedType.Bool)] bool initialState, string? name);
    }
}
