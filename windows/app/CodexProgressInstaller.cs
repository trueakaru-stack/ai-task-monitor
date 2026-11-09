using System;
using System.Collections.Generic;
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
            EnsureInstallationFilesAvailable(installDirectory);
            Directory.CreateDirectory(installDirectory);

            Extract("CodexProgress.ps1", Path.Combine(installDirectory, "CodexProgress.ps1"));
            Extract("Uninstall-CodexProgress.ps1", Path.Combine(installDirectory, "Uninstall-CodexProgress.ps1"));
            Extract("Uninstall-CodexProgress.cmd", Path.Combine(installDirectory, "Uninstall-CodexProgress.cmd"));
            Extract("ClaudeStageObservation.dll", Path.Combine(installDirectory, "ClaudeStageObservation.dll"));
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
            foreach (string name in new[] { "ProviderEventView.ps1", "ProviderRuntime.ps1", "ProviderEventState.cs", "ProviderEventChannel.cs", "provider-events.mjs", "provider-observers.mjs", "provider-transport.mjs", "opencode-entry.js", "DeepSeekRuntime.ps1", "KimiRuntime.ps1", "HermesRuntime.ps1", "HermesBridgeProcess.cs", "hermes-setup.py", "hermes-manager.py", "ruamel.yaml-0.18.16-py3-none-any.whl", "ruamel.yaml-LICENSE.txt", "provider_bundle.py", "hermes-entry.py", "hermes-plugin.yaml", "hermes_observer.py", "provider_hooks.py", "provider_sender.py", "provider_transport.py", "kimi-integration.mjs", "kimi-setup.mjs", "CodexCloudRuntime.ps1", "CodexCloudProcess.cs", "deepseek-integration.mjs", "deepseek-setup.mjs", "deepseek-plugin.js", "package.json", "cordis.patch.yml" })
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
                    "Перед подключением обновите все используемые копии Claude Code, включая Claude Desktop, до версии 2.1.101 или новее. Закройте Claude Code, Claude Desktop и другие программы, которые могут изменять настройки Claude Code, включая их фоновые процессы. Приложение не проверяет версии и закрытие программ автоматически.\n\nПодключить Claude Code? AI task monitor добавит локальные hooks в настройки Claude. Существующие hooks сохранятся.",
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

    private static void EnsureInstallationFilesAvailable(string installDirectory)
    {
        var opened = new List<FileStream>();
        try
        {
            foreach (string resource in Assembly.GetExecutingAssembly().GetManifestResourceNames())
            {
                string destination;
                const string kimiPrefix = "integrations.kimi-plugin.";
                const string integrationsPrefix = "integrations.";
                if (resource.StartsWith(kimiPrefix, StringComparison.Ordinal))
                    destination = Path.Combine(installDirectory, "integrations", "kimi-plugin", resource.Substring(kimiPrefix.Length));
                else if (resource.StartsWith(integrationsPrefix, StringComparison.Ordinal))
                    destination = Path.Combine(installDirectory, "integrations", resource.Substring(integrationsPrefix.Length));
                else if (resource == "app-icon.ico")
                    destination = Path.Combine(installDirectory, "assets", "app-icon.ico");
                else destination = Path.Combine(installDirectory, resource);

                FileAttributes attributes;
                try { attributes = File.GetAttributes(destination); }
                catch (FileNotFoundException) { continue; }
                catch (DirectoryNotFoundException) { continue; }
                if ((attributes & FileAttributes.Directory) != 0)
                    throw new IOException("An installation file path is a directory.");
                opened.Add(new FileStream(destination, FileMode.Open, FileAccess.ReadWrite, FileShare.None));
            }
        }
        catch (Exception error)
        {
            throw new InvalidOperationException("Не удалось подготовить обновление: файлы заняты или недоступны. Закройте AI task monitor, Claude Code, Claude Desktop и другие агенты, затем повторите попытку. Проверьте права доступа.", error);
        }
        finally
        {
            foreach (FileStream stream in opened) stream.Dispose();
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
