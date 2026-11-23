using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows.Forms;

internal static class CodexProgressInstaller
{
    [STAThread]
    private static void Main()
    {
        string installDirectory = null;
        try
        {
            InstallerLanguage.Initialize();
            string localDirectory = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            installDirectory = Path.Combine(localDirectory, "AITaskMonitor");
            string shortcutStatus = null;
            string launcher = Path.Combine(installDirectory, "AI task monitor.exe");
            string backup = null;
            string journalBackup = null;
            using (SafeInstallPaths parentGuard = SafeInstallPaths.OpenExisting(localDirectory))
            using (SafeInstallSwap swap = new SafeInstallSwap(localDirectory, installDirectory))
            {
                journalBackup = swap.PreservedJournalPath;
                if (Directory.Exists(installDirectory)) MonitorProcessCheck.EnsureNotRunning(installDirectory);
                string id = SafeInstallSwap.NewId();
                string stageDirectory = swap.StagePath(id);
                string stageIdentity;
                using (SafeInstallPaths installGuard = SafeInstallPaths.OpenExisting(localDirectory))
                {
                installGuard.CreateChild(stageDirectory);

                Extract(installGuard, "CodexProgress.ps1", Path.Combine(stageDirectory, "CodexProgress.ps1"));
                Extract(installGuard, "Uninstall-CodexProgress.ps1", Path.Combine(stageDirectory, "Uninstall-CodexProgress.ps1"));
                Extract(installGuard, "Uninstall-CodexProgress.cmd", Path.Combine(stageDirectory, "Uninstall-CodexProgress.cmd"));
                Extract(installGuard, "ClaudeStageObservation.dll", Path.Combine(stageDirectory, "ClaudeStageObservation.dll"));
                Extract(installGuard, "ClaudeTaskHook.ps1", Path.Combine(stageDirectory, "ClaudeTaskHook.ps1"));
                Extract(installGuard, "ClaudeLoopClient.ps1", Path.Combine(stageDirectory, "ClaudeLoopClient.ps1"));
                Extract(installGuard, "ClaudeLoopDetection.ps1", Path.Combine(stageDirectory, "ClaudeLoopDetection.ps1"));
                Extract(installGuard, "ClaudeLoopChannel.cs", Path.Combine(stageDirectory, "ClaudeLoopChannel.cs"));
                Extract(installGuard, "ClaudeReaderCore.ps1", Path.Combine(stageDirectory, "ClaudeReaderCore.ps1"));
                Extract(installGuard, "ClaudeRetention.cs", Path.Combine(stageDirectory, "ClaudeRetention.cs"));
                Extract(installGuard, "CodexRecentEventObserver.cs", Path.Combine(stageDirectory, "CodexRecentEventObserver.cs"));
                Extract(installGuard, "SafeUninstall.cs", Path.Combine(stageDirectory, "SafeUninstall.cs"));
                Extract(installGuard, "AppShellIdentity.cs", Path.Combine(stageDirectory, "AppShellIdentity.cs"));
                Extract(installGuard, "Configure-ClaudeIntegration.ps1", Path.Combine(stageDirectory, "Configure-ClaudeIntegration.ps1"));
                Extract(installGuard, "Configure-OpenCodeIntegration.ps1", Path.Combine(stageDirectory, "Configure-OpenCodeIntegration.ps1"));
                string integrationsDirectory = Path.Combine(stageDirectory, "integrations");
                installGuard.CreateChild(integrationsDirectory);
                foreach (string name in new[] { "ProviderEventView.ps1", "ProviderRuntime.ps1", "ProviderEventState.cs", "ProviderEventChannel.cs", "provider-events.mjs", "provider-observers.mjs", "provider-transport.mjs", "opencode-entry.js", "DeepSeekRuntime.ps1", "KimiRuntime.ps1", "HermesRuntime.ps1", "HermesBridgeProcess.cs", "hermes-setup.py", "hermes-manager.py", "ruamel.yaml-0.18.16-py3-none-any.whl", "ruamel.yaml-LICENSE.txt", "provider_bundle.py", "hermes-entry.py", "hermes-plugin.yaml", "hermes_observer.py", "provider_hooks.py", "provider_sender.py", "provider_transport.py", "kimi-integration.mjs", "kimi-setup.mjs", "CodexCloudRuntime.ps1", "CodexCloudProcess.cs", "deepseek-integration.mjs", "deepseek-setup.mjs", "deepseek-plugin.js", "package.json", "cordis.patch.yml" })
                    Extract(installGuard, "integrations." + name, Path.Combine(integrationsDirectory, name));
                string kimiDirectory = Path.Combine(integrationsDirectory, "kimi-plugin");
                installGuard.CreateChild(kimiDirectory);
                foreach (string name in new[] { "kimi.plugin.json", "kimi-hook.mjs", "kimi-observer.mjs", "provider-transport.mjs" })
                    Extract(installGuard, "integrations.kimi-plugin." + name, Path.Combine(kimiDirectory, name));
                Extract(installGuard, "DiagnosticPolicy.ps1", Path.Combine(stageDirectory, "DiagnosticPolicy.ps1"));
                Extract(installGuard, "DiagnosticStore.ps1", Path.Combine(stageDirectory, "DiagnosticStore.ps1"));
                Extract(installGuard, "LoopDetection.ps1", Path.Combine(stageDirectory, "LoopDetection.ps1"));
                Extract(installGuard, "DiagnosticCollector.ps1", Path.Combine(stageDirectory, "DiagnosticCollector.ps1"));
                Extract(installGuard, "DiagnosticRuntime.ps1", Path.Combine(stageDirectory, "DiagnosticRuntime.ps1"));
                Extract(installGuard, "ReleaseUpdates.ps1", Path.Combine(stageDirectory, "ReleaseUpdates.ps1"));
                string assetsDirectory = Path.Combine(stageDirectory, "assets");
                installGuard.CreateChild(assetsDirectory);
                string iconPath = Path.Combine(assetsDirectory, "app-icon.ico");
                Extract(installGuard, "app-icon.ico", iconPath);

                Extract(installGuard, "AI task monitor.exe", Path.Combine(stageDirectory, "AI task monitor.exe"));
                VerifyPayload(installGuard, stageDirectory);
                stageIdentity = SafeInstallSwap.ReadStageIdentity(stageDirectory);
                }
                swap.Commit(id, stageIdentity);
                backup = swap.BackupDirectory;
            }

            string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            string shortcut = Path.Combine(programs, "AI task monitor.lnk");
            string alternateShortcut = Path.Combine(programs, "AI task monitor (new).lnk");
            string installedIcon = Path.Combine(installDirectory, "assets", "app-icon.ico");
            if (SafeShortcut.TargetsCurrentLauncher(shortcut, launcher)) shortcutStatus = "existing-main";
            else if (SafeShortcut.TargetsCurrentLauncher(alternateShortcut, launcher)) shortcutStatus = "existing-alternate";
            else if (SafeShortcut.TryCreate(shortcut, launcher, installDirectory, installedIcon)) shortcutStatus = "created-main";
            else if (SafeShortcut.TryCreate(alternateShortcut, launcher, installDirectory, installedIcon)) shortcutStatus = "created-alternate";

            bool claudeConnected = false, claudeFailed = false;
            if (backup == null && ClaudeCommandFound())
            {
                DialogResult answer = MessageBox.Show(
                    InstallerLanguage.Text("Найден файл команды с именем claude. Если это Claude Code, перед подключением обновите все используемые копии Claude Code, включая Claude Desktop, до версии 2.1.101 или новее. Закройте программы, которые могут изменять настройки Claude Code. Приложение не проверяет версии и закрытие программ автоматически.\n\nПодключить Claude Code? Существующие hooks сохранятся.",
                    "A command file named claude was found. If this is Claude Code, update all copies of Claude Code you use, including Claude Desktop, to version 2.1.101 or later before connecting. Close programs that may change Claude Code settings. The app does not check versions or whether programs are closed automatically.\n\nConnect Claude Code? Existing hooks will be preserved."),
                    "AI task monitor", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (answer == DialogResult.Yes)
                {
                    try
                    {
                        using (Process setup = Process.Start(new ProcessStartInfo
                        {
                            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(installDirectory, "Configure-ClaudeIntegration.ps1") + "\" -Mode Install",
                            WorkingDirectory = installDirectory, UseShellExecute = false, CreateNoWindow = true,
                        }))
                        { setup.WaitForExit(); claudeConnected = setup.ExitCode == 0; claudeFailed = !claudeConnected; }
                    }
                    catch { claudeFailed = true; }
                }
            }
            bool launched = false;
            try { Process.Start(new ProcessStartInfo(launcher) { WorkingDirectory = installDirectory, UseShellExecute = false }); launched = true; }
            catch { }
            MessageBox.Show(
                InstallerLanguage.Text("AI task monitor установлен. ", "AI task monitor is installed. ") +
                (shortcutStatus == "existing-main" ? InstallerLanguage.Text("Существующий ярлык в меню «Пуск» сохранён.", "The existing Start menu shortcut was preserved.") :
                    shortcutStatus == "existing-alternate" ? InstallerLanguage.Text("Существующий ярлык «AI task monitor (new)» сохранён.", "The existing AI task monitor (new) shortcut was preserved.") :
                    shortcutStatus == "created-main" ? InstallerLanguage.Text("Ярлык добавлен в меню «Пуск».", "A shortcut was added to the Start menu.") :
                    shortcutStatus == "created-alternate" ? InstallerLanguage.Text("Существующий ярлык сохранён. Добавлен новый ярлык «AI task monitor (new)».", "The existing shortcut was preserved. A new shortcut, AI task monitor (new), was added.") :
                    InstallerLanguage.Text("Не удалось подтвердить подходящий ярлык или создать новый. Приложение можно открыть из папки ", "An existing shortcut could not be confirmed and a new shortcut could not be created. You can open the app from ") + installDirectory + ".") +
                (backup != null ? InstallerLanguage.Text(" Прежняя папка сохранена: ", " The previous folder was preserved at: ") + backup + "." : "") +
                (journalBackup != null ? InstallerLanguage.Text(" Исходный служебный файл сохранён: ", " The original update file was preserved at: ") + journalBackup + "." : "") +
                (claudeConnected ? InstallerLanguage.Text(" Claude Code подключён. Перезапустите Claude Code.", " Claude Code is connected. Restart Claude Code.") : "") +
                (claudeFailed ? InstallerLanguage.Text(" Не удалось подключить Claude Code. Проверьте настройки подключения.", " Could not connect Claude Code. Review its connection settings.") : "") +
                (!launched ? InstallerLanguage.Text(" Приложение не удалось запустить автоматически.", " The app could not be opened automatically.") : ""),
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

    private static bool ClaudeCommandFound()
    {
        return ClaudeCommandFound(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Environment.GetEnvironmentVariable("PATH"));
    }

    internal static bool ClaudeCommandFound(string profile, string roaming, string local, string pathValue)
    {
        string desktop = Path.GetFullPath(Path.Combine(local, @"Programs\Claude\Claude.exe"));
        string[] paths = (Path.Combine(profile, @".local\bin") + ";" + Path.Combine(roaming, "npm") + ";" +
            (pathValue ?? "")).Split(';');
        foreach (string part in paths)
        {
            try
            {
                string directory = part.Trim().Trim('"');
                if (!Path.IsPathRooted(directory) || directory.StartsWith(@"\\", StringComparison.Ordinal)) continue;
                foreach (string name in new[] { "claude.exe", "claude.cmd", "claude.bat" })
                {
                    string candidate = Path.GetFullPath(Path.Combine(directory, name));
                    if (!String.Equals(candidate, desktop, StringComparison.OrdinalIgnoreCase) && File.Exists(candidate)) return true;
                }
            }
            catch { }
        }
        return false;
    }

    private static void Extract(SafeInstallPaths guard, string resourceName, string destination)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        using (Stream source = assembly.GetManifestResourceStream(resourceName))
        {
            if (source == null) throw new InvalidOperationException(InstallerLanguage.Text("Не найден компонент: ", "Missing resource: ") + resourceName);
            using (FileStream target = guard.CreateNewFile(destination)) source.CopyTo(target);
        }
    }

    private static void VerifyPayload(SafeInstallPaths guard, string directory)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        foreach (string resource in assembly.GetManifestResourceNames())
        {
            string path;
            const string kimi = "integrations.kimi-plugin.", integrations = "integrations.";
            if (resource.StartsWith(kimi, StringComparison.Ordinal))
                path = Path.Combine(directory, "integrations", "kimi-plugin", resource.Substring(kimi.Length));
            else if (resource.StartsWith(integrations, StringComparison.Ordinal))
                path = Path.Combine(directory, "integrations", resource.Substring(integrations.Length));
            else if (resource == "app-icon.ico") path = Path.Combine(directory, "assets", "app-icon.ico");
            else path = Path.Combine(directory, resource);
            using (Stream expected = assembly.GetManifestResourceStream(resource))
            using (Stream actual = guard.OpenPreparedFile(path))
            using (SHA256 algorithm = SHA256.Create())
            {
                if (expected == null) throw new IOException("A prepared component is missing.");
                byte[] left = algorithm.ComputeHash(expected), right = algorithm.ComputeHash(actual);
                if (left.Length != right.Length) throw new IOException("A prepared component changed.");
                for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) throw new IOException("A prepared component changed.");
            }
        }
    }

}
