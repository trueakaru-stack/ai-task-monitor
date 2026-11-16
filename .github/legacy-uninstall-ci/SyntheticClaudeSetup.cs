using System;
using System.IO;

internal static class SyntheticClaudeSetup
{
    private static int Main()
    {
        if (Environment.GetEnvironmentVariable("CI") != "true" ||
            Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
            Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted")
            return 70;
        string local = Path.GetFullPath(Environment.GetEnvironmentVariable("AITM_TEST_LOCAL"));
        string install = Path.GetFullPath(Environment.GetEnvironmentVariable("AITM_TEST_INSTALL"));
        string profile = Path.GetFullPath(Environment.GetEnvironmentVariable("USERPROFILE"));
        string expectedProfile = Path.GetFullPath(Environment.GetEnvironmentVariable("AITM_TEST_PROFILE"));
        string marker = Path.GetFullPath(Environment.GetEnvironmentVariable("AITM_TEST_MARKER"));
        string tempRoot = Path.GetFullPath(Environment.GetEnvironmentVariable("AITM_TEST_FIXTURE")).TrimEnd('\\') + "\\";
        if (!String.Equals(Path.GetDirectoryName(install), local, StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(Path.GetFileName(install), "AITaskMonitor", StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(profile, expectedProfile, StringComparison.OrdinalIgnoreCase) ||
            !profile.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase) ||
            !marker.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase))
            return 71;
        string executable = Path.Combine(install, "AI task monitor.exe");
        string blocked = Path.Combine(install, "AI task monitor.synthetic-blocked");
        string settings = Path.Combine(profile, ".claude", "settings.json");
        if (!File.Exists(executable) || File.Exists(blocked) || !File.Exists(settings)) return 72;
        File.Move(executable, blocked);
        File.WriteAllText(settings, "{\"user\":\"preserved\",\"fixture_hook\":\"synthetic\"}");
        File.WriteAllText(marker, "synthetic setup completed");
        return 0;
    }
}
