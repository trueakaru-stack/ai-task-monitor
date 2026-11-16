$ErrorActionPreference = "Stop"

# Do not remove installation files without a trustworthy inventory. A partial
# removal could delete unrelated or changed files in the installation folder.
Add-Type -AssemblyName System.Windows.Forms
if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq "ru") {
    $message = "Удаление не выполнено. Файлы приложения, ярлык и подключения сохранены.`n`nЧтобы удалить приложение, сначала отключите источники в настройках AI task monitor или по инструкциям этих источников. Затем закройте приложение и вручную проверьте и удалите нужные файлы и ярлык."
} else {
    $message = "Uninstallation was not performed. Application files, shortcut and connections were preserved.`n`nTo remove the application, first disconnect sources in AI task monitor settings or follow each source's instructions. Then close the application and manually review and remove the relevant files and shortcut."
}
[void][System.Windows.Forms.MessageBox]::Show(
    $message,
    "AI task monitor",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Warning
)
exit 1
