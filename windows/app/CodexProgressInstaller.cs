using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
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
            Extract("ClaudeLoopClient.ps1", Path.Combine(installDirectory, "ClaudeLoopClient.ps1"));
            Extract("ClaudeLoopDetection.ps1", Path.Combine(installDirectory, "ClaudeLoopDetection.ps1"));
            Extract("ClaudeLoopChannel.cs", Path.Combine(installDirectory, "ClaudeLoopChannel.cs"));
            Extract("ClaudeReaderCore.ps1", Path.Combine(installDirectory, "ClaudeReaderCore.ps1"));
            Extract("ClaudeRetention.cs", Path.Combine(installDirectory, "ClaudeRetention.cs"));
            Extract("AppShellIdentity.cs", Path.Combine(installDirectory, "AppShellIdentity.cs"));
            Extract("Configure-ClaudeIntegration.ps1", Path.Combine(installDirectory, "Configure-ClaudeIntegration.ps1"));
            Extract("Configure-OpenCodeIntegration.ps1", Path.Combine(installDirectory, "Configure-OpenCodeIntegration.ps1"));
            string integrationsDirectory = Path.Combine(installDirectory, "integrations");
            Directory.CreateDirectory(integrationsDirectory);
            foreach (string name in new[] { "ProviderEventView.ps1", "ProviderRuntime.ps1", "ProviderEventState.cs", "ProviderEventChannel.cs", "provider-events.mjs", "provider-observers.mjs", "provider-transport.mjs", "opencode-entry.js", "DeepSeekRuntime.ps1", "KimiRuntime.ps1", "kimi-integration.mjs", "kimi-setup.mjs", "CodexCloudRuntime.ps1", "CodexCloudProcess.cs", "deepseek-integration.mjs", "deepseek-setup.mjs", "deepseek-plugin.js", "package.json", "cordis.patch.yml" })
                Extract("integrations." + name, Path.Combine(integrationsDirectory, name));
            string kimiDirectory = Path.Combine(integrationsDirectory, "kimi-plugin");
            Directory.CreateDirectory(kimiDirectory);
            foreach (string name in new[] { "kimi.plugin.json", "kimi-hook.mjs", "kimi-observer.mjs", "provider-transport.mjs" })
                Extract("integrations.kimi-plugin." + name, Path.Combine(kimiDirectory, name));
            Extract("DiagnosticPolicy.ps1", Path.Combine(installDirectory, "DiagnosticPolicy.ps1"));
            Extract("DiagnosticStore.ps1", Path.Combine(installDirectory, "DiagnosticStore.ps1"));
            Extract("LoopDetection.ps1", Path.Combine(installDirectory, "LoopDetection.ps1"));
            Extract("DiagnosticCollector.ps1", Path.Combine(installDirectory, "DiagnosticCollector.ps1"));
            Extract("DiagnosticRuntime.ps1", Path.Combine(installDirectory, "DiagnosticRuntime.ps1"));
            Extract("ReleaseUpdates.ps1", Path.Combine(installDirectory, "ReleaseUpdates.ps1"));
            string assetsDirectory = Path.Combine(installDirectory, "assets");
            Directory.CreateDirectory(assetsDirectory);
            string iconPath = Path.Combine(assetsDirectory, "app-icon.ico");
            Extract("app-icon.ico", iconPath);

            string launcher = Path.Combine(installDirectory, "AI task monitor.exe");
            Extract("AI task monitor.exe", launcher);

            string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            string shortcut = Path.Combine(programs, "AI task monitor.lnk");
            CreateShortcut(shortcut, launcher, installDirectory, iconPath);

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

            Process.Start(new ProcessStartInfo(launcher) { WorkingDirectory = installDirectory, UseShellExecute = false });
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

    private static void CreateShortcut(string shortcutPath, string targetPath, string workingDirectory, string iconPath)
    {
        Type shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) throw new InvalidOperationException("WScript.Shell is unavailable.");
        object shell = Activator.CreateInstance(shellType);
        object link = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { shortcutPath });
        Type linkType = link.GetType();
        linkType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { targetPath });
        linkType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { workingDirectory });
        linkType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, link, new object[] { iconPath + ",0" });
        linkType.InvokeMember("Description", BindingFlags.SetProperty, null, link, new object[] { "AI task monitor" });
        linkType.InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
    }
}
