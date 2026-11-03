using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class CodexTasksLauncher
{
    [STAThread]
    private static void Main(string[] args)
    {
        string directory = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(directory, "CodexProgress.ps1");
        string powerShell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        StringBuilder arguments = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File ");
        arguments.Append(QuoteArgument(script));
        foreach (string argument in args) arguments.Append(' ').Append(QuoteArgument(argument));

        Process.Start(new ProcessStartInfo
        {
            FileName = powerShell,
            Arguments = arguments.ToString(),
            WorkingDirectory = directory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        });
    }

    private static string QuoteArgument(string value)
    {
        StringBuilder result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { backslashes++; continue; }
            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1).Append('"');
                backslashes = 0;
                continue;
            }
            result.Append('\\', backslashes).Append(character);
            backslashes = 0;
        }
        result.Append('\\', backslashes * 2).Append('"');
        return result.ToString();
    }
}
