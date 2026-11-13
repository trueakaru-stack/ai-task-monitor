using System.Text;
using System.Text.RegularExpressions;

internal static class Program
{
    private const string DangerousCursor = "--leading \"quoted\" & %PATH% \\trailing\\";
    private static readonly byte[] Page = Encoding.UTF8.GetBytes("{\"tasks\":[],\"cursor\":null}");

    private static bool Hosted() =>
        OperatingSystem.IsWindows() &&
        string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase) &&
        string.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase) &&
        string.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"), "github-hosted", StringComparison.OrdinalIgnoreCase) &&
        string.Equals(Environment.GetEnvironmentVariable("RUNNER_OS"), "Windows", StringComparison.OrdinalIgnoreCase) &&
        Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0";

    private static void WriteRepeated(Stream stream, int count, byte value)
    {
        byte[] bytes = Enumerable.Repeat(value, 8192).ToArray();
        while (count > 0)
        {
            int part = Math.Min(count, bytes.Length);
            stream.Write(bytes, 0, part);
            count -= part;
        }
        stream.Flush();
    }

    private static async Task<int> Main(string[] args)
    {
        if (!OperatingSystem.IsWindows()) return 20;
        if (!Hosted() || (args.Length != 5 && args.Length != 6) ||
            args[0] != "cloud" || args[1] != "list" || args[2] != "--json" ||
            args[3] != "--limit" || args[4] != "20" ||
            (args.Length == 6 && !args[5].StartsWith("--cursor=", StringComparison.Ordinal)))
            return 20;

        string? cursor = args.Length == 6 ? args[5]["--cursor=".Length..] : null;
        using Stream stdout = Console.OpenStandardOutput();
        using Stream stderr = Console.OpenStandardError();

        if (cursor is null || cursor == DangerousCursor)
        {
            stdout.Write(Page);
            return 0;
        }
        if (cursor == "stdin-eof")
        {
            using Stream stdin = Console.OpenStandardInput();
            if (stdin.ReadByte() != -1) return 21;
            stdout.Write(Page);
            return 0;
        }
        if (cursor == "both-exact")
        {
            for (int i = 0; i < 8; i++)
            {
                WriteRepeated(stdout, 131_072, (byte)'A');
                WriteRepeated(stderr, 8_192, (byte)'B');
            }
            return 0;
        }
        if (cursor == "stdout-over")
        {
            WriteRepeated(stdout, 1_048_577, (byte)'A');
            await Task.Delay(TimeSpan.FromSeconds(30));
            return 22;
        }
        if (cursor == "stderr-over")
        {
            WriteRepeated(stderr, 65_537, (byte)'B');
            await Task.Delay(TimeSpan.FromSeconds(30));
            return 22;
        }
        if (cursor == "bad-utf8")
        {
            stdout.Write(new byte[] { 0xc3, 0x28 });
            return 0;
        }
        if (cursor == "nonzero")
        {
            byte[] privateData = Encoding.UTF8.GetBytes("synthetic-private-process-data");
            stdout.Write(privateData);
            stderr.Write(privateData);
            return 23;
        }
        if (cursor.StartsWith("wait-", StringComparison.Ordinal) &&
            Regex.IsMatch(cursor[5..], "^[0-9a-f]{32}$", RegexOptions.CultureInvariant))
        {
            string id = cursor[5..];
            using EventWaitHandle ready = EventWaitHandle.OpenExisting("Local\\AITM.Cloud.Ready." + id);
            using var lifetime = new Mutex(true, "Local\\AITM.Cloud.Lifetime." + id, out bool created);
            if (!created) return 24;
            ready.Set();
            await Task.Delay(TimeSpan.FromSeconds(30));
            return 25;
        }
        return 26;
    }
}

