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
        bool installationAttempted = false;
        bool claudeSetupAttempted = false;
        string installDirectory = null;
        try
        {
            string localDirectory = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            installDirectory = Path.Combine(localDirectory, "AITaskMonitor");
            bool claudeConnected = false;
            string shortcutName = null;
            string launcher = Path.Combine(installDirectory, "AI task monitor.exe");
            if (Directory.Exists(installDirectory) || File.Exists(installDirectory))
                throw new IOException(SafeInstallPaths.ExistingInstallMessage(installDirectory));
            bool connectClaude = false;
            string claudeDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
            if (Directory.Exists(claudeDirectory))
            {
                DialogResult answer = MessageBox.Show(
                    "Перед подключением обновите все используемые копии Claude Code, включая Claude Desktop, до версии 2.1.101 или новее. Закройте Claude Code, Claude Desktop и другие программы, которые могут изменять настройки Claude Code, включая их фоновые процессы. Приложение не проверяет версии и закрытие программ автоматически.\n\nПодключить Claude Code? AI task monitor добавит локальные hooks в настройки Claude. Существующие hooks сохранятся.",
                    "AI task monitor",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);
                connectClaude = answer == DialogResult.Yes;
            }
            using (SafeInstallPaths installGuard = SafeInstallPaths.OpenExisting(localDirectory))
            {
                installationAttempted = true;
                installGuard.CreateChild(installDirectory);

                Extract(installGuard, "CodexProgress.ps1", Path.Combine(installDirectory, "CodexProgress.ps1"));
                Extract(installGuard, "Uninstall-CodexProgress.ps1", Path.Combine(installDirectory, "Uninstall-CodexProgress.ps1"));
                Extract(installGuard, "Uninstall-CodexProgress.cmd", Path.Combine(installDirectory, "Uninstall-CodexProgress.cmd"));
                Extract(installGuard, "ClaudeStageObservation.dll", Path.Combine(installDirectory, "ClaudeStageObservation.dll"));
                Extract(installGuard, "ClaudeTaskHook.ps1", Path.Combine(installDirectory, "ClaudeTaskHook.ps1"));
                Extract(installGuard, "ClaudeLoopClient.ps1", Path.Combine(installDirectory, "ClaudeLoopClient.ps1"));
                Extract(installGuard, "ClaudeLoopDetection.ps1", Path.Combine(installDirectory, "ClaudeLoopDetection.ps1"));
                Extract(installGuard, "ClaudeLoopChannel.cs", Path.Combine(installDirectory, "ClaudeLoopChannel.cs"));
                Extract(installGuard, "ClaudeReaderCore.ps1", Path.Combine(installDirectory, "ClaudeReaderCore.ps1"));
                Extract(installGuard, "ClaudeRetention.cs", Path.Combine(installDirectory, "ClaudeRetention.cs"));
                Extract(installGuard, "SafeUninstall.cs", Path.Combine(installDirectory, "SafeUninstall.cs"));
                Extract(installGuard, "AppShellIdentity.cs", Path.Combine(installDirectory, "AppShellIdentity.cs"));
                Extract(installGuard, "Configure-ClaudeIntegration.ps1", Path.Combine(installDirectory, "Configure-ClaudeIntegration.ps1"));
                Extract(installGuard, "Configure-OpenCodeIntegration.ps1", Path.Combine(installDirectory, "Configure-OpenCodeIntegration.ps1"));
                string integrationsDirectory = Path.Combine(installDirectory, "integrations");
                installGuard.CreateChild(integrationsDirectory);
                foreach (string name in new[] { "ProviderEventView.ps1", "ProviderRuntime.ps1", "ProviderEventState.cs", "ProviderEventChannel.cs", "provider-events.mjs", "provider-observers.mjs", "provider-transport.mjs", "opencode-entry.js", "DeepSeekRuntime.ps1", "KimiRuntime.ps1", "HermesRuntime.ps1", "HermesBridgeProcess.cs", "hermes-setup.py", "hermes-manager.py", "ruamel.yaml-0.18.16-py3-none-any.whl", "ruamel.yaml-LICENSE.txt", "provider_bundle.py", "hermes-entry.py", "hermes-plugin.yaml", "hermes_observer.py", "provider_hooks.py", "provider_sender.py", "provider_transport.py", "kimi-integration.mjs", "kimi-setup.mjs", "CodexCloudRuntime.ps1", "CodexCloudProcess.cs", "deepseek-integration.mjs", "deepseek-setup.mjs", "deepseek-plugin.js", "package.json", "cordis.patch.yml" })
                    Extract(installGuard, "integrations." + name, Path.Combine(integrationsDirectory, name));
                string kimiDirectory = Path.Combine(integrationsDirectory, "kimi-plugin");
                installGuard.CreateChild(kimiDirectory);
                foreach (string name in new[] { "kimi.plugin.json", "kimi-hook.mjs", "kimi-observer.mjs", "provider-transport.mjs" })
                    Extract(installGuard, "integrations.kimi-plugin." + name, Path.Combine(kimiDirectory, name));
                Extract(installGuard, "DiagnosticPolicy.ps1", Path.Combine(installDirectory, "DiagnosticPolicy.ps1"));
                Extract(installGuard, "DiagnosticStore.ps1", Path.Combine(installDirectory, "DiagnosticStore.ps1"));
                Extract(installGuard, "LoopDetection.ps1", Path.Combine(installDirectory, "LoopDetection.ps1"));
                Extract(installGuard, "DiagnosticCollector.ps1", Path.Combine(installDirectory, "DiagnosticCollector.ps1"));
                Extract(installGuard, "DiagnosticRuntime.ps1", Path.Combine(installDirectory, "DiagnosticRuntime.ps1"));
                Extract(installGuard, "ReleaseUpdates.ps1", Path.Combine(installDirectory, "ReleaseUpdates.ps1"));
                string assetsDirectory = Path.Combine(installDirectory, "assets");
                installGuard.CreateChild(assetsDirectory);
                string iconPath = Path.Combine(assetsDirectory, "app-icon.ico");
                Extract(installGuard, "app-icon.ico", iconPath);

                Extract(installGuard, "AI task monitor.exe", launcher);

                string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
                string shortcut = Path.Combine(programs, "AI task monitor.lnk");
                if (SafeShortcut.TryCreate(shortcut, launcher, installDirectory, iconPath))
                    shortcutName = "AI task monitor.lnk";
                else if (SafeShortcut.TryCreate(Path.Combine(programs, "AI task monitor (new).lnk"), launcher, installDirectory, iconPath))
                    shortcutName = "AI task monitor (new).lnk";

                if (connectClaude)
                {
                    claudeSetupAttempted = true;
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
                Process.Start(new ProcessStartInfo(launcher) { WorkingDirectory = installDirectory, UseShellExecute = false });
            }

            MessageBox.Show(
                "AI task monitor установлен. " +
                (shortcutName == "AI task monitor.lnk" ? "Ярлык добавлен в меню «Пуск»." :
                    shortcutName != null ? "Существующий ярлык сохранён. Добавлен новый ярлык «AI task monitor (new)»." :
                    "Новый ярлык создать не удалось. Приложение можно открыть из папки " + installDirectory + ".") +
                (claudeConnected ? " Claude Code подключён. Перезапустите Claude Code." : ""),
                "AI task monitor",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception error)
        {
            string claudeAdvice = claudeSetupAttempted ? SafeInstallPaths.ClaudeSetupMayHaveChangedMessage() : "";
            string advice = installationAttempted ? SafeInstallPaths.PartialInstallMessage(installDirectory) : "";
            MessageBox.Show(error.Message + claudeAdvice + advice, "AI task monitor", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }

    private static void Extract(SafeInstallPaths guard, string resourceName, string destination)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        using (Stream source = assembly.GetManifestResourceStream(resourceName))
        {
            if (source == null) throw new InvalidOperationException("Missing resource: " + resourceName);
            using (FileStream target = guard.CreateNewFile(destination)) source.CopyTo(target);
        }
    }

}
