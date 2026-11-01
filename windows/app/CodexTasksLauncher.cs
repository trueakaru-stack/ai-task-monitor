using System;
using System.Diagnostics;
using System.IO;

internal static class CodexTasksLauncher
{
    [STAThread]
    private static void Main()
    {
        string directory = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(directory, "CodexProgress.ps1");
        string progress = Path.GetFullPath(Path.Combine(directory, "..", "..", "task-progress-v2.json"));

        Process.Start(new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File \"" + script + "\" \"" + progress + "\"",
            WorkingDirectory = directory,
            UseShellExecute = false,
            CreateNoWindow = true,
        });
    }
}
