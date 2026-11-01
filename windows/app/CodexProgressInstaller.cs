using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class CodexProgressInstaller
{
    [STAThread]
    private static void Main()
    {
        try
        {
            string installDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "AITaskMonitor");
            Directory.CreateDirectory(installDirectory);

            Extract("CodexProgress.ps1", Path.Combine(installDirectory, "CodexProgress.ps1"));
            Extract("Uninstall-CodexProgress.ps1", Path.Combine(installDirectory, "Uninstall-CodexProgress.ps1"));
            Extract("Uninstall-CodexProgress.cmd", Path.Combine(installDirectory, "Uninstall-CodexProgress.cmd"));
            Extract("ClaudeTaskHook.ps1", Path.Combine(installDirectory, "ClaudeTaskHook.ps1"));
            Extract("Configure-ClaudeIntegration.ps1", Path.Combine(installDirectory, "Configure-ClaudeIntegration.ps1"));

            string launcher = Path.Combine(installDirectory, "AI task monitor.cmd");
            File.WriteAllText(
                launcher,
                "@echo off\r\nstart \"AI task monitor\" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File \"%~dp0CodexProgress.ps1\"\r\n",
                Encoding.ASCII);

            string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            string shortcut = Path.Combine(programs, "AI task monitor.lnk");
            CreateShortcut(shortcut, launcher, installDirectory);

            bool claudeConnected = false;
            string claudeDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
            if (Directory.Exists(claudeDirectory))
            {
                DialogResult answer = MessageBox.Show(
                    "Подключить Claude Code? AI task monitor добавит локальные hooks в настройки Claude. Существующие hooks сохранятся.",
                    "AI task monitor",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);
                if (answer == DialogResult.Yes)
                {
                    Process setup = Process.Start(new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(installDirectory, "Configure-ClaudeIntegration.ps1") + "\" -Mode Install",
                        WorkingDirectory = installDirectory,
                        UseShellExecute = false,
                        CreateNoWindow = true,
                    });
                    setup.WaitForExit();
                    if (setup.ExitCode != 0) throw new InvalidOperationException("Не удалось подключить Claude Code.");
                    claudeConnected = true;
                }
            }

            Process.Start(new ProcessStartInfo(launcher) { WorkingDirectory = installDirectory, UseShellExecute = true });
            MessageBox.Show(
                "AI task monitor установлен. Ярлык добавлен в меню «Пуск»." + (claudeConnected ? " Claude Code подключён. Перезапустите Claude Code." : ""),
                "AI task monitor",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "AI task monitor", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }

    private static void Extract(string resourceName, string destination)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        using (Stream source = assembly.GetManifestResourceStream(resourceName))
        {
            if (source == null) throw new InvalidOperationException("Missing resource: " + resourceName);
            using (FileStream target = File.Create(destination)) source.CopyTo(target);
        }
    }

    private static void CreateShortcut(string shortcutPath, string targetPath, string workingDirectory)
    {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) throw new InvalidOperationException("WScript.Shell is unavailable.");
        object shell = Activator.CreateInstance(shellType);
        object link = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { shortcutPath });
        Type linkType = link.GetType();
        linkType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { targetPath });
        linkType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { workingDirectory });
        linkType.InvokeMember("Description", BindingFlags.SetProperty, null, link, new object[] { "AI task monitor" });
        linkType.InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
    }
}
