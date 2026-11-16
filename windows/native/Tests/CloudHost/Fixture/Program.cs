using System.Text.Json;
using System.Text.RegularExpressions;

internal static class Program
{
    private static bool Hosted() =>
        OperatingSystem.IsWindows() &&
        string.Equals(Environment.GetEnvironmentVariable("CI"), "true", StringComparison.OrdinalIgnoreCase) &&
        string.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"), "true", StringComparison.OrdinalIgnoreCase) &&
        string.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"), "github-hosted", StringComparison.OrdinalIgnoreCase) &&
        string.Equals(Environment.GetEnvironmentVariable("RUNNER_OS"), "Windows", StringComparison.OrdinalIgnoreCase) &&
        Environment.GetEnvironmentVariable("DOTNET_ADD_GLOBAL_TOOLS_TO_PATH") == "0";

    private static void WritePage(object[] tasks, string? cursor)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new { tasks, cursor });
        using Stream output = Console.OpenStandardOutput();
        output.Write(bytes);
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
        string? mode = Environment.GetEnvironmentVariable("AITM_CLOUDHOST_MODE");
        if (mode == "pages")
        {
            if (cursor is null)
                WritePage([new { id = "host-first", title = "Fixture first", status = "pending" }], "second");
            else if (cursor == "second")
                WritePage([new { id = "host-second", title = "Fixture second", status = "pending" }], null);
            else return 21;
            return 0;
        }
        if (mode == "partial")
        {
            int index;
            if (cursor is null) index = 0;
            else if (Regex.IsMatch(cursor, "^p[1-4]$", RegexOptions.CultureInvariant)) index = cursor[1] - '0';
            else return 22;
            WritePage([new { id = "partial-" + index, title = "Fixture partial " + index, status = "pending" }],
                "p" + (index + 1));
            return 0;
        }
        if (mode == "empty")
        {
            if (cursor is not null) return 23;
            WritePage([], null);
            return 0;
        }
        if (mode == "error") return 24;
        if (mode == "hold")
        {
            string id = Environment.GetEnvironmentVariable("AITM_CLOUDHOST_SIGNAL") ?? "";
            if (!Regex.IsMatch(id, "^[0-9a-f]{32}$", RegexOptions.CultureInvariant)) return 25;
            using EventWaitHandle ready = EventWaitHandle.OpenExisting("Local\\AITM.CloudHost.Ready." + id);
            using var lifetime = new Mutex(true, "Local\\AITM.CloudHost.Lifetime." + id, out bool created);
            if (!created) return 28;
            ready.Set();
            await Task.Delay(TimeSpan.FromSeconds(30));
            return 26;
        }
        return 27;
    }
}

