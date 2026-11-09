param(
 [string]$ProgressFile = "",
 [string]$SnapshotFile = "",
 [switch]$CompactMode,
 [ValidateSet("","system","dark","light")][string]$ThemeOverride = "",
 [ValidateSet("","system","ru","en")][string]$LanguageOverride = "",
 [string]$PreferencesFile = "",
 [switch]$PreviewLanguageUiTest,
 [string]$SettingsSnapshotFile = "",
 [string]$JournalSnapshotFile = "",
 [switch]$PreviewJournalSettings,
 [switch]$PreviewJournalClearConfirmation,
 [string]$JournalDropdownSnapshotFile = "",
 [string]$JournalFilterDropdownSnapshotFile = "",
 [switch]$PreviewJournalFilterTask,
 [switch]$PreviewSettingsBackHover,
 [switch]$PreviewSettingsEnd,
 [switch]$PreviewSources,
 [ValidateSet('','disconnected','connected','error','partial')][string]$PreviewCloudState = '',
 [switch]$PreviewCloudUiTest,
 [switch]$PreviewCloudTask,
 [switch]$PreviewKimiTask,
 [switch]$PreviewDeepSeekUiTest,
 [switch]$PreviewDeepSeekErrorUiTest,
 [ValidateSet('','disconnected','connected','disabled','error')][string]$PreviewKimiState = '',
 [switch]$PreviewKimiUiTest,
 [ValidateSet('','absent','prepared','enabled','long','error','unselected')][string]$PreviewHermesState = '',
 [switch]$PreviewHermesUiTest,
 [switch]$PreviewHermesFocus,
 [switch]$PreviewHermesSelection,
 [switch]$PreviewHermesDisableSelection,
 [switch]$PreviewAbout,
 [switch]$PreviewAboutUiTest,
 [switch]$PreviewClipboardUiTest,
 [switch]$PreviewUpdate,
 [switch]$PreviewUpdateUiTest,
 [switch]$PreviewLoopWarning,
 [switch]$PreviewLoopSettings,
 [switch]$PreviewLoopUiTest,
 [string]$PreviewClaudeLoopPipe = "",
 [switch]$PreviewClaudeLoopUiTest,
 [switch]$PreviewJournalRecoveryUiTest,
 [string]$JournalRecoverySnapshotFile = "",
 [switch]$PreviewIconUiTest,
 [string]$PreviewStartupReadyFile = "",
 [ValidateRange(0,5000)][int]$PreviewStartupDelayMilliseconds = 0,
 [ValidateRange(-1,6)][int]$PreviewActiveTasks = -1,
 [switch]$PreviewManyProviders,
 [switch]$PreviewTabsUiTest,
 [ValidateSet("default","planned","unplanned")][string]$PreviewScenario = "default",
 [switch]$PreviewActivityUiTest,
 [switch]$PreviewFocusUiTest,
 [ValidateSet("default","on","off")][string]$PreviewMotion = "default",
 [ValidateRange(0,2500)][int]$PreviewMotionDelayMilliseconds = 0,
 [switch]$PreviewMotionUiTest,
 [switch]$PreviewOffscreen,
 [switch]$PreviewUnconfirmed,
 [switch]$PreviewPlanUnconfirmed,
 [switch]$PreviewPlanUiTest,
 [ValidateSet("all","codex","claude","kimi","deepseek","hermes","opencode")][string]$PreviewProvider = "all",
 [string]$ClaudeEventFile = "",
 [string]$DiagnosticDirectory = "",
 [string]$HintSnapshotFile = "",
 [string]$HintRawSnapshotFile = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
if($PreviewLoopUiTest){
 if($PreviewActiveTasks -lt 1 -or -not $PreviewLoopWarning -or -not $SnapshotFile -or -not $DiagnosticDirectory){throw "Loop UI tests require synthetic tasks, a snapshot, and an isolated diagnostic directory."}
 $previewDataPath=[IO.Path]::GetFullPath($DiagnosticDirectory)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $previewDataPath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Loop UI tests require a diagnostic directory inside the temporary folder."}
}
if($PreviewClaudeLoopPipe -or $PreviewClaudeLoopUiTest){
 if(-not $SnapshotFile -or -not $DiagnosticDirectory -or $PreviewActiveTasks -lt 2 -or $PreviewClaudeLoopPipe -cnotmatch '^AITM\.Test\.[A-Za-z0-9_.-]{1,100}$'){
  throw "Claude loop previews require synthetic tasks, a test pipe, a snapshot, and an isolated diagnostic directory."
 }
 $previewDataPath=[IO.Path]::GetFullPath($DiagnosticDirectory)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $previewDataPath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Claude loop previews require a diagnostic directory inside the temporary folder."}
}
if($PreviewJournalRecoveryUiTest){
 if(-not $SnapshotFile -or -not $DiagnosticDirectory -or $PreviewActiveTasks -lt 0){throw "Journal recovery tests require synthetic tasks, a snapshot, and an isolated diagnostic directory."}
 $previewDataPath=[IO.Path]::GetFullPath($DiagnosticDirectory)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $previewDataPath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Journal recovery tests require a diagnostic directory inside the temporary folder."}
}
if($PreviewIconUiTest -and (-not $SnapshotFile -or $PreviewActiveTasks -lt 1)){throw "Icon UI tests require a synthetic snapshot."}
if($PreviewSources -and (-not $SnapshotFile -or -not $SettingsSnapshotFile -or $PreviewActiveTasks -lt 0)){throw 'Source previews require synthetic tasks and settings snapshots.'}
if($PreviewCloudState -and -not $PreviewSources){throw 'Cloud source previews require synthetic source snapshots.'}
if($PreviewCloudUiTest -and (-not $PreviewSources -or -not $PreferencesFile)){throw 'Cloud UI tests require synthetic sources and isolated preferences.'}
if($PreviewCloudTask -and (-not $SnapshotFile -or $PreviewActiveTasks -lt 0)){throw 'Cloud task previews require synthetic tasks and a snapshot.'}
if($PreviewKimiTask -and (-not $SnapshotFile -or $PreviewActiveTasks -lt 0)){throw 'Kimi task previews require synthetic tasks and a snapshot.'}
if($PreviewDeepSeekUiTest -and -not $PreviewSources){throw 'DeepSeek UI tests require a synthetic source preview.'}
if($PreviewDeepSeekErrorUiTest -and -not $PreviewDeepSeekUiTest){throw 'DeepSeek error previews require the synthetic DeepSeek UI test.'}
if(($PreviewKimiState -or $PreviewKimiUiTest) -and -not $PreviewSources){throw 'Kimi source previews require synthetic source snapshots.'}
if(($PreviewHermesState -or $PreviewHermesUiTest) -and -not $PreviewSources){throw 'Hermes source previews require synthetic source snapshots.'}
if($PreviewHermesFocus -and (-not $PreviewSources -or $PreviewHermesState -notin @('prepared','enabled','long'))){throw 'Hermes focus previews require a prepared synthetic profile.'}
if($PreviewHermesSelection -and -not $PreviewHermesFocus){throw 'Hermes selection previews require the isolated focus preview.'}
if($PreviewHermesDisableSelection -and -not $PreviewHermesSelection){throw 'Hermes disable selection requires the isolated selection preview.'}
if(($PreviewManyProviders -or $PreviewTabsUiTest) -and (-not $SnapshotFile -or -not $PreviewManyProviders -or $PreviewActiveTasks -ne 6)){throw 'Provider tab previews require six synthetic tasks and a snapshot.'}
if($PreviewActivityUiTest -and (-not $SnapshotFile -or $PreviewActiveTasks -ne 1 -or $PreviewScenario -eq "default")){throw "Activity UI tests require one synthetic task, a scenario and a snapshot."}
if($PreviewFocusUiTest -and (-not $SnapshotFile -or $PreviewActiveTasks -ne 1 -or -not $CompactMode)){throw "Focus UI tests require a compact synthetic snapshot."}
if(($PreviewMotion -ne "default" -or $PreviewMotionDelayMilliseconds -gt 0) -and (-not $SnapshotFile -or $PreviewActiveTasks -lt 1)){throw "Motion previews require synthetic tasks and a snapshot."}
if($PreviewMotionUiTest -and (-not $SnapshotFile -or $PreviewActiveTasks -ne 1)){throw "Motion UI tests require one synthetic task and a snapshot."}
if($PreferencesFile){
 if(-not $SnapshotFile -or $PreviewActiveTasks -lt 0){throw 'Isolated preferences are available only for synthetic snapshots.'}
 $preferencesPath=[IO.Path]::GetFullPath($PreferencesFile)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $preferencesPath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Isolated preferences must be inside the temporary folder.'}
}
if($PreviewLanguageUiTest -and (-not $PreferencesFile -or -not $SnapshotFile -or $PreviewActiveTasks -lt 1)){throw 'Language UI tests require isolated preferences and synthetic tasks.'}
if(($PreviewPlanUnconfirmed -or $PreviewPlanUiTest) -and (-not $SnapshotFile -or $PreviewActiveTasks -ne 1 -or $PreviewScenario -ne 'planned')){throw 'Plan UI tests require one synthetic planned task and a snapshot.'}
if($PreviewOffscreen -and (-not $SnapshotFile -or $PreviewActiveTasks -lt 0)){throw "Offscreen previews require synthetic tasks and a snapshot."}
if(($PreviewAbout -or $PreviewAboutUiTest) -and (-not $PreviewAbout -or -not $SnapshotFile -or $PreviewActiveTasks -lt 0)){throw "About previews require synthetic tasks and a snapshot."}
if($PreviewClipboardUiTest -and -not $PreviewAboutUiTest){throw 'Clipboard UI testing requires the isolated About preview.'}
if(($PreviewUpdate -or $PreviewUpdateUiTest) -and (-not $PreviewUpdate -or -not $SnapshotFile -or $PreviewActiveTasks -lt 0)){throw "Update previews require synthetic tasks and a snapshot."}
if($PreviewStartupReadyFile){
 if(-not $SnapshotFile -or -not $DiagnosticDirectory -or $PreviewStartupDelayMilliseconds -le 0){throw "A startup probe requires an isolated snapshot test."}
 $probePath=[IO.Path]::GetFullPath($PreviewStartupReadyFile)
 $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $probePath.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw "A startup probe must be inside the temporary folder."}
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$sessionIndex = Join-Path $codexHome "session_index.jsonl"
$sessionsDirectory = Join-Path $codexHome "sessions"
$lockDirectory = Join-Path $codexHome "thread-writer-locks"
$script:isStoreEdition=Test-Path -LiteralPath (Join-Path $PSScriptRoot "store-channel.marker") -PathType Leaf
$dataDirectory=if($script:isStoreEdition){Join-Path $env:USERPROFILE '.ai-task-monitor'}else{Join-Path $env:LOCALAPPDATA 'CodexTaskProgress'}
$claudeEventPath = if($ClaudeEventFile){$ClaudeEventFile}else{Join-Path $dataDirectory "claude-events-v2.jsonl"}
$claudeLegacyEventPath = if($ClaudeEventFile){""}else{Join-Path $dataDirectory "claude-events.jsonl"}
$script:fingerprint = ""
$script:sessionFiles = @{}
$script:sessionDates = [hashtable]::Synchronized(@{})
$script:sessionDiscovery = [PSCustomObject]@{
 Gate=[object]::new()
 Files=$script:sessionFiles
 Rollouts=$null
 LastScanTicks=[long]0
 Attempted=$false
 ScanFailed=$false
 RetrySeconds=5
 HotUntilTicks=[long]0
 IndexVersions=@{}
 DatedMisses=@{}
 RolloutMisses=@{}
}
$script:sessionIndexLookup = @{}
$script:planCache = @{}
$script:planConfirmations = @{}
$script:lifecycleState = @{}
$script:observedCodex = @{}
$script:monitorStartedUtc = [DateTime]::UtcNow
$script:lastTasks = @()
$script:lastAllTasks = @()
$script:lastCodexTasks = @()
$script:lastClaudeTasks = @()
$script:sourceErrors = @()
$script:compactTaskId = ""
$script:taskPriority = @{}
$script:taskPriorityCounter = 0
$script:settingsPath = if($PreferencesFile){$preferencesPath}else{Join-Path $dataDirectory "settings.json"}
$script:diagnosticDirectory = if($DiagnosticDirectory){$DiagnosticDirectory}else{Join-Path (Split-Path -Parent $script:settingsPath) "diagnostics"}
$script:diagnosticRuntime = $null
$script:diagnosticError = ""
$script:diagnosticModulesAvailable = $true
$script:claudeLoopChannel=$null
$script:claudeLoopStates=New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
$script:claudeLoopError=""
$script:claudeLoopModulesAvailable=$false
$script:previewDiagnosticFailure=""
$script:previewReaderFailure=""
try {
 foreach($module in @("DiagnosticPolicy.ps1","DiagnosticStore.ps1","LoopDetection.ps1","DiagnosticCollector.ps1","DiagnosticRuntime.ps1")){
  $modulePath=Join-Path $PSScriptRoot $module
  if(-not (Test-Path -LiteralPath $modulePath -PathType Leaf)){throw "Diagnostic module missing."}
  . $modulePath
 }
}catch{$script:diagnosticModulesAvailable=$false;$script:diagnosticError="Журнал недоступен";if($PreviewStartupReadyFile){$script:previewDiagnosticFailure=$_.Exception.ToString()}}
try{
 . (Join-Path $PSScriptRoot "ClaudeLoopDetection.ps1")
 if(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "ClaudeLoopChannel.cs") -PathType Leaf)){throw "Claude loop channel missing."}
 $script:claudeLoopModulesAvailable=$true
}catch{$script:claudeLoopModulesAvailable=$false}
try { . (Join-Path $PSScriptRoot "ClaudeReaderCore.ps1") }catch{if($PreviewStartupReadyFile){$script:previewReaderFailure=$_.Exception.ToString()}}
$script:claudeRetentionAvailable=$false
try{
 if(-not ('AITaskMonitor.Claude.Retention' -as [type])){
  Add-Type -AssemblyName System.Web.Extensions
  Add-Type -Path (Join-Path $PSScriptRoot 'ClaudeRetention.cs') -ReferencedAssemblies System.Web.Extensions
 }
 $script:claudeRetentionAvailable=$true
}catch{}
$script:releaseUpdatesAvailable=$false
$script:releaseUpdatesPath=Join-Path $PSScriptRoot "ReleaseUpdates.ps1"
try { . $script:releaseUpdatesPath;if(-not $script:isStoreEdition){Initialize-UpdateTransport};$script:releaseUpdatesAvailable=$true }catch{}
$script:externalProviderController=$null
$script:externalProviderModulesAvailable=$false
$script:lastExternalTasks=@()
$script:seenExternalConnections=@{}
try{
 . (Join-Path $PSScriptRoot 'integrations\ProviderEventView.ps1')
 . (Join-Path $PSScriptRoot 'integrations\ProviderRuntime.ps1')
 $script:externalProviderController=New-ExternalProviderController
 $script:externalProviderModulesAvailable=$true
}catch{}
$script:kimiModulesAvailable=$false
$script:kimiController=$null
try{
 . (Join-Path $PSScriptRoot 'integrations\KimiRuntime.ps1')
 $script:kimiController=New-KimiMonitorController -AppRoot $PSScriptRoot
 $script:kimiModulesAvailable=$true
}catch{}
$script:deepSeekModulesAvailable=$false
$script:deepSeekController=$null
try{
 . (Join-Path $PSScriptRoot 'integrations\DeepSeekRuntime.ps1')
 $script:deepSeekController=New-DeepSeekMonitorController -AppRoot $PSScriptRoot
 $script:deepSeekModulesAvailable=$true
}catch{}
$script:hermesModulesAvailable=$false
$script:hermesController=$null
$script:hermesPreviewRequest=''
if(-not $PreviewSources){
 try{
  . (Join-Path $PSScriptRoot 'integrations\HermesRuntime.ps1')
  $script:hermesController=New-HermesMonitorController -AppRoot $PSScriptRoot
  $script:hermesModulesAvailable=$true
 }catch{}
}
$script:codexCloudModulesAvailable=$false
$script:codexCloudController=$null
$script:codexCloudPreferenceError=''
try{
 if(-not ('AITaskMonitor.CodexCloud.Command' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'integrations\CodexCloudProcess.cs') -ErrorAction Stop}
 . (Join-Path $PSScriptRoot 'integrations\CodexCloudRuntime.ps1')
 $script:codexCloudController=New-CodexCloudController
 $script:codexCloudModulesAvailable=$true
}catch{}
$script:currentVersion='0.2.7-alpha'
$script:availableUpdate=$null
$script:dismissedUpdate=''
$script:updateRequest=$null
$script:updateCancellation=$null
$script:updateParser=$null
$script:updateParserRequest=$null
$script:updateTransportResult=$null
$script:updateRetry=if($script:releaseUpdatesAvailable){New-UpdateRetryState}else{$null}
$script:themeMode = "system"
$script:resolvedTheme = "dark"
$script:palette = @{}
$script:motionEnabled = $false
$accentColor = [Windows.SystemParameters]::WindowGlassColor
$script:accentHex = "#{0:X2}{1:X2}{2:X2}" -f $accentColor.R, $accentColor.G, $accentColor.B
$accentLuma = (0.299 * $accentColor.R) + (0.587 * $accentColor.G) + (0.114 * $accentColor.B)
$script:accentForeground = if ($accentLuma -gt 155) { "#161616" } else { "#FFFFFF" }
$script:languageMode='system'
$script:resolvedLanguage='ru'
$script:translations=@{
 'Окно всегда поверх других окон'='Keep window on top'
 'Свернуть в панель задач'='Minimize to taskbar'
 'Компактный режим'='Compact view'
 'Закрыть'='Close'
 'Ход выполнения'='Progress'
 'Открыть настройки'='Open settings'
 'Настройки'='Settings'
 'Развернуть'='Expand'
 'Назад к задачам'='Back to tasks'
 'Внешний вид'='Appearance'
 'Системная'='System'
 'Системный'='System'
 'Тёмная'='Dark'
 'Светлая'='Light'
 'Язык'='Language'
 'Источники'='Sources'
 'Использует установленный Codex, его вход в аккаунт и интернет. Статус облачных задач может быть неподтверждённым.'='Uses the installed Codex, its signed-in account and the internet. Cloud task status may be unconfirmed.'
 'Не удалось получить облачные задачи. Проверьте установку Codex, вход и интернет.'='Could not retrieve cloud tasks. Check the Codex installation, sign-in and internet connection.'
 'Показаны не все облачные задачи.'='Not all cloud tasks are shown.'
 'Не удалось сохранить настройку облака.'='Could not save the cloud setting.'
 'Не удалось сохранить настройку. Облако может включиться после перезапуска.'='Could not save the setting. Cloud monitoring may resume after restart.'
 'Проверка'='Checking'
 'Облако: '='Cloud: '
 'Перед подключением обновите все используемые копии Claude Code, в том числе в Claude Desktop, до версии 2.1.101 или новее. Перед подключением или отключением закройте Claude Code, Claude Desktop и другие программы, которые могут изменять настройки Claude Code, включая их фоновые процессы. Приложение не проверяет версии и закрытие программ автоматически. Приложение добавит локальные hooks в настройки Claude Code. Права администратора, токены и вход в аккаунт не нужны. После подключения перезапустите Claude Desktop или Claude Code. Пока отслеживаются только локальные сессии.'='Before connecting, update every copy of Claude Code you use, including in Claude Desktop, to version 2.1.101 or later. Before connecting or disconnecting, close Claude Code, Claude Desktop and other programs that may change Claude Code settings, including their background processes. The app does not automatically check versions or whether these programs are closed. The app adds local hooks to Claude Code settings. No administrator rights, tokens or sign-in are needed. Restart Claude Desktop or Claude Code after connecting. Only local sessions are monitored for now.'
 'Приложение добавит локальный плагин OpenCode. Поддерживаются совместимые версии 1 начиная с 1.18.29 и версия 2. После подключения перезапустите OpenCode.'='The app adds a local OpenCode plugin. Compatible versions 1.18.29 and later within version 1, and version 2, are supported. Restart OpenCode after connecting.'
 'Не удалось подтвердить установку или совместимость OpenCode'='Could not confirm the OpenCode installation or compatibility'
 'Не удалось прочитать подключение OpenCode'='Could not read the OpenCode connection'
 'Для локальных задач Kimi Code CLI 2.5.0, установленного через npm: скопируйте путь, откройте в Kimi меню /plugins и установите плагин через Custom. Затем выполните /reload или откройте новую сессию. Статус задач не подтверждён; завершённые задачи могут оставаться в списке. Отключение выполняется в меню Kimi.'='For local tasks in Kimi Code CLI 2.5.0 installed via npm: copy the path, open /plugins in Kimi and install the plugin through Custom. Then run /reload or open a new session. Task status is unconfirmed; finished tasks may remain listed. Disable the plugin in Kimi.'
 'Скопировать путь'='Copy path'
 'Плагин включён'='Plugin enabled'
 'Плагин отключён'='Plugin disabled'
 'Плагин не установлен'='Plugin not installed'
 'Не удалось проверить плагин Kimi Code.'='Could not check the Kimi Code plugin.'
 'Не удалось скопировать путь.'='Could not copy the path.'
 'Подключение проверено с DeepSeek Harness 0.2.1-rc.5 и pnpm 11.25.0. Приложение добавит локальный плагин в выбранный профиль. После подключения перезапустите DeepSeek Harness.'='Connection has been tested with DeepSeek Harness 0.2.1-rc.5 and pnpm 11.25.0. The app adds a local plugin to the selected profile. Restart DeepSeek Harness after connecting.'
 'Профиль'='Profile'
 'Профиль DeepSeek Harness'='DeepSeek Harness profile'
 'Выберите профиль'='Select a profile'
 'Подключение DeepSeek Harness неполное или его файлы изменены.'='The DeepSeek Harness connection is incomplete or its files were changed.'
 'Версия DeepSeek Harness или pnpm не подтверждена.'='The DeepSeek Harness or pnpm version could not be verified.'
 'Не удалось изменить подключение DeepSeek Harness.'='Could not change the DeepSeek Harness connection.'
 'Не удалось проверить профиль DeepSeek Harness.'='Could not check the DeepSeek Harness profile.'
 'Профиль DeepSeek Desktop пока не поддерживается.'='The DeepSeek Desktop profile is not supported yet.'
 'Профиль Hermes'='Hermes profile'
 'Подготовить'='Prepare'
 'Не подготовлен'='Not prepared'
 'Плагин подготовлен'='Plugin prepared'
 'Включён локально'='Enabled locally'
 'Отключён локально'='Disabled locally'
 'Подготовка'='Preparing'
 'Не удалось подготовить плагин Hermes.'='Could not prepare the Hermes plugin.'
 'Не удалось проверить профиль Hermes.'='Could not check the Hermes profile.'
 'Не удалось скопировать команду.'='Could not copy the command.'
 'Выберите профиль и нажмите «Подготовить». Полностью закройте Hermes и фоновые службы. Выполните команду включения в PowerShell. После запуска или переподключения монитора дождитесь статуса «Включён локально» у выбранного профиля, затем запустите или перезапустите Hermes. Прежние задачи не показываются. Для отключения снова закройте Hermes и фоновые службы и выполните команду отключения в PowerShell. Перед запуском менеджера команда локально проверяет файлы .env, которые могут содержать ключи; сама проверка не сохраняет, не выводит и не передаёт их. Проверено с исходной установкой Hermes Agent v0.22.7.'='Select a profile and choose Prepare. Close Hermes and its background services completely. Run the enable command in PowerShell. After starting or reconnecting the monitor, wait until the selected profile says “Enabled locally”, then start or restart Hermes. Previous tasks are not shown. To disable, close Hermes and its background services again and run the disable command in PowerShell. Before starting the manager, the command checks local .env files, which may contain keys; the check itself does not save, display or transmit them. Tested with a source installation of Hermes Agent v0.22.7.'
 'Включение: '='Enable: '
 'Отключение: '='Disable: '
 'Команда включения Hermes'='Hermes enable command'
 'Команда отключения Hermes'='Hermes disable command'
 'Журнал'='Journal'
 'Срок хранения'='Retention period'
 'Срок хранения журнала'='Journal retention period'
 'Максимальный размер'='Maximum size'
 'Максимальный размер журнала'='Maximum journal size'
 'Хранение Claude Code'='Claude Code storage'
 'Срок хранения событий'='Event retention period'
 'Максимальный размер событий'='Maximum event size'
 'События очищаются автоматически. Резервные копии настроек хранятся 30 дней; последняя сохраняется.'='Events are cleaned automatically. Settings backups are kept for 30 days; the most recent is retained.'
 'Не удалось очистить данные Claude Code'='Could not clean Claude Code data'
 'Настройки хранения Claude Code повреждены'='Claude Code storage settings are invalid'
 'Не удалось сохранить настройки хранения Claude Code'='Could not save Claude Code storage settings'
 'Очистка Claude Code недоступна'='Claude Code cleanup is unavailable'
 'Открыть журнал'='Open journal'
 'Очистить'='Clear'
 'Удалить все события журнала? История Codex и Claude Code не изменится.'='Delete all journal events? Codex and Claude Code history will not change.'
 'Удалить'='Delete'
 'Отмена'='Cancel'
 'Возможный цикл'='Possible loop'
 'Количество ошибок'='Error count'
 'Количество повторных ошибок для предупреждения'='Repeated error threshold'
 'Интервал'='Time window'
 'Интервал для повторных ошибок'='Time window for repeated errors'
 'Предупреждение не останавливает задачу.'='The warning does not stop the task.'
 'О приложении'='About'
 'Отзывы и предложения'='Feedback and suggestions'
 'Адрес для отзывов и предложений'='Feedback email address'
 'Скопировать адрес'='Copy email address'
 'Не удалось скопировать адрес. Выделите его и скопируйте вручную.'='Could not copy the address. Select and copy it manually.'
 'Не удалось открыть почтовое приложение. Напишите на truea.k.a.ru@gmail.com.'='Could not open your email app. Write to truea.k.a.ru@gmail.com.'
 'Назад к настройкам'='Back to settings'
 'AI Task Monitor показывает задачи и доступные сведения об их ходе. Локальные источники: Codex, Claude Code, OpenCode, DeepSeek Harness, Kimi Code и Hermes Agent. Для Codex также доступны облачные задачи с неподтверждённым статусом.'='AI Task Monitor shows tasks and available progress information. Local sources: Codex, Claude Code, OpenCode, DeepSeek Harness, Kimi Code and Hermes Agent. Codex cloud tasks are also available with unconfirmed status.'
 'При нескольких источниках можно переключать задачи по вкладкам. Компактное окно остаётся поверх других и показывает до трёх задач с переключением между ними. Тему можно выбрать вручную или использовать тему Windows. Если источник недоступен, приложение сообщит об этом.'='When multiple sources are available, use tabs to switch between them. The compact window stays on top and lets you switch between up to three tasks. Choose a theme or follow Windows. The app reports unavailable sources.'
 'Если задача публикует план, приложение показывает выполненные, текущий и следующие этапы. В карточке одновременно видны до пяти этапов; остальные можно прокрутить. Без плана отображается текущее действие без списка этапов.'='When a task publishes a plan, the app shows completed, current and upcoming steps. Up to five steps are visible at once; scroll to see the rest. Without a plan, only the current action is shown.'
 'Если источник сообщает общий прогресс задачи, точный процент показывается числом, а приблизительный — со знаком ≈. Если известен только план, показывается текущий этап или число завершённых этапов.'='When a source reports overall task progress, an exact percentage is shown as a number and an estimate is marked ≈. If only a plan is available, the current step or completed step count is shown.'
 'Диагностический журнал хранится локально. В настройках можно выбрать срок и размер хранения, просмотреть события или очистить журнал.'='The diagnostic journal stays on this device. In Settings you can choose its retention period and size, view events or clear the journal.'
 'Приложение может предупредить о возможном цикле при повторных ошибках одной команды. Это предположение, оно не останавливает задачу.'='The app may warn about a possible loop when one command repeatedly fails. This is a warning only and does not stop the task.'
 'Данные задач обрабатываются локально. Для Claude Code после подключения используются локальные hooks. Самому монитору не нужны вход в аккаунт, токены или права администратора.'='Task data is processed locally. Claude Code uses local hooks after connection. The monitor does not require sign-in, tokens or administrator rights.'
 'При запуске и раз в сутки приложение проверяет новые версии на GitHub, не отправляя данные задач. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению.'='The app checks GitHub for updates at startup and daily without sending task data. Feedback opens in your email app and is sent only if you choose to send it.'
 'Обновления этой версии устанавливаются через Microsoft Store. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению.'='Updates for this edition are installed through Microsoft Store. Feedback opens in your email app and is sent only if you choose to send it.'
 'Фильтр журнала по задаче'='Filter journal by task'
 'События журнала'='Journal events'
 'Доступна новая версия'='A new version is available'
 'Скачайте приложение, полностью закройте старую версию и переустановите новую.'='Download the app, quit the old version completely, and install the new one.'
 'Не удалось открыть страницу загрузки.'='Could not open the download page.'
 'Позже'='Later'
 'Напомнить при следующем запуске'='Remind me next time'
 'Скачать'='Download'
 'Скачать новую версию'='Download the new version'
 'Нет данных'='No data'
 'Нет данных от '='No data from '
 'Подключён'='Connected'
 'Подключён частично'='Partially connected'
 'Не подключён'='Not connected'
 'Не найден'='Not found'
 'Установка не подтверждена'='Installation unconfirmed'
 'Не удалось подтвердить установку Claude Code'='Could not confirm that Claude Code is installed'
 'Подключить'='Connect'
 'Отключить'='Disconnect'
 'Claude Code не найден на этом компьютере'='Claude Code was not found on this computer'
 'Подключить Claude Code. Claude Code не найден'='Connect Claude Code. Claude Code was not found'
 'Не удалось прочитать настройки Claude Code'='Could not read Claude Code settings'
 'Claude Code: не удалось прочитать настройки'='Claude Code: could not read settings'
 'Подключение неполное. Нажмите, чтобы восстановить.'='Connection is incomplete. Select to repair it.'
 'Статус не подтверждён'='Status unconfirmed'
 'Выполняется'='Working'
 'Выполняет команду'='Running a command'
 'Читает файл'='Reading a file'
 'Изменяет файл'='Editing a file'
 'Выполняет поиск'='Searching'
 'Ожидает подтверждения'='Waiting for confirmation'
 'Задача Claude Code'='Claude Code task'
 'Задача Codex'='Codex task'
 'Обрабатывает новый запрос'='Processing a new request'
 'Выполняет действие'='Running an action'
 'Действие завершено'='Action completed'
 'Ошибка действия'='Action failed'
 'Добавлен этап'='Step added'
 'Завершён этап'='Step completed'
 'Этап завершён'='Step completed'
 'Запущен дополнительный агент'='Subagent started'
 'Дополнительный агент завершён'='Subagent finished'
 'Выполняет: '='Running: '
 'Завершено: '='Completed: '
 'Ошибка: '='Failed: '
 'Добавлен этап: '='Step added: '
 'Завершён этап: '='Step completed: '
 'План задачи'='Task plan'
 'План не подтверждён'='Plan unconfirmed'
 'План не подтверждён; список может быть неполным'='Plan unconfirmed; the list may be incomplete'
 'По известным этапам, возможна неточность'='Based on observed steps; may be inaccurate'
 ' этапов'=' steps'
 'Приблизительная оценка'='Approximate estimate'
 'Скрыть'='Hide'
 'План ещё не опубликован этой задачей'='This task has not published a plan yet'
 'Без названия'='Untitled'
 'Показать задачу: '='Show task: '
 'Активных задач сейчас нет'='No active tasks'
 'Журнал недоступен'='Journal unavailable'
 'Журнал очищен, но недоступен'='Journal was cleared but is unavailable'
 'Не удалось обновить журнал'='Could not update the journal'
 'Не удалось сохранить настройки журнала'='Could not save journal settings'
 'Не удалось применить очистку журнала'='Could not apply journal cleanup'
 'Не удалось очистить журнал'='Could not clear the journal'
 'Настройка недоступна'='Setting unavailable'
 'Не удалось сохранить настройки предупреждения'='Could not save warning settings'
 'Предупреждение Claude Code недоступно'='Claude Code loop warning unavailable'
 'Все задачи'='All tasks'
 'Задача обнаружена'='Task observed'
 'Работа началась'='Task started'
 'Работа завершена'='Task completed'
 'Работа прервана'='Task interrupted'
 'Источник недоступен'='Source unavailable'
 'Источник восстановлен'='Source restored'
 'Действие началось'='Action started'
 'Нет событий для этой задачи'='No events for this task'
 'Пока нет событий'='No events yet'
 'Не удалось открыть журнал'='Could not open the journal'
 'Все'='All'
 'Не удалось обновить задачи'='Could not refresh tasks'
 'Файл настройки не найден'='Configuration file not found'
 'Ошибка подключения'='Connection error'
 'Выход'='Quit'
 'Не удалось сохранить язык'='Could not save language'
}
function Tr([string]$text){
 if($script:resolvedLanguage -eq 'en' -and $script:translations.ContainsKey($text)){return [string]$script:translations[$text]}
 return $text
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="AI task monitor" Width="590" Height="760" MinWidth="500" MinHeight="500" WindowStartupLocation="CenterScreen" Topmost="True"
 WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanResize" SnapsToDevicePixels="True"
 TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
 <Window.Resources>
  <SolidColorBrush x:Key="Surface" Color="#202020"/>
  <SolidColorBrush x:Key="SurfaceRaised" Color="#282828"/>
  <SolidColorBrush x:Key="Border" Color="#393939"/>
  <SolidColorBrush x:Key="TextPrimary" Color="#F1F1F1"/>
  <SolidColorBrush x:Key="TextSecondary" Color="#ACACAC"/>
  <SolidColorBrush x:Key="TextMuted" Color="#989898"/>
  <SolidColorBrush x:Key="Accent" Color="$script:accentHex"/>
  <SolidColorBrush x:Key="SurfaceHover" Color="#333333"/>
  <SolidColorBrush x:Key="SurfacePressed" Color="#3B3B3B"/>
  <SolidColorBrush x:Key="Divider" Color="#343434"/>
  <SolidColorBrush x:Key="Track" Color="#3A3A3A"/>
  <SolidColorBrush x:Key="ScrollThumbBrush" Color="#555555"/>
  <SolidColorBrush x:Key="ScrollThumbHoverBrush" Color="#747474"/>
  <SolidColorBrush x:Key="TooltipSurface" Color="#171717"/>
  <SolidColorBrush x:Key="TooltipBorder" Color="#3D3D3D"/>
  <Style TargetType="ToolTip">
   <Setter Property="OverridesDefaultStyle" Value="True"/>
   <Setter Property="Background" Value="Transparent"/>
   <Setter Property="BorderBrush" Value="Transparent"/>
   <Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Padding" Value="0"/>
   <Setter Property="SnapsToDevicePixels" Value="True"/>
   <Setter Property="UseLayoutRounding" Value="True"/>
   <Setter Property="Placement" Value="Bottom"/>
   <Setter Property="VerticalOffset" Value="4"/>
   <Setter Property="MaxWidth" Value="360"/>
   <Setter Property="HasDropShadow" Value="False"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip">
    <Grid Background="Transparent" SnapsToDevicePixels="True" UseLayoutRounding="True">
     <Border Background="{DynamicResource TooltipSurface}" BorderBrush="{DynamicResource TooltipBorder}" BorderThickness="1" CornerRadius="10" Padding="12,10" SnapsToDevicePixels="True">
      <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="5" Direction="270" Opacity="0.42" Color="#000000" RenderingBias="Quality"/></Border.Effect>
      <TextBlock Text="{TemplateBinding Content}" TextWrapping="Wrap" FontFamily="Segoe UI Variable Text" FontSize="12" LineHeight="17" Foreground="{DynamicResource TextPrimary}"/>
     </Border>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Thickness x:Key="CursorHintShadowInset">18,18,18,23</Thickness>
  <Style x:Key="CursorHintStyle" TargetType="ToolTip" BasedOn="{StaticResource {x:Type ToolTip}}">
   <Setter Property="MaxWidth" Value="396"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip">
    <Grid Background="Transparent" SnapsToDevicePixels="True" UseLayoutRounding="True">
     <Border Margin="{StaticResource CursorHintShadowInset}" Background="{DynamicResource TooltipSurface}" BorderBrush="{DynamicResource TooltipBorder}" BorderThickness="1" CornerRadius="10" Padding="12,10" SnapsToDevicePixels="True">
      <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="5" Direction="270" Opacity="0.42" Color="#000000" RenderingBias="Quality"/></Border.Effect>
      <TextBlock Text="{TemplateBinding Content}" TextWrapping="Wrap" FontFamily="Segoe UI Variable Text" FontSize="12" LineHeight="17" Foreground="{DynamicResource TextPrimary}"/>
     </Border>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="KeyboardFocusStyle">
   <Setter Property="Control.Template"><Setter.Value><ControlTemplate><Border BorderBrush="{DynamicResource Accent}" BorderThickness="1" CornerRadius="6"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="Button">
   <Setter Property="FontFamily" Value="Segoe UI Variable Text"/>
   <Setter Property="Cursor" Value="Hand"/>
   <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
  </Style>
  <Style x:Key="TitleButton" TargetType="Button">
   <Setter Property="Width" Value="36"/><Setter Property="Height" Value="34"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
   <Setter Property="Template">
    <Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="ButtonSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="5">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Border>
     <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value>
   </Setter>
  </Style>
  <Style x:Key="SettingsOptionStyle" TargetType="Button">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="10,0"/>
   <Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="OptionSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="5" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="OptionSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger>
     <Trigger Property="IsPressed" Value="True"><Setter TargetName="OptionSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="FooterNavStyle" TargetType="Button">
   <Setter Property="Height" Value="38"/><Setter Property="Padding" Value="10,0"/>
   <Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="FooterSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="7" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
    </Border>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="CompactDotStyle" TargetType="Button">
   <Setter Property="Width" Value="18"/><Setter Property="Height" Value="18"/><Setter Property="Padding" Value="0"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="CompactDotSurface" Background="Transparent" BorderBrush="Transparent" BorderThickness="0" CornerRadius="7"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="SourceActionStyle" TargetType="Button">
   <Setter Property="Height" Value="28"/><Setter Property="Padding" Value="10,0"/><Setter Property="Background" Value="{DynamicResource SurfaceHover}"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="SourceActionSurface" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="0" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="SourceActionSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="UpdateActionStyle" TargetType="Button">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="12,0"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="Background" Value="{DynamicResource SurfaceHover}"/>
   <Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="ActionSurface" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ActionSurface" Property="Opacity" Value="0.85"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="JournalComboItemStyle" TargetType="ComboBoxItem">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="10,0"/><Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
    <Border x:Name="ItemSurface" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}"><TextBlock Text="{TemplateBinding Content}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger>
     <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="JournalComboStyle" TargetType="ComboBox">
   <Setter Property="Height" Value="28"/><Setter Property="MinWidth" Value="108"/><Setter Property="FontFamily" Value="Segoe UI Variable Text"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="FontSize" Value="12"/><Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="Background" Value="{DynamicResource SurfaceHover}"/>
   <Setter Property="ItemContainerStyle" Value="{StaticResource JournalComboItemStyle}"/><Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
    <Grid>
     <ToggleButton x:Name="DropDownToggle" Focusable="False" Background="{TemplateBinding Background}" IsChecked="{Binding IsDropDownOpen,Mode=TwoWay,RelativeSource={RelativeSource TemplatedParent}}">
      <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border x:Name="ToggleSurface" Background="{TemplateBinding Background}" CornerRadius="7"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ToggleSurface" Property="Background" Value="{DynamicResource SurfacePressed}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template>
     </ToggleButton>
     <TextBlock Text="{TemplateBinding SelectionBoxItem}" TextTrimming="CharacterEllipsis" Margin="10,0,28,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
     <Path Data="M 4,7 L 10,13 L 16,7" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="Uniform" Width="9" Height="6" HorizontalAlignment="Right" Margin="0,0,10,0" IsHitTestVisible="False"/>
     <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="None">
      <Border Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="7" Padding="4" MinWidth="{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}" MaxWidth="{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="248">
       <ScrollViewer CanContentScroll="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><ItemsPresenter/></ScrollViewer>
      </Border>
     </Popup>
    </Grid>
    <ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ProviderTabStyle" TargetType="Button">
   <Setter Property="Height" Value="34"/><Setter Property="Padding" Value="13,0"/><Setter Property="Margin" Value="0,0,4,0"/>
   <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/><Setter Property="BorderThickness" Value="0"/><Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="RefreshButtonStyle" TargetType="Button">
   <Setter Property="Padding" Value="14,8"/><Setter Property="Background" Value="#2C2C2C"/>
   <Setter Property="Foreground" Value="#E7E7E7"/><Setter Property="BorderBrush" Value="#454545"/><Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="RefreshSurface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="RefreshSurface" Property="Background" Value="#363636"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ProgressBar">
   <Setter Property="Height" Value="3"/><Setter Property="Background" Value="{DynamicResource Track}"/><Setter Property="Foreground" Value="{DynamicResource Accent}"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar">
    <Grid>
     <Border x:Name="PART_Track" Height="3" VerticalAlignment="Center" Background="{TemplateBinding Background}" CornerRadius="1.5"/>
     <Grid x:Name="PART_Indicator" HorizontalAlignment="Left">
      <Border Height="3" VerticalAlignment="Center" Background="{TemplateBinding Foreground}" CornerRadius="1.5"/>
     </Grid>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ScrollRepeat" TargetType="RepeatButton">
   <Setter Property="Focusable" Value="False"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ScrollThumb" TargetType="Thumb">
   <Setter Property="MinHeight" Value="32"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
    <Border x:Name="ThumbSurface" Width="5" Margin="0,2" CornerRadius="2.5" Background="{DynamicResource ScrollThumbBrush}"/>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbSurface" Property="Background" Value="{DynamicResource ScrollThumbHoverBrush}"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ScrollBar">
   <Setter Property="Width" Value="7"/><Setter Property="Margin" Value="2,0,0,0"/><Setter Property="Background" Value="Transparent"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
    <Grid Background="Transparent">
     <Track x:Name="PART_Track" IsDirectionReversed="True">
      <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollRepeat}" Command="{x:Static ScrollBar.PageUpCommand}"/></Track.DecreaseRepeatButton>
      <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
      <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollRepeat}" Command="{x:Static ScrollBar.PageDownCommand}"/></Track.IncreaseRepeatButton>
     </Track>
    </Grid>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>

 <Grid Background="Transparent">
  <Border x:Name="WindowFrame" Margin="28" Background="{DynamicResource Surface}" BorderThickness="0" SnapsToDevicePixels="True">
   <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="8" Direction="270" Opacity="0.48" Color="#000000"/></Border.Effect>
   <Grid>
   <Grid x:Name="ExpandedView">
    <Grid.RowDefinitions><RowDefinition Height="62"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="54"/></Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="18,0,12,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Image x:Name="ExpandedTitleIcon" Width="16" Height="16" Margin="0,0,16,0" VerticalAlignment="Center" Stretch="Uniform" Visibility="Collapsed" IsHitTestVisible="False" Focusable="False"/>
      <StackPanel VerticalAlignment="Center">
       <TextBlock Text="AI task monitor" FontFamily="Segoe UI Variable Display Semibold" FontSize="14" Foreground="{DynamicResource TextPrimary}"/>
      </StackPanel>
     </StackPanel>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="PinButton" Style="{StaticResource TitleButton}" Visibility="Collapsed" AutomationProperties.Name="Окно всегда поверх других окон">
       <Path x:Name="PinIcon" Data="M 7,3 L 13,3 L 12,8 L 15,11 L 15,12 L 10.7,12 L 10,17 L 9.3,12 L 5,12 L 5,11 L 8,8 Z" Fill="{DynamicResource TextSecondary}" Stretch="Uniform" Width="15" Height="15"/>
      </Button>
      <Button x:Name="TaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="MinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Компактный режим">
       <Path Data="M 4,7 L 10,13 L 16,7" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="CloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть">
       <Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
     </StackPanel>
    </Grid>

     <Border Grid.Row="1" BorderBrush="{DynamicResource Divider}" BorderThickness="0,0,0,1">
     <Grid Margin="20,18,20,17">
      <StackPanel x:Name="TaskHeaderStack">
       <TextBlock Text="Ход выполнения" FontFamily="Segoe UI Variable Display Semibold" FontSize="22" Foreground="{DynamicResource TextPrimary}"/>
       <Grid x:Name="ProviderTabsHost" Visibility="Collapsed" Margin="0,16,0,0" HorizontalAlignment="Stretch" MaxWidth="{Binding ActualWidth, ElementName=TaskHeaderStack}">
        <Path x:Name="ProviderTabsShape" Fill="{DynamicResource Track}" Opacity="0.36"/>
        <Border Padding="4"><ScrollViewer x:Name="ProviderTabsScroll" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled" CanContentScroll="False" PanningMode="HorizontalOnly" Focusable="False"><StackPanel x:Name="ProviderTabsPanel" Orientation="Horizontal"/></ScrollViewer></Border>
       </Grid>
      </StackPanel>
     </Grid>
    </Border>

    <Grid Grid.Row="2">
     <ScrollViewer x:Name="TasksScroll" Margin="20,16,20,18" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled">
      <StackPanel x:Name="TasksPanel"/>
     </ScrollViewer>
     <ScrollBar x:Name="TasksScrollBar" Orientation="Vertical" HorizontalAlignment="Right" Margin="0,16,2,18" Visibility="Hidden"/>
    </Grid>
    <Border Grid.Row="3" BorderBrush="{DynamicResource Divider}" BorderThickness="0,1,0,0" Padding="10,7,10,7">
     <Button x:Name="SettingsFooterButton" Style="{StaticResource FooterNavStyle}" HorizontalAlignment="Left" AutomationProperties.Name="Открыть настройки">
      <StackPanel Orientation="Horizontal">
       <Grid Width="16" Height="16" VerticalAlignment="Center">
        <Path Data="M 5.50,3.67 L 6.37,3.27 L 6.40,1.60 L 9.60,1.60 L 9.63,3.27 L 10.50,3.67 L 11.28,4.23 L 12.75,3.42 L 14.34,6.18 L 12.91,7.05 L 13,8 L 12.91,8.95 L 14.34,9.82 L 12.75,12.58 L 11.28,11.77 L 10.50,12.33 L 9.63,12.73 L 9.60,14.40 L 6.40,14.40 L 6.37,12.73 L 5.50,12.33 L 4.72,11.77 L 3.25,12.58 L 1.66,9.82 L 3.09,8.95 L 3,8 L 3.09,7.05 L 1.66,6.18 L 3.25,3.42 L 4.72,4.23 Z" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.15" StrokeLineJoin="Round" Fill="Transparent"/>
        <Ellipse Width="4.5" Height="4.5" HorizontalAlignment="Center" VerticalAlignment="Center" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.15" Fill="Transparent"/>
       </Grid>
       <TextBlock Text="Настройки" Margin="10,0,0,0" VerticalAlignment="Center" FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource TextPrimary}"/>
      </StackPanel>
     </Button>
    </Border>
   </Grid>

   <Grid x:Name="CompactView" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="50"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="16,0,8,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Image x:Name="CompactTitleIcon" Width="16" Height="16" Margin="0,0,16,0" VerticalAlignment="Center" Stretch="Uniform" Visibility="Collapsed" IsHitTestVisible="False" Focusable="False"/>
      <TextBlock Text="AI task monitor" FontFamily="Segoe UI Variable Display Semibold" FontSize="14" Foreground="{DynamicResource TextPrimary}"/>
     </StackPanel>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="CompactTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="ExpandButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Развернуть">
       <Path Data="M 4,13 L 10,7 L 16,13" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="CompactCloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть">
       <Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
     </StackPanel>
    </Grid>
    <Border Grid.Row="1" BorderThickness="0">
     <StackPanel Margin="16,10,16,12">
      <StackPanel x:Name="CompactTasksPanel"/>
      <StackPanel x:Name="CompactDotsPanel" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,1,0,0"/>
      <TextBlock x:Name="CompactMoreText" Visibility="Collapsed" Margin="0,6,0,0" FontFamily="Segoe UI Variable Text" FontSize="11.5" Foreground="{DynamicResource TextMuted}"/>
     </StackPanel>
    </Border>
   </Grid>

   <Grid x:Name="SettingsView" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="62"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="12,0,12,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Button x:Name="SettingsBackButton" Width="28" Height="28" HorizontalAlignment="Left" VerticalAlignment="Center" Style="{StaticResource TitleButton}" AutomationProperties.Name="Назад к задачам">
      <TextBlock Text="&#xE72B;" FontFamily="Segoe Fluent Icons" FontSize="13" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Button>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="SettingsTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="SettingsCloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть">
       <Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
     </StackPanel>
    </Grid>

    <Grid Grid.Row="1">
     <ScrollViewer x:Name="SettingsScroll" Margin="20,10,28,20" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>
      <TextBlock x:Name="SettingsHeading" Text="Настройки" FontFamily="Segoe UI Variable Display Semibold" FontSize="22" Foreground="{DynamicResource TextPrimary}"/>
      <TextBlock Text="Внешний вид" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border Margin="0,12,0,0" Padding="6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Button x:Name="SystemThemeButton" Style="{StaticResource SettingsOptionStyle}" Content="Системная"/>
        <Button x:Name="DarkThemeButton" Style="{StaticResource SettingsOptionStyle}" Content="Тёмная"/>
        <Button x:Name="LightThemeButton" Style="{StaticResource SettingsOptionStyle}" Content="Светлая"/>
       </StackPanel>
      </Border>

      <TextBlock x:Name="LanguageHeading" Text="Язык" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border Margin="0,12,0,0" Padding="6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Button x:Name="SystemLanguageButton" Style="{StaticResource SettingsOptionStyle}" Content="Системный"/>
        <Button x:Name="RussianLanguageButton" Style="{StaticResource SettingsOptionStyle}" Content="Русский"/>
        <Button x:Name="EnglishLanguageButton" Style="{StaticResource SettingsOptionStyle}" Content="English"/>
       </StackPanel>
      </Border>
      <TextBlock x:Name="LanguageSettingsError" Visibility="Collapsed" Margin="0,6,0,0" Text="Не удалось сохранить язык" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>

      <TextBlock Text="Источники" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border Margin="0,12,0,0" Padding="16,6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Codex" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="CodexSourceStatus" Grid.Column="1" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="50">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Codex Cloud" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="CodexCloudSourceStatus" Grid.Column="1" Margin="0,0,8,0" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <Button x:Name="CodexCloudSourceAction" Grid.Column="2" Style="{StaticResource SourceActionStyle}"/>
        </Grid>
        <TextBlock Margin="0,0,0,12" Text="Использует установленный Codex, его вход в аккаунт и интернет. Статус облачных задач может быть неподтверждённым." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <TextBlock x:Name="CodexCloudSourceError" Visibility="Collapsed" Margin="0,0,0,12" TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="50">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Claude Code" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="ClaudeSourceStatus" Grid.Column="1" Margin="0,0,8,0" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <Button x:Name="ClaudeSourceAction" Grid.Column="2" Style="{StaticResource SourceActionStyle}"/>
        </Grid>
        <TextBlock Margin="0,0,0,12" Text="Перед подключением обновите все используемые копии Claude Code, в том числе в Claude Desktop, до версии 2.1.101 или новее. Перед подключением или отключением закройте Claude Code, Claude Desktop и другие программы, которые могут изменять настройки Claude Code, включая их фоновые процессы. Приложение не проверяет версии и закрытие программ автоматически. Приложение добавит локальные hooks в настройки Claude Code. Права администратора, токены и вход в аккаунт не нужны. После подключения перезапустите Claude Desktop или Claude Code. Пока отслеживаются только локальные сессии." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="50">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="OpenCode" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="OpenCodeSourceStatus" Grid.Column="1" Margin="0,0,8,0" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <Button x:Name="OpenCodeSourceAction" Grid.Column="2" Style="{StaticResource SourceActionStyle}"/>
        </Grid>
        <TextBlock Margin="0,0,0,12" Text="Приложение добавит локальный плагин OpenCode. Поддерживаются совместимые версии 1 начиная с 1.18.29 и версия 2. После подключения перезапустите OpenCode." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="50">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Kimi Code" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="KimiSourceStatus" Grid.Column="1" Margin="0,0,8,0" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <Button x:Name="KimiSourceAction" Grid.Column="2" Style="{StaticResource SourceActionStyle}"/>
        </Grid>
        <TextBlock x:Name="KimiSourceError" Visibility="Collapsed" Margin="0,0,0,6" TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextSecondary}"/>
        <TextBlock Margin="0,0,0,12" Text="Для локальных задач Kimi Code CLI 2.5.0, установленного через npm: скопируйте путь, откройте в Kimi меню /plugins и установите плагин через Custom. Затем выполните /reload или откройте новую сессию. Статус задач не подтверждён; завершённые задачи могут оставаться в списке. Отключение выполняется в меню Kimi." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="50">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="DeepSeek Harness" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="DeepSeekSourceStatus" Grid.Column="1" Margin="0,0,8,0" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <Button x:Name="DeepSeekSourceAction" Grid.Column="2" Style="{StaticResource SourceActionStyle}"/>
        </Grid>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
         <TextBlock Text="Профиль" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="DeepSeekProfileCombo" Grid.Column="1" Margin="16,0,0,0" HorizontalAlignment="Stretch" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Профиль DeepSeek Harness"/>
        </Grid>
        <TextBlock x:Name="DeepSeekSourceError" Visibility="Collapsed" Margin="0,0,0,6" TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextSecondary}"/>
        <TextBlock Margin="0,0,0,12" Text="Подключение проверено с DeepSeek Harness 0.2.1-rc.5 и pnpm 11.25.0. Приложение добавит локальный плагин в выбранный профиль. После подключения перезапустите DeepSeek Harness." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="50">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Hermes Agent" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <TextBlock x:Name="HermesSourceStatus" Grid.Column="1" Margin="0,0,8,0" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <Button x:Name="HermesSourceAction" Grid.Column="2" Style="{StaticResource SourceActionStyle}"/>
        </Grid>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
         <TextBlock Text="Профиль" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="HermesProfileCombo" Grid.Column="1" Margin="16,0,0,0" HorizontalAlignment="Stretch" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Профиль Hermes"/>
        </Grid>
        <TextBlock x:Name="HermesSourceError" Visibility="Collapsed" Margin="0,0,0,6" TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextSecondary}"/>
        <TextBlock x:Name="HermesSourceDescription" Margin="0,0,0,6" Text="Выберите профиль и нажмите «Подготовить». Полностью закройте Hermes и фоновые службы. Выполните команду включения в PowerShell. После запуска или переподключения монитора дождитесь статуса «Включён локально» у выбранного профиля, затем запустите или перезапустите Hermes. Прежние задачи не показываются. Для отключения снова закройте Hermes и фоновые службы и выполните команду отключения в PowerShell. Перед запуском менеджера команда локально проверяет файлы .env, которые могут содержать ключи; сама проверка не сохраняет, не выводит и не передаёт их. Проверено с исходной установкой Hermes Agent v0.22.7." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <StackPanel x:Name="HermesSourceCommands" Visibility="Collapsed" Margin="0,0,0,12">
         <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock xml:space="preserve" Text="Включение: " FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
          <RichTextBox x:Name="HermesEnableCommand" Grid.Column="1" Margin="-5,0,0,0" Padding="0" BorderThickness="0" Background="Transparent" CaretBrush="{DynamicResource TextPrimary}" IsReadOnly="True" IsReadOnlyCaretVisible="True" AcceptsTab="False" ScrollViewer.VerticalScrollBarVisibility="Disabled" ScrollViewer.HorizontalScrollBarVisibility="Disabled" FocusVisualStyle="{StaticResource KeyboardFocusStyle}" AutomationProperties.Name="Команда включения Hermes">
           <FlowDocument PagePadding="0" FontSize="11.5" Foreground="{DynamicResource TextPrimary}"><Paragraph Margin="0" LineHeight="16"><Run x:Name="HermesEnableRun"/></Paragraph></FlowDocument>
          </RichTextBox>
         </Grid>
         <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock xml:space="preserve" Text="Отключение: " FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
          <RichTextBox x:Name="HermesDisableCommand" Grid.Column="1" Margin="-5,0,0,0" Padding="0" BorderThickness="0" Background="Transparent" CaretBrush="{DynamicResource TextPrimary}" IsReadOnly="True" IsReadOnlyCaretVisible="True" AcceptsTab="False" ScrollViewer.VerticalScrollBarVisibility="Disabled" ScrollViewer.HorizontalScrollBarVisibility="Disabled" FocusVisualStyle="{StaticResource KeyboardFocusStyle}" AutomationProperties.Name="Команда отключения Hermes">
           <FlowDocument PagePadding="0" FontSize="11.5" Foreground="{DynamicResource TextPrimary}"><Paragraph Margin="0" LineHeight="16"><Run x:Name="HermesDisableRun"/></Paragraph></FlowDocument>
          </RichTextBox>
         </Grid>
        </StackPanel>
       </StackPanel>
      </Border>
      <TextBlock Text="Журнал" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border x:Name="JournalSettingsSection" Margin="0,12,0,0" Padding="16,6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Срок хранения" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="JournalDaysCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Срок хранения журнала"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Максимальный размер" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="JournalSizeCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Максимальный размер журнала"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <StackPanel Orientation="Horizontal" Margin="0,10,0,6">
         <Button x:Name="JournalOpenButton" Content="Открыть журнал" Style="{StaticResource SourceActionStyle}"/>
         <Button x:Name="JournalClearButton" Content="Очистить" Style="{StaticResource SourceActionStyle}" Margin="8,0,0,0"/>
        </StackPanel>
        <TextBlock x:Name="JournalSettingsError" Visibility="Collapsed" Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
        <StackPanel x:Name="JournalClearConfirmation" Visibility="Collapsed" Margin="0,6,0,8">
         <TextBlock Text="Удалить все события журнала? История Codex и Claude Code не изменится." TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
         <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
          <Button x:Name="JournalConfirmClearButton" Content="Удалить" Style="{StaticResource SourceActionStyle}"/>
          <Button x:Name="JournalCancelClearButton" Content="Отмена" Style="{StaticResource SourceActionStyle}" Margin="8,0,0,0"/>
         </StackPanel>
        </StackPanel>
       </StackPanel>
      </Border>
      <TextBlock Text="Хранение Claude Code" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border x:Name="ClaudeRetentionSection" Margin="0,12,0,0" Padding="16,6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Срок хранения событий" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="ClaudeRetentionDaysCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Срок хранения событий"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Максимальный размер событий" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="ClaudeRetentionSizeCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Максимальный размер событий"/>
        </Grid>
        <TextBlock Margin="0,0,0,8" Text="События очищаются автоматически. Резервные копии настроек хранятся 30 дней; последняя сохраняется." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <TextBlock x:Name="ClaudeRetentionError" Visibility="Collapsed" Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
       </StackPanel>
      </Border>
      <TextBlock Text="Возможный цикл" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Border x:Name="LoopSettingsSection" Margin="0,12,0,0" Padding="16,6" Background="{DynamicResource SurfaceRaised}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="10">
       <StackPanel>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Количество ошибок" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="LoopThresholdCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Количество повторных ошибок для предупреждения"/>
        </Grid>
        <Border Height="1" Background="{DynamicResource Divider}"/>
        <Grid Height="46">
         <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
         <TextBlock Text="Интервал" VerticalAlignment="Center" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
         <ComboBox x:Name="LoopWindowCombo" Grid.Column="1" VerticalAlignment="Center" Style="{StaticResource JournalComboStyle}" AutomationProperties.Name="Интервал для повторных ошибок"/>
        </Grid>
        <TextBlock Margin="0,0,0,8" Text="Предупреждение не останавливает задачу." TextWrapping="Wrap" FontSize="11.5" LineHeight="16" Foreground="{DynamicResource TextMuted}"/>
        <TextBlock x:Name="LoopSettingsError" Visibility="Collapsed" Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}"/>
       </StackPanel>
      </Border>
      <Button x:Name="AboutSettingsButton" Content="О приложении" Margin="-10,22,0,0" HorizontalAlignment="Left" Style="{StaticResource FooterNavStyle}" FontSize="13" AutomationProperties.Name="О приложении"/>
      <TextBlock Text="Отзывы и предложения" Margin="0,26,0,0" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}"/>
      <Grid Margin="0,8,0,0">
       <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
       <RichTextBox x:Name="FeedbackEmailBox" Margin="-5,0,0,0" Padding="0" HorizontalAlignment="Left" VerticalAlignment="Center" BorderThickness="0" Background="Transparent" IsReadOnly="True" IsDocumentEnabled="True" ScrollViewer.VerticalScrollBarVisibility="Disabled" ScrollViewer.HorizontalScrollBarVisibility="Disabled" AutomationProperties.Name="Адрес для отзывов и предложений">
        <FlowDocument PagePadding="0" FontFamily="Segoe UI Variable Text" FontSize="13">
         <Paragraph Margin="0"><Hyperlink x:Name="FeedbackEmailLink" Foreground="{DynamicResource Accent}">truea.k.a.ru@gmail.com</Hyperlink></Paragraph>
        </FlowDocument>
       </RichTextBox>
       <Button x:Name="FeedbackCopyButton" Grid.Column="1" Width="28" Height="28" Margin="-5.5,0,0,0" VerticalAlignment="Center" Cursor="Hand" Style="{StaticResource TitleButton}" FocusVisualStyle="{StaticResource KeyboardFocusStyle}" AutomationProperties.Name="Скопировать адрес">
        <TextBlock x:Name="FeedbackCopyGlyph" Text="&#xE8C8;" Width="28" FontFamily="Segoe Fluent Icons" FontSize="13" Foreground="{DynamicResource TextSecondary}" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center"/>
       </Button>
      </Grid>
      <TextBlock x:Name="FeedbackError" Visibility="Collapsed" Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextSecondary}" Text="Не удалось открыть почтовое приложение. Напишите на truea.k.a.ru@gmail.com."/>
      </StackPanel>
     </ScrollViewer>
     <ScrollBar x:Name="SettingsScrollBar" Orientation="Vertical" HorizontalAlignment="Right" Margin="0,10,7,20" Visibility="Hidden"/>
    </Grid>
   </Grid>

   <Grid x:Name="AboutView" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="62"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="12,0,12,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Button x:Name="AboutBackButton" Width="28" Height="28" HorizontalAlignment="Left" VerticalAlignment="Center" Style="{StaticResource TitleButton}" AutomationProperties.Name="Назад к настройкам">
      <TextBlock Text="&#xE72B;" FontFamily="Segoe Fluent Icons" FontSize="13" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Button>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="AboutTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач">
       <Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
      <Button x:Name="AboutCloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть">
       <Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/>
      </Button>
     </StackPanel>
    </Grid>
    <Grid Grid.Row="1">
     <ScrollViewer x:Name="AboutScroll" Margin="20,10,28,20" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>
       <TextBlock x:Name="AboutHeading" Text="О приложении" FontFamily="Segoe UI Variable Display Semibold" FontSize="22" Foreground="{DynamicResource TextPrimary}"/>
       <TextBlock x:Name="AboutVersionText" Text="AI task monitor · версия $($script:currentVersion.Replace('-',' '))" Margin="0,18,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource TextPrimary}"/>
       <TextBlock x:Name="AboutProviders" Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="AI Task Monitor показывает задачи и доступные сведения об их ходе. Локальные источники: Codex, Claude Code, OpenCode, DeepSeek Harness, Kimi Code и Hermes Agent. Для Codex также доступны облачные задачи с неподтверждённым статусом."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="При нескольких источниках можно переключать задачи по вкладкам. Компактное окно остаётся поверх других и показывает до трёх задач с переключением между ними. Тему можно выбрать вручную или использовать тему Windows. Если источник недоступен, приложение сообщит об этом."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Если задача публикует план, приложение показывает выполненные, текущий и следующие этапы. В карточке одновременно видны до пяти этапов; остальные можно прокрутить. Без плана отображается текущее действие без списка этапов."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Если источник сообщает общий прогресс задачи, точный процент показывается числом, а приблизительный — со знаком ≈. Если известен только план, показывается текущий этап или число завершённых этапов."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Диагностический журнал хранится локально. В настройках можно выбрать срок и размер хранения, просмотреть события или очистить журнал."/>
       <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Приложение может предупредить о возможном цикле при повторных ошибках одной команды. Это предположение, оно не останавливает задачу."/>
       <TextBlock Margin="0,12,0,8" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="Данные задач обрабатываются локально. Для Claude Code после подключения используются локальные hooks. Самому монитору не нужны вход в аккаунт, токены или права администратора."/>
       <TextBlock x:Name="AboutUpdatesText" Margin="0,4,0,8" TextWrapping="Wrap" FontSize="12.5" LineHeight="18" Foreground="{DynamicResource TextSecondary}" Text="При запуске и раз в сутки приложение проверяет новые версии на GitHub, не отправляя данные задач. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению."/>
      </StackPanel>
     </ScrollViewer>
     <ScrollBar x:Name="AboutScrollBar" Orientation="Vertical" HorizontalAlignment="Right" Margin="0,10,7,20" Visibility="Hidden"/>
    </Grid>
   </Grid>

   <Grid x:Name="JournalView" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="62"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="12,0,12,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Button x:Name="JournalBackButton" Width="28" Height="28" HorizontalAlignment="Left" VerticalAlignment="Center" Style="{StaticResource TitleButton}" AutomationProperties.Name="Назад к настройкам">
      <TextBlock Text="&#xE72B;" FontFamily="Segoe Fluent Icons" FontSize="13" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
     </Button>
     <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="JournalTaskbarMinimizeButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Свернуть в панель задач"><Path Data="M 4,10 L 16,10" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform" Width="13" Height="13"/></Button>
      <Button x:Name="JournalCloseButton" Style="{StaticResource TitleButton}" AutomationProperties.Name="Закрыть"><Path Data="M 4,4 L 16,16 M 16,4 L 4,16" Stroke="{DynamicResource TextSecondary}" StrokeThickness="1.3" Stretch="Uniform" Width="13" Height="13"/></Button>
     </StackPanel>
    </Grid>
    <StackPanel Grid.Row="1" Margin="20,18,20,0">
     <TextBlock Text="Журнал" FontFamily="Segoe UI Variable Display Semibold" FontSize="22" Foreground="{DynamicResource TextPrimary}"/>
     <ComboBox x:Name="JournalTaskFilter" Style="{StaticResource JournalComboStyle}" HorizontalAlignment="Stretch" Margin="0,16,0,0" AutomationProperties.Name="Фильтр журнала по задаче"/>
    </StackPanel>
    <Grid Grid.Row="2" Margin="20,16,20,20">
     <ListBox x:Name="JournalEventsList" Background="Transparent" BorderThickness="0" ScrollViewer.CanContentScroll="True" ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Disabled" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" AutomationProperties.Name="События журнала">
      <ListBox.ItemContainerStyle><Style TargetType="ListBoxItem">
       <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="FocusVisualStyle" Value="{StaticResource KeyboardFocusStyle}"/>
       <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="EventSurface" Background="Transparent" BorderBrush="{DynamicResource Divider}" BorderThickness="0,0,0,1" Padding="0,10"><ContentPresenter HorizontalAlignment="Stretch"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="EventSurface" Property="Background" Value="{DynamicResource SurfaceHover}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
      </Style></ListBox.ItemContainerStyle>
      <ListBox.ItemTemplate><DataTemplate>
       <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="95"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBlock Text="{Binding TimeLabel}" FontFamily="Segoe UI Variable Text" FontSize="12" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" Text="{Binding SourceLabel}" FontFamily="Segoe UI Variable Text" FontSize="12" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="2" Text="{Binding EventLabel}" FontFamily="Segoe UI Variable Text" FontSize="13" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap" VerticalAlignment="Center"/>
       </Grid>
      </DataTemplate></ListBox.ItemTemplate>
     </ListBox>
     <TextBlock x:Name="JournalEmptyText" Visibility="Collapsed" FontSize="14" Foreground="{DynamicResource TextSecondary}" Margin="4,24,0,0" TextWrapping="Wrap"/>
    </Grid>
   </Grid>

   <Grid x:Name="UpdateOverlay" Visibility="Collapsed" Background="#99000000" Panel.ZIndex="19" KeyboardNavigation.TabNavigation="Cycle">
    <Grid x:Name="UpdateDialog" Width="368" HorizontalAlignment="Center" VerticalAlignment="Center">
     <Path x:Name="UpdateDialogShape" Fill="{DynamicResource SurfaceRaised}" Stroke="{DynamicResource Border}" StrokeThickness="1" IsHitTestVisible="False">
      <Path.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="8" Direction="270" Opacity="0.48" Color="#000000"/></Path.Effect>
     </Path>
     <StackPanel Margin="24">
      <TextBlock Text="Доступна новая версия" FontFamily="Segoe UI Variable Display Semibold" FontSize="19" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap"/>
      <TextBlock x:Name="UpdateVersionText" Margin="0,14,0,0" FontSize="13" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap"/>
      <TextBlock Text="Скачайте приложение, полностью закройте старую версию и переустановите новую." Margin="0,12,0,0" FontSize="13" LineHeight="19" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap"/>
      <TextBlock x:Name="UpdateOpenError" Visibility="Collapsed" Text="Не удалось открыть страницу загрузки." Margin="0,10,0,0" FontSize="12" Foreground="{DynamicResource TextSecondary}" TextWrapping="Wrap"/>
      <Grid Margin="0,22,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
       <Button x:Name="UpdateLaterButton" Content="Позже" Style="{StaticResource UpdateActionStyle}" AutomationProperties.Name="Напомнить при следующем запуске"/>
       <Button x:Name="UpdateDownloadButton" Grid.Column="2" Content="Скачать" Style="{StaticResource UpdateActionStyle}" Background="{DynamicResource Accent}" Foreground="$script:accentForeground" AutomationProperties.Name="Скачать новую версию"/>
      </Grid>
     </StackPanel>
    </Grid>
   </Grid>
   <Path x:Name="WindowOutline" Stroke="{DynamicResource Border}" StrokeThickness="1" IsHitTestVisible="False" Panel.ZIndex="20"/>
   </Grid>
  </Border>
 </Grid>
</Window>
"@

$script:staticResourceKeys=@{}
$resourceParent=$xaml.SelectSingleNode("//*[local-name()='Window.Resources']")
$namespaceAttribute=$xaml.CreateAttribute('xmlns','sys','http://www.w3.org/2000/xmlns/')
$namespaceAttribute.Value='clr-namespace:System;assembly=mscorlib'
[void]$xaml.DocumentElement.Attributes.Append($namespaceAttribute)
foreach($node in $xaml.SelectNodes('//*')){
 foreach($attribute in @($node.Attributes)){
  if($attribute.LocalName -notin @('Text','Content','ToolTip','AutomationProperties.Name')){continue}
  $original=[string]$attribute.Value
  if(-not $script:translations.ContainsKey($original)){continue}
  if(-not $script:staticResourceKeys.ContainsKey($original)){
   $key='Localized'+$script:staticResourceKeys.Count
   $script:staticResourceKeys[$original]=$key
   $item=$xaml.CreateElement('sys','String','clr-namespace:System;assembly=mscorlib')
   $keyAttribute=$xaml.CreateAttribute('x','Key','http://schemas.microsoft.com/winfx/2006/xaml')
   $keyAttribute.Value=$key;[void]$item.Attributes.Append($keyAttribute)
   $item.InnerText=$original;[void]$resourceParent.AppendChild($item)
  }
  $attribute.Value='{DynamicResource '+$script:staticResourceKeys[$original]+'}'
 }
}

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$iconPath = Join-Path $PSScriptRoot "assets\app-icon.ico"
$script:applicationIcon = $null
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
 try {
  $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]::new($iconPath, [UriKind]::Absolute), [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
  $window.Icon = @($decoder.Frames | Where-Object { $_.PixelWidth -eq 32 } | Select-Object -First 1)[0]
  foreach($titleIconName in @("ExpandedTitleIcon","CompactTitleIcon")){
   $titleIcon=$window.FindName($titleIconName);$titleIcon.Source=$window.Icon;$titleIcon.Visibility="Visible"
  }
  $script:applicationIcon = [Drawing.Icon]::new($iconPath, 16, 16)
 } catch {
  Write-Warning "Не удалось загрузить иконку AI task monitor: $($_.Exception.Message)"
 }
}
$script:shellIdentityAvailable=$false
try{
 $identitySource=Join-Path $PSScriptRoot "AppShellIdentity.cs"
 if(Test-Path -LiteralPath $identitySource -PathType Leaf){
  if(-not ("AITaskMonitor.Windows.AppShellIdentity" -as [type])){Add-Type -Path $identitySource -ErrorAction Stop}
  $script:shellIdentityAvailable=$true
 }
}catch{Write-Warning "Не удалось настроить значок панели задач: $($_.Exception.Message)"}
$window.Add_SourceInitialized({
 if(-not $script:shellIdentityAvailable){return}
 try{
  $handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
  [AITaskMonitor.Windows.AppShellIdentity]::Apply($handle,$iconPath,(Join-Path $PSScriptRoot "AI task monitor.exe"))
 }catch{Write-Warning "Не удалось настроить значок панели задач: $($_.Exception.Message)"}
})
$window.Add_Closing({
 if(-not $script:shellIdentityAvailable){return}
 try{
  $handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
  if($handle -ne [IntPtr]::Zero){[AITaskMonitor.Windows.AppShellIdentity]::Clear($handle)}
 }catch{}
})
$windowFrame = $window.FindName("WindowFrame")
$windowOutline = $window.FindName("WindowOutline")
$expandedView = $window.FindName("ExpandedView")
$compactView = $window.FindName("CompactView")
$settingsView = $window.FindName("SettingsView")
$aboutView = $window.FindName("AboutView")
$journalView = $window.FindName("JournalView")
$updateOverlay = $window.FindName("UpdateOverlay")
$updateDialog = $window.FindName("UpdateDialog")
$updateDialogShape = $window.FindName("UpdateDialogShape")
$updateVersionText = $window.FindName("UpdateVersionText")
$updateOpenError = $window.FindName("UpdateOpenError")
$updateLaterButton = $window.FindName("UpdateLaterButton")
$updateDownloadButton = $window.FindName("UpdateDownloadButton")
$tasksPanel = $window.FindName("TasksPanel")
$tasksScroll = $window.FindName("TasksScroll")
$tasksScrollBar = $window.FindName("TasksScrollBar")
$providerTabsHost = $window.FindName("ProviderTabsHost")
$providerTabsShape = $window.FindName("ProviderTabsShape")
$providerTabsPanel = $window.FindName("ProviderTabsPanel")
$providerTabsScroll = $window.FindName("ProviderTabsScroll")
$pinButton = $window.FindName("PinButton")
$pinIcon = $window.FindName("PinIcon")
$minimizeButton = $window.FindName("MinimizeButton")
$taskbarMinimizeButton = $window.FindName("TaskbarMinimizeButton")
$closeButton = $window.FindName("CloseButton")
$compactTasksPanel = $window.FindName("CompactTasksPanel")
$compactDotsPanel = $window.FindName("CompactDotsPanel")
$compactMoreText = $window.FindName("CompactMoreText")
$expandButton = $window.FindName("ExpandButton")
$compactTaskbarMinimizeButton = $window.FindName("CompactTaskbarMinimizeButton")
$compactCloseButton = $window.FindName("CompactCloseButton")
$settingsFooterButton = $window.FindName("SettingsFooterButton")
$settingsBackButton = $window.FindName("SettingsBackButton")
$settingsTaskbarMinimizeButton = $window.FindName("SettingsTaskbarMinimizeButton")
$settingsCloseButton = $window.FindName("SettingsCloseButton")
$settingsScroll = $window.FindName("SettingsScroll")
$settingsScrollBar = $window.FindName("SettingsScrollBar")
$aboutSettingsButton = $window.FindName("AboutSettingsButton")
$feedbackEmailBox = $window.FindName("FeedbackEmailBox")
$feedbackEmailLink = $window.FindName("FeedbackEmailLink")
$feedbackCopyButton = $window.FindName("FeedbackCopyButton")
$feedbackCopyGlyph = $window.FindName("FeedbackCopyGlyph")
$feedbackAddress=[Windows.Documents.TextRange]::new($feedbackEmailLink.ContentStart,$feedbackEmailLink.ContentEnd).Text.Trim()
$feedbackTypeface=[Windows.Media.Typeface]::new($feedbackEmailBox.Document.FontFamily,$feedbackEmailBox.Document.FontStyle,$feedbackEmailBox.Document.FontWeight,$feedbackEmailBox.Document.FontStretch)
$feedbackMetrics=[Windows.Media.FormattedText]::new($feedbackAddress,[Globalization.CultureInfo]::CurrentUICulture,[Windows.FlowDirection]::LeftToRight,$feedbackTypeface,$feedbackEmailBox.Document.FontSize,[Windows.Media.Brushes]::Black,[Windows.Media.VisualTreeHelper]::GetDpi($window).PixelsPerDip)
$feedbackEmailBox.Width=[Math]::Ceiling($feedbackMetrics.WidthIncludingTrailingWhitespace)+20
$feedbackError = $window.FindName("FeedbackError")
$aboutBackButton = $window.FindName("AboutBackButton")
$aboutHeading = $window.FindName("AboutHeading")
$aboutVersionText = $window.FindName("AboutVersionText")
$aboutUpdatesText = $window.FindName("AboutUpdatesText")
if($script:isStoreEdition){$aboutUpdatesText.Text="Обновления этой версии устанавливаются через Microsoft Store. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению."}
$aboutProviders = $window.FindName("AboutProviders")
$aboutTaskbarMinimizeButton = $window.FindName("AboutTaskbarMinimizeButton")
$aboutCloseButton = $window.FindName("AboutCloseButton")
$aboutScroll = $window.FindName("AboutScroll")
$aboutScrollBar = $window.FindName("AboutScrollBar")
$journalSettingsSection = $window.FindName("JournalSettingsSection")
$claudeRetentionSection = $window.FindName('ClaudeRetentionSection')
$claudeRetentionDaysCombo = $window.FindName('ClaudeRetentionDaysCombo')
$claudeRetentionSizeCombo = $window.FindName('ClaudeRetentionSizeCombo')
$claudeRetentionError = $window.FindName('ClaudeRetentionError')
$loopSettingsSection = $window.FindName("LoopSettingsSection")
$loopThresholdCombo = $window.FindName("LoopThresholdCombo")
$loopWindowCombo = $window.FindName("LoopWindowCombo")
$loopSettingsError = $window.FindName("LoopSettingsError")
$journalDaysCombo = $window.FindName("JournalDaysCombo")
$journalSizeCombo = $window.FindName("JournalSizeCombo")
$journalOpenButton = $window.FindName("JournalOpenButton")
$journalClearButton = $window.FindName("JournalClearButton")
$journalSettingsError = $window.FindName("JournalSettingsError")
$journalClearConfirmation = $window.FindName("JournalClearConfirmation")
$journalConfirmClearButton = $window.FindName("JournalConfirmClearButton")
$journalCancelClearButton = $window.FindName("JournalCancelClearButton")
$journalBackButton = $window.FindName("JournalBackButton")
$journalTaskbarMinimizeButton = $window.FindName("JournalTaskbarMinimizeButton")
$journalCloseButton = $window.FindName("JournalCloseButton")
$journalTaskFilter = $window.FindName("JournalTaskFilter")
$journalEventsList = $window.FindName("JournalEventsList")
$journalEmptyText = $window.FindName("JournalEmptyText")
$systemThemeButton = $window.FindName("SystemThemeButton")
$darkThemeButton = $window.FindName("DarkThemeButton")
$lightThemeButton = $window.FindName("LightThemeButton")
$systemLanguageButton = $window.FindName("SystemLanguageButton")
$russianLanguageButton = $window.FindName("RussianLanguageButton")
$englishLanguageButton = $window.FindName("EnglishLanguageButton")
$languageSettingsError = $window.FindName("LanguageSettingsError")
$codexSourceStatus = $window.FindName("CodexSourceStatus")
$codexCloudSourceStatus = $window.FindName("CodexCloudSourceStatus")
$codexCloudSourceAction = $window.FindName("CodexCloudSourceAction")
$codexCloudSourceError = $window.FindName("CodexCloudSourceError")
$claudeSourceStatus = $window.FindName("ClaudeSourceStatus")
$claudeSourceAction = $window.FindName("ClaudeSourceAction")
$openCodeSourceStatus = $window.FindName("OpenCodeSourceStatus")
$openCodeSourceAction = $window.FindName("OpenCodeSourceAction")
$kimiSourceStatus = $window.FindName("KimiSourceStatus")
$kimiSourceAction = $window.FindName("KimiSourceAction")
$kimiSourceError = $window.FindName("KimiSourceError")
$script:kimiCopyError = ''
$deepSeekSourceStatus = $window.FindName("DeepSeekSourceStatus")
$deepSeekSourceAction = $window.FindName("DeepSeekSourceAction")
$deepSeekProfileCombo = $window.FindName("DeepSeekProfileCombo")
$deepSeekSourceError = $window.FindName("DeepSeekSourceError")
$script:updatingDeepSeekControls = $false
$hermesSourceStatus = $window.FindName("HermesSourceStatus")
$hermesSourceAction = $window.FindName("HermesSourceAction")
$hermesProfileCombo = $window.FindName("HermesProfileCombo")
$hermesSourceError = $window.FindName("HermesSourceError")
$hermesSourceDescription = $window.FindName("HermesSourceDescription")
$hermesSourceCommands = $window.FindName("HermesSourceCommands")
$hermesEnableCommand = $window.FindName("HermesEnableCommand")
$hermesDisableCommand = $window.FindName("HermesDisableCommand")
$hermesEnableRun = $window.FindName("HermesEnableRun")
$hermesDisableRun = $window.FindName("HermesDisableRun")
$script:updatingHermesControls = $false
$script:hermesCopyError = ''
$script:hermesPreviewCopiedCommand = ''
$script:isCompact = $false
$script:showingSettings = $false
$script:showingAbout = $false
$script:showingJournal = $false
$script:updatingJournalControls = $false
$script:updatingClaudeRetentionControls = $false
$script:claudeRetentionUiError = ''
$script:nextClaudeRetention = [DateTime]::MinValue
$script:retentionPolicyInvalidated = $false
$script:updatingLoopControls = $false
$script:loopUiError = ""
$script:previewLoopDismissed = $false
$script:journalFingerprint = ""
$script:journalUiError = ""
$script:navigationByKeyboard = $false
$script:expandedBounds = $null
$script:selectedProvider = $PreviewProvider
$script:providerTabsFingerprint = ""
$script:providerLastSelected = ""
$script:cardRadius = 12.0
$script:tabPadding = 4.0
$script:providerTabsRadius = 14.0
$script:providerTabRadius = 10.0
$script:providerTabsEqualWidth = $false
$script:previewHintTarget = $null
$providerTabsScroll.Add_PreviewMouseWheel({param($sender,$event) if($sender.ScrollableWidth -gt 0){$sender.ScrollToHorizontalOffset($sender.HorizontalOffset - $event.Delta);$event.Handled=$true}})
$tasksScroll.Add_ScrollChanged({
 $tasksScrollBar.Maximum=$tasksScroll.ScrollableHeight
 $tasksScrollBar.ViewportSize=$tasksScroll.ViewportHeight
 $tasksScrollBar.Value=$tasksScroll.VerticalOffset
 $tasksScrollBar.Visibility=$(if($tasksScroll.ScrollableHeight -gt 0){"Visible"}else{"Hidden"})
})
$tasksScrollBar.Add_ValueChanged({if([Math]::Abs($tasksScroll.VerticalOffset-$tasksScrollBar.Value) -gt 0.5){$tasksScroll.ScrollToVerticalOffset($tasksScrollBar.Value)}})
$settingsScroll.Add_ScrollChanged({
 $settingsScrollBar.Maximum=$settingsScroll.ScrollableHeight
 $settingsScrollBar.ViewportSize=$settingsScroll.ViewportHeight
 $settingsScrollBar.Value=$settingsScroll.VerticalOffset
 $settingsScrollBar.Visibility=$(if($settingsScroll.ScrollableHeight -gt 0){"Visible"}else{"Hidden"})
})
$settingsScrollBar.Add_ValueChanged({if([Math]::Abs($settingsScroll.VerticalOffset-$settingsScrollBar.Value) -gt 0.5){$settingsScroll.ScrollToVerticalOffset($settingsScrollBar.Value)}})
$aboutScroll.Add_ScrollChanged({
 $aboutScrollBar.Maximum=$aboutScroll.ScrollableHeight
 $aboutScrollBar.ViewportSize=$aboutScroll.ViewportHeight
 $aboutScrollBar.Value=$aboutScroll.VerticalOffset
 $aboutScrollBar.Visibility=$(if($aboutScroll.ScrollableHeight -gt 0){"Visible"}else{"Hidden"})
})
$aboutScrollBar.Add_ValueChanged({if([Math]::Abs($aboutScroll.VerticalOffset-$aboutScrollBar.Value) -gt 0.5){$aboutScroll.ScrollToVerticalOffset($aboutScrollBar.Value)}})

function Prop($object, [string]$name, $fallback = $null) {
 if ($null -ne $object -and $null -ne $object.PSObject.Properties[$name]) { return $object.$name }
 return $fallback
}

function Brush([string]$color) { return [Windows.Media.BrushConverter]::new().ConvertFromString($color) }

function Squircle-Geometry([double]$width,[double]$height,[double]$radius,[double]$inset = 0,[double]$curve = 0.72) {
 $left=$inset; $top=$inset; $right=[Math]::Max($left,$width-$inset); $bottom=[Math]::Max($top,$height-$inset)
 $r=[Math]::Min($radius,[Math]::Min(($right-$left)/2,($bottom-$top)/2))
 $k=$r*$curve
 $figure=New-Object Windows.Media.PathFigure
 $figure.StartPoint=[Windows.Point]::new($left+$r,$top)
 $figure.IsClosed=$true
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($right-$r,$top),$true))
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($right-$r+$k,$top),[Windows.Point]::new($right,$top+$r-$k),[Windows.Point]::new($right,$top+$r),$true))
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($right,$bottom-$r),$true))
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($right,$bottom-$r+$k),[Windows.Point]::new($right-$r+$k,$bottom),[Windows.Point]::new($right-$r,$bottom),$true))
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($left+$r,$bottom),$true))
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($left+$r-$k,$bottom),[Windows.Point]::new($left,$bottom-$r+$k),[Windows.Point]::new($left,$bottom-$r),$true))
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($left,$top+$r),$true))
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($left,$top+$r-$k),[Windows.Point]::new($left+$r-$k,$top),[Windows.Point]::new($left+$r,$top),$true))
 $geometry=New-Object Windows.Media.PathGeometry
 $geometry.Figures.Add($figure)
 return $geometry
}

# The exported SwiftUI continuous corners are available for the current tab
# heights only. Other sizes retain the previous Windows contour.
function Add-ProviderTabCubic($figure,[double]$x1,[double]$y1,[double]$x2,[double]$y2,[double]$x3,[double]$y3) {
 $figure.Segments.Add([Windows.Media.BezierSegment]::new([Windows.Point]::new($x1,$y1),[Windows.Point]::new($x2,$y2),[Windows.Point]::new($x3,$y3),$true))
}
function Provider-TabGeometry([double]$width,[double]$height,[double]$radius) {
 if($height -eq 42 -and $radius -eq 14){
  $xl=21.401309251785278;$yl=21.0;$xc1=15.238860130310059;$xc2=12.157698154449463
  $yc1=15.14132285118103;$yc2=12.120952486991882;$n=1.0487596094608307;$f=8.84091579914093
  $dn=2.3668400943279266;$df=5.2195361852645874;$fallback=0.56
 }elseif($height -eq 34 -and $radius -eq 10){
  $xl=15.286649465560913;$yl=15.286649465560913;$xc1=10.884900093078613;$xc2=8.684070110321045
  $yc1=10.884900093078613;$yc2=8.684070110321045;$n=0.7491140067577362;$f=6.314939856529236
  $dn=1.6906000673770905;$df=3.728240132331848;$fallback=0.60
 }else{
  $fallback=if($radius -eq 14){0.56}else{0.60}
  return Squircle-Geometry $width $height $radius 0 $fallback
 }
 if([double]::IsNaN($width) -or [double]::IsInfinity($width) -or $width -lt (2*$xl)){
  return Squircle-Geometry $width $height $radius 0 $fallback
 }
 $figure=New-Object Windows.Media.PathFigure
 $figure.StartPoint=[Windows.Point]::new($width,$height/2);$figure.IsClosed=$true
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($width,($height-$yl)),$true))
 Add-ProviderTabCubic $figure $width ($height-$yc1) $width ($height-$yc2) ($width-$n) ($height-$f)
 Add-ProviderTabCubic $figure ($width-$dn) ($height-$df) ($width-$df) ($height-$dn) ($width-$f) ($height-$n)
 Add-ProviderTabCubic $figure ($width-$xc2) $height ($width-$xc1) $height ($width-$xl) $height
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($xl,$height),$true))
 Add-ProviderTabCubic $figure $xc1 $height $xc2 $height $f ($height-$n)
 Add-ProviderTabCubic $figure $df ($height-$dn) $dn ($height-$df) $n ($height-$f)
 Add-ProviderTabCubic $figure 0 ($height-$yc2) 0 ($height-$yc1) 0 ($height-$yl)
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new(0,$yl),$true))
 Add-ProviderTabCubic $figure 0 $yc1 0 $yc2 $n $f
 Add-ProviderTabCubic $figure $dn $df $df $dn $f $n
 Add-ProviderTabCubic $figure $xc2 0 $xc1 0 $xl 0
 $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new(($width-$xl),0),$true))
 Add-ProviderTabCubic $figure ($width-$xc1) 0 ($width-$xc2) 0 ($width-$f) $n
 Add-ProviderTabCubic $figure ($width-$df) $dn ($width-$dn) $df ($width-$n) $f
 Add-ProviderTabCubic $figure $width $yc2 $width $yc1 $width $yl
 $geometry=New-Object Windows.Media.PathGeometry
 $geometry.Figures.Add($figure)
 return $geometry
}

function Update-SquircleGeometry {
 if($windowFrame.ActualWidth -gt 0 -and $windowFrame.ActualHeight -gt 0){
  $windowFrame.Clip=Squircle-Geometry $windowFrame.ActualWidth $windowFrame.ActualHeight 16 0
  $windowOutline.Data=Squircle-Geometry $windowFrame.ActualWidth $windowFrame.ActualHeight 16 0.5
 }
 if($providerTabsHost.ActualWidth -gt 0 -and $providerTabsHost.ActualHeight -gt 0){
  $providerTabsShape.Data=Provider-TabGeometry $providerTabsHost.ActualWidth $providerTabsHost.ActualHeight $script:providerTabsRadius
  $providerTabsHost.Clip=Provider-TabGeometry $providerTabsHost.ActualWidth $providerTabsHost.ActualHeight $script:providerTabsRadius
 }
}

function Windows-Theme {
 try { if((Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme) -eq 1){return "light"} } catch {}
 return "dark"
}

function Resolve-Language([string]$mode,[string]$systemName="") {
 if($mode -in @('ru','en')){return $mode}
 if(-not $systemName){$systemName=[Globalization.CultureInfo]::CurrentUICulture.Name}
 if(($systemName -split '[-_]')[0] -ieq 'ru'){return 'ru'}
 return 'en'
}

function Save-DisplayPreference([string]$name,$value) {
 $temporaryPath=''
 try{
  $folder=Split-Path -Parent $script:settingsPath
  [void][IO.Directory]::CreateDirectory($folder)
  $settings=[PSCustomObject]@{}
  $hadFile=Test-Path -LiteralPath $script:settingsPath -PathType Leaf
  $originalHash=''
  if($hadFile){
   if(([IO.File]::GetAttributes($script:settingsPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing to overwrite linked preferences.'}
   $originalHash=(Get-FileHash -LiteralPath $script:settingsPath -Algorithm SHA256 -ErrorAction Stop).Hash
   $settings=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
   if($null -eq $settings -or $settings -isnot [PSCustomObject]){throw 'Unsupported display preferences.'}
  }
  if($null -eq $settings.PSObject.Properties[$name]){$settings|Add-Member -MemberType NoteProperty -Name $name -Value $value}
  else{$settings.$name=$value}
  $temporaryPath=Join-Path $folder ('.display-preferences-'+[Guid]::NewGuid().ToString('N')+'.tmp')
  [IO.File]::WriteAllText($temporaryPath,($settings|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($true))
  if($hadFile){
   if(-not (Test-Path -LiteralPath $script:settingsPath -PathType Leaf) -or (Get-FileHash -LiteralPath $script:settingsPath -Algorithm SHA256 -ErrorAction Stop).Hash -cne $originalHash){throw 'Display preferences changed during the update.'}
   [IO.File]::Replace($temporaryPath,$script:settingsPath,[System.Management.Automation.Language.NullString]::Value)
  }else{[IO.File]::Move($temporaryPath,$script:settingsPath)}
  return $true
 }catch{return $false}
 finally{if($temporaryPath -and [IO.File]::Exists($temporaryPath)){[IO.File]::Delete($temporaryPath)}}
}

function Load-ThemeMode {
 try {
  if(Test-Path -LiteralPath $script:settingsPath){
   $saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
   $mode=[string](Prop $saved "theme" "system")
   if($mode -in @("system","dark","light")){return $mode}
  }
 }catch{}
 return "system"
}

function Save-ThemeMode([string]$mode) {
 if($mode -notin @('system','dark','light')){return $false}
 return (Save-DisplayPreference 'theme' $mode)
}

function Load-LanguageMode {
 try{
  if(Test-Path -LiteralPath $script:settingsPath -PathType Leaf){
   $saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json
   $mode=[string](Prop $saved 'language' 'system')
   if($mode -in @('system','ru','en')){return $mode}
  }
 }catch{}
 return 'system'
}

function Save-LanguageMode([string]$mode) {
 if($mode -notin @('system','ru','en')){return $false}
 return (Save-DisplayPreference 'language' $mode)
}

function Load-CodexCloudEnabled {
 try{
  if(Test-Path -LiteralPath $script:settingsPath -PathType Leaf){
   $saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
   $value=Prop $saved 'codexCloudEnabled' $false
   if($value -is [bool]){return $value}
  }
 }catch{}
 return $false
}

function Load-ClaudeRetentionSettings {
 $days=7;$maximum=10
 try{
  if(Test-Path -LiteralPath $script:settingsPath -PathType Leaf){
   $saved=Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
   if($null -eq $saved -or $saved -isnot [PSCustomObject]){throw 'Unsupported settings.'}
   if($null -ne $saved.PSObject.Properties['claudeRetentionDays'] -and (-not [int]::TryParse([string]$saved.claudeRetentionDays,[ref]$days) -or $days -lt 1 -or $days -gt 30)){throw 'Invalid retention days.'}
   if($null -ne $saved.PSObject.Properties['claudeMaximumMB'] -and (-not [int]::TryParse([string]$saved.claudeMaximumMB,[ref]$maximum) -or $maximum -lt 1 -or $maximum -gt 100)){throw 'Invalid retention size.'}
  }
  return [PSCustomObject]@{Valid=$true;Days=$days;MaximumMB=$maximum}
 }catch{return [PSCustomObject]@{Valid=$false;Days=$days;MaximumMB=$maximum}}
}

function Save-ClaudeRetentionPreference([string]$name,[int]$value) {
 if($name -eq 'claudeRetentionDays' -and $value -ge 1 -and $value -le 30){return (Save-DisplayPreference $name $value)}
 if($name -eq 'claudeMaximumMB' -and $value -ge 1 -and $value -le 100){return (Save-DisplayPreference $name $value)}
 return $false
}

function Update-ThemeButtons {
 foreach($entry in @(@($systemThemeButton,"system"),@($darkThemeButton,"dark"),@($lightThemeButton,"light"))){
  $entry[0].Background=if($script:themeMode -eq $entry[1]){Brush $script:palette.Pressed}else{[Windows.Media.Brushes]::Transparent}
 }
 Update-LanguageButtons
}

function Update-LanguageButtons {
 foreach($entry in @(@($systemLanguageButton,'system'),@($russianLanguageButton,'ru'),@($englishLanguageButton,'en'))){
  $entry[0].Background=if($script:languageMode -eq $entry[1]){Brush $script:palette.Pressed}else{[Windows.Media.Brushes]::Transparent}
 }
}

function Update-SettingsButtonName {
 $modeName=switch($script:themeMode){"system"{"Системная"};"light"{"Светлая"};default{"Тёмная"}}
 $name=if($script:resolvedLanguage -eq 'en'){"Open settings. Theme: $(Tr $modeName)"}else{"Открыть настройки. Тема: $modeName"}
 [Windows.Automation.AutomationProperties]::SetName($settingsFooterButton,$name)
}

function Apply-Language([string]$mode,[bool]$persist) {
 if($mode -notin @('system','ru','en')){$mode='system'}
 if($persist -and -not (Save-LanguageMode $mode)){$languageSettingsError.Visibility='Visible';return}
 $languageSettingsError.Visibility='Collapsed'
 $script:languageMode=$mode
 $script:resolvedLanguage=Resolve-Language $mode
 foreach($original in $script:staticResourceKeys.Keys){$window.Resources[$script:staticResourceKeys[$original]]=Tr $original}
 $window.Language=[Windows.Markup.XmlLanguage]::GetLanguage($(if($script:resolvedLanguage -eq 'ru'){'ru-RU'}else{'en-US'}))
 $aboutVersionText.Text=$(if($script:resolvedLanguage -eq 'en'){'AI task monitor · version '}else{'AI task monitor · версия '})+$script:currentVersion.Replace('-',' ')
 if($feedbackError.Visibility -eq 'Visible' -and $feedbackError.Tag){$feedbackError.Text=Tr ([string]$feedbackError.Tag)}
 if($script:isStoreEdition){$aboutUpdatesText.Text=Tr 'Обновления этой версии устанавливаются через Microsoft Store. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению.'}
 if($null -ne (Get-Variable -Scope Script -Name trayShowMenu -ErrorAction SilentlyContinue)){$script:trayShowMenu.Text=Tr 'Развернуть';$script:trayExitMenu.Text=Tr 'Выход'}
 Update-LanguageButtons
 Update-SettingsButtonName
 Update-SourceSettings
 $script:updatingJournalControls=$true;$script:updatingLoopControls=$true;$script:updatingClaudeRetentionControls=$true
 try{$journalDaysCombo.Items.Clear();$journalSizeCombo.Items.Clear();$loopThresholdCombo.Items.Clear();$loopWindowCombo.Items.Clear();$claudeRetentionDaysCombo.Items.Clear();$claudeRetentionSizeCombo.Items.Clear()}
 finally{$script:updatingJournalControls=$false;$script:updatingLoopControls=$false;$script:updatingClaudeRetentionControls=$false}
 Update-JournalSettings
 Update-ClaudeRetentionSettings
 Update-LoopSettings
 $script:journalFingerprint='';$script:fingerprint=''
 Update-View
}

function Claude-ConnectionState {
 $path=Join-Path (Join-Path $env:USERPROFILE ".claude") "settings.json"
 try{$attributes=[IO.File]::GetAttributes($path)}
 catch [IO.FileNotFoundException]{return "disconnected"}
 catch [IO.DirectoryNotFoundException]{return "disconnected"}
 if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){throw "Claude Code settings are not a file."}
 $hookPath=Join-Path $PSScriptRoot "ClaudeTaskHook.ps1"
 $legacy='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$hookPath+'"'
 $hookScript="& '"+$hookPath.Replace("'","''")+"'"
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hookScript))
 $expected='powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded
 if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'store-channel.marker') -PathType Leaf){
  . (Join-Path $PSScriptRoot 'StoreClaudeHook.ps1')
  $expected=Get-StoreClaudeHookCommand $PSScriptRoot
 }
 $raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
 if(-not $raw.Trim()){return "disconnected"}
 $settings=$raw|ConvertFrom-Json -ErrorAction Stop
 if($null -eq $settings -or $settings -is [array] -or $settings -is [string] -or $settings -is [ValueType]){throw "Claude Code settings are not a JSON object."}
 $hooksProperty=$settings.PSObject.Properties["hooks"]
 if($null -eq $hooksProperty){return "disconnected"}
 if($hooksProperty.Value -isnot [PSCustomObject]){throw "Claude Code hooks are not a JSON object."}
 $knownEvents=@("UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","TaskCreated","TaskCompleted","SubagentStart","SubagentStop","Stop","StopFailure","SessionEnd")
 $connectedEvents=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($eventProperty in $hooksProperty.Value.PSObject.Properties){
  if($eventProperty.Name -notin $knownEvents){continue}
  if($eventProperty.Value -isnot [array]){throw "Claude Code hook groups are not an array."}
  foreach($entry in $eventProperty.Value){
   if($entry -isnot [PSCustomObject]){throw "A Claude Code hook group is not an object."}
   $entryHooks=$entry.PSObject.Properties["hooks"]
   if($null -eq $entryHooks){continue}
   if($entryHooks.Value -isnot [array]){throw "Claude Code commands are not an array."}
   foreach($hook in $entryHooks.Value){
    if($hook -isnot [PSCustomObject]){throw "A Claude Code hook is not an object."}
    if($null -eq $hook.PSObject.Properties["type"] -or [string]$hook.type -ne "command" -or $null -eq $hook.PSObject.Properties["command"] -or $null -ne $hook.PSObject.Properties["args"]){continue}
    $hasExtraProperties=$false
    foreach($propertyName in $hook.PSObject.Properties.Name){if($propertyName -notin @("type","command","timeout")){$hasExtraProperties=$true;break}}
    if($hasExtraProperties){continue}
    $command=([string]$hook.command).Trim()
    if([string]::Equals($command,$expected,[StringComparison]::Ordinal) -or [string]::Equals($command,$legacy,[StringComparison]::OrdinalIgnoreCase)){[void]$connectedEvents.Add($eventProperty.Name)}
   }
  }
 }
 if($connectedEvents.Count -eq $knownEvents.Count){return "connected"}
 if($connectedEvents.Count -gt 0){return "partial"}
 return "disconnected"
}

function Claude-HookConnected {
 try{return (Claude-ConnectionState) -eq "connected"}catch{return $false}
}

function Claude-InstallationState([string]$profile,[string]$appData,[string]$localData,[string]$pathValue) {
 $directories=New-Object 'Collections.Generic.List[string]'
 $desktopExecutable=if($localData){Join-Path $localData 'Programs\Claude\Claude.exe'}else{''}
 if($profile){$directories.Add((Join-Path $profile '.local\bin'))}
 if($appData){$directories.Add((Join-Path $appData 'npm'))}
 foreach($part in ($pathValue -split ';')){
  $directory=$part.Trim().Trim('"')
  if($directory){$directories.Add($directory)}
 }
 foreach($directory in $directories){
  foreach($name in @('claude.exe','claude.cmd','claude.bat')){
   try{
    $candidate=Join-Path $directory $name
    if($desktopExecutable -and [string]::Equals([IO.Path]::GetFullPath($candidate),[IO.Path]::GetFullPath($desktopExecutable),[StringComparison]::OrdinalIgnoreCase)){continue}
    if(Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop){return 'available'}
   }catch{}
  }
 }
 if($desktopExecutable -and (Test-Path -LiteralPath $desktopExecutable -PathType Leaf)){return 'unconfirmed'}
 if($profile -and (Test-Path -LiteralPath (Join-Path $profile '.claude') -PathType Container)){return 'unconfirmed'}
 return 'not-found'
}

function Update-SourceSettings {
 $codexSourceStatus.Text=Tr $(if($script:sourceErrors -contains "Codex"){"Нет данных"}elseif(Test-Path -LiteralPath $sessionIndex){"Подключён"}else{"Не найден"})
 Update-CodexCloudSourceSettings
 Update-OpenCodeSourceSettings
 Update-KimiSourceSettings
 Update-DeepSeekSourceSettings
 Update-HermesSourceSettings
 $installation=Claude-InstallationState $env:USERPROFILE $env:APPDATA $env:LOCALAPPDATA $env:PATH
 try{$connectionState=Claude-ConnectionState;$connected=$connectionState -eq "connected"}
 catch{
  $claudeSourceStatus.Text=Tr "Нет данных"
  $claudeSourceAction.Visibility="Visible";$claudeSourceAction.IsEnabled=$false;$claudeSourceAction.Content=Tr "Подключить";$claudeSourceAction.Tag=""
  $claudeSourceAction.ToolTip=Tr "Не удалось прочитать настройки Claude Code"
  [Windows.Automation.AutomationProperties]::SetName($claudeSourceAction,(Tr "Claude Code: не удалось прочитать настройки"))
  return
 }
 if($installation -eq 'not-found' -and $connectionState -eq 'disconnected'){
  $claudeSourceStatus.Text=Tr 'Не найден'
  $claudeSourceAction.Visibility="Visible";$claudeSourceAction.IsEnabled=$false;$claudeSourceAction.Content=Tr "Подключить";$claudeSourceAction.Tag=""
  $claudeSourceAction.ToolTip=Tr 'Claude Code не найден на этом компьютере'
  [Windows.Automation.AutomationProperties]::SetName($claudeSourceAction,([string]$claudeSourceAction.ToolTip))
  return
 }
 $claudeSourceStatus.Text=Tr $(if($connectionState -eq "partial"){"Подключён частично"}elseif($connected -and $script:sourceErrors -contains "Claude Code"){"Нет данных"}elseif($connected){"Подключён"}elseif($installation -eq 'unconfirmed'){"Установка не подтверждена"}else{"Не подключён"})
 $claudeSourceAction.Visibility="Visible";$claudeSourceAction.IsEnabled=$true;$claudeSourceAction.ToolTip=$null
 $claudeSourceAction.Content=Tr $(if($connected){"Отключить"}else{"Подключить"})
 $claudeSourceAction.Tag=$(if($connected){"Remove"}else{"Install"})
 if($connectionState -eq "partial"){$claudeSourceAction.ToolTip=Tr "Подключение неполное. Нажмите, чтобы восстановить."}
 elseif($installation -eq 'unconfirmed' -and -not $connected){$claudeSourceAction.ToolTip=Tr 'Не удалось подтвердить установку Claude Code'}
 [Windows.Automation.AutomationProperties]::SetName($claudeSourceAction,$claudeSourceAction.Content+" Claude Code")
}

function Update-CodexCloudSourceSettings {
 $codexCloudSourceAction.Visibility='Visible';$codexCloudSourceAction.IsEnabled=$script:codexCloudModulesAvailable
 $codexCloudSourceAction.ToolTip=$null;$codexCloudSourceError.Visibility='Collapsed'
 $controller=$script:codexCloudController
 $enabled=$null -ne $controller -and $controller.Enabled
 $codexCloudSourceAction.Content=Tr $(if($enabled){'Отключить'}else{'Подключить'})
 $codexCloudSourceAction.Tag=if($enabled){'Remove'}else{'Install'}
 $codexCloudSourceStatus.Text=Tr $(if(-not $script:codexCloudModulesAvailable){'Нет данных'}elseif(-not $enabled){'Не подключён'}elseif($controller.LastError){'Нет данных'}elseif(-not $controller.Scanned){'Проверка'}else{'Подключён'})
 $message=if($script:codexCloudPreferenceError){$script:codexCloudPreferenceError}
  elseif(-not $script:codexCloudModulesAvailable -or ($enabled -and $controller.LastError)){'Не удалось получить облачные задачи. Проверьте установку Codex, вход и интернет.'}
  elseif($enabled -and $controller.Partial){'Показаны не все облачные задачи.'}else{''}
 if($message){$codexCloudSourceError.Text=Tr $message;$codexCloudSourceError.Visibility='Visible'}
 [Windows.Automation.AutomationProperties]::SetName($codexCloudSourceAction,$codexCloudSourceAction.Content+' Codex Cloud')
}

function Update-OpenCodeSourceSettings {
 $openCodeSourceAction.Visibility='Visible';$openCodeSourceAction.IsEnabled=$false
 $openCodeSourceAction.Content=Tr 'Подключить';$openCodeSourceAction.Tag='';$openCodeSourceAction.ToolTip=$null
 try {
  if(-not $script:externalProviderModulesAvailable){throw 'Provider runtime unavailable.'}
  $state=Get-OpenCodeConnectionState -AppRoot $PSScriptRoot
  if($state -in @('connected','partial')){
   $openCodeSourceStatus.Text=Tr $(if($state -eq 'partial'){'Подключён частично'}elseif($script:sourceErrors -contains 'OpenCode'){'Нет данных'}else{'Подключён'})
   $openCodeSourceAction.IsEnabled=$true;$openCodeSourceAction.Content=Tr 'Отключить';$openCodeSourceAction.Tag='Remove'
  }else{
   $installed=Test-OpenCodePotentialInstallation
   $openCodeSourceStatus.Text=Tr $(if($installed){'Не подключён'}else{'Установка не подтверждена'})
   $openCodeSourceAction.IsEnabled=$installed
   if($installed){$openCodeSourceAction.Tag='Install'}else{$openCodeSourceAction.ToolTip=Tr 'Не удалось подтвердить установку или совместимость OpenCode'}
  }
 }catch{
  $openCodeSourceStatus.Text=Tr 'Нет данных'
  $openCodeSourceAction.ToolTip=Tr 'Не удалось прочитать подключение OpenCode'
 }
 [Windows.Automation.AutomationProperties]::SetName($openCodeSourceAction,$openCodeSourceAction.Content+' OpenCode')
}

function Update-KimiSourceSettings {
 $kimiSourceAction.Content=Tr 'Скопировать путь'
 [Windows.Automation.AutomationProperties]::SetName($kimiSourceAction,((Tr 'Скопировать путь')+' Kimi Code'))
 $kimiSourceAction.IsEnabled=$false
 $kimiSourceStatus.Text=Tr 'Установка не подтверждена'
 $kimiSourceError.Visibility='Collapsed';$kimiSourceError.Text=''
 if(-not $script:kimiModulesAvailable -or $null -eq $script:kimiController){return}
 $controller=$script:kimiController
 if($controller.LastError -and $controller.LastError -ne 'installation-unconfirmed'){
  $kimiSourceStatus.Text=Tr 'Нет данных'
  $kimiSourceError.Text=Tr 'Не удалось проверить плагин Kimi Code.';$kimiSourceError.Visibility='Visible'
 }elseif($controller.Scanned -and -not $controller.LastError){
  $kimiSourceStatus.Text=Tr $(switch($controller.State){'connected'{'Плагин включён'} 'disabled'{'Плагин отключён'} default{'Плагин не установлен'}})
  $kimiSourceAction.IsEnabled=[IO.Directory]::Exists((Join-Path $PSScriptRoot 'integrations\kimi-plugin'))
 }
 if($script:kimiCopyError){$kimiSourceError.Text=Tr $script:kimiCopyError;$kimiSourceError.Visibility='Visible'}
}

function Get-DeepSeekErrorMessage([string]$code,[bool]$profileScan=$false) {
 $message=switch($code){
  'unsupported-desktop'{'Профиль DeepSeek Desktop пока не поддерживается.';break}
  {$_ -in @('unverified-dsh','unverified-pnpm')}{'Версия DeepSeek Harness или pnpm не подтверждена.';break}
  {$_ -in @('linked-path','modified-bundle','partial-connection') -or $_ -like 'bundle-conflict*'}{'Подключение DeepSeek Harness неполное или его файлы изменены.';break}
  default{if($profileScan){'Не удалось проверить профиль DeepSeek Harness.'}else{'Не удалось изменить подключение DeepSeek Harness.'}}
 }
 return (Tr $message)
}

function Update-DeepSeekSourceSettings {
 $deepSeekSourceAction.Visibility='Visible';$deepSeekSourceAction.IsEnabled=$false
 $deepSeekSourceAction.Content=Tr 'Подключить';$deepSeekSourceAction.Tag=''
 [Windows.Automation.AutomationProperties]::SetName($deepSeekSourceAction,$deepSeekSourceAction.Content+' DeepSeek Harness')
 $deepSeekSourceStatus.Text=Tr 'Установка не подтверждена'
 $deepSeekSourceError.Visibility='Collapsed';$deepSeekSourceError.Text=''
 if(-not $script:deepSeekModulesAvailable -or $null -eq $script:deepSeekController){$deepSeekProfileCombo.IsEnabled=$false;return}
 $controller=$script:deepSeekController
 $names=@($controller.Profiles | ForEach-Object {[string]$_.Name})
 $selected=[string]$deepSeekProfileCombo.SelectedItem
 $changed=($names.Count -ne $deepSeekProfileCombo.Items.Count)
 if(-not $changed){for($index=0;$index -lt $names.Count;$index++){if([string]$deepSeekProfileCombo.Items[$index] -cne $names[$index]){$changed=$true;break}}}
 if($changed){
  $script:updatingDeepSeekControls=$true
  try{
   $deepSeekProfileCombo.Items.Clear()
   foreach($name in $names){[void]$deepSeekProfileCombo.Items.Add($name)}
   if($selected -and $names -ccontains $selected){$deepSeekProfileCombo.SelectedItem=$selected}else{$deepSeekProfileCombo.SelectedIndex=-1;$selected=''}
  }finally{$script:updatingDeepSeekControls=$false}
 }
 $changing=$null -ne $controller.Request -and $controller.Request.Action -ne 'list'
 $deepSeekProfileCombo.IsEnabled=$names.Count -gt 0 -and -not $changing
 $errorCode=if($controller.ActionError){[string]$controller.ActionError}else{[string]$controller.LastError}
 if($errorCode -and $errorCode -ne 'installation-unconfirmed'){
  $deepSeekSourceError.Text=Get-DeepSeekErrorMessage $errorCode;$deepSeekSourceError.Visibility='Visible'
 }
 if($controller.LastError -or -not $controller.Scanned){return}
 if(-not $selected){$deepSeekSourceStatus.Text=Tr 'Выберите профиль';return}
 $profile=@($controller.Profiles | Where-Object {$_.Name -ceq $selected})
 if($profile.Count -ne 1){return}
 $state=[string]$profile[0].State
 $deepSeekSourceStatus.Text=Tr $(if($state -eq 'connected'){'Подключён'}elseif($state -eq 'partial'){'Подключён частично'}elseif($state -eq 'error'){'Нет данных'}else{'Не подключён'})
 if($state -eq 'error'){
  $profileError=if($null -ne $profile[0].PSObject.Properties['Error']){[string]$profile[0].Error}else{'operation-failed'}
  $deepSeekSourceError.Text=Get-DeepSeekErrorMessage $profileError $true;$deepSeekSourceError.Visibility='Visible'
 }elseif($null -eq $controller.Request){
  $deepSeekSourceAction.IsEnabled=$true
  if($state -in @('connected','partial')){$deepSeekSourceAction.Content=Tr 'Отключить';$deepSeekSourceAction.Tag='Remove'}else{$deepSeekSourceAction.Tag='Install'}
 }
 [Windows.Automation.AutomationProperties]::SetName($deepSeekSourceAction,$deepSeekSourceAction.Content+' DeepSeek Harness')
}

function Test-HermesUiProfile($profile) {
 if($null -eq $profile){return $false}
 foreach($property in @('Id','Name','State')){
  if($null -eq $profile.PSObject.Properties[$property]){return $false}
 }
 $name=[string]$profile.Name;$id=[string]$profile.Id
 if($name -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){return $false}
 if($id -ceq 'root'){return $name -ceq 'default'}
 if($name -in @('default','hermes','test','tmp','root','sudo')){return $false}
 return $id -ceq ('profile:'+$name)
}

function ConvertTo-HermesPowerShellLiteral([string]$value) {
 if([string]::IsNullOrWhiteSpace($value)){return $null}
 $builder=New-Object Text.StringBuilder
 $quotes=@([char]0x0027,[char]0x2018,[char]0x2019,[char]0x201A,[char]0x201B)
 foreach($character in $value.ToCharArray()){
  if([char]::IsControl($character) -or [char]::GetUnicodeCategory($character) -in @([Globalization.UnicodeCategory]::Format,[Globalization.UnicodeCategory]::LineSeparator,[Globalization.UnicodeCategory]::ParagraphSeparator)){return $null}
  [void]$builder.Append($character)
  if($quotes -contains $character){[void]$builder.Append($character)}
 }
 return "'"+$builder.ToString()+"'"
}

function Get-HermesManualCommand($context,$profile,[string]$action) {
 if($null -eq $context -or -not (Test-HermesUiProfile $profile) -or $action -cnotin @('enable','disable')){return $null}
 $paths=@{}
 foreach($property in @('Python','Assets','Home','Project')){
  $entry=$context.PSObject.Properties[$property]
  if($null -eq $entry -or $entry.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Value) -or
     $entry.Value -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/.?][^\\/]*[\\/][^\\/]+(?:[\\/]|$))'){return $null}
  $paths[$property]=[string]$entry.Value
 }
 if($paths.Python.EndsWith('\') -or $paths.Python.EndsWith('/')){return $null}
 # Windows PowerShell 5.1 can corrupt a native argument ending in a slash.
 # A final "." denotes the same directory without a trailing separator.
 foreach($property in @('Home','Project')){
  if($paths[$property].EndsWith('\') -or $paths[$property].EndsWith('/')){$paths[$property]+='.'}
 }
 try{$helper=[IO.Path]::Combine($paths.Assets,'hermes-manager.py')}catch{return $null}
 $literals=@(foreach($value in @($paths.Python,$helper,$paths.Home,$paths.Project,[string]$profile.Name,$action)){
  $literal=ConvertTo-HermesPowerShellLiteral $value
  if($null -eq $literal){return $null}
  $literal
 })
 if($literals.Count -ne 6){return $null}
 return '& '+$literals[0]+' -I -B '+$literals[1]+' '+$literals[2]+' '+$literals[3]+' '+$literals[4]+' '+$literals[5]
}

function Hide-HermesSourceCommands {
 if($hermesSourceCommands.Visibility -ne 'Collapsed'){$hermesSourceCommands.Visibility='Collapsed'}
 if($hermesEnableRun.Text){$hermesEnableRun.Text=''}
 if($hermesDisableRun.Text){$hermesDisableRun.Text=''}
}

function Update-HermesSourceSettings {
 $hermesSourceAction.Content=Tr 'Подготовить';$hermesSourceAction.IsEnabled=$false
 [Windows.Automation.AutomationProperties]::SetName($hermesSourceAction,((Tr 'Подготовить')+' Hermes Agent'))
 $hermesSourceStatus.Text=Tr 'Установка не подтверждена'
 $hermesSourceError.Visibility='Collapsed';$hermesSourceError.Text=''
 if(-not $script:hermesModulesAvailable -or $null -eq $script:hermesController){$hermesProfileCombo.IsEnabled=$false;Hide-HermesSourceCommands;return}
 $controller=$script:hermesController
 $profiles=@($controller.Profiles | Where-Object {Test-HermesUiProfile $_})
 $names=@($profiles | ForEach-Object {[string]$_.Name})
 $selected=[string]$hermesProfileCombo.SelectedItem
 $changed=$names.Count -ne $hermesProfileCombo.Items.Count
 if(-not $changed){for($index=0;$index -lt $names.Count;$index++){if([string]$hermesProfileCombo.Items[$index] -cne $names[$index]){$changed=$true;break}}}
 if($changed){
  $script:updatingHermesControls=$true
  try{
   $hermesProfileCombo.Items.Clear()
   foreach($name in $names){[void]$hermesProfileCombo.Items.Add($name)}
   if($selected -and $names -ccontains $selected){$hermesProfileCombo.SelectedItem=$selected}else{$hermesProfileCombo.SelectedIndex=-1;$selected=''}
  }finally{$script:updatingHermesControls=$false}
 }
 $changing=$null -ne $controller.Request -and ($null -eq $controller.Request.PSObject.Properties['Action'] -or $controller.Request.Action -ne 'list')
 $hermesProfileCombo.IsEnabled=$names.Count -gt 0 -and -not $changing -and -not $controller.LastError
 $errorCode=if($controller.ActionError){[string]$controller.ActionError}else{[string]$controller.LastError}
 if($errorCode -and $errorCode -ne 'installation-unconfirmed'){
  if($controller.LastError){$hermesSourceStatus.Text=Tr 'Нет данных'}
  $hermesSourceError.Text=Tr $(if($controller.ActionError){'Не удалось подготовить плагин Hermes.'}else{'Не удалось проверить профиль Hermes.'})
  $hermesSourceError.Visibility='Visible'
 }elseif($script:hermesCopyError){
  $hermesSourceError.Text=Tr $script:hermesCopyError;$hermesSourceError.Visibility='Visible'
 }
 if($controller.LastError -or -not $controller.Scanned){Hide-HermesSourceCommands;return}
 if(-not $selected){$hermesSourceStatus.Text=Tr 'Выберите профиль';Hide-HermesSourceCommands;return}
 $match=@($profiles | Where-Object {[string]$_.Name -ceq $selected})
 if($match.Count -ne 1){$hermesSourceStatus.Text=Tr 'Нет данных';Hide-HermesSourceCommands;return}
 $profile=$match[0];$name=[string]$profile.Name
 if($changing){$hermesSourceStatus.Text=Tr 'Подготовка';Hide-HermesSourceCommands;return}
 if($profile.State -in @('prepared','absent')){
  $enable=Get-HermesManualCommand $controller.Context $profile 'enable'
  $disable=Get-HermesManualCommand $controller.Context $profile 'disable'
  if(-not $enable -or -not $disable){
   $hermesSourceStatus.Text=Tr 'Нет данных';$hermesSourceError.Text=Tr 'Не удалось проверить профиль Hermes.';$hermesSourceError.Visibility='Visible';Hide-HermesSourceCommands;return
  }
 }
 switch([string]$profile.State){
  'prepared' {
   if($null -eq $profile.PSObject.Properties['Enabled'] -or $profile.Enabled -isnot [bool]){
    $hermesSourceStatus.Text=Tr 'Нет данных';$hermesSourceError.Text=Tr 'Не удалось проверить профиль Hermes.';$hermesSourceError.Visibility='Visible';Hide-HermesSourceCommands;return
   }
   $hermesSourceStatus.Text=Tr $(if($profile.Enabled){'Включён локально'}else{'Отключён локально'})
   if($hermesEnableRun.Text -cne $enable){$hermesEnableRun.Text=$enable}
   if($hermesDisableRun.Text -cne $disable){$hermesDisableRun.Text=$disable}
   if($hermesSourceCommands.Visibility -ne 'Visible'){$hermesSourceCommands.Visibility='Visible'}
  }
  'absent' {$hermesSourceStatus.Text=Tr 'Не подготовлен';$hermesSourceAction.IsEnabled=$null -eq $controller.Request;Hide-HermesSourceCommands}
  default {$hermesSourceStatus.Text=Tr 'Нет данных';$hermesSourceError.Text=Tr 'Не удалось проверить профиль Hermes.';$hermesSourceError.Visibility='Visible';Hide-HermesSourceCommands}
 }
}

function Apply-Theme([string]$mode,[bool]$persist) {
 $resolved=if($mode -eq "system"){Windows-Theme}else{$mode}
 $script:themeMode=$mode; $script:resolvedTheme=$resolved
 if($resolved -eq "light"){
  $script:palette=@{Surface="#F6F6F6";Raised="#FFFFFF";TooltipSurface="#ECECEC";TooltipBorder="#CDCDCD";Border="#D7D7D7";Primary="#1F1F1F";Secondary="#575757";Muted="#707070";Hover="#EAEAEA";Pressed="#DFDFDF";Divider="#E2E2E2";Track="#D8D8D8";Scroll="#B3B3B3";ScrollHover="#8F8F8F";CardBorder="#DADADA";Activity="#707070";Done="#707070";Pending="#4F4F4F"}
 }else{
  $script:palette=@{Surface="#202020";Raised="#282828";TooltipSurface="#171717";TooltipBorder="#3D3D3D";Border="#414141";Primary="#F1F1F1";Secondary="#ACACAC";Muted="#989898";Hover="#333333";Pressed="#3B3B3B";Divider="#343434";Track="#3A3A3A";Scroll="#555555";ScrollHover="#747474";CardBorder="#474747";Activity="#989898";Done="#989898";Pending="#B8B8B8"}
 }
 $resources=@{Surface=$script:palette.Surface;SurfaceRaised=$script:palette.Raised;TooltipSurface=$script:palette.TooltipSurface;TooltipBorder=$script:palette.TooltipBorder;Border=$script:palette.Border;TextPrimary=$script:palette.Primary;TextSecondary=$script:palette.Secondary;TextMuted=$script:palette.Muted;SurfaceHover=$script:palette.Hover;SurfacePressed=$script:palette.Pressed;Divider=$script:palette.Divider;Track=$script:palette.Track;ScrollThumbBrush=$script:palette.Scroll;ScrollThumbHoverBrush=$script:palette.ScrollHover}
 foreach($key in $resources.Keys){$window.Resources[$key]=Brush $resources[$key]}
 if($persist){[void](Save-ThemeMode $mode)}
 Update-ThemeButtons
 Update-SettingsButtonName
 $script:fingerprint=""
}

function Refresh-SystemTheme {
 if($script:themeMode -eq "system"){
  $resolved=Windows-Theme
  if($resolved -ne $script:resolvedTheme){Apply-Theme "system" $false}
 }
}

function Lock-State([string]$path) {
 if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { return "missing" }
 try {
  $sharing=[IO.FileShare]::Read -bor [IO.FileShare]::Delete
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
  $stream.Dispose()
  return "free"
 } catch {
  $exception=$_.Exception
  while($null -ne $exception.InnerException){$exception=$exception.InnerException}
  if($exception -is [IO.IOException] -and (($exception.HResult -band 65535) -in @(32,33))){return "held"}
  return "unavailable"
 }
}

function Find-PriorLifecycle([string]$path) {
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try {
  $position=$stream.Length;$buffer=New-Object byte[] 262144;$carry='';$discardPartial=$false
  $terminals=New-Object 'Collections.Generic.List[object]'
  while($position -gt 0){
   $count=[int][Math]::Min([long]$buffer.Length,$position);$position-=$count
   [void]$stream.Seek($position,[IO.SeekOrigin]::Begin)
   $read=0
   while($read -lt $count){$n=$stream.Read($buffer,$read,$count-$read);if($n -le 0){throw 'Unable to read Codex session history.'};$read+=$n}
   $text=[Text.Encoding]::UTF8.GetString($buffer,0,$read)
   if(-not $discardPartial){$text+=$carry}
   $lines=$text.Split([char]10)
   if($lines.Length -eq 1 -and $position -gt 0){
    if($discardPartial){$carry=''}elseif($text.Length -gt 1048576){$carry='';$discardPartial=$true}else{$carry=$text}
    continue
   }
   $last=$lines.Length-1
   if($discardPartial){$last--;$discardPartial=$false}
   $first=if($position -eq 0){0}else{1}
   for($i=$last;$i -ge $first;$i--){
    $line=$lines[$i]
    if($line.Length -gt 1048576 -or $line -notmatch '"event_msg"' -or $line -notmatch '"(task_started|turn_started|task_complete|turn_complete|turn_aborted)"'){continue}
    try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
    if($null -eq $record.PSObject.Properties['type'] -or [string]$record.type -ne 'event_msg' -or $null -eq $record.PSObject.Properties['payload']){continue}
    $payload=$record.payload
    if($null -eq $payload -or $null -eq $payload.PSObject.Properties['type']){continue}
    $type=[string]$payload.type
    if($type -notin @('task_started','turn_started','task_complete','turn_complete','turn_aborted')){continue}
    $turn=if($null -ne $payload.PSObject.Properties['turn_id']){[string]$payload.turn_id}else{''}
    if($type -in @('task_started','turn_started')){
     $raw=if($null -ne $record.PSObject.Properties['timestamp']){[string]$record.timestamp}else{''}
     $timestamp=[DateTime]::MinValue
     if($null -ne $record.PSObject.Properties['timestamp']){
      $value=$record.timestamp
      if($value -is [DateTime]){$timestamp=$value.ToUniversalTime()}
      elseif($value -is [DateTimeOffset]){$timestamp=$value.UtcDateTime}
      elseif($null -ne $value -and [DateTime]::TryParse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp)){$timestamp=$timestamp.ToUniversalTime()}
     }
     $lifecycle='task_started'
     foreach($terminal in $terminals){
      if(-not $turn -or -not $terminal.TurnId -or $turn -eq $terminal.TurnId){$lifecycle=$terminal.Lifecycle;break}
     }
     $key=if($turn){'turn:'+$turn}elseif($raw){'time:'+$raw}else{''}
     return [PSCustomObject]@{Lifecycle=$lifecycle;TurnId=$turn;LastEventUtc=$timestamp;StartKey=$key;StartedUtc=$timestamp}
    }
    if($terminals.Count -ge 1024){return $null}
    $terminals.Add([PSCustomObject]@{Lifecycle=$(if($type -eq 'turn_aborted'){'turn_aborted'}else{'task_complete'});TurnId=$turn})
   }
   if($position -gt 0){
    $carry=$lines[0]
    if($carry.Length -gt 1048576){$carry='';$discardPartial=$true}
   }
  }
  if($terminals.Count){return [PSCustomObject]@{Lifecycle=$terminals[0].Lifecycle;TurnId='';LastEventUtc=[DateTime]::MinValue;StartKey='';StartedUtc=[DateTime]::MinValue}}
  return $null
 } finally {$stream.Dispose()}
}

function Thread-State([string]$id) {
 if($id -notmatch '^[A-Za-z0-9_-]{1,128}$'){return [PSCustomObject]@{State="unknown";HasStartMarker=$false;UpdatedUtc=[DateTime]::MinValue;StartKey="";StartedUtc=[DateTime]::MinValue}}
 $path = Session-File $id
 if (-not $path -or -not (Test-Path -LiteralPath $path)) { return [PSCustomObject]@{State="unknown";HasStartMarker=$false;UpdatedUtc=[DateTime]::MinValue;StartKey="";StartedUtc=[DateTime]::MinValue} }
 $file=Get-Item -LiteralPath $path
 $cached=if($script:lifecycleState.ContainsKey($path)){$script:lifecycleState[$path]}else{$null}
 if($null -ne $cached -and [long]$cached.Length -eq [long]$file.Length -and [long]$cached.Stamp -eq $file.LastWriteTimeUtc.Ticks){
  $lifecycle=[string]$cached.Lifecycle
  $lastEventUtc=[DateTime]$cached.LastEventUtc
  $startKey=if($null -ne $cached.PSObject.Properties["StartKey"]){[string]$cached.StartKey}else{""}
  $startedUtc=if($null -ne $cached.PSObject.Properties["StartedUtc"]){[DateTime]$cached.StartedUtc}else{[DateTime]::MinValue}
 }else{
  $tailLimit=2097152
  $tail=Read-TailText $path $tailLimit
  $seed=$null
  if($null -ne $cached -and $cached.Lifecycle -in @('task_started','task_complete','turn_aborted') -and
     $null -ne $cached.PSObject.Properties['TurnId'] -and [long]$file.Length -ge [long]$cached.Length -and
     ([long]$file.Length-[long]$cached.Length) -le $tailLimit -and $file.LastWriteTimeUtc.Ticks -ge [long]$cached.Stamp){$seed=$cached}
  $scannedPrior=($null -ne $cached -and $null -ne $cached.PSObject.Properties['PriorScanComplete'] -and $cached.PriorScanComplete -and
   [long]$file.Length -ge [long]$cached.Length -and ([long]$file.Length-[long]$cached.Length) -le $tailLimit -and
   $file.LastWriteTimeUtc.Ticks -ge [long]$cached.Stamp)
  $parseTail={param($text,$initial)
   $lifecycle=if($initial){[string]$initial.Lifecycle}else{''}
   $turnId=if($initial){[string]$initial.TurnId}else{''}
   $startKey=if($initial){[string]$initial.StartKey}else{''}
   $startedUtc=if($initial){[DateTime]$initial.StartedUtc}else{[DateTime]::MinValue}
   $lastEventUtc=if($initial){[DateTime]$initial.LastEventUtc}else{[DateTime]::MinValue}
   $latestTailEventUtc=[DateTime]::MinValue;$sawStart=$false
   foreach($line in ($text -split "`r?`n")){
   if($line.Length -gt 1048576 -or $line -notmatch '"event_msg"'){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   if($null -eq $record.PSObject.Properties["type"] -or [string]$record.type -ne "event_msg" -or $null -eq $record.PSObject.Properties["payload"]){continue}
   $payload=$record.payload
   if($null -eq $payload -or $null -eq $payload.PSObject.Properties["type"]){continue}
   $eventType=[string]$payload.type
   $eventTurn=if($null -ne $payload.PSObject.Properties["turn_id"]){[string]$payload.turn_id}else{""}
   $timestampValue=if($null -ne $record.PSObject.Properties["timestamp"]){$record.timestamp}else{$null}
   $timestamp=[DateTime]::MinValue
   if($timestampValue -is [DateTime]){$timestamp=$timestampValue.ToUniversalTime()}
   elseif($timestampValue -is [DateTimeOffset]){$timestamp=$timestampValue.UtcDateTime}
   elseif($null -ne $timestampValue -and [DateTime]::TryParse([string]$timestampValue,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp)){$timestamp=$timestamp.ToUniversalTime()}
   if($timestamp -gt $latestTailEventUtc){$latestTailEventUtc=$timestamp}
   if($eventType -in @("task_started","turn_started")){
    $sawStart=$true
    $lifecycle="task_started";$turnId=$eventTurn;$lastEventUtc=[DateTime]::MinValue
    $rawStart=if($null -ne $record.PSObject.Properties["timestamp"]){[string]$record.timestamp}else{""}
    $startKey=if($eventTurn){"turn:"+$eventTurn}elseif($rawStart){"time:"+$rawStart}else{""}
   }
   elseif($eventType -notin @("task_complete","turn_complete","turn_aborted") -and $lifecycle -ne "task_started"){continue}
   if($turnId -and $eventTurn -and $eventTurn -ne $turnId){continue}
   if($eventType -in @("task_complete","turn_complete","turn_aborted")){
    $lifecycle=if($eventType -eq "turn_aborted"){"turn_aborted"}else{"task_complete"}
    continue
   }
   if($eventType -in @("task_started","turn_started")){$startedUtc=$timestamp}
   if($timestamp -gt $lastEventUtc){$lastEventUtc=$timestamp}
   }
   return [PSCustomObject]@{Lifecycle=$lifecycle;TurnId=$turnId;LastEventUtc=$lastEventUtc;StartKey=$startKey;StartedUtc=$startedUtc;LatestTailEventUtc=$latestTailEventUtc;SawStart=$sawStart}
  }
  $parsed=& $parseTail $tail $seed
  if($null -eq $seed -and -not $scannedPrior -and -not $parsed.SawStart -and [long]$file.Length -gt $tailLimit -and $parsed.LatestTailEventUtc -ge $script:monitorStartedUtc){
   $priorLock=Lock-State (Join-Path $lockDirectory "$id.lock")
   if($priorLock -eq 'unavailable'){throw 'Codex session lock cannot be checked.'}
   if($priorLock -eq 'held'){
    $prior=Find-PriorLifecycle $path
    $scannedPrior=$true
    if($null -ne $prior){$parsed=& $parseTail $tail $prior}
   }
  }
  $lifecycle=[string]$parsed.Lifecycle;$turnId=[string]$parsed.TurnId;$lastEventUtc=[DateTime]$parsed.LastEventUtc
  $startKey=[string]$parsed.StartKey;$startedUtc=[DateTime]$parsed.StartedUtc
  $script:lifecycleState[$path]=[PSCustomObject]@{Length=[long]$file.Length;Stamp=$file.LastWriteTimeUtc.Ticks;Lifecycle=$lifecycle;TurnId=$turnId;LastEventUtc=$lastEventUtc;StartKey=$startKey;StartedUtc=$startedUtc;PriorScanComplete=$scannedPrior}
 }
 $hasStart=$lifecycle -eq "task_started"
 $lock=if($hasStart){Lock-State (Join-Path $lockDirectory "$id.lock")}else{"missing"}
 if($lock -eq "unavailable"){throw "Codex session lock cannot be checked."}
 $state=if($lifecycle -eq "task_complete"){"completed"}elseif($lifecycle -eq "turn_aborted"){"interrupted"}elseif($hasStart -and $lock -eq "held"){
  if($lastEventUtc -ge $script:monitorStartedUtc -or $script:observedCodex.ContainsKey($id)){"active"}else{"unobserved"}
 }else{"unknown"}
 return [PSCustomObject]@{State=$state;HasStartMarker=$hasStart;UpdatedUtc=$file.LastWriteTimeUtc;StartKey=$startKey;StartedUtc=$startedUtc}
}

function Codex-Uncertain([string]$id,$threadState) {
 if($threadState.State -eq "active"){$script:observedCodex[$id]=$true}
 elseif($threadState.State -in @("completed","interrupted")){[void]$script:observedCodex.Remove($id)}
 elseif($threadState.State -eq "unknown" -and $threadState.HasStartMarker -and $threadState.UpdatedUtc -ge $script:monitorStartedUtc){$script:observedCodex[$id]=$true}
 return ($threadState.State -eq "unknown" -and $script:observedCodex.ContainsKey($id))
}

function Session-File([string]$id) {
 $cache=$script:sessionDiscovery
 [Threading.Monitor]::Enter($cache.Gate)
 try {
  $markActivity={
   $cache.RetrySeconds=5
   $cache.HotUntilTicks=[Diagnostics.Stopwatch]::GetTimestamp()+([long][Diagnostics.Stopwatch]::Frequency * 30)
  }
  $fileAvailable={param([string]$candidate)
   try {
    $attributes=[IO.File]::GetAttributes($candidate)
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { throw 'Not a session file.' }
    return $true
   } catch {
    $exception=$_.Exception
    while($null -ne $exception.InnerException){$exception=$exception.InnerException}
    if($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException]){return $false}
    throw 'Codex session file cannot be read.'
   }
  }
  if ($cache.Files.ContainsKey($id)) {
   $cached=[string]$cache.Files[$id]
   if ($cached -and (& $fileAvailable $cached)) { return $cached }
   [void]$cache.Files.Remove($id)
   [void]$cache.DatedMisses.Remove($id)
   & $markActivity
  }
  if ($script:sessionDates.ContainsKey($id)) {
   $folder = $script:sessionDates[$id]
   $skipDated=$false
   if ($cache.DatedMisses.ContainsKey($id)) {
    $miss=$cache.DatedMisses[$id]
    $age=[Diagnostics.Stopwatch]::GetTimestamp()-[long]$miss.Tick
    if ([string]::Equals([string]$miss.Folder,[string]$folder,[StringComparison]::OrdinalIgnoreCase) -and
        $age -ge 0 -and $age -lt [Diagnostics.Stopwatch]::Frequency) { $skipDated=$true }
    else { [void]$cache.DatedMisses.Remove($id) }
   }
   if (-not $skipDated) {
    try {
     if (Test-Path -LiteralPath $folder -PathType Container -ErrorAction Stop) {
      $datedFile = Get-ChildItem -LiteralPath $folder -File -Filter ("*" + $id + ".jsonl") -ErrorAction Stop | Select-Object -First 1
      if ($null -ne $datedFile) {
       [void]$cache.DatedMisses.Remove($id)
       $cache.Files[$id] = $datedFile.FullName
       & $markActivity
       return $datedFile.FullName
      }
     }
     $cache.DatedMisses[$id]=[PSCustomObject]@{Folder=$folder;Tick=[Diagnostics.Stopwatch]::GetTimestamp()}
    } catch {
     [void]$cache.DatedMisses.Remove($id)
     throw 'Codex session files cannot be read.'
    }
   }
  }
  try {
   $rootAttributes=[IO.File]::GetAttributes($sessionsDirectory)
   if (($rootAttributes -band [IO.FileAttributes]::Directory) -eq 0) { throw 'Not a session directory.' }
  } catch {
   throw 'Codex session files cannot be read.'
  }
  $now=[Diagnostics.Stopwatch]::GetTimestamp()
  if ($cache.Attempted -and $now -lt $cache.LastScanTicks) { $cache.LastScanTicks=$now; $cache.RetrySeconds=5 }
  $interval=[long][Diagnostics.Stopwatch]::Frequency * [Math]::Max(5,[int]$cache.RetrySeconds)
  if (-not $cache.Attempted -or ($now - $cache.LastScanTicks) -ge $interval) {
   $previousAttempt=[bool]$cache.Attempted
   $previousFailure=[bool]$cache.ScanFailed
   $cache.RolloutMisses.Clear()
   try {
    $cache.Rollouts = @([IO.Directory]::EnumerateFiles($sessionsDirectory, "*.jsonl", [IO.SearchOption]::AllDirectories))
    $cache.ScanFailed = $false
    if ($previousFailure) { & $markActivity }
   } catch {
    $cache.Rollouts = $null
    $cache.ScanFailed = $true
   } finally {
    $cache.LastScanTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    $cache.Attempted = $true
    if ($previousAttempt -and $cache.LastScanTicks -ge $cache.HotUntilTicks) {
     $cache.RetrySeconds = [Math]::Min(60,[int]$cache.RetrySeconds * 2)
    }
   }
  }
  if ($cache.ScanFailed) { throw 'Codex session files cannot be read.' }
  if ($cache.RolloutMisses.ContainsKey($id)) { return "" }
  $matched=$false
  foreach ($file in $cache.Rollouts) {
   if ($file.EndsWith($id + ".jsonl", [StringComparison]::OrdinalIgnoreCase)) {
    $matched=$true
    if (& $fileAvailable $file) {
     $path = [string]$file
     $cache.Files[$id] = $path
     & $markActivity
     return $path
    }
   }
  }
  if (-not $matched) { $cache.RolloutMisses[$id]=$true }
  return ""
 } finally {
  [Threading.Monitor]::Exit($cache.Gate)
 }
}

function Session-Workspace([string]$id) {
 $path = Session-File $id
 if (-not $path) { return "" }
 try {
  foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8 -TotalCount 12) {
   if ($line -notmatch '"type":"session_meta"') { continue }
   $record = $line | ConvertFrom-Json
   return [string](Prop $record.payload "cwd" "")
  }
 } catch {}
 return ""
}

function Progress-Files($sessions) {
 $paths = New-Object Collections.Generic.List[string]
 if ($ProgressFile -and (Test-Path -LiteralPath $ProgressFile)) { $paths.Add((Resolve-Path -LiteralPath $ProgressFile).Path) }
 foreach ($session in $sessions) {
  $workspace = Session-Workspace ([string]$session.id)
  if (-not $workspace) { continue }
  foreach ($name in @("task-progress.json", "task-progress-v2.json")) {
   $candidate = Join-Path $workspace $name
   if ((Test-Path -LiteralPath $candidate) -and -not $paths.Contains($candidate)) { $paths.Add($candidate) }
  }
 }
 return @($paths)
}

function Manual-Tasks($sessions) {
 $map = @{}
 foreach ($path in @(Progress-Files $sessions)) {
  try {
   $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
   $all = if ($null -ne $data.PSObject.Properties["tasks"]) { @($data.tasks) } else { @($data) }
   foreach ($item in $all) {
    if ($null -eq $item) { continue }
    $id = [string](Prop $item "threadId" ""); $title = [string](Prop $item "title" "")
    if ($id) { $map[$id] = $item } elseif ($title) { $map["title:$title"] = $item }
   }
  } catch {}
 }
 return $map
}

function Read-TailText([string]$path,[long]$maxBytes,[bool]$allowDelete=$false) {
 $sharing=[IO.FileShare]::ReadWrite
 if($allowDelete){$sharing=$sharing -bor [IO.FileShare]::Delete}
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
 try {
  $bytes=[Math]::Min($maxBytes,$stream.Length); [void]$stream.Seek(-$bytes,[IO.SeekOrigin]::End)
  $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true,4096,$true)
  try{return $reader.ReadToEnd()}finally{$reader.Dispose()}
 }finally{$stream.Dispose()}
}

function Codex-Plan([string]$id) {
 $path = Session-File $id
 if (-not $path) { return @() }
 if($null -eq (Get-Variable -Scope Script -Name planConfirmations -ErrorAction SilentlyContinue)){$script:planConfirmations=@{}}
 $file=Get-Item -LiteralPath $path -ErrorAction Stop
 $stamp=$file.LastWriteTimeUtc.Ticks
 $cached=if($script:planCache.ContainsKey($path)){$script:planCache[$path]}else{$null}
 if($null -ne $cached -and $cached.Stamp -eq $stamp -and $cached.Length -eq $file.Length){
  $script:planConfirmations[$id]=[bool]$cached.Confirmed
  return @($cached.Steps)
 }
 $latest=@();$confirmed=$false;$currentTurn='';$offset=[long]0
 $sharing=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
 try{
  $length=[long]$stream.Length
  $readAnchor={param([IO.Stream]$inputStream,[long]$position)
   $count=[int][Math]::Min([long]128,$position)
   if($count -eq 0){return ''}
   $data=New-Object byte[] $count
   [void]$inputStream.Seek($position-$count,[IO.SeekOrigin]::Begin)
   $read=0
   while($read -lt $count){$n=$inputStream.Read($data,$read,$count-$read);if($n -le 0){throw 'Unable to verify Codex plan history.'};$read+=$n}
   return [Convert]::ToBase64String($data)
  }
  $safeEnd=[long]0;$position=$length;$buffer=New-Object byte[] 65536
  while($position -gt 0 -and $safeEnd -eq 0){
   $count=[int][Math]::Min([long]$buffer.Length,$position);$position-=$count
   [void]$stream.Seek($position,[IO.SeekOrigin]::Begin)
   $read=0
   while($read -lt $count){$n=$stream.Read($buffer,$read,$count-$read);if($n -le 0){throw 'Unable to read Codex plan history.'};$read+=$n}
   for($i=$read-1;$i -ge 0;$i--){if($buffer[$i] -eq 10){$safeEnd=$position+$i+1;break}}
  }
  if($null -ne $cached -and $length -gt [long]$cached.Length -and $safeEnd -ge [long]$cached.Offset){
   $anchor=& $readAnchor $stream ([long]$cached.Offset)
   if($anchor -ceq [string]$cached.Anchor){$offset=[long]$cached.Offset;$latest=@($cached.Steps);$confirmed=[bool]$cached.Confirmed;$currentTurn=[string]$cached.CurrentTurn}
  }
  if($safeEnd -gt $offset){
   [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin)
   $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,($offset -eq 0),4096,$true)
   try{
    while($null -ne ($line=$reader.ReadLine())){
     if($reader.EndOfStream -and $safeEnd -lt $length){break}
     if($line -notmatch 'update_plan|task_started|turn_started'){continue}
     try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
     $payload=Prop $record "payload"
     if($null -eq $payload){continue}
     $eventType=[string](Prop $payload "type" "")
     if([string](Prop $record "type" "") -eq 'event_msg' -and $eventType -in @('task_started','turn_started')){
      $eventTurn=[string](Prop $payload 'turn_id' '')
      if(-not $eventTurn -or -not $currentTurn -or $eventTurn -cne $currentTurn){if($latest.Count -gt 0){$confirmed=$false}}
      $currentTurn=$eventTurn
      continue
     }
     if($eventType -notin @('custom_tool_call','function_call')){continue}
     $eventTurn=[string](Prop $payload 'turn_id' '')
     if($currentTurn -and $eventTurn -and $eventTurn -cne $currentTurn){continue}
     $name=[string](Prop $payload 'name' '')
     $inputText=[string](Prop $payload 'input' (Prop $payload 'arguments' ''))
     if(-not $inputText){continue}
     $isDirectPlan=$name -eq 'update_plan'
     if(-not $isDirectPlan -and $inputText -notmatch 'update_plan\s*\('){continue}
     $candidate=New-Object Collections.Generic.List[object]
     if($isDirectPlan){
      try{$parsed=$inputText|ConvertFrom-Json -ErrorAction Stop}catch{$parsed=$null}
      if($null -ne $parsed -and $null -ne $parsed.PSObject.Properties['plan'] -and $parsed.plan -is [array]){
       foreach($step in $parsed.plan){
        $label=[string](Prop $step 'step' '');$status=[string](Prop $step 'status' '')
        if(-not $label -or $status -notin @('completed','in_progress','pending')){continue}
        $state=switch($status){'completed'{'done'} 'in_progress'{'active'} default{'pending'}}
        $candidate.Add([PSCustomObject]@{title=$label;status=$state})
       }
       if($parsed.plan.Count -eq 0 -or $candidate.Count -gt 0){$latest=$candidate.ToArray();$confirmed=$true}
       continue
      }
     }
     $matches=[regex]::Matches($inputText, 'step\s*:\s*"(?<step>(?:\\.|[^"\\])*)"\s*,\s*status\s*:\s*"(?<status>completed|in_progress|pending)"')
     if($matches.Count -eq 0){continue}
     foreach($match in $matches){
      $state=switch($match.Groups['status'].Value){'completed'{'done'} 'in_progress'{'active'} default{'pending'}}
      $candidate.Add([PSCustomObject]@{title=[regex]::Unescape($match.Groups['step'].Value);status=$state})
     }
     $latest=$candidate.ToArray();$confirmed=$true
    }
   }finally{$reader.Dispose()}
  }
  $anchor=& $readAnchor $stream $safeEnd
 }finally{$stream.Dispose()}
 if($script:planCache.Count -ge 100){$script:planCache.Clear()}
 $script:planCache[$path]=[PSCustomObject]@{Length=$length;Stamp=$stamp;Offset=$safeEnd;Anchor=$anchor;Steps=@($latest);Confirmed=$confirmed;CurrentTurn=$currentTurn}
 $script:planConfirmations[$id]=[bool]$confirmed
 return @($latest)
}

function Codex-Activity([string]$id) {
 $path = Session-File $id
 if (-not $path) { return "" }
 try {
  $tail=Read-TailText $path 2097152
  $lines=$tail -split "`r?`n"; $startIndex=-1; $turnId=""; $latestCommentary=""
  for($index=$lines.Count-1;$index -ge 0;$index--){
   $line=$lines[$index]
   if($line.Length -gt 1048576 -or $line -notmatch '"(task_started|turn_started)"'){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   $payload=Prop $record "payload"
   if([string](Prop $record "type" "") -eq "event_msg" -and [string](Prop $payload "type" "") -in @("task_started","turn_started")){
    $startIndex=$index;$turnId=[string](Prop $payload "turn_id" "");break
   }
  }
  for($index=$lines.Count-1;$index -gt $startIndex;$index--){
   $line=$lines[$index]
   if($line.Length -gt 1048576 -or $line -notmatch '"(agent_reasoning|reasoning|Reasoning|commentary)"'){continue}
   try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
   $payload=Prop $record "payload"
   $recordType=[string](Prop $record "type" ""); $kind=[string](Prop $payload "type" "")
   $eventTurn=[string](Prop $payload "turn_id" "")
   if($turnId -and $eventTurn -and $turnId -ne $eventTurn){continue}
   $summary=""
   if($recordType -eq "event_msg" -and $kind -eq "agent_reasoning"){
    $summary=[string](Prop $payload "text" "")
   }elseif($recordType -eq "response_item" -and $kind -eq "reasoning"){
    foreach($part in @(Prop $payload "summary" @())){
     if([string](Prop $part "type" "") -eq "summary_text" -and [string](Prop $part "text" "")){$summary=[string](Prop $part "text" "")}
    }
   }elseif($kind -eq "item_completed"){
    $item=Prop $payload "item"
    if([string](Prop $item "type" "") -eq "Reasoning"){
     foreach($part in @(Prop $item "summary_text" @())){if($part -is [string] -and $part.Trim()){$summary=[string]$part}}
    }elseif(-not $latestCommentary -and [string](Prop $item "type" "") -eq "AgentMessage" -and [string](Prop $item "phase" "") -eq "commentary"){
     foreach($part in @(Prop $item "content" @())){if([string](Prop $part "type" "") -eq "Text"){$latestCommentary=[string](Prop $part "text" "")}}
    }
   }elseif(-not $latestCommentary -and $kind -eq "message" -and [string](Prop $payload "phase" "") -eq "commentary"){
    foreach($part in @(Prop $payload "content" @())){if([string](Prop $part "type" "") -eq "output_text"){$latestCommentary=[string](Prop $part "text" "")}}
   }
   if($summary){
    $firstLine=@($summary -split "`r?`n" | Where-Object {$_.Trim()} | Select-Object -First 1)
    if($firstLine.Count -gt 0){
     $value=$firstLine[0].Trim()
     if($value -match '^\*\*(?<heading>.+?)\*\*'){$value=$Matches.heading}
     return [regex]::Replace($value,'\s+',' ')
    }
   }
  }
  if($latestCommentary){return [regex]::Replace($latestCommentary.Trim(),'\s+',' ')}
 } catch {}
 return ""
}

function Plan-Progress($steps, [int]$fallback) {
 $all = @($steps)
 if ($all.Count -eq 0) { return $fallback }
 $done = @($all | Where-Object { [string](Prop $_ "status" "pending") -eq "done" }).Count
 return [int][Math]::Round(($done / $all.Count) * 100)
}

function Codex-IndexCandidates {
 $sessionMap=@{}
 foreach($line in Get-Content -LiteralPath $sessionIndex -Encoding UTF8 -Tail 50){
  if(-not $line){continue}
  try{
   $session=$line|ConvertFrom-Json -ErrorAction Stop
   $id=[string](Prop $session "id" "")
   if($id -match '^[A-Za-z0-9_-]{1,128}$'){$sessionMap[$id]=$session}
  }catch{}
 }
 $needed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($id in @($script:observedCodex.Keys)){
  if([string]$id -match '^[A-Za-z0-9_-]{1,128}$' -and -not $sessionMap.ContainsKey([string]$id)){[void]$needed.Add([string]$id)}
 }
 if(Test-Path -LiteralPath $lockDirectory -PathType Container -ErrorAction Stop){
  foreach($lock in Get-ChildItem -LiteralPath $lockDirectory -File -Filter '*.lock' -ErrorAction Stop){
   $id=[IO.Path]::GetFileNameWithoutExtension($lock.Name)
   if($id -notmatch '^[A-Za-z0-9_-]{1,128}$' -or $sessionMap.ContainsKey($id)){continue}
   if((Lock-State $lock.FullName) -in @('held','unavailable')){[void]$needed.Add($id)}
  }
 }
 if($needed.Count -gt 0){
  $indexFile=Get-Item -LiteralPath $sessionIndex -ErrorAction Stop
  $version="{0}|{1}|{2}" -f $indexFile.FullName,$indexFile.Length,$indexFile.LastWriteTimeUtc.Ticks
  if($null -eq (Get-Variable -Scope Script -Name sessionIndexLookup -ErrorAction SilentlyContinue)){$script:sessionIndexLookup=@{}}
  if(-not $script:sessionIndexLookup.ContainsKey('Version') -or $script:sessionIndexLookup.Version -cne $version){$script:sessionIndexLookup=@{Version=$version;Items=@{}}}
  $missing=@($needed|Where-Object {-not $script:sessionIndexLookup.Items.ContainsKey($_)})
  if($missing.Count -gt 0){
   foreach($id in $missing){$script:sessionIndexLookup.Items[$id]=$null}
   $filter='"(?:'+(($missing|ForEach-Object {[regex]::Escape($_)}) -join '|')+')"'
   $sharing=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
   $stream=[IO.File]::Open($sessionIndex,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
   try{
    $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true,4096,$true)
    try{
     while($null -ne ($line=$reader.ReadLine())){
      if($line.Length -gt 1048576){throw 'Codex session index contains an oversized line.'}
      if($line -notmatch $filter){continue}
      try{
       $session=$line|ConvertFrom-Json -ErrorAction Stop
       $id=[string](Prop $session "id" "")
       if($id -and $script:sessionIndexLookup.Items.ContainsKey($id)){$script:sessionIndexLookup.Items[$id]=$session}
      }catch{}
     }
    }finally{$reader.Dispose()}
   }finally{$stream.Dispose()}
  }
  foreach($id in $needed){
   $session=$script:sessionIndexLookup.Items[$id]
   if($null -ne $session){$sessionMap[$id]=$session}
  }
 }
 foreach($session in $sessionMap.Values){
  try{
   $id=[string](Prop $session "id" "")
   $updated=[DateTime]$session.updated_at
   $yearFolder=Join-Path $sessionsDirectory ([string]$updated.Year)
   $monthFolder=Join-Path $yearFolder $updated.Month.ToString("00")
   $script:sessionDates[$id]=Join-Path $monthFolder $updated.Day.ToString("00")
  }catch{}
 }
 return @($sessionMap.Values)
}

function Codex-Tasks {
 if (-not (Test-Path -LiteralPath $sessionIndex -ErrorAction Stop)) {
  if ($script:lastCodexTasks.Count -gt 0 -or (Test-Path -LiteralPath $codexHome -PathType Container -ErrorAction Stop)) { throw "Codex session index is unavailable." }
  return @()
 }
 $sessions = @(Codex-IndexCandidates)
 $discoveryVariable=Get-Variable -Scope Script -Name 'sessionDiscovery' -ErrorAction SilentlyContinue
 if ($null -ne $discoveryVariable -and $null -ne $discoveryVariable.Value) {
  $cache=$discoveryVariable.Value
  [Threading.Monitor]::Enter($cache.Gate)
  try {
   $cache.DatedMisses.Clear()
   $versions=@{}
   $newActivity=$false
   foreach ($session in $sessions) {
    $id=[string](Prop $session 'id' '')
    if ($id -notmatch '^[A-Za-z0-9_-]{1,128}$') { continue }
    $updated=[string](Prop $session 'updated_at' '')
    $versions[$id]=$updated
    if (-not $cache.Files.ContainsKey($id) -and
        (-not $cache.IndexVersions.ContainsKey($id) -or $cache.IndexVersions[$id] -cne $updated)) { $newActivity=$true }
   }
   $cache.IndexVersions=$versions
   if ($newActivity) {
    $cache.RetrySeconds=5
    $cache.HotUntilTicks=[Diagnostics.Stopwatch]::GetTimestamp()+([long][Diagnostics.Stopwatch]::Frequency * 30)
   }
  } finally {
   [Threading.Monitor]::Exit($cache.Gate)
  }
 }
 $manual = Manual-Tasks $sessions
 $items = New-Object Collections.Generic.List[object]
 foreach ($session in $sessions) {
  $id = [string]$session.id; $title = [string]$session.thread_name
  if($title -eq "Guardian review"){continue}
  $threadState = Thread-State $id
  $eventActive = $threadState.State -eq "active"
  $uncertain = Codex-Uncertain $id $threadState
  if($threadState.State -in @("interrupted","unobserved")){continue}
  $override = if ($manual.ContainsKey($id)) { $manual[$id] } elseif ($manual.ContainsKey("title:$title")) { $manual["title:$title"] } else { $null }
  $paused = $false; $steps = @(); $source = "Оценка активности"; $planConfirmed=$true
  if ($null -ne $override) {
   $title = [string](Prop $override "title" $title)
   $paused = [bool](Prop $override "paused" $false)
   $steps = @(Prop $override "steps" @())
   if ($steps.Count -gt 0) { $source = "План задачи" }
  }
  $uncertain=$uncertain -and -not $paused
  if ($steps.Count -eq 0 -and ($eventActive -or $uncertain)) {
   $steps = @(Codex-Plan $id)
   if ($steps.Count -gt 0) {
    $source = "План Codex"
    if($null -ne (Get-Variable -Scope Script -Name planConfirmations -ErrorAction SilentlyContinue) -and $script:planConfirmations.ContainsKey($id)){$planConfirmed=[bool]$script:planConfirmations[$id]}
   }
  }
  $running = $eventActive -and -not $paused
  $status = if ($paused) { "На паузе" } elseif ($running) { "В работе" } elseif ($uncertain) { "Статус не подтверждён" } else { "Ожидает" }
  $progress=$null; $progressKind="none"; $progressBasis="task"
  if($steps.Count -gt 0){$progress=Plan-Progress $steps 0;$progressKind="exact";$progressBasis="steps"}
  if ($null -ne $override) {
   $value = Prop $override "progress"
   if ($null -ne $value) {
    $progress = [Math]::Max(0, [Math]::Min(100, [int]$value))
    $progressKind=[string](Prop $override "progressKind" "approximate")
    $progressBasis="task"
    if($progressKind -notin @("exact","approximate")){$progressKind="approximate"}
   }
   if(-not $uncertain){$status = [string](Prop $override "status" $status)}
  }
  if ($steps.Count -gt 0) {
   $doneCount = @($steps | Where-Object { [string](Prop $_ "status" "pending") -eq "done" }).Count
   if ($doneCount -eq $steps.Count) { $progress = 100; $progressKind="exact"; $progressBasis="steps" }
   elseif ($null -ne $progress -and $progress -ge 100) { $progress = 99 }
  }
  $updated = if($threadState.UpdatedUtc -ne [DateTime]::MinValue){$threadState.UpdatedUtc.ToLocalTime()}else{[DateTime]::MinValue}
  $activityGenerated=$uncertain
  $activity = if($uncertain){"Статус не подтверждён"}elseif($running){$currentActivity=Codex-Activity $id;if($currentActivity){$currentActivity}else{$activityGenerated=$true;"Выполняется"}}else{""}
  $startKey=[string](Prop $threadState "StartKey" "")
  $started=[DateTime](Prop $threadState "StartedUtc" ([DateTime]::MinValue))
  $items.Add([PSCustomObject]@{ Id=$id; Title=$title; Activity=$activity; ActivityGenerated=$activityGenerated; Active=$running; Paused=$paused; Progress=$progress; ProgressKind=$progressKind; ProgressBasis=$progressBasis; Provider="codex"; ProviderName="Codex"; Status=$status; Updated=$updated; Started=$started; StartKey=$startKey; Steps=$steps; Source=$source; PlanConfirmed=$planConfirmed })
 }
 $runningItems = @($items | Where-Object Active | Sort-Object Updated -Descending)
 $trackedItems = @($items | Where-Object { -not $_.Active -and ($_.Status -in @("Статус не подтверждён","Ожидает подтверждения") -or $_.Paused) } | Sort-Object Updated -Descending)
 return @($runningItems + $trackedItems)
}

function Claude-Tasks {
 # A bounded digest records continuity, not task content. It is held in memory only.
 $readSource={
  param([string]$path,$prior)
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try{
   $digest={
    param([IO.Stream]$inputStream,[long]$end)
    $count=[int][Math]::Min([long]4194304,$end);$data=[byte[]]::new($count)
    [void]$inputStream.Seek($end-$count,[IO.SeekOrigin]::Begin);$read=0
    while($read -lt $count){$n=$inputStream.Read($data,$read,$count-$read);if($n -le 0){throw 'Unable to verify Claude journal continuity.'};$read+=$n}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [Convert]::ToBase64String($sha.ComputeHash($data))}finally{$sha.Dispose()}
   }
   $length=[long]$stream.Length;$discontinuity=$false
   if($null -ne $prior){
    if($length -lt [long]$prior.Length){$discontinuity=$true}
    elseif((& $digest $stream ([long]$prior.Length)) -cne [string]$prior.EndDigest){$discontinuity=$true}
   }
   $endDigest=& $digest $stream $length
   $count=[int][Math]::Min([long]4194304,$length);$data=[byte[]]::new($count)
   $offset=$length-$count;$startsAtBoundary=$true
   if($offset -gt 0){[void]$stream.Seek($offset-1,[IO.SeekOrigin]::Begin);$startsAtBoundary=$stream.ReadByte() -eq 10}
   [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin);$read=0
   while($read -lt $count){$n=$stream.Read($data,$read,$count-$read);if($n -le 0){throw 'Unable to read Claude journal.'};$read+=$n}
   if($stream.Length -lt $length -or (& $digest $stream $length) -cne $endDigest){throw 'Claude journal changed during reading.'}
   # Only completed records are parsed. A writer can be interrupted mid-record.
   $start=0
   if($length -gt 4194304){
    $discontinuity=$true
    if(-not $startsAtBoundary){
     while($start -lt $count -and $data[$start] -ne 10){$start++}
     if($start -lt $count){$start++}
    }
   }
   $end=$count;$pending=$count -gt 0 -and $data[$count-1] -ne 10
   if($pending){while($end -gt $start -and $data[$end-1] -ne 10){$end--}}
   $value=''
   if($end -gt $start){
    $encoding=[Text.UTF8Encoding]::new($false,$true)
    $value=$encoding.GetString($data,$start,$end-$start)
    if($length -le 4194304){$value=$value.TrimStart([char]0xFEFF)}
   }
   return [PSCustomObject]@{Text=$value;HasPartialLine=$pending;Discontinuity=$discontinuity;Cursor=[PSCustomObject]@{Length=$length;EndDigest=$endDigest}}
  }finally{$stream.Dispose()}
 }
 if(-not ("AITaskMonitor.Claude.Reader" -as [type])){throw "Claude event reader is unavailable."}
 if($null -eq (Get-Variable -Scope Script -Name claudeReaderSession -ErrorAction SilentlyContinue) -or $null -eq $script:claudeReaderSession){$script:claudeReaderSession=[AITaskMonitor.Claude.SessionReader]::new()}
 if($null -eq (Get-Variable -Scope Script -Name claudeLegacySourceSeen -ErrorAction SilentlyContinue)){$script:claudeLegacySourceSeen=$false}
 if($null -eq (Get-Variable -Scope Script -Name claudeCurrentSourceSeen -ErrorAction SilentlyContinue)){$script:claudeCurrentSourceSeen=$false}
 if($null -eq (Get-Variable -Scope Script -Name claudeCurrentSourceCursor -ErrorAction SilentlyContinue)){$script:claudeCurrentSourceCursor=$null}
 if($null -eq (Get-Variable -Scope Script -Name claudeLegacySourceCursor -ErrorAction SilentlyContinue)){$script:claudeLegacySourceCursor=$null}
 try{$attributes=[IO.File]::GetAttributes($claudeEventPath)}
 catch [IO.FileNotFoundException]{if($script:claudeCurrentSourceSeen -or $script:lastClaudeTasks.Count -gt 0){throw};return @()}
 catch [IO.DirectoryNotFoundException]{if($script:claudeCurrentSourceSeen -or $script:lastClaudeTasks.Count -gt 0){throw};return @()}
 if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){throw "Claude event source is not a file."}
 $currentRead=& $readSource $claudeEventPath $script:claudeCurrentSourceCursor
 if($currentRead.Discontinuity){$script:claudeReaderSession.MarkSourceLoss()}
 $script:claudeCurrentSourceCursor=$currentRead.Cursor
 $tail=$currentRead.Text
 $transientUncertain=[bool]$currentRead.HasPartialLine
 $script:claudeCurrentSourceSeen=$true
 $legacyTail=""
 if($claudeLegacyEventPath){
  $legacyAttributes=$null
  try{$legacyAttributes=[IO.File]::GetAttributes($claudeLegacyEventPath)}
  catch [IO.FileNotFoundException]{if($script:claudeLegacySourceSeen){$script:claudeReaderSession.MarkSourceLoss();throw}}
  catch [IO.DirectoryNotFoundException]{if($script:claudeLegacySourceSeen){$script:claudeReaderSession.MarkSourceLoss();throw}}
  catch{$script:claudeReaderSession.MarkSourceLoss();throw}
  if($null -ne $legacyAttributes){
   if(($legacyAttributes -band [IO.FileAttributes]::Directory) -ne 0){$script:claudeReaderSession.MarkSourceLoss();throw "Claude legacy event source is not a file."}
   $script:claudeLegacySourceSeen=$true
   try{
    $legacyRead=& $readSource $claudeLegacyEventPath $script:claudeLegacySourceCursor
    if($legacyRead.Discontinuity){$script:claudeReaderSession.MarkSourceLoss()}
    $script:claudeLegacySourceCursor=$legacyRead.Cursor
    $legacyTail=$legacyRead.Text
    $transientUncertain=$transientUncertain -or [bool]$legacyRead.HasPartialLine
   }catch{$script:claudeReaderSession.MarkSourceLoss();throw}
  }
 }
 $sessions=@($script:claudeReaderSession.Read($tail,$legacyTail,[DateTime]::UtcNow,$script:monitorStartedUtc))
 $items=New-Object Collections.Generic.List[object]
 foreach($state in $sessions){
  $steps=@($state.Steps)
  $progress=$null;$kind="none"
  $planConfirmed=[bool]$state.PlanConfirmed -and -not $transientUncertain -and -not [bool]$state.RetainedPlanIncomplete
  if($steps.Count -gt 0 -and $planConfirmed){$progress=Plan-Progress $steps 0;$kind="exact"}
  $title="Задача Claude Code"
  $unconfirmed=[bool]$state.Unconfirmed -or $transientUncertain
  $activity=if($unconfirmed){"Статус не подтверждён"}else{$state.Activity}
  $status=if($unconfirmed){"Статус не подтверждён"}else{"В работе"}
  $items.Add([PSCustomObject]@{Id="claude:"+$state.Id;Title=$title;Activity=$activity;Active=(-not $unconfirmed);Paused=$false;Progress=$progress;ProgressKind=$kind;ProgressBasis=$(if($steps.Count -gt 0){"steps"}else{"task"});Provider="claude";ProviderName="Claude Code";Status=$status;Updated=$state.Updated.ToLocalTime();Started=$state.Started;StartKey=$state.StartKey;Steps=$steps;Source="Claude Code";PlanConfirmed=$planConfirmed;KnownStepCount=$(if($planConfirmed){[int]$state.KnownStepCount}else{0});KnownDoneCount=$(if($planConfirmed){[int]$state.KnownDoneCount}else{0});UnknownStepCount=$(if($planConfirmed){[int]$state.UnknownStepCount}else{$steps.Count});RetainedPlanIncomplete=[bool]$state.RetainedPlanIncomplete})
 }
 return @($items|Sort-Object Updated -Descending)
}

function Source-Snapshot {
 $codex=@(); $claude=@(); $external=@(); $cloud=@(); $unavailable=New-Object Collections.Generic.List[string]
 try{$codex=@(Codex-Tasks);$script:lastCodexTasks=$codex}catch{[void]$unavailable.Add("Codex");$codex=@(Unconfirmed-Tasks $script:lastCodexTasks)}
 try{
  $connectionState=if($ClaudeEventFile){"connected"}else{Claude-ConnectionState}
  if($connectionState -eq "connected"){$claude=@(Claude-Tasks);$script:lastClaudeTasks=$claude}
  elseif($connectionState -eq "partial"){$claude=@(Unconfirmed-Tasks @(Claude-Tasks));$script:lastClaudeTasks=$claude;[void]$unavailable.Add("Claude Code")}
  else{$script:lastClaudeTasks=@()}
  if($null -ne (Get-Variable -Scope Script -Name claudeReaderSession -ErrorAction SilentlyContinue) -and $null -ne $script:claudeReaderSession -and $script:claudeReaderSession.RetentionOverflow){[void]$unavailable.Add("Claude Code")}
 }catch{
  if($null -ne (Get-Variable -Scope Script -Name claudeReaderSession -ErrorAction SilentlyContinue) -and $null -ne $script:claudeReaderSession){$script:claudeReaderSession.MarkSourceLoss()}
  [void]$unavailable.Add("Claude Code");$claude=@(Unconfirmed-Tasks $script:lastClaudeTasks)
 }
 if($script:codexCloudModulesAvailable -and $script:codexCloudController.Enabled){
  try{Update-CodexCloudController $script:codexCloudController}catch{$script:codexCloudController.LastError='unavailable'}
  try{$cloud=@(ConvertTo-CodexCloudMonitorTasks $script:codexCloudController.Tasks (Tr 'Облако: ') (Tr 'Задача Codex') 'Статус не подтверждён')}
  catch{$script:codexCloudController.LastError='unavailable'}
  if($script:showingSettings){Update-CodexCloudSourceSettings}
 }
 if($script:externalProviderModulesAvailable){
  $connection=try{Get-OpenCodeConnectionState -AppRoot $PSScriptRoot}catch{'error'}
  $connections=@{opencode=$connection}
  $profileScopes=@{};$uncertainProfileScopes=@{}
  $kimiAvailable=Get-Variable -Scope Script -Name 'kimiModulesAvailable' -ErrorAction SilentlyContinue
  if($null -ne $kimiAvailable -and $kimiAvailable.Value -and -not ($SnapshotFile -and $PreviewActiveTasks -ge 0)){
   $connections.kimi=try{
    Update-KimiMonitorController $script:kimiController
    if($script:showingSettings){Update-KimiSourceSettings}
    $profileScopes.kimi=@(Get-KimiAllowedScopes $script:kimiController)
    $uncertainProfileScopes.kimi=@(Get-KimiUncertainScopes $script:kimiController)
    Get-KimiMonitorConnectionState $script:kimiController
   }catch{'error'}
  }
  $deepSeekAvailable=Get-Variable -Scope Script -Name 'deepSeekModulesAvailable' -ErrorAction SilentlyContinue
  if($null -ne $deepSeekAvailable -and $deepSeekAvailable.Value){
   $connections.deepseek=try{
    Update-DeepSeekMonitorController $script:deepSeekController
    if($script:showingSettings){Update-DeepSeekSourceSettings}
    $profileScopes.deepseek=@(Get-DeepSeekAllowedScopes $script:deepSeekController)
    $uncertainProfileScopes.deepseek=@(Get-DeepSeekUncertainScopes $script:deepSeekController)
    Get-DeepSeekMonitorConnectionState $script:deepSeekController
   }catch{'error'}
  }
  $hermesAvailable=Get-Variable -Scope Script -Name 'hermesModulesAvailable' -ErrorAction SilentlyContinue
  if($null -ne $hermesAvailable -and $hermesAvailable.Value -and -not ($SnapshotFile -and $PreviewActiveTasks -ge 0)){
   $connections.hermes=try{
    Update-HermesMonitorController $script:hermesController
    if($script:showingSettings){Update-HermesSourceSettings}
    $profileScopes.hermes=@(Get-HermesAllowedScopes $script:hermesController)
    $uncertainProfileScopes.hermes=@(Get-HermesUncertainScopes $script:hermesController)
    Get-HermesMonitorConnectionState $script:hermesController
   }catch{'error'}
  }
  try{
   $group=Read-ExternalProviderGroupSnapshot -Controller $script:externalProviderController -Connections $connections -Seen $script:seenExternalConnections -PreviousTasks $script:lastExternalTasks -ProfileScopes $profileScopes -UncertainProfileScopes $uncertainProfileScopes -Language $script:resolvedLanguage
   $external=@($group.Tasks);$script:lastExternalTasks=$external
   foreach($name in $group.Unavailable){[void]$unavailable.Add($name)}
  }catch{
   foreach($pair in @(@('opencode','OpenCode'),@('kimi','Kimi Code'),@('deepseek','DeepSeek Harness'),@('hermes','Hermes Agent'))){if($script:seenExternalConnections.ContainsKey($pair[0])){[void]$unavailable.Add($pair[1])}}
   $external=@(Unconfirmed-ExternalTasks $script:lastExternalTasks);$script:lastExternalTasks=$external
   try{Stop-ExternalProviderController $script:externalProviderController}catch{}
  }
 }
 return [PSCustomObject]@{Tasks=@($codex+$claude+$external+$cloud);Unavailable=$unavailable.ToArray()}
}

function Sync-ClaudeLoopChannel {
 try{
  $wanted=if($PreviewClaudeLoopPipe){$true}elseif($PreviewActiveTasks -ge 0){$false}else{(Claude-ConnectionState) -eq 'connected'}
  if(-not $wanted -or $script:sourceErrors -contains 'Claude Code'){
   if($null -ne $script:claudeLoopChannel){$script:claudeLoopChannel.Dispose();$script:claudeLoopChannel=$null}
   $script:claudeLoopStates.Clear();$script:claudeLoopError=''
   return
  }
  if($null -eq $script:diagnosticRuntime -or -not $script:claudeLoopModulesAvailable){
   if($null -ne $script:claudeLoopChannel){$script:claudeLoopChannel.Dispose();$script:claudeLoopChannel=$null}
   $script:claudeLoopStates.Clear()
   $script:claudeLoopError='Предупреждение Claude Code недоступно'
   return
  }
  if($null -eq $script:claudeLoopChannel){
   if(-not ('AITaskMonitor.ClaudeLoop.Channel' -as [type])){
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    Add-Type -Path (Join-Path $PSScriptRoot 'ClaudeLoopChannel.cs') -ReferencedAssemblies 'System.Web.Extensions' -ErrorAction Stop
   }
   $script:claudeLoopChannel=[AITaskMonitor.ClaudeLoop.Channel]::new($PreviewClaudeLoopPipe)
  }
  $script:claudeLoopError=''
  $now=[DateTimeOffset]::UtcNow
  $threshold=[int]$script:diagnosticRuntime.Settings.LoopThreshold
  $windowMinutes=[int]$script:diagnosticRuntime.Settings.LoopWindowMinutes
  $batch=$script:claudeLoopChannel.Drain()
  if($batch.Gap){$script:claudeLoopStates.Clear()}
  foreach($event in $batch.Events){
   $session=[string]$event.SessionId
   if(-not $script:claudeLoopStates.ContainsKey($session)){
    if($event.Kind -cne 'start'){continue}
    if($script:claudeLoopStates.Count -ge 256){
     $oldest=@($script:claudeLoopStates.Keys|Sort-Object {$script:claudeLoopStates[$_].LastSeen}|Select-Object -First 1)
     if($oldest.Count){$script:claudeLoopStates.Remove([string]$oldest[0])}
    }
    $script:claudeLoopStates[$session]=New-ClaudeLoopTracker -Threshold $threshold -WindowMinutes $windowMinutes
   }
   $tracker=$script:claudeLoopStates[$session]
   if($tracker.Threshold -ne $threshold -or $tracker.WindowMinutes -ne $windowMinutes){
    Reset-ClaudeLoopTracker $tracker;$tracker.Threshold=$threshold;$tracker.WindowMinutes=$windowMinutes
   }
   Update-ClaudeLoopTracker $tracker $event $now
   if($event.Kind -ceq 'stop'){$script:claudeLoopStates.Remove($session)}
  }
  foreach($session in @($script:claudeLoopStates.Keys)){
   $tracker=$script:claudeLoopStates[$session]
   if($tracker.Threshold -ne $threshold -or $tracker.WindowMinutes -ne $windowMinutes){
    Reset-ClaudeLoopTracker $tracker;$tracker.Threshold=$threshold;$tracker.WindowMinutes=$windowMinutes
   }
   Refresh-ClaudeLoopTracker $tracker $now
   if($tracker.LastSeen -lt $now.AddMinutes(-30)){$script:claudeLoopStates.Remove($session)}
  }
 }catch{
  $script:claudeLoopStates.Clear();$script:claudeLoopError='Предупреждение Claude Code недоступно'
  if($null -ne $script:claudeLoopChannel){try{$script:claudeLoopChannel.Dispose()}catch{};$script:claudeLoopChannel=$null}
 }
}

function Refresh-Diagnostics($tasks) {
 if($null -eq $script:diagnosticRuntime){return}
 $observations=@(foreach($task in $tasks){
  $provider=[string](Prop $task "Provider" "")
  $id=[string](Prop $task "Id" "")
  if($provider -eq "claude" -and $id.StartsWith("claude:")){$id=$id.Substring(7)}
  $status=[string](Prop $task "Status" "")
  $state=if([bool](Prop $task "Active" $false)){"active"}elseif($status -eq "Статус не подтверждён"){"unknown"}else{""}
  if($state){[PSCustomObject]@{Provider=$provider;Id=$id;State=$state}}
 })
 $resolver=if($PreviewActiveTasks -ge 0){{param($id) return ""}}else{{param($id) return (Session-File $id)}}
 $stateResolver=if($PreviewActiveTasks -ge 0){{param($id) return [PSCustomObject]@{State="unknown"}}}else{{param($id) return (Thread-State $id)}}
 try{
  Update-DiagnosticRuntime -Runtime $script:diagnosticRuntime -Tasks $observations -Unavailable $script:sourceErrors -Now ([DateTimeOffset]::UtcNow) -SessionResolver $resolver -StateResolver $stateResolver
  $script:diagnosticError=""
 }catch{$script:diagnosticError="Не удалось обновить журнал"}
}

function Unconfirmed-Tasks($tasks) {
 foreach($task in $tasks){
  if(-not $task.Active -and [string](Prop $task "Status" "") -ne "Статус не подтверждён"){continue}
  $copy=$task.PSObject.Copy()
  $copy.Active=$false; $copy.Status="Статус не подтверждён"; $copy.Activity="Статус не подтверждён"
  if([string](Prop $copy 'Provider' '') -eq 'claude'){
   if($null -ne $copy.PSObject.Properties['PlanConfirmed']){$copy.PlanConfirmed=$false}
   if($null -ne $copy.PSObject.Properties['Progress']){$copy.Progress=$null}
   if($null -ne $copy.PSObject.Properties['ProgressKind']){$copy.ProgressKind='none'}
   if($null -ne $copy.PSObject.Properties['KnownStepCount']){$copy.KnownStepCount=0}
   if($null -ne $copy.PSObject.Properties['KnownDoneCount']){$copy.KnownDoneCount=0}
   if($null -ne $copy.PSObject.Properties['UnknownStepCount']){$copy.UnknownStepCount=@($copy.Steps).Count}
  }
  if($null -eq $copy.PSObject.Properties['ActivityGenerated']){$copy|Add-Member -MemberType NoteProperty -Name ActivityGenerated -Value $true}else{$copy.ActivityGenerated=$true}
  $copy
 }
}

function Unconfirmed-ExternalTasks($tasks) {
 foreach($task in $tasks){
  $copy=$task.PSObject.Copy()
  $copy.Active=$false;$copy.Paused=$false;$copy.Status='Статус не подтверждён';$copy.Activity='Статус не подтверждён'
  $copy.PlanConfirmed=$false
  $copy
 }
}

function Text([string]$value, [double]$size, [string]$color, [string]$weight = "Normal") {
 $block = New-Object Windows.Controls.TextBlock
 $block.Text=$value; $block.FontFamily=New-Object Windows.Media.FontFamily("Segoe UI Variable Text"); $block.FontSize=$size
 $block.Foreground=Brush $color; $block.FontWeight=$weight; $block.TextWrapping="Wrap"; $block.LineHeight=$size*1.35
 return $block
}

function Get-CursorHintPosition([Windows.Point]$pointer,[Windows.Size]$hintSize,[Windows.Rect]$workArea,[Windows.Thickness]$inset=[Windows.Thickness]::new(0)) {
 $gap=4.0
 $maximumX=[Math]::Max($workArea.Left,$workArea.Right-$hintSize.Width)
 $visibleWidth=[Math]::Max(0,$hintSize.Width-$inset.Left-$inset.Right)
 $x=[Math]::Max($workArea.Left,[Math]::Min($pointer.X-$inset.Left-$visibleWidth/2,$maximumX))
 $maximumY=[Math]::Max($workArea.Top,$workArea.Bottom-$hintSize.Height)
 $above=$pointer.Y-$hintSize.Height+$inset.Bottom-$gap
 $below=$pointer.Y+$gap-$inset.Top
 if($above -ge $workArea.Top){$y=[Math]::Min($above,$maximumY)}
 elseif($below -le $maximumY){$y=[Math]::Max($below,$workArea.Top)}
 else{$y=[Math]::Max($workArea.Top,[Math]::Min($above,$maximumY))}
 return [Windows.Point]::new($x,$y)
}

function New-CursorHint($block,[string]$text) {
 $hint=New-Object Windows.Controls.ToolTip
 $hint.Content=$text
 $hint.SetResourceReference([Windows.FrameworkElement]::StyleProperty,"CursorHintStyle")
 $hint.PlacementTarget=$block
 $hint.Placement=[Windows.Controls.Primitives.PlacementMode]::Custom
 $hint.HorizontalOffset=0; $hint.VerticalOffset=0
 $target=$block
 $positioner=${function:Get-CursorHintPosition}
 $preview=[bool]($HintSnapshotFile -and $PreviewActiveTasks -ge 0)
 $place={
  param($popupSize,$targetSize,$offset)
  $pointer=if($preview){[Windows.Point]::new($target.ActualWidth/2,$target.ActualHeight/2)}else{[Windows.Input.Mouse]::GetPosition($target)}
  $screenPoint=$target.PointToScreen($pointer)
  $screen=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int][Math]::Round($screenPoint.X),[int][Math]::Round($screenPoint.Y)))
  $work=$screen.WorkingArea
  $first=$target.PointFromScreen([Windows.Point]::new($work.Left,$work.Top))
  $last=$target.PointFromScreen([Windows.Point]::new($work.Right,$work.Bottom))
  $area=[Windows.Rect]::new($first,[Windows.Size]::new([Math]::Max(0,$last.X-$first.X),[Math]::Max(0,$last.Y-$first.Y)))
  $inset=$target.TryFindResource("CursorHintShadowInset")
  if($inset -isnot [Windows.Thickness]){$inset=[Windows.Thickness]::new(0)}
  $position=& $positioner $pointer $popupSize $area $inset
  return ,([Windows.Controls.Primitives.CustomPopupPlacement[]]@([Windows.Controls.Primitives.CustomPopupPlacement]::new($position,[Windows.Controls.Primitives.PopupPrimaryAxis]::Horizontal)))
 }.GetNewClosure()
 $hint.CustomPopupPlacementCallback=[Windows.Controls.Primitives.CustomPopupPlacementCallback]$place
 return $hint
}

function Update-ConditionalHint($block) {
 $data=$block.Tag
 if($null -eq $data -or $block.ActualWidth -le 0){return}
 $probe=New-Object Windows.Controls.TextBlock
 $probe.Text=[string]$data.Text
 $probe.FontFamily=$block.FontFamily
 $probe.FontSize=$block.FontSize
 $probe.FontWeight=$block.FontWeight
 $probe.FontStyle=$block.FontStyle
 $probe.FontStretch=$block.FontStretch
 $probe.LineHeight=$block.LineHeight
 $probe.TextTrimming="None"
 if([string]$data.Mode -eq "wrap"){
  $probe.TextWrapping="Wrap"
  $probe.Width=$block.ActualWidth
  $probe.Measure([Windows.Size]::new($block.ActualWidth,[double]::PositiveInfinity))
  $truncated=$probe.DesiredSize.Height -gt ($block.ActualHeight+0.5)
 }else{
  $probe.TextWrapping="NoWrap"
  $probe.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
  $truncated=$probe.DesiredSize.Width -gt ($block.ActualWidth+0.5)
 }
 if($truncated){
  if($block.ToolTip -isnot [Windows.Controls.ToolTip]){$block.ToolTip=New-CursorHint $block ([string]$data.Text)}
  else{$block.ToolTip.Content=[string]$data.Text}
 }else{$block.ToolTip=$null}
}

function Add-ConditionalHint($block,[string]$text,[ValidateSet("line","wrap")][string]$mode="line") {
 $block.Tag=[PSCustomObject]@{Text=$text;Mode=$mode}
 [Windows.Controls.ToolTipService]::SetInitialShowDelay($block,350)
 [Windows.Controls.ToolTipService]::SetShowDuration($block,30000)
 [Windows.Controls.ToolTipService]::SetPlacement($block,[Windows.Controls.Primitives.PlacementMode]::Custom)
 [Windows.Controls.ToolTipService]::SetHorizontalOffset($block,0)
 [Windows.Controls.ToolTipService]::SetVerticalOffset($block,0)
 $block.Add_Loaded({param($sender,$args) Update-ConditionalHint $sender})
 $block.Add_SizeChanged({param($sender,$args) Update-ConditionalHint $sender})
}

function Progress-Label($task) {
 $kind=[string](Prop $task "ProgressKind" "none")
 $value=Prop $task "Progress"
 $steps=@(Prop $task "Steps" @())
 $basis=[string](Prop $task "ProgressBasis" "")
 if(-not $basis){$basis=if($steps.Count -gt 0){"steps"}else{"task"}}
 if(($kind -eq "none" -or $null -eq $value) -and $steps.Count -gt 0){$basis="steps"}
 if($basis -eq "steps"){
  if($steps.Count -eq 0 -or -not [bool](Prop $task "PlanConfirmed" $true) -or [string](Prop $task "Status" "") -eq "Статус не подтверждён"){return ""}
  $active=@();$done=0
  for($i=0;$i -lt $steps.Count;$i++){
   $state=[string](Prop $steps[$i] "status" "")
   if($state -notin @("done","active","pending")){return ""}
   if($state -eq "active"){$active+=($i+1)}elseif($state -eq "done"){$done++}
  }
  if($active.Count -eq 1){if($script:resolvedLanguage -eq 'en'){return "Step $($active[0]) of $($steps.Count)"}else{return "Этап $($active[0]) из $($steps.Count)"}}
  if($script:resolvedLanguage -eq 'en'){return "Done $done of $($steps.Count)"}else{return "Готово $done из $($steps.Count)"}
 }
 if($kind -eq "none" -or $null -eq $value){return ""}
 $prefix=if($kind -eq "approximate"){"≈ "}else{""}
 return $prefix+([int]$value).ToString()+"%"
}

function Plan-StatusNote($task) {
 if(@(Prop $task 'Steps' @()).Count -eq 0){return ''}
 if([bool](Prop $task 'RetainedPlanIncomplete' $false)){return (Tr 'План не подтверждён; список может быть неполным')}
 if(-not [bool](Prop $task 'PlanConfirmed' $true) -or
    ([string](Prop $task 'Provider' '') -eq 'claude' -and [string](Prop $task 'Status' '') -eq 'Статус не подтверждён')){return (Tr 'План не подтверждён')}
 if([string](Prop $task 'Provider' '') -eq 'claude'){return (Tr 'По известным этапам, возможна неточность')}
 return ''
}

function Plan-StepCount([int]$count) {
 if($script:resolvedLanguage -eq 'en'){$word=if($count -eq 1){'step'}else{'steps'}}
 else{
  $lastHundred=$count % 100;$lastDigit=$count % 10
  $word=if($lastHundred -ge 11 -and $lastHundred -le 14){'этапов'}elseif($lastDigit -eq 1){'этап'}elseif($lastDigit -ge 2 -and $lastDigit -le 4){'этапа'}else{'этапов'}
 }
 return "$count $word"
}

function Localized-TaskTitle($task) {
 $title=[string](Prop $task 'Title' '')
 if([string](Prop $task 'Provider' '') -eq 'claude' -and $title -ceq 'Задача Claude Code'){return (Tr $title)}
 return $title
}

function Localized-TaskActivity($task) {
 $activity=[string](Prop $task 'Activity' '')
 if(-not $activity){return ''}
 if([bool](Prop $task 'ActivityGenerated' $false) -or [string](Prop $task 'Status' '') -eq 'Статус не подтверждён'){return (Tr $activity)}
 if([string](Prop $task 'Provider' '') -eq 'claude'){
  foreach($prefix in @('Выполняет: ','Завершено: ','Ошибка: ','Добавлен этап: ','Завершён этап: ')){
   if($activity.StartsWith($prefix,[StringComparison]::Ordinal)){return (Tr $prefix)+$activity.Substring($prefix.Length)}
  }
  return (Tr $activity)
 }
 return $activity
}

function Get-LoopWarning($task) {
 if(-not $task.Active){return $null}
 $provider=[string]$task.Provider
 if($provider -eq 'claude'){
  $session=[string]$task.Id
  if($session.StartsWith('claude:')){$session=$session.Substring(7)}
  if(-not $script:claudeLoopStates.ContainsKey($session)){return $null}
  $loop=$script:claudeLoopStates[$session]
  if(-not $loop.Warning -or $loop.Dismissed){return $null}
  return $loop
 }
 if($provider -ne 'codex'){return $null}
 if($PreviewActiveTasks -ge 0 -and $PreviewLoopWarning -and [string]$task.Id -eq "preview-0" -and -not $script:previewLoopDismissed){
  return [PSCustomObject]@{Threshold=5;WindowMinutes=10}
 }
 if($null -eq $script:diagnosticRuntime){return $null}
 $key="codex:"+[string]$task.Id
 if(-not $script:diagnosticRuntime.LoopStates.ContainsKey($key)){return $null}
 $loop=$script:diagnosticRuntime.LoopStates[$key]
 if(-not $loop.Warning -or $loop.Dismissed){return $null}
 return $loop
}

function Add-LoopWarning($container,$task,[bool]$compact) {
 $loop=Get-LoopWarning $task
 if($null -eq $loop){return}
 $row=New-Object Windows.Controls.Grid
 $row.Margin=$(if($compact){New-Object Windows.Thickness(12,6,0,0)}else{New-Object Windows.Thickness(0,8,0,0)})
 $messageColumn=New-Object Windows.Controls.ColumnDefinition; $messageColumn.Width=New-Object Windows.GridLength(1,"Star")
 $actionColumn=New-Object Windows.Controls.ColumnDefinition; $actionColumn.Width=[Windows.GridLength]::Auto
 $row.ColumnDefinitions.Add($messageColumn);$row.ColumnDefinitions.Add($actionColumn)
 $message=if($script:resolvedLanguage -eq 'en'){"Possible loop: one command failed with the same code at least $($loop.Threshold) times in $($loop.WindowMinutes) min."}else{"Возможный цикл: одна команда завершилась с одинаковым кодом ошибки не менее $($loop.Threshold) раз за $($loop.WindowMinutes) мин."}
 $label=Text $message $(if($compact){11.5}else{12}) $script:palette.Secondary
 $label.TextWrapping="Wrap"; $label.Margin=New-Object Windows.Thickness(0,0,8,0)
 [Windows.Automation.AutomationProperties]::SetName($label,$message)
 $dismiss=New-Object Windows.Controls.Button; $dismiss.Content=Tr "Скрыть"; $dismiss.Style=$window.Resources["SourceActionStyle"]; $dismiss.FontSize=11.5
 $dismiss.VerticalAlignment="Top"; $dismiss.Tag=[PSCustomObject]@{Id=[string]$task.Id;Provider=[string]$task.Provider}; $dismiss.FocusVisualStyle=$window.Resources["KeyboardFocusStyle"]
 $dismissName=if($script:resolvedLanguage -eq 'en'){'Hide possible loop warning for task: '}else{'Скрыть предупреждение о возможном цикле для задачи: '}
 [Windows.Automation.AutomationProperties]::SetName($dismiss,$dismissName+(Localized-TaskTitle $task))
 $dismiss.Add_Click({param($sender,$eventArgs)
  $id=[string]$sender.Tag.Id;$provider=[string]$sender.Tag.Provider
  if($PreviewActiveTasks -ge 0 -and $provider -eq 'codex' -and $id -eq "preview-0"){$script:previewLoopDismissed=$true}
  elseif($provider -eq 'claude'){
   $session=if($id.StartsWith('claude:')){$id.Substring(7)}else{$id}
   if($script:claudeLoopStates.ContainsKey($session)){$script:claudeLoopStates[$session].Dismissed=$true}
  }elseif($null -ne $script:diagnosticRuntime){$key="codex:"+$id;if($script:diagnosticRuntime.LoopStates.ContainsKey($key)){$script:diagnosticRuntime.LoopStates[$key].Dismissed=$true}}
  $script:fingerprint="";Update-View
 })
 [Windows.Controls.Grid]::SetColumn($dismiss,1);$row.Children.Add($label)|Out-Null;$row.Children.Add($dismiss)|Out-Null
 $container.Children.Add($row)|Out-Null
}

function Add-Steps($container, $steps, [bool]$hidePlanState=$false) {
 $all = @($steps)
 if($all.Count -eq 0){
  $empty = Text (Tr "План ещё не опубликован этой задачей") 12.5 $script:palette.Activity
  $empty.Margin=New-Object Windows.Thickness(0,11,0,0); $container.Children.Add($empty)|Out-Null
  return
 }
 $scroll = New-Object Windows.Controls.ScrollViewer; $scroll.Height=110; $scroll.Margin=New-Object Windows.Thickness(0,11,0,0); $scroll.VerticalScrollBarVisibility=$(if($all.Count -gt 5){"Auto"}else{"Hidden"}); $scroll.HorizontalScrollBarVisibility="Disabled"
 $rail = New-Object Windows.Controls.StackPanel
 $activeIndex=-1; $pendingIndex=-1; $stepIndex=0
 foreach ($step in $all) {
  $row=New-Object Windows.Controls.Grid; $row.Height=22
  $c1=New-Object Windows.Controls.ColumnDefinition; $c1.Width=New-Object Windows.GridLength(22)
  $c2=New-Object Windows.Controls.ColumnDefinition; $c2.Width=New-Object Windows.GridLength(1,"Star")
  $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)
  $state=[string](Prop $step "status" "pending")
  if($state -eq "active" -and $activeIndex -lt 0){$activeIndex=$stepIndex}
  if($state -eq "pending" -and $pendingIndex -lt 0){$pendingIndex=$stepIndex}
  if($hidePlanState){$state="pending"}
  $marker=New-Object Windows.Controls.Border; $marker.Width=14; $marker.Height=14; $marker.CornerRadius=New-Object Windows.CornerRadius(7); $marker.HorizontalAlignment="Center"; $marker.VerticalAlignment="Top"; $marker.Margin=New-Object Windows.Thickness(0,2,0,0)
  if($state -eq "done"){
   $marker.Background=Brush $script:palette.Raised
   $check=New-Object Windows.Shapes.Path; $check.Data=[Windows.Media.Geometry]::Parse("M 2,7 L 5.2,10 L 11.5,3.5"); $check.Width=11; $check.Height=9; $check.Stretch="Uniform"; $check.Stroke=Brush $script:accentHex; $check.StrokeThickness=1.5; $check.StrokeStartLineCap="Round"; $check.StrokeEndLineCap="Round"; $check.StrokeLineJoin="Round"; $check.HorizontalAlignment="Center"; $check.VerticalAlignment="Center"; $marker.Child=$check
  }elseif($state -eq "active"){
   $marker.Background=Brush $script:accentHex
  }else{$marker.Background=Brush $script:palette.Surface; $marker.BorderBrush=Brush $script:palette.Muted; $marker.BorderThickness=New-Object Windows.Thickness(1)}
  [Windows.Controls.Grid]::SetColumn($marker,0)
  $labelColor=if($state -eq "active"){$script:palette.Primary}elseif($state -eq "done"){$script:palette.Done}else{$script:palette.Pending}
  $labelWeight=if($state -eq "active"){"SemiBold"}else{"Normal"}
  $stepTitle=[string](Prop $step "title" (Tr "Без названия"))
  if($script:resolvedLanguage -eq 'en' -and [bool](Prop $step 'generated' $false)){$stepTitle='Step '+[string](Prop $step 'id' '')}
  $label=Text $stepTitle 13 $labelColor $labelWeight
  $label.Margin=New-Object Windows.Thickness(4,0,0,0); $label.TextWrapping="NoWrap"; $label.TextTrimming="CharacterEllipsis"; Add-ConditionalHint $label $stepTitle "line"; $label.VerticalAlignment="Center"; [Windows.Controls.Grid]::SetColumn($label,1)
  $row.Children.Add($marker)|Out-Null; $row.Children.Add($label)|Out-Null; $rail.Children.Add($row)|Out-Null
  $stepIndex++
 }
 $focusIndex=if($activeIndex -ge 0){$activeIndex}elseif($pendingIndex -ge 0){$pendingIndex}else{[Math]::Max(0,$all.Count-2)}
 $scroll.Tag=[double]($focusIndex*22)
 $scroll.Add_Loaded({param($sender,$args) $sender.ScrollToVerticalOffset([double]$sender.Tag)})
 $scroll.Add_PreviewMouseWheel({
  param($sender,$eventArgs)
  $atTop=$sender.VerticalOffset -le 0.5
  $atBottom=$sender.VerticalOffset -ge ($sender.ScrollableHeight-0.5)
  $passToCards=$sender.ScrollableHeight -le 0 -or ($eventArgs.Delta -gt 0 -and $atTop) -or ($eventArgs.Delta -lt 0 -and $atBottom)
  if($passToCards){
   $eventArgs.Handled=$true
   $distance=if($eventArgs.Delta -gt 0){-48}else{48}
   $tasksScroll.ScrollToVerticalOffset($tasksScroll.VerticalOffset+$distance)
  }
 })
 $scroll.Content=$rail; $container.Children.Add($scroll)|Out-Null
}

function Refresh-ActivityMotion {
 $enabled=$PreviewMotion -ne "off"
 if($enabled -ne $script:motionEnabled){$script:motionEnabled=$enabled;$script:fingerprint=""}
}

function New-ActivityIndicator([bool]$active) {
 $track=New-Object Windows.Controls.Canvas; $track.Width=16; $track.Height=4; $track.ClipToBounds=$true; $track.IsHitTestVisible=$false; $track.Tag="ActivityIndicator"
 $geometry=New-Object Windows.Media.RectangleGeometry; $geometry.Rect=[Windows.Rect]::new(0,0,4,4); $geometry.RadiusX=2; $geometry.RadiusY=2
 $mark=New-Object Windows.Shapes.Path; $mark.Width=16; $mark.Height=4; $mark.Stretch="None"; $mark.Data=$geometry
 $mark.Fill=Brush $(if($active){$script:accentHex}else{$script:palette.Muted})
 $track.Children.Add($mark)|Out-Null
 if($active -and $script:motionEnabled){
  $ease=New-Object Windows.Media.Animation.SineEase; $ease.EasingMode="EaseInOut"
  $animation=New-Object Windows.Media.Animation.RectAnimationUsingKeyFrames
  $animation.Duration=[Windows.Duration]::new([TimeSpan]::FromMilliseconds(900));$animation.AutoReverse=$true;$animation.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
  foreach($entry in @(@([Windows.Rect]::new(0,0,16,4),450),@([Windows.Rect]::new(12,0,4,4),900))){
   $key=New-Object Windows.Media.Animation.EasingRectKeyFrame; $key.Value=$entry[0]; $key.KeyTime=[Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds([int]$entry[1])); $key.EasingFunction=$ease
   $animation.KeyFrames.Add($key)|Out-Null
  }
  $geometry.BeginAnimation([Windows.Media.RectangleGeometry]::RectProperty,$animation)
 }
 return $track
}

function Add-Card($task) {
 $stepCount=@($task.Steps).Count
 $hideClaudePlanState=([string]$task.Provider -eq "claude" -and (-not [bool](Prop $task "PlanConfirmed" $true) -or [string](Prop $task "Status" "") -eq "Статус не подтверждён"))
 $hasLoopWarning=$null -ne (Get-LoopWarning $task)
 $card=New-Object Windows.Controls.Grid; if($stepCount -gt 0){$card.Height=$(if($script:showProviderLabels){278}else{258})+$(if($hasLoopWarning){64}else{0})}; $card.Margin=New-Object Windows.Thickness(0,0,0,12)
 $cardShape=New-Object Windows.Shapes.Path; $cardShape.Fill=Brush $script:palette.Raised; $cardShape.Stroke=Brush $(if($task.Active){$script:palette.CardBorder}else{$script:palette.Border}); $cardShape.StrokeThickness=1; $cardShape.IsHitTestVisible=$false
 $cardContent=New-Object Windows.Controls.Border; $cardContent.Padding=New-Object Windows.Thickness(16,15,16,14)
 $card.Children.Add($cardShape)|Out-Null; $card.Children.Add($cardContent)|Out-Null
 $card.Tag=$cardShape
 $card.Add_SizeChanged({param($sender,$args) if($sender.ActualWidth -gt 0 -and $sender.ActualHeight -gt 0){$sender.Tag.Data=Squircle-Geometry $sender.ActualWidth $sender.ActualHeight $script:cardRadius 0.5}})
 $stack=New-Object Windows.Controls.StackPanel
 if($script:showProviderLabels){$providerLabel=Text ([string]$task.ProviderName) 11.5 $script:accentHex "SemiBold";$providerLabel.Margin=New-Object Windows.Thickness(0,0,0,3);$stack.Children.Add($providerLabel)|Out-Null}
 $header=New-Object Windows.Controls.Grid
 $c1=New-Object Windows.Controls.ColumnDefinition; $c1.Width=New-Object Windows.GridLength(1,"Star"); $c2=New-Object Windows.Controls.ColumnDefinition; $c2.Width=[Windows.GridLength]::Auto; $header.ColumnDefinitions.Add($c1); $header.ColumnDefinitions.Add($c2)
 $titleStack=New-Object Windows.Controls.StackPanel
 $displayTitle=Localized-TaskTitle $task
 $title=Text $displayTitle 16 $script:palette.Primary "SemiBold"; $title.Margin=New-Object Windows.Thickness(0,0,14,0); $title.Height=22; $title.MaxWidth=390; $title.HorizontalAlignment="Left"; $title.TextWrapping="NoWrap"; $title.TextTrimming="CharacterEllipsis"; Add-ConditionalHint $title $displayTitle "line"; $titleStack.Children.Add($title)|Out-Null
 $activityText=Localized-TaskActivity $task; $activity=Text $activityText 12 $script:palette.Activity; $activity.MaxWidth=390; $activity.HorizontalAlignment="Left"; $activity.Height=34; $activity.MaxHeight=34; $activity.TextTrimming="CharacterEllipsis"; if($activityText){Add-ConditionalHint $activity $activityText "wrap"}
 $activityRow=New-Object Windows.Controls.Grid; $activityRow.Margin=New-Object Windows.Thickness(0,5,14,0)
 $activityMarkColumn=New-Object Windows.Controls.ColumnDefinition; $activityMarkColumn.Width=New-Object Windows.GridLength(22); $activityTextColumn=New-Object Windows.Controls.ColumnDefinition; $activityTextColumn.Width=New-Object Windows.GridLength(1,"Star"); $activityRow.ColumnDefinitions.Add($activityMarkColumn); $activityRow.ColumnDefinitions.Add($activityTextColumn)
 if($activityText){$indicator=New-ActivityIndicator ([bool]$task.Active);$indicator.Margin=New-Object Windows.Thickness(0,7,6,0);$indicator.VerticalAlignment="Top";$indicator.HorizontalAlignment="Left";$activityRow.Children.Add($indicator)|Out-Null}
 [Windows.Controls.Grid]::SetColumn($activity,1);$activityRow.Children.Add($activity)|Out-Null;$titleStack.Children.Add($activityRow)|Out-Null
 if(-not $CompactMode -and $PreviewActiveTasks -ge 0 -and $null -eq $script:previewHintTarget -and $activityText){$script:previewHintTarget=$activity}
 $progressLabel=Progress-Label $task
 $percent=Text $progressLabel 16 $script:palette.Primary "SemiBold"; $percent.Height=22; $percent.VerticalAlignment="Top"; if($task.ProgressKind -eq "approximate"){$percent.ToolTip=Tr "Приблизительная оценка"}; [Windows.Controls.Grid]::SetColumn($percent,1)
 $header.Children.Add($titleStack)|Out-Null; $header.Children.Add($percent)|Out-Null; $stack.Children.Add($header)|Out-Null
 Add-LoopWarning $stack $task $false
 if(-not $hideClaudePlanState -and $task.ProgressKind -ne "none" -and $null -ne $task.Progress){$bar=New-Object Windows.Controls.ProgressBar; $bar.Maximum=100; $bar.Value=$task.Progress; $bar.Margin=New-Object Windows.Thickness(0,14,0,0); $stack.Children.Add($bar)|Out-Null}
 if($stepCount -gt 0){
  Add-Steps $stack $task.Steps $hideClaudePlanState
  $planNote=Plan-StatusNote $task
  $metaText=$(if($planNote){$planNote}else{Tr 'План задачи'})+' · '+(Plan-StepCount $stepCount)
  if($task.Updated -ne [DateTime]::MinValue){$metaText += " · "+$task.Updated.ToString("HH:mm")}
  $meta=Text $metaText 11.5 $script:palette.Muted; $meta.Margin=New-Object Windows.Thickness(0,11,0,0); $stack.Children.Add($meta)|Out-Null
 }
 $cardContent.Child=$stack; $tasksPanel.Children.Add($card)|Out-Null
}

function Add-CompactTask($task) {
 if($script:showProviderLabels){$providerLabel=Text ([string]$task.ProviderName) 10.5 $script:accentHex "SemiBold";$providerLabel.Margin=New-Object Windows.Thickness(12,0,0,2);$compactTasksPanel.Children.Add($providerLabel)|Out-Null}
 $container=New-Object Windows.Controls.Grid; $container.Margin=New-Object Windows.Thickness(0,0,0,10)
 $r1=New-Object Windows.Controls.RowDefinition; $r1.Height=[Windows.GridLength]::Auto
 $r2=New-Object Windows.Controls.RowDefinition; $r2.Height=[Windows.GridLength]::Auto
 $r3=New-Object Windows.Controls.RowDefinition; $r3.Height=[Windows.GridLength]::Auto
 $r4=New-Object Windows.Controls.RowDefinition; $r4.Height=[Windows.GridLength]::Auto
 $container.RowDefinitions.Add($r1); $container.RowDefinitions.Add($r2); $container.RowDefinitions.Add($r3); $container.RowDefinitions.Add($r4)

 $header=New-Object Windows.Controls.Grid
 $c1=New-Object Windows.Controls.ColumnDefinition; $c1.Width=New-Object Windows.GridLength(12)
 $c2=New-Object Windows.Controls.ColumnDefinition; $c2.Width=New-Object Windows.GridLength(1,"Star")
 $c3=New-Object Windows.Controls.ColumnDefinition; $c3.Width=[Windows.GridLength]::Auto
 $header.ColumnDefinitions.Add($c1); $header.ColumnDefinitions.Add($c2); $header.ColumnDefinitions.Add($c3)
 $displayTitle=Localized-TaskTitle $task
 $title=Text $displayTitle 16 $script:palette.Primary "SemiBold"; $title.TextWrapping="NoWrap"; $title.TextTrimming="CharacterEllipsis"; $title.Margin=New-Object Windows.Thickness(0,0,10,0); Add-ConditionalHint $title $displayTitle "line"; [Windows.Automation.AutomationProperties]::SetName($title,$displayTitle)
 $progressLabel=Progress-Label $task
 $percent=Text $progressLabel 16 $script:palette.Primary "SemiBold"; $percent.VerticalAlignment="Center"; if($task.ProgressKind -eq "approximate"){$percent.ToolTip=Tr "Приблизительная оценка"}
 [Windows.Controls.Grid]::SetColumn($title,1); [Windows.Controls.Grid]::SetColumn($percent,2)
 $header.Children.Add($title)|Out-Null; $header.Children.Add($percent)|Out-Null
 [Windows.Controls.Grid]::SetRow($header,0); $container.Children.Add($header)|Out-Null

 $activityText=Localized-TaskActivity $task; if(-not $activityText){$activityText=Tr "Выполняется"}
 $activity=Text $activityText 11.5 $script:palette.Activity; $activity.TextWrapping="NoWrap"; $activity.TextTrimming="CharacterEllipsis"; Add-ConditionalHint $activity $activityText "line"; [Windows.Automation.AutomationProperties]::SetName($activity,$activityText)
 $activityRow=New-Object Windows.Controls.Grid; $activityRow.Margin=New-Object Windows.Thickness(12,2,0,0)
 $activityMarkColumn=New-Object Windows.Controls.ColumnDefinition; $activityMarkColumn.Width=New-Object Windows.GridLength(22); $activityTextColumn=New-Object Windows.Controls.ColumnDefinition; $activityTextColumn.Width=New-Object Windows.GridLength(1,"Star"); $activityRow.ColumnDefinitions.Add($activityMarkColumn); $activityRow.ColumnDefinitions.Add($activityTextColumn)
 $indicator=New-ActivityIndicator ([bool]$task.Active);$indicator.Margin=New-Object Windows.Thickness(0,7,6,0);$indicator.VerticalAlignment="Top";$indicator.HorizontalAlignment="Left";$activityRow.Children.Add($indicator)|Out-Null
 [Windows.Controls.Grid]::SetColumn($activity,1);$activityRow.Children.Add($activity)|Out-Null
 if($CompactMode -and $PreviewActiveTasks -ge 0 -and $null -eq $script:previewHintTarget){$script:previewHintTarget=$activity}
 [Windows.Controls.Grid]::SetRow($activityRow,1); $container.Children.Add($activityRow)|Out-Null
 $warningPanel=New-Object Windows.Controls.StackPanel
 $planNoteText=Plan-StatusNote $task
 if($planNoteText){$planNote=Text $planNoteText 11.5 $script:palette.Muted;$planNote.Margin=New-Object Windows.Thickness(12,4,0,0);$warningPanel.Children.Add($planNote)|Out-Null}
 Add-LoopWarning $warningPanel $task $true; [Windows.Controls.Grid]::SetRow($warningPanel,2); $container.Children.Add($warningPanel)|Out-Null
 $hideClaudePlanState=([string]$task.Provider -eq 'claude' -and (-not [bool](Prop $task 'PlanConfirmed' $true) -or [string](Prop $task 'Status' '') -eq 'Статус не подтверждён'))
 if(-not $hideClaudePlanState -and $task.ProgressKind -ne "none" -and $null -ne $task.Progress){$bar=New-Object Windows.Controls.ProgressBar; $bar.Maximum=100; $bar.Value=$task.Progress; $bar.Height=2; $bar.Margin=New-Object Windows.Thickness(12,7,0,0); [Windows.Controls.Grid]::SetRow($bar,3); $container.Children.Add($bar)|Out-Null}
 $compactTasksPanel.Children.Add($container)|Out-Null
}

function Add-CompactDot($task,[bool]$selected) {
 $button=New-Object Windows.Controls.Button
 $button.Style=$window.Resources["CompactDotStyle"]
 $button.Tag=[string]$task.Id
 [Windows.Automation.AutomationProperties]::SetName($button,(Tr "Показать задачу: ")+(Localized-TaskTitle $task))
 $dot=New-Object Windows.Controls.Border
 $dot.Width=7; $dot.Height=7; $dot.CornerRadius=New-Object Windows.CornerRadius(3.5)
 $dot.Background=Brush $(if($selected){$script:accentHex}else{$script:palette.Scroll})
 $button.Content=$dot
 $button.Add_Click({param($sender,$eventArgs) $script:compactTaskId=[string]$sender.Tag; Render-CompactTasks $script:lastAllTasks})
 $compactDotsPanel.Children.Add($button)|Out-Null
}

function Prioritize-Tasks($tasks,$previous,[string]$selectedId) {
 $previousById=@{}; $present=@{}; $activated=New-Object Collections.Generic.List[object]
 foreach($task in @($previous)){$previousById[[string]$task.Id]=$task}
 foreach($task in @($tasks)){
  $id=[string]$task.Id; $present[$id]=$true
  if(-not $script:taskPriority.ContainsKey($id)){$script:taskPriority[$id]=0}
  $old=if($previousById.ContainsKey($id)){$previousById[$id]}else{$null}
  $newKey=[string](Prop $task "StartKey" ""); $oldKey=[string](Prop $old "StartKey" "")
  $newTurn=$newKey -and $newKey -cne $oldKey
  $started=[DateTime](Prop $task "Started" ([DateTime]::MinValue))
  $recentUnconfirmed=-not $task.Active -and [string](Prop $task "Status" "") -eq "Статус не подтверждён" -and $newKey -and $started -ne [DateTime]::MinValue -and $started.ToUniversalTime() -ge $script:monitorStartedUtc
  $recentWaiting=-not $task.Active -and [string](Prop $task "Status" "") -eq "Ожидает подтверждения" -and $newKey -and $started -ne [DateTime]::MinValue -and $started.ToUniversalTime() -ge $script:monitorStartedUtc
  if(-not $task.Active -and -not $recentUnconfirmed -and -not $recentWaiting){continue}
  $becameActive=$null -ne $old -and -not $old.Active -and (-not $newKey -or -not $oldKey)
  if($null -eq $old -or $newTurn -or ($task.Active -and $becameActive)){$activated.Add($task)}
 }
 foreach($id in @($script:taskPriority.Keys)){if(-not $present.ContainsKey($id)){[void]$script:taskPriority.Remove($id)}}
 $activatedByStart=@($activated | Sort-Object -Property @{
  Expression={
   $started=[DateTime](Prop $_ "Started" ([DateTime]::MinValue))
   if($started -eq [DateTime]::MinValue){$started=[DateTime](Prop $_ "Updated" ([DateTime]::MinValue))}
   if($started -eq [DateTime]::MinValue){$started}else{$started.ToUniversalTime()}
  }
 }, @{Expression={[string]$_.Id}})
 foreach($task in $activatedByStart){$script:taskPriorityCounter++;$script:taskPriority[[string]$task.Id]=$script:taskPriorityCounter}
 $ordered=@($tasks | Sort-Object -Property @{
  Expression={$script:taskPriority[[string]$_.Id]};Descending=$true
 }, @{
  Expression={if($_.Active){1}else{0}};Descending=$true
 }, @{
  Expression={[DateTime](Prop $_ "Updated" ([DateTime]::MinValue))};Descending=$true
 })
 if($activatedByStart.Count -gt 0){$selectedId=[string]$activatedByStart[$activatedByStart.Count-1].Id}
 elseif(-not @($ordered | Where-Object {[string]$_.Id -eq $selectedId}).Count){$selectedId=if($ordered.Count){[string]$ordered[0].Id}else{""}}
 return [PSCustomObject]@{Tasks=$ordered;SelectedId=$selectedId}
}

function Compact-VisibleTasks($tasks) {
 return @($tasks|Where-Object {$_.Active -or [string](Prop $_ "Status" "") -in @("Статус не подтверждён","Ожидает подтверждения")})
}

function Render-CompactTasks($tasks) {
 $compactTasksPanel.Children.Clear(); $compactDotsPanel.Children.Clear()
 $compactTasks=@(Compact-VisibleTasks $tasks)
 $visibleTasks=@($compactTasks|Select-Object -First 3)
 $unavailable=@($script:sourceErrors)
 $warningText=if($unavailable.Count -gt 0){(Tr "Нет данных от ")+($unavailable -join ", ")}else{""}
 if($visibleTasks.Count -eq 0){
  $script:compactTaskId=""
  $compactEmpty=Text $(if($warningText){$warningText}else{Tr "Активных задач сейчас нет"}) 12.5 $script:palette.Activity
  $compactEmpty.Margin=New-Object Windows.Thickness(0,5,0,5)
  $compactTasksPanel.Children.Add($compactEmpty)|Out-Null
  $compactDotsPanel.Visibility="Collapsed"
 } else {
  $selected=@($visibleTasks|Where-Object {[string]$_.Id -eq $script:compactTaskId}|Select-Object -First 1)
  if($selected.Count -eq 0){$selected=@($visibleTasks[0]);$script:compactTaskId=[string]$visibleTasks[0].Id}
  Add-CompactTask $selected[0]
  if($warningText){
   $warning=Text $warningText 11.5 $script:palette.Muted
   $warning.Margin=New-Object Windows.Thickness(12,0,0,6)
   $compactTasksPanel.Children.Add($warning)|Out-Null
  }
  if($visibleTasks.Count -gt 1){
   $compactDotsPanel.Visibility="Visible"
   foreach($task in $visibleTasks){Add-CompactDot $task ([string]$task.Id -eq $script:compactTaskId)}
  }else{$compactDotsPanel.Visibility="Collapsed"}
 }
 $hiddenCount=[Math]::Max(0,$compactTasks.Count-3)
 $compactMoreText.Visibility=$(if($hiddenCount -gt 0){"Visible"}else{"Collapsed"})
 $compactMoreText.Text=$(if($hiddenCount -gt 0){if($script:resolvedLanguage -eq 'en'){"$hiddenCount more tasks"}else{"Ещё $hiddenCount задач"}}else{""})
 $hasLoopWarning=$visibleTasks.Count -gt 0 -and $null -ne (Get-LoopWarning $selected[0])
 $hasUnconfirmedPlan=$visibleTasks.Count -gt 0 -and [bool](Plan-StatusNote $selected[0])
 if($script:isCompact){$window.Height=Compact-Height $compactTasks.Count ($unavailable.Count -gt 0) $hasLoopWarning $hasUnconfirmedPlan; Move-CompactWindow}
}

function Compact-Height([int]$activeCount,[bool]$hasSourceErrors=$false,[bool]$hasLoopWarning=$false,[bool]$hasUnconfirmedPlan=$false) {
 if($activeCount -le 0){return 132}
 $dots=if($activeCount -gt 1){18}else{0}
 $more=if($activeCount -gt 3){20}else{0}
 $provider=if($script:showProviderLabels){18}else{0}
 $warning=if($hasSourceErrors){20}else{0}
 $loopSpace=if($hasLoopWarning){72}else{0}
 $planSpace=if($hasUnconfirmedPlan){20}else{0}
 return 162+$dots+$more+$provider+$warning+$loopSpace+$planSpace
}

function Move-CompactWindow {
 $work=[Windows.SystemParameters]::WorkArea
 $window.UpdateLayout()
 $window.Left=$work.Right-$window.Width
 $window.Top=$work.Bottom-$window.Height
}

function Set-CompactMode([bool]$compact) {
 if($compact -eq $script:isCompact){return}
 if($compact){
  $script:expandedBounds=[PSCustomObject]@{Left=$window.Left;Top=$window.Top;Width=$window.Width;Height=$window.Height}
  $expandedView.Visibility="Collapsed"; $settingsView.Visibility="Collapsed"; $aboutView.Visibility="Collapsed"; $journalView.Visibility="Collapsed"; $compactView.Visibility="Visible"
  $script:showingSettings=$false; $script:showingAbout=$false; $script:showingJournal=$false
  $window.ResizeMode="NoResize"; $window.MinWidth=0; $window.MinHeight=0; $window.Width=390
  $compactCount=@(Compact-VisibleTasks $script:lastAllTasks).Count
  $selectedTask=@($script:lastAllTasks|Where-Object {[string]$_.Id -eq $script:compactTaskId}|Select-Object -First 1)
  $hasLoopWarning=$selectedTask.Count -gt 0 -and $null -ne (Get-LoopWarning $selectedTask[0])
  $hasUnconfirmedPlan=$selectedTask.Count -gt 0 -and [bool](Plan-StatusNote $selectedTask[0])
  $window.Height=Compact-Height $compactCount ($script:sourceErrors.Count -gt 0) $hasLoopWarning $hasUnconfirmedPlan
  $windowFrame.Margin=New-Object Windows.Thickness(16)
  $script:isCompact=$true; $window.Topmost=$true; Move-CompactWindow
 }else{
  $compactView.Visibility="Collapsed"; $expandedView.Visibility="Visible"
  $window.ResizeMode="CanResize"; $window.MinWidth=500; $window.MinHeight=500
  $windowFrame.Margin=New-Object Windows.Thickness(28)
  if($null -ne $script:expandedBounds){$window.Left=$script:expandedBounds.Left;$window.Top=$script:expandedBounds.Top;$window.Width=$script:expandedBounds.Width;$window.Height=$script:expandedBounds.Height}else{$window.Width=590;$window.Height=760;$window.WindowStartupLocation="CenterScreen"}
  $script:isCompact=$false; $window.Topmost=$true
  Show-PendingUpdate
 }
}

function Show-PendingUpdate {
 if($script:isCompact -or $null -eq $script:availableUpdate -or $script:availableUpdate.Version -ceq $script:dismissedUpdate){return}
 $updateVersionText.Text=if($script:resolvedLanguage -eq 'en'){'Version '+$script:availableUpdate.Version+' is available to download'}else{'Версия '+$script:availableUpdate.Version+' доступна для скачивания'}
 $updateOpenError.Visibility='Collapsed';$updateOverlay.Visibility='Visible'
 $updateLaterButton.Focus()|Out-Null
}

function Hide-UpdateForSession {
 if($null -ne $script:availableUpdate){$script:dismissedUpdate=[string]$script:availableUpdate.Version}
 $updateOverlay.Visibility='Collapsed'
 [Windows.Input.Keyboard]::ClearFocus()|Out-Null
}

function Invoke-UpdateDownload {
 if($null -eq $script:availableUpdate){return}
 $url=[string]$script:availableUpdate.Url
 try{
  $uri=[Uri]$url;$parts=$uri.AbsolutePath.Split('/')
  if($parts.Count -ne 7 -or -not (Get-TrustedReleaseUrl $url $parts[5] $parts[6] 'windows')){throw 'Untrusted release URL'}
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$url;$info.UseShellExecute=$true
  [void][Diagnostics.Process]::Start($info)
  Hide-UpdateForSession
 }catch{$updateOpenError.Visibility='Visible'}
}

function Invoke-UpdateCheckTick {
 if($script:isStoreEdition -or -not $script:releaseUpdatesAvailable){return}
 if($null -ne $script:updateParserRequest){
  if(-not $script:updateParserRequest.IsCompleted){return}
  $parsed=$null;$valid=$false
  try{
   $output=@($script:updateParser.EndInvoke($script:updateParserRequest))
   if($script:updateParser.Streams.Error.Count -ne 0 -or $output.Count -ne 1){throw 'Invalid update result.'}
   $parsed=$output[0]
   if($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['Update']){throw 'Invalid update result.'}
   $valid=$true
  }catch{}finally{
   try{$script:updateParser.Dispose()}catch{};$script:updateParser=$null;$script:updateParserRequest=$null
  }
  $updateWall=[DateTimeOffset]::UtcNow
  $updateTick=[Diagnostics.Stopwatch]::GetTimestamp()
  Set-UpdateRetryResult $script:updateRetry $valid $script:updateTransportResult $updateTick $updateWall
  $script:updateTransportResult=$null
  if($valid -and $null -ne $parsed.Update){try{$script:availableUpdate=$parsed.Update;Show-PendingUpdate}catch{}}
  return
 }
 if($null -ne $script:updateRequest){
  if(-not $script:updateRequest.IsCompleted){return}
  $result=$null
  try{
   $result=$script:updateRequest.GetAwaiter().GetResult()
  }catch{}finally{
   $script:updateRequest=$null
   if($null -ne $script:updateCancellation){$script:updateCancellation.Dispose();$script:updateCancellation=$null}
  }
  if($null -eq $result -or -not $result.Success){
   $updateWall=[DateTimeOffset]::UtcNow
   $updateTick=[Diagnostics.Stopwatch]::GetTimestamp()
   Set-UpdateRetryResult $script:updateRetry $false $result $updateTick $updateWall
   return
  }
  try{
   $parser=[PowerShell]::Create();$script:updateParser=$parser
   $body={param([string]$module,[string]$json,[string]$version)
    $ErrorActionPreference='Stop'
    . $module
    if(-not (Test-ReleasePayload $json)){throw 'Invalid release metadata.'}
    [PSCustomObject]@{Update=(Find-PlatformUpdate $json $version 'windows')}
   }
   [void]$parser.AddScript($body.ToString()).AddArgument($script:releaseUpdatesPath).AddArgument($result.Json).AddArgument($script:currentVersion)
   $script:updateTransportResult=$result;$script:updateParserRequest=$parser.BeginInvoke()
  }catch{
   if($null -ne $script:updateParser){try{$script:updateParser.Dispose()}catch{};$script:updateParser=$null}
   $script:updateParserRequest=$null;$script:updateTransportResult=$null
   $updateWall=[DateTimeOffset]::UtcNow
   $updateTick=[Diagnostics.Stopwatch]::GetTimestamp()
   Set-UpdateRetryResult $script:updateRetry $false $result $updateTick $updateWall
  }
  return
 }
 if(-not (Test-UpdateRetryDue $script:updateRetry ([Diagnostics.Stopwatch]::GetTimestamp()))){return}
 try{
  $script:updateCancellation=[Threading.CancellationTokenSource]::new()
  $script:updateRequest=Start-UpdateTransport $script:updateCancellation.Token
 }catch{
  $script:updateRequest=$null
  if($null -ne $script:updateCancellation){$script:updateCancellation.Dispose();$script:updateCancellation=$null}
  $updateWall=[DateTimeOffset]::UtcNow
  $updateTick=[Diagnostics.Stopwatch]::GetTimestamp()
  Set-UpdateRetryResult $script:updateRetry $false $null $updateTick $updateWall
 }
}
function Stop-UpdateCheck {
 if($null -ne $script:updateCancellation){try{$script:updateCancellation.CancelAfter(1)}catch{}}
 if($null -ne $script:updateParser){
  try{
   if($null -ne $script:updateParserRequest -and $script:updateParserRequest.IsCompleted){$script:updateParser.Dispose()}
   else{[void]$script:updateParser.BeginStop($null,$null)}
  }catch{}
 }
}

function Show-SettingsView([bool]$keyboardNavigation = $false,[bool]$fromJournal = $false,[bool]$fromAbout = $false) {
 if($script:isCompact){Set-CompactMode $false}
 $expandedView.Visibility="Collapsed"
 $compactView.Visibility="Collapsed"
 $journalView.Visibility="Collapsed"
 $aboutView.Visibility="Collapsed"
 $settingsView.Visibility="Visible"
 $script:showingSettings=$true; $script:showingAbout=$false; $script:showingJournal=$false
 Update-SourceSettings
 Update-JournalSettings
 Update-ClaudeRetentionSettings
 Update-LoopSettings
 if($keyboardNavigation){if($fromJournal){$journalOpenButton.Focus()|Out-Null}elseif($fromAbout){$aboutSettingsButton.Focus()|Out-Null}else{$settingsBackButton.Focus()|Out-Null}}else{[Windows.Input.Keyboard]::ClearFocus()|Out-Null}
}

function Get-FeedbackUri {
 $subject=if($script:resolvedLanguage -eq 'en'){'AI Task Monitor feedback or suggestion'}else{'Отзыв или предложение об AI Task Monitor'}
 return 'mailto:truea.k.a.ru@gmail.com?subject='+[Uri]::EscapeDataString($subject)
}

function Open-FeedbackDraft {
 if($PreviewAboutUiTest){$script:previewFeedbackClicks++;return}
 try{
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=Get-FeedbackUri; $info.UseShellExecute=$true
  [void][Diagnostics.Process]::Start($info)
  $feedbackError.Visibility="Collapsed"
 }catch{$feedbackError.Tag='Не удалось открыть почтовое приложение. Напишите на truea.k.a.ru@gmail.com.';$feedbackError.Text=Tr ([string]$feedbackError.Tag);$feedbackError.Visibility="Visible"}
}

function Copy-FeedbackEmail {
 try{
  $address=[Windows.Documents.TextRange]::new($feedbackEmailLink.ContentStart,$feedbackEmailLink.ContentEnd).Text.Trim()
  if(-not $address){throw 'The feedback address is unavailable.'}
  if($PreviewAboutUiTest -and $script:previewClipboardFailure){throw 'Simulated clipboard failure.'}
  if($PreviewAboutUiTest -and -not $PreviewClipboardUiTest){$script:previewClipboardText=$address}
  else{
   [Windows.Clipboard]::SetText($address)
   if($PreviewAboutUiTest){$script:previewClipboardText=[Windows.Clipboard]::GetText()}
  }
  $feedbackError.Visibility='Collapsed'
 }catch{
  $feedbackError.Tag='Не удалось скопировать адрес. Выделите его и скопируйте вручную.'
  $feedbackError.Text=Tr ([string]$feedbackError.Tag);$feedbackError.Visibility='Visible'
 }
}

function Show-TasksView([bool]$keyboardNavigation = $false) {
 $settingsView.Visibility="Collapsed"
 $aboutView.Visibility="Collapsed"
 $journalView.Visibility="Collapsed"
 $compactView.Visibility="Collapsed"
 $expandedView.Visibility="Visible"
 $script:showingSettings=$false; $script:showingAbout=$false; $script:showingJournal=$false
 if($keyboardNavigation){$settingsFooterButton.Focus()|Out-Null}else{[Windows.Input.Keyboard]::ClearFocus()|Out-Null}
}

function Show-AboutView([bool]$keyboardNavigation = $false) {
 if($script:isCompact){Set-CompactMode $false}
 $expandedView.Visibility="Collapsed"; $compactView.Visibility="Collapsed"
 $settingsView.Visibility="Collapsed"; $journalView.Visibility="Collapsed"; $aboutView.Visibility="Visible"
 $script:showingSettings=$false; $script:showingAbout=$true; $script:showingJournal=$false
 $aboutScroll.ScrollToTop()
 if($keyboardNavigation){$aboutBackButton.Focus()|Out-Null}else{[Windows.Input.Keyboard]::ClearFocus()|Out-Null}
}

function New-JournalComboItem([string]$label,$tag) {
 $item=New-Object Windows.Controls.ComboBoxItem
 $item.Content=$label; $item.Tag=$tag
 [Windows.Automation.AutomationProperties]::SetName($item,$label)
 $item.Add_SizeChanged({param($sender,$eventArgs)
  $probe=New-Object Windows.Controls.TextBlock
  $probe.Text=[string]$sender.Content; $probe.FontFamily=$sender.FontFamily; $probe.FontSize=$sender.FontSize; $probe.FontWeight=$sender.FontWeight
  $probe.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
  $sender.ToolTip=$(if($sender.ActualWidth -gt 0 -and $probe.DesiredSize.Width -gt [Math]::Max(0,$sender.ActualWidth-20)){[string]$sender.Content}else{$null})
 })
 return $item
}

function Update-JournalComboHint($combo) {
 if($null -eq $combo.SelectedItem -or $combo.ActualWidth -le 0){$combo.ToolTip=$null;return}
 $value=[string]$combo.SelectedItem.Content
 $probe=New-Object Windows.Controls.TextBlock
 $probe.Text=$value; $probe.FontFamily=$combo.FontFamily; $probe.FontSize=$combo.FontSize; $probe.FontWeight=$combo.FontWeight
 $probe.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
 $combo.ToolTip=$(if($probe.DesiredSize.Width -gt [Math]::Max(0,$combo.ActualWidth-38)){$value}else{$null})
}

function Update-JournalSettings {
 $script:updatingJournalControls=$true
 try{
  if($journalDaysCombo.Items.Count -eq 0){
   foreach($day in 1..7){$unit=if($script:resolvedLanguage -eq 'en'){if($day -eq 1){'day'}else{'days'}}elseif($day -eq 1){"день"}elseif($day -le 4){"дня"}else{"дней"};[void]$journalDaysCombo.Items.Add((New-JournalComboItem "$day $unit" $day))}
   foreach($size in 1..10){$unit=if($script:resolvedLanguage -eq 'en'){'MB'}else{'МБ'};[void]$journalSizeCombo.Items.Add((New-JournalComboItem "$size $unit" $size))}
  }
  $ready=$null -ne $script:diagnosticRuntime
  $journalDaysCombo.IsEnabled=$ready; $journalSizeCombo.IsEnabled=$ready; $journalOpenButton.IsEnabled=$ready; $journalClearButton.IsEnabled=$script:diagnosticModulesAvailable -and $journalClearConfirmation.Visibility -ne "Visible"
  if($ready){
   foreach($item in $journalDaysCombo.Items){if([int]$item.Tag -eq [int]$script:diagnosticRuntime.Settings.RetentionDays){$journalDaysCombo.SelectedItem=$item;break}}
   foreach($item in $journalSizeCombo.Items){if([int]$item.Tag -eq [int]$script:diagnosticRuntime.Settings.MaximumMB){$journalSizeCombo.SelectedItem=$item;break}}
  }
  $error=if($script:journalUiError){$script:journalUiError}elseif($script:diagnosticError){$script:diagnosticError}elseif(-not $ready){"Журнал недоступен"}else{""}
  $journalSettingsError.Text=Tr $error
  $journalSettingsError.Visibility=$(if($error){"Visible"}else{"Collapsed"})
 }finally{$script:updatingJournalControls=$false}
 Update-JournalComboHint $journalDaysCombo
 Update-JournalComboHint $journalSizeCombo
}

function Update-ClaudeRetentionSettings {
 $script:updatingClaudeRetentionControls=$true
 try{
  if($claudeRetentionDaysCombo.Items.Count -eq 0){
   foreach($day in 1..30){
    $last=$day%10;$lastTwo=$day%100
    $unit=if($script:resolvedLanguage -eq 'en'){if($day -eq 1){'day'}else{'days'}}elseif($lastTwo -ge 11 -and $lastTwo -le 14){'дней'}elseif($last -eq 1){'день'}elseif($last -ge 2 -and $last -le 4){'дня'}else{'дней'}
    [void]$claudeRetentionDaysCombo.Items.Add((New-JournalComboItem "$day $unit" $day))
   }
   foreach($size in 1..100){$unit=if($script:resolvedLanguage -eq 'en'){'MB'}else{'МБ'};[void]$claudeRetentionSizeCombo.Items.Add((New-JournalComboItem "$size $unit" $size))}
  }
  $policy=Load-ClaudeRetentionSettings
  $ready=$script:claudeRetentionAvailable -and $policy.Valid
  $claudeRetentionDaysCombo.IsEnabled=$ready;$claudeRetentionSizeCombo.IsEnabled=$ready
  if($ready){
   foreach($item in $claudeRetentionDaysCombo.Items){if([int]$item.Tag -eq $policy.Days){$claudeRetentionDaysCombo.SelectedItem=$item;break}}
   foreach($item in $claudeRetentionSizeCombo.Items){if([int]$item.Tag -eq $policy.MaximumMB){$claudeRetentionSizeCombo.SelectedItem=$item;break}}
  }
  $error=if($script:claudeRetentionUiError){$script:claudeRetentionUiError}elseif(-not $policy.Valid){'Настройки хранения Claude Code повреждены'}elseif(-not $script:claudeRetentionAvailable){'Очистка Claude Code недоступна'}elseif([AITaskMonitor.Claude.Retention]::Status -eq 'error'){'Не удалось очистить данные Claude Code'}else{''}
  $claudeRetentionError.Text=Tr $error;$claudeRetentionError.Visibility=$(if($error){'Visible'}else{'Collapsed'})
 }finally{$script:updatingClaudeRetentionControls=$false}
 Update-JournalComboHint $claudeRetentionDaysCombo
 Update-JournalComboHint $claudeRetentionSizeCombo
}

function Schedule-ClaudeRetention([bool]$force=$false) {
 if($PreviewActiveTasks -ge 0 -or $SnapshotFile -or -not $script:claudeRetentionAvailable){return}
 $policy=Load-ClaudeRetentionSettings
 if(-not $policy.Valid){
  if(-not $script:retentionPolicyInvalidated){[AITaskMonitor.Claude.Retention]::Invalidate();$script:retentionPolicyInvalidated=$true}
  return
 }
 $script:retentionPolicyInvalidated=$false
 if(-not $force -and [DateTime]::UtcNow -lt $script:nextClaudeRetention){return}
 try{
  [AITaskMonitor.Claude.Retention]::Schedule($dataDirectory,(Join-Path $env:USERPROFILE '.claude'),[int]$policy.Days,([long]$policy.MaximumMB*1000000))
  $script:nextClaudeRetention=[DateTime]::UtcNow.AddSeconds($(if($force -or [AITaskMonitor.Claude.Retention]::Status -in @('busy','cancelled')){10}else{300}))
 }catch{$script:claudeRetentionUiError='Не удалось очистить данные Claude Code';$script:nextClaudeRetention=[DateTime]::UtcNow.AddMinutes(1)}
}

function Save-ClaudeRetentionControls([string]$name,$combo) {
 if($script:updatingClaudeRetentionControls -or $null -eq $combo.SelectedItem){return}
 if(Save-ClaudeRetentionPreference $name ([int]$combo.SelectedItem.Tag)){
  $script:claudeRetentionUiError='';Schedule-ClaudeRetention $true
 }else{$script:claudeRetentionUiError='Не удалось сохранить настройки хранения Claude Code'}
 Update-ClaudeRetentionSettings
}

function Update-LoopSettings {
 $script:updatingLoopControls=$true
 try{
  if($loopThresholdCombo.Items.Count -eq 0){
   foreach($count in 3..10){[void]$loopThresholdCombo.Items.Add((New-JournalComboItem ([string]$count) $count))}
   foreach($minutes in 1..30){$unit=if($script:resolvedLanguage -eq 'en'){'min'}else{'мин'};[void]$loopWindowCombo.Items.Add((New-JournalComboItem "$minutes $unit" $minutes))}
  }
  $ready=$null -ne $script:diagnosticRuntime
  $loopThresholdCombo.IsEnabled=$ready; $loopWindowCombo.IsEnabled=$ready
  if($ready){
   foreach($item in $loopThresholdCombo.Items){if([int]$item.Tag -eq [int]$script:diagnosticRuntime.Settings.LoopThreshold){$loopThresholdCombo.SelectedItem=$item;break}}
   foreach($item in $loopWindowCombo.Items){if([int]$item.Tag -eq [int]$script:diagnosticRuntime.Settings.LoopWindowMinutes){$loopWindowCombo.SelectedItem=$item;break}}
  }
  $error=if($script:loopUiError){$script:loopUiError}elseif(-not $ready){"Настройка недоступна"}elseif($script:claudeLoopError){$script:claudeLoopError}else{""}
  $loopSettingsError.Text=Tr $error; $loopSettingsError.Visibility=$(if($error){"Visible"}else{"Collapsed"})
 }finally{$script:updatingLoopControls=$false}
 Update-JournalComboHint $loopThresholdCombo
 Update-JournalComboHint $loopWindowCombo
}

function Save-LoopControls {
 if($script:updatingLoopControls -or $null -eq $script:diagnosticRuntime -or $null -eq $loopThresholdCombo.SelectedItem -or $null -eq $loopWindowCombo.SelectedItem){return}
 try{
  Save-DiagnosticSettings -Directory $script:diagnosticDirectory -LoopThreshold ([int]$loopThresholdCombo.SelectedItem.Tag) -LoopWindowMinutes ([int]$loopWindowCombo.SelectedItem.Tag)
  $script:diagnosticRuntime.Settings=Get-DiagnosticSettings -Directory $script:diagnosticDirectory
  $script:loopUiError=""; $script:fingerprint=""
 }catch{$script:loopUiError="Не удалось сохранить настройки предупреждения"}
 Update-LoopSettings
}

function Reveal-JournalSettings {
 $window.UpdateLayout()
 $point=$journalSettingsSection.TranslatePoint([Windows.Point]::new(0,0),$settingsScroll)
 $target=[Math]::Max(0,$settingsScroll.VerticalOffset+$point.Y-40)
 $settingsScroll.ScrollToVerticalOffset($target)
 $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
 $window.UpdateLayout()
}

function Save-JournalControls {
 if($script:updatingJournalControls -or $null -eq $script:diagnosticRuntime -or $null -eq $journalDaysCombo.SelectedItem -or $null -eq $journalSizeCombo.SelectedItem){return}
 $days=[int]$journalDaysCombo.SelectedItem.Tag; $size=[int]$journalSizeCombo.SelectedItem.Tag
 try{
  Save-DiagnosticSettings -Directory $script:diagnosticDirectory -RetentionDays $days -MaximumMB $size
  $script:diagnosticRuntime.Settings=Get-DiagnosticSettings -Directory $script:diagnosticDirectory
  $script:journalUiError=""
 }catch{$script:journalUiError="Не удалось сохранить настройки журнала";Update-JournalSettings;return}
 try{
  $now=[DateTimeOffset]::UtcNow; $limit=[long]$size*1000000
  Remove-ExpiredDiagnosticEvents -Directory $script:diagnosticDirectory -Now $now -RetentionDays $days -MaximumBytes $limit
  $events=@(Read-DiagnosticEvents -Directory $script:diagnosticDirectory -Now $now -RetentionDays $days -MaximumBytes $limit)
  Set-DiagnosticNextCleanup $script:diagnosticRuntime $events
  $script:journalFingerprint=""
 }catch{$script:journalUiError="Не удалось применить очистку журнала"}
 Update-JournalSettings
}

function Get-JournalTaskOptions($references) {
 $targetKeys=@{}
 foreach($reference in $references){$targetKeys[[string]$reference.Key]=[string]$reference.Provider}
 $known=@{}
 foreach($task in $script:lastAllTasks){
  $provider=[string](Prop $task "Provider" "");$id=[string](Prop $task "Id" "")
  if($provider -eq "claude" -and $id.StartsWith("claude:")){$id=$id.Substring(7)}
  if($provider -notin @("codex","claude") -or $id -notmatch '^[A-Za-z0-9_-]{1,128}$'){continue}
  $key=Get-DiagnosticTaskKey -Provider $provider -TaskId $id -Key $script:diagnosticRuntime.Key
  if($targetKeys.ContainsKey($key)){$known[$key]=[regex]::Replace(([string](Prop $task "Title" "")).Trim(),'\s+',' ')}
 }
 if(Test-Path -LiteralPath $sessionIndex){
  try{
   foreach($line in Get-Content -LiteralPath $sessionIndex -Encoding UTF8 -Tail 100){
    try{
     $session=$line|ConvertFrom-Json;$id=[string](Prop $session "id" "")
     if($id -notmatch '^[A-Za-z0-9_-]{1,128}$'){continue}
     $key=Get-DiagnosticTaskKey -Provider "codex" -TaskId $id -Key $script:diagnosticRuntime.Key
     if($targetKeys.ContainsKey($key) -and -not $known.ContainsKey($key)){$known[$key]=[regex]::Replace(([string](Prop $session "thread_name" "")).Trim(),'\s+',' ')}
    }catch{}
   }
  }catch{}
 }
 $labels=@{};$options=New-Object 'Collections.Generic.List[object]'
 foreach($reference in $references){
  $key=[string]$reference.Key
  $provider=[string]$reference.Provider
  $hasKnown=$known.ContainsKey($key) -and $known[$key]
  $label=if($hasKnown){[string]$known[$key]}elseif($provider -eq "claude"){Tr "Задача Claude Code"}else{Tr "Задача Codex"}
  if($provider -eq "claude" -and $label -ceq "Задача Claude Code"){$label=Tr $label}
  if($provider -eq "codex" -and $hasKnown){$label="$label (Codex)"}
  if($labels.ContainsKey($label)){$labels[$label]++;$label="$label $($labels[$label])"}else{$labels[$label]=1}
  $options.Add([PSCustomObject]@{Key=$key;Label=$label})
 }
 return $options.ToArray()
}

function Render-Journal {
 if(-not $script:showingJournal){return}
 if($null -eq $script:diagnosticRuntime){$journalEventsList.ItemsSource=$null;$journalEmptyText.Text=Tr "Журнал недоступен";$journalEmptyText.Visibility="Visible";return}
 try{
  $filter=if($null -ne $journalTaskFilter.SelectedItem){[string]$journalTaskFilter.SelectedItem.Tag}else{""}
  $path=Join-Path $script:diagnosticDirectory "diagnostic-events-v1.jsonl"
  $fileVersion=if(Test-Path -LiteralPath $path){$file=Get-Item -LiteralPath $path;[string]$file.Length+":"+[string]$file.LastWriteTimeUtc.Ticks}else{"none"}
  $titles=(($script:lastAllTasks|ForEach-Object{"$($_.Provider):$($_.Id):$($_.Title)"}) -join "|")
  $fingerprint=$fileVersion+"|"+$filter+"|"+$titles
  if($fingerprint -eq $script:journalFingerprint){return}
  $settings=$script:diagnosticRuntime.Settings
  $events=@(Read-DiagnosticEvents -Directory $script:diagnosticDirectory -Now ([DateTimeOffset]::UtcNow) -RetentionDays $settings.RetentionDays -MaximumBytes ([long]$settings.MaximumMB*1000000))
  # Storage returns chronological records; the journal displays the newest first.
  [Array]::Reverse($events)
  $references=@([AITaskMonitor.Diagnostics.Policy]::DistinctTasks($events))
  $options=@(Get-JournalTaskOptions $references)
  $script:updatingJournalControls=$true
  try{
   $journalTaskFilter.Items.Clear()
   [void]$journalTaskFilter.Items.Add((New-JournalComboItem (Tr "Все задачи") ""))
   $selected=0
   foreach($option in $options){[void]$journalTaskFilter.Items.Add((New-JournalComboItem $option.Label $option.Key));if($option.Key -eq $filter){$selected=$journalTaskFilter.Items.Count-1}}
   $journalTaskFilter.SelectedIndex=$selected
  }finally{$script:updatingJournalControls=$false}
  $filter=if($null -ne $journalTaskFilter.SelectedItem){[string]$journalTaskFilter.SelectedItem.Tag}else{""}
  $labels=@{
   task_observed="Задача обнаружена";task_started="Работа началась";task_completed="Работа завершена";task_interrupted="Работа прервана";task_unconfirmed="Статус не подтверждён"
   source_unavailable="Источник недоступен";source_recovered="Источник восстановлен";tool_started="Действие началось";tool_finished="Действие завершено";tool_failed="Ошибка действия"
  }
  foreach($key in @($labels.Keys)){$labels[$key]=Tr $labels[$key]}
  $rows=@([AITaskMonitor.Diagnostics.Policy]::MakeRows($events,$filter,$labels))
  $journalEventsList.ItemsSource=$rows
  $journalEmptyText.Text=Tr $(if($filter){"Нет событий для этой задачи"}else{"Пока нет событий"})
  $journalEmptyText.Visibility=$(if($rows.Count -eq 0){"Visible"}else{"Collapsed"})
  $script:journalFingerprint=$fileVersion+"|"+$filter+"|"+$titles
  Update-JournalComboHint $journalTaskFilter
 }catch{$journalEventsList.ItemsSource=$null;$journalEmptyText.Text=Tr "Не удалось открыть журнал";$journalEmptyText.Visibility="Visible"}
}

function Show-JournalView([bool]$keyboardNavigation = $false) {
 if($null -eq $script:diagnosticRuntime){return}
 $expandedView.Visibility="Collapsed";$compactView.Visibility="Collapsed";$settingsView.Visibility="Collapsed";$aboutView.Visibility="Collapsed";$journalView.Visibility="Visible"
 $script:showingSettings=$false;$script:showingAbout=$false;$script:showingJournal=$true;$script:journalFingerprint=""
 Render-Journal
 if($keyboardNavigation){$journalBackButton.Focus()|Out-Null}else{[Windows.Input.Keyboard]::ClearFocus()|Out-Null}
}

function Minimize-ToTaskbar {
 $window.WindowState=[Windows.WindowState]::Minimized
}

function Restore-Window {
 $window.WindowState=[Windows.WindowState]::Normal
 $window.Show()
 $window.Activate()
}

function Invoke-HiddenProviderSetup([string]$configScript,[ValidateSet("Install","Remove")][string]$mode) {
 $powerShell=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) "WindowsPowerShell\v1.0\powershell.exe"
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=$powerShell
 $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$configScript+'" -Mode '+$mode
 $start.WorkingDirectory=Split-Path -Parent $configScript
 $start.UseShellExecute=$false
 $start.CreateNoWindow=$true
 $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $process=[Diagnostics.Process]::Start($start)
 try{$process.WaitForExit();if($process.ExitCode -ne 0){throw "Configuration failed"}}finally{$process.Dispose()}
}

function Filtered-Tasks($tasks){
 if($script:selectedProvider -eq "all"){return @($tasks)}
 return @($tasks|Where-Object {[string]$_.Provider -eq $script:selectedProvider})
}

function Add-ProviderTab([string]$id,[string]$label,[int]$count){
 $button=New-Object Windows.Controls.Button
 $button.Style=$window.Resources["ProviderTabStyle"]
 $button.Tag=$id
 $surfaceGrid=New-Object Windows.Controls.Grid
 $tabShape=New-Object Windows.Shapes.Path
 $tabShape.IsHitTestVisible=$false
 $surfaceGrid.Children.Add($tabShape)|Out-Null
 $contentBorder=New-Object Windows.Controls.Border
 $contentBorder.Padding=New-Object Windows.Thickness(13,0,13,0)
 $content=New-Object Windows.Controls.Grid
 $content.HorizontalAlignment="Center"
 $labelColumn=New-Object Windows.Controls.ColumnDefinition;$labelColumn.Width=[Windows.GridLength]::Auto
 $countColumn=New-Object Windows.Controls.ColumnDefinition;$countColumn.Width=[Windows.GridLength]::Auto
 $content.ColumnDefinitions.Add($labelColumn);$content.ColumnDefinitions.Add($countColumn)
 $selected=$script:selectedProvider -eq $id
 $tabForeground=Brush $script:palette.Primary
 $button.Foreground=$tabForeground
 $labelText=Text $label 13 $script:palette.Secondary "SemiBold"
 $labelText.Foreground=$tabForeground;$labelText.VerticalAlignment="Center";$labelText.TextWrapping="NoWrap"
 $countText=Text $count.ToString() 11.5 $script:palette.Secondary "SemiBold"
 $countText.Foreground=$tabForeground;$countText.Margin=New-Object Windows.Thickness(3,-5,0,0);$countText.VerticalAlignment="Center"
 [Windows.Controls.Grid]::SetColumn($countText,1);$content.Children.Add($labelText)|Out-Null;$content.Children.Add($countText)|Out-Null
 $contentBorder.Child=$content
 $surfaceGrid.Children.Add($contentBorder)|Out-Null
 $button.Content=$surfaceGrid
 $button.DataContext=$tabShape
 $button.Add_SizeChanged({param($sender,$args) if($sender.ActualWidth -gt 0 -and $sender.ActualHeight -gt 0){$sender.DataContext.Data=Provider-TabGeometry $sender.ActualWidth $sender.ActualHeight $script:providerTabRadius}})
 $button.Add_GotKeyboardFocus({param($sender,$args) $sender.BringIntoView()})
 $button.Add_MouseEnter({param($sender,$args) if($script:selectedProvider -ne [string]$sender.Tag){$sender.DataContext.Fill=Brush $script:palette.Hover}})
 $button.Add_MouseLeave({param($sender,$args) if($script:selectedProvider -ne [string]$sender.Tag){$sender.DataContext.Fill=[Windows.Media.Brushes]::Transparent}})
 [Windows.Automation.AutomationProperties]::SetName($button,$(if($script:resolvedLanguage -eq 'en'){"Show tasks: $label, $count"}else{"Показать задачи: $label, $count"}))
 $tabShape.Fill=$(if($selected){Brush $script:palette.Surface}else{[Windows.Media.Brushes]::Transparent})
 $button.Add_Click({param($sender,$args) $script:selectedProvider=[string]$sender.Tag;$script:fingerprint="";Update-View})
 $providerTabsPanel.Children.Add($button)|Out-Null
}

function Update-ProviderTabSizing {
 if(-not $script:providerTabsEqualWidth -or $providerTabsPanel.Children.Count -ne 3 -or $providerTabsHost.ActualWidth -le 0){return}
 $spacing=4.0
 $usable=[Math]::Max(0,$providerTabsHost.ActualWidth-(2*$script:tabPadding)-($spacing*2))
 $width=$usable/3
 foreach($button in $providerTabsPanel.Children){$button.Width=$width}
}

function Render-ProviderTabs($tasks){
 $providers=@($tasks|ForEach-Object{[string]$_.Provider}|Where-Object{$_}|Sort-Object -Unique)
 $script:showProviderLabels=$providers.Count -ge 2
 $script:providerTabsEqualWidth=$providers.Count -eq 2
 if($providers.Count -lt 2){$providerTabsHost.Visibility="Collapsed";$script:selectedProvider="all";$script:providerTabsFingerprint="";return}
 if($script:selectedProvider -ne "all" -and $script:selectedProvider -notin $providers){$script:selectedProvider="all"}
 $definitions=@(@("codex","Codex"),@("claude","Claude Code"),@("kimi","Kimi Code"),@("deepseek","DeepSeek Harness"),@("hermes","Hermes Agent"),@("opencode","OpenCode"))
 $tabState=($definitions|ForEach-Object{if($_[0] -in $providers){$id=$_[0];"${id}:$(@($tasks|Where-Object {$_.Provider -eq $id}).Count)"}})-join '|'
 $tabFingerprint="$script:selectedProvider|$script:resolvedLanguage|$($script:palette.Surface)|$($script:palette.Primary)|$($script:palette.Hover)|$tabState"
 $providerTabsHost.Visibility="Visible"
 $oldOffset=$providerTabsScroll.HorizontalOffset
 if($script:providerTabsFingerprint -eq $tabFingerprint -and $providerTabsPanel.Children.Count -gt 0){return}
 $selectionChanged=$script:providerLastSelected -ne $script:selectedProvider
 $oldFocused=@($providerTabsPanel.Children|Where-Object {$_.IsKeyboardFocusWithin}|Select-Object -First 1)
 $focusedId=if($oldFocused.Count){[string]$oldFocused[0].Tag}else{""}
 $providerTabsPanel.Children.Clear()
 $script:providerTabsFingerprint=$tabFingerprint
 $script:providerLastSelected=$script:selectedProvider
 Add-ProviderTab "all" (Tr "Все") @($tasks).Count
 foreach($definition in $definitions){$id=$definition[0];if($id -in $providers){Add-ProviderTab $id $definition[1] @($tasks|Where-Object {$_.Provider -eq $id}).Count}}
 if($providerTabsPanel.Children.Count -gt 0){$providerTabsPanel.Children[$providerTabsPanel.Children.Count-1].Margin=New-Object Windows.Thickness(0)}
 Update-ProviderTabSizing
 $providerTabsHost.UpdateLayout()
 $providerTabsScroll.ScrollToHorizontalOffset($oldOffset)
 if($selectionChanged){$selectedTab=@($providerTabsPanel.Children|Where-Object {[string]$_.Tag -eq $script:selectedProvider}|Select-Object -First 1);if($selectedTab.Count){$selectedTab[0].BringIntoView()}}
 if($focusedId){$replacement=@($providerTabsPanel.Children|Where-Object {[string]$_.Tag -eq $focusedId}|Select-Object -First 1);if($replacement.Count){$replacement[0].Focus()|Out-Null}}
 Update-SquircleGeometry
}

$providerTabsHost.Add_SizeChanged({Update-ProviderTabSizing;Update-SquircleGeometry})

function Preview-Text([string]$russian,[string]$english) {
 if($script:resolvedLanguage -eq 'en'){return $english}
 return $russian
}

function Update-View {
 try {
  $previousAllTasks=@($script:lastAllTasks)
  $sourceSnapshot=if($PreviewActiveTasks -ge 0){[PSCustomObject]@{Tasks=@();Unavailable=@()}}else{Source-Snapshot}
  $allTasks=@($sourceSnapshot.Tasks)
  $script:sourceErrors=@($sourceSnapshot.Unavailable)
  if($PreviewActiveTasks -ge 0){
   $previewTitles=@((Preview-Text 'Создать индикатор прогресса задач' 'Create a task progress indicator'),(Preview-Text 'Задача Claude Code' 'Claude Code task'),(Preview-Text 'Задача Claude Code' 'Claude Code task'),(Preview-Text 'Задача DeepSeek Harness' 'DeepSeek Harness task'),(Preview-Text 'Задача Hermes Agent' 'Hermes Agent task'),(Preview-Text 'Задача OpenCode' 'OpenCode task'))
   $previewActivities=@((Preview-Text 'Проверяю карточки планов, переключение источников и прокрутку этапов перед публикацией новой версии, светлую тему и поведение длинных описаний' 'Checking plan cards, source filters, scrolling, the light theme and long descriptions before release'),(Preview-Text 'Запускаю визуальную проверку' 'Running visual checks'),(Preview-Text 'Собираю данные для переноса' 'Preparing migration data'),(Preview-Text 'Проверяю план' 'Checking the plan'),(Preview-Text 'Проверяю данные' 'Checking data'),(Preview-Text 'Выполняю действие' 'Performing an action'))
   $previewProgress=@(50,33,$null,$null,$null,$null);$previewKinds=@("exact","exact","none","none","none","none");$previewProviders=@("codex","claude","claude","deepseek","hermes","opencode");$previewProviderNames=@("Codex","Claude Code","Claude Code","DeepSeek Harness","Hermes Agent","OpenCode")
   if($PreviewManyProviders){
    $previewProviders[2]='kimi';$previewProviderNames[2]='Kimi Code'
    foreach($previewIndex in 2..5){
     $previewTitles[$previewIndex]=if($script:resolvedLanguage -eq 'en'){$previewProviderNames[$previewIndex]+' task'}else{'Задача '+$previewProviderNames[$previewIndex]}
     $previewActivities[$previewIndex]=Preview-Text 'Выполняет действие' 'Running an action'
    }
   }
   $allTasks=@()
   for($i=0;$i -lt $PreviewActiveTasks;$i++){
    $previewSteps=$(if($i -eq 0){
     @(
      [PSCustomObject]@{title=(Preview-Text 'Синхронизировать список задач' 'Synchronize the task list');status="done"},
      [PSCustomObject]@{title=(Preview-Text 'Восстановить карточки планов' 'Restore plan cards');status="done"},
      [PSCustomObject]@{title=(Preview-Text 'Исправить прокрутку этапов' 'Fix step scrolling');status="done"},
      [PSCustomObject]@{title=(Preview-Text 'Применить системный акцент' 'Apply the system accent');status="done"},
      [PSCustomObject]@{title=(Preview-Text 'Проверить скругления и фокус' 'Check corners and focus');status="active"},
      [PSCustomObject]@{title=(Preview-Text 'Снять тёмный и светлый экран' 'Capture dark and light screens');status="pending"},
      [PSCustomObject]@{title=(Preview-Text 'Провести финальную проверку' 'Run final checks');status="pending"},
      [PSCustomObject]@{title=(Preview-Text 'Опубликовать исходники' 'Publish the source');status="pending"}
     )
    }elseif($i -eq 1){
     @(
      [PSCustomObject]@{title=(Preview-Text 'Проверить локальное окружение' 'Check the local environment');status="done"},
      [PSCustomObject]@{title=(Preview-Text 'Подготовить тестовые данные' 'Prepare test data');status="done"},
      [PSCustomObject]@{title=(Preview-Text 'Запустить визуальную проверку' 'Run visual checks');status="active"},
      [PSCustomObject]@{title=(Preview-Text 'Проверить светлую тему' 'Check the light theme');status="pending"},
      [PSCustomObject]@{title=(Preview-Text 'Зафиксировать результат' 'Record the result');status="pending"},
      [PSCustomObject]@{title=(Preview-Text 'Очистить временные данные' 'Clear temporary data');status="pending"}
     )
    }else{@()})
    $previewIsUnconfirmed=$PreviewUnconfirmed -and $i -eq 0
    $previewActivity=if($previewIsUnconfirmed){"Статус не подтверждён"}else{$previewActivities[$i]}
    $previewStatus=if($previewIsUnconfirmed){"Статус не подтверждён"}else{"В работе"}
    $previewValue=$previewProgress[$i];$previewKind=$previewKinds[$i]
    if($i -eq 0 -and $PreviewScenario -ne "default"){
     $previewActivity=Preview-Text 'Проверяю стабильность снимков' 'Checking screenshot stability'
     if($PreviewScenario -eq "unplanned"){$previewSteps=@();$previewValue=$null;$previewKind="none"}
    }
    $previewTime=[DateTime]::Now.AddSeconds(-$i)
    $allTasks += [PSCustomObject]@{Id="preview-$i";Title=$previewTitles[$i];Activity=$previewActivity;ActivityGenerated=($PreviewManyProviders -and $i -ge 2);Active=(-not $previewIsUnconfirmed);Paused=$false;Progress=$previewValue;ProgressKind=$previewKind;Provider=$previewProviders[$i];ProviderName=$previewProviderNames[$i];Status=$previewStatus;Updated=$previewTime;Started=$previewTime;StartKey="preview-$i";Steps=$previewSteps;Source="Предпросмотр";PlanConfirmed=(-not ($PreviewPlanUnconfirmed -and $i -eq 0))}
   }
   if($PreviewCloudTask -and $script:codexCloudModulesAvailable){
    $fixture=[PSCustomObject]@{Id='codex-cloud:synthetic';Title=(Preview-Text 'Тестовая облачная задача' 'Synthetic cloud task');State='pending';Updated=[DateTimeOffset]::UtcNow}
    $allTasks+=@(ConvertTo-CodexCloudMonitorTasks @($fixture) (Tr 'Облако: ') (Tr 'Задача Codex') 'Статус не подтверждён')
   }
   if($PreviewKimiTask -and $script:externalProviderModulesAvailable){
    if(-not ('AITaskMonitor.ExternalProviders.StateStore' -as [type])){
     Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
     Add-Type -Path @((Join-Path $PSScriptRoot 'integrations\ProviderEventState.cs'),(Join-Path $PSScriptRoot 'integrations\ProviderEventChannel.cs')) -ReferencedAssemblies System.Web.Extensions -ErrorAction Stop
    }
    $state=[AITaskMonitor.ExternalProviders.StateStore]::new()
    $event=[AITaskMonitor.ExternalProviders.EventParser]::Parse('{"version":1,"provider":"kimi","session":"synthetic","kind":"started"}')
    if($null -eq $event -or -not $state.Apply($event,[DateTimeOffset]::UtcNow)){throw 'Kimi task preview could not be prepared.'}
    $allTasks+=@(Convert-ExternalProviderStates -States @($state.Snapshot([DateTimeOffset]::UtcNow)) -Language $script:resolvedLanguage)
   }
  }
  $ordered=Prioritize-Tasks $allTasks $previousAllTasks $script:compactTaskId
  $allTasks=@($ordered.Tasks);$script:compactTaskId=[string]$ordered.SelectedId
  $script:lastAllTasks=$allTasks
  Sync-ClaudeLoopChannel
  Refresh-Diagnostics $allTasks
  Render-ProviderTabs $allTasks
  $tasks=@(Filtered-Tasks $allTasks)
  $script:lastTasks=$tasks
  $next=$script:selectedProvider+"|"+$script:compactTaskId+"|"+($script:sourceErrors -join ",")+"|"+(($allTasks|ForEach-Object{$stepState=(@($_.Steps)|ForEach-Object{"$(Prop $_ 'title' '')=$(Prop $_ 'status' '')"})-join","; $loop=Get-LoopWarning $_;$loopState=if($null -ne $loop){"$($loop.Threshold):$($loop.WindowMinutes)"}else{"none"}; "$($_.Id):$($_.Provider):$($_.Title):$($_.Active):$($_.ProgressKind):$(Prop $_ 'ProgressBasis' ''):$($_.Progress):$(Prop $_ 'PlanConfirmed' $true):$(Prop $_ 'RetainedPlanIncomplete' $false):$($_.Status):$($_.Activity):$stepState`:$loopState"})-join"|")
  if($next -ne $script:fingerprint){
   $script:fingerprint=$next; $tasksPanel.Children.Clear()
   if($script:sourceErrors.Count -gt 0){$warning=Text ((Tr "Нет данных от ")+($script:sourceErrors -join ", ")) 14 $script:palette.Secondary; $warning.Margin=New-Object Windows.Thickness(4,0,0,12); $tasksPanel.Children.Add($warning)|Out-Null}
   foreach($task in $tasks){Add-Card $task}
   if($tasks.Count -eq 0 -and $script:sourceErrors.Count -eq 0){$empty=Text (Tr "Активных задач сейчас нет") 14 $script:palette.Secondary; $empty.Margin=New-Object Windows.Thickness(4,24,0,0); $tasksPanel.Children.Add($empty)|Out-Null}
   Render-CompactTasks $allTasks
  }
  if($script:showingJournal){Render-Journal}
  if($script:showingSettings -and -not $journalDaysCombo.IsDropDownOpen -and -not $journalSizeCombo.IsDropDownOpen){Update-JournalSettings}
  if($script:showingSettings -and -not $claudeRetentionDaysCombo.IsDropDownOpen -and -not $claudeRetentionSizeCombo.IsDropDownOpen){Update-ClaudeRetentionSettings}
  if($script:showingSettings -and -not $loopThresholdCombo.IsDropDownOpen -and -not $loopWindowCombo.IsDropDownOpen){Update-LoopSettings}
 } catch {
  $tasksPanel.Children.Clear()
  $errorText=Text (Tr "Не удалось обновить задачи") 14 $script:palette.Secondary
  $errorText.Margin=New-Object Windows.Thickness(4,24,0,0)
  $tasksPanel.Children.Add($errorText)|Out-Null
 }
}

$window.Add_MouseLeftButtonDown({if($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed){$window.DragMove()}})
$pinButton.Add_Click({$window.Topmost=$true})
$minimizeButton.Add_Click({Set-CompactMode $true})
$expandButton.Add_Click({Set-CompactMode $false})
$taskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$compactTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$settingsTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$aboutTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$journalTaskbarMinimizeButton.Add_Click({Minimize-ToTaskbar})
$settingsFooterButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$settingsBackButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$settingsFooterButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$settingsBackButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$journalOpenButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$journalBackButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$journalOpenButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$journalBackButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$settingsFooterButton.Add_Click({Show-SettingsView $script:navigationByKeyboard;$script:navigationByKeyboard=$false})
$settingsBackButton.Add_Click({Show-TasksView $script:navigationByKeyboard;$script:navigationByKeyboard=$false})
$aboutSettingsButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$aboutSettingsButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$aboutSettingsButton.Add_Click({Show-AboutView $script:navigationByKeyboard;$script:navigationByKeyboard=$false})
$feedbackEmailLink.Add_Click({Open-FeedbackDraft})
$feedbackCopyButton.Add_Click({Copy-FeedbackEmail})
$aboutBackButton.Add_PreviewMouseLeftButtonDown({$script:navigationByKeyboard=$false;[Windows.Input.Keyboard]::ClearFocus()|Out-Null})
$aboutBackButton.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -in @([Windows.Input.Key]::Enter,[Windows.Input.Key]::Space)){$script:navigationByKeyboard=$true}})
$aboutBackButton.Add_Click({Show-SettingsView $script:navigationByKeyboard $false $true;$script:navigationByKeyboard=$false})
$updateLaterButton.Add_Click({Hide-UpdateForSession})
$updateDownloadButton.Add_Click({Invoke-UpdateDownload})
$updateOverlay.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq [Windows.Input.Key]::Escape){Hide-UpdateForSession;$eventArgs.Handled=$true}})
$updateDialog.Add_SizeChanged({if($updateDialog.ActualWidth -gt 0 -and $updateDialog.ActualHeight -gt 0){$updateDialogShape.Data=Squircle-Geometry $updateDialog.ActualWidth $updateDialog.ActualHeight 16 0.5}})
$journalOpenButton.Add_Click({$journalClearConfirmation.Visibility="Collapsed";Show-JournalView $script:navigationByKeyboard;$script:navigationByKeyboard=$false})
$journalBackButton.Add_Click({Show-SettingsView $script:navigationByKeyboard $true;$script:navigationByKeyboard=$false})
$journalDaysCombo.Add_SelectionChanged({Save-JournalControls})
$journalSizeCombo.Add_SelectionChanged({Save-JournalControls})
$claudeRetentionDaysCombo.Add_SelectionChanged({Save-ClaudeRetentionControls 'claudeRetentionDays' $claudeRetentionDaysCombo})
$claudeRetentionSizeCombo.Add_SelectionChanged({Save-ClaudeRetentionControls 'claudeMaximumMB' $claudeRetentionSizeCombo})
$loopThresholdCombo.Add_SelectionChanged({Save-LoopControls})
$loopWindowCombo.Add_SelectionChanged({Save-LoopControls})
$journalTaskFilter.Add_SelectionChanged({if(-not $script:updatingJournalControls){$script:journalFingerprint="";Render-Journal}})
foreach($combo in @($journalDaysCombo,$journalSizeCombo,$journalTaskFilter,$loopThresholdCombo,$loopWindowCombo,$claudeRetentionDaysCombo,$claudeRetentionSizeCombo)){$combo.Add_SizeChanged({param($sender,$eventArgs) Update-JournalComboHint $sender})}
$journalClearButton.Add_Click({$journalClearConfirmation.Visibility="Visible";Update-JournalSettings;Reveal-JournalSettings})
$journalCancelClearButton.Add_Click({$journalClearConfirmation.Visibility="Collapsed";Update-JournalSettings})
$journalConfirmClearButton.Add_Click({
 try{
  Clear-DiagnosticEvents -Directory $script:diagnosticDirectory
  if($null -ne $script:diagnosticRuntime){$script:diagnosticRuntime.NextCleanup=[DateTimeOffset]::MaxValue}
  else{
   try{$script:diagnosticRuntime=New-DiagnosticRuntime -Directory $script:diagnosticDirectory -Since ([DateTimeOffset]$script:monitorStartedUtc) -Now ([DateTimeOffset]::UtcNow);$script:diagnosticError=""}
   catch{$script:diagnosticError="Журнал очищен, но недоступен"}
  }
  $script:journalUiError="";$script:journalFingerprint=""
 }
 catch{$script:journalUiError="Не удалось очистить журнал"}
 $journalClearConfirmation.Visibility="Collapsed";Update-JournalSettings
})
$systemThemeButton.Add_Click({Apply-Theme "system" $true;Update-View})
$darkThemeButton.Add_Click({Apply-Theme "dark" $true;Update-View})
$lightThemeButton.Add_Click({Apply-Theme "light" $true;Update-View})
$systemLanguageButton.Add_Click({Apply-Language 'system' $true})
$russianLanguageButton.Add_Click({Apply-Language 'ru' $true})
$englishLanguageButton.Add_Click({Apply-Language 'en' $true})
$codexCloudSourceAction.Add_Click({
 if(-not $script:codexCloudModulesAvailable){return}
 $enable=-not $script:codexCloudController.Enabled
 if($enable){
  if(Save-DisplayPreference 'codexCloudEnabled' $true){
   $script:codexCloudPreferenceError=''
   Set-CodexCloudControllerEnabled $script:codexCloudController $true
  }else{$script:codexCloudPreferenceError='Не удалось сохранить настройку облака.'}
 }else{
  Set-CodexCloudControllerEnabled $script:codexCloudController $false
  if(Save-DisplayPreference 'codexCloudEnabled' $false){$script:codexCloudPreferenceError=''}
  else{$script:codexCloudPreferenceError='Не удалось сохранить настройку. Облако может включиться после перезапуска.'}
 }
 Update-CodexCloudSourceSettings
 Update-View
})
$claudeSourceAction.Add_Click({
 $mode=[string]$claudeSourceAction.Tag
 $configScript=Join-Path $PSScriptRoot "Configure-ClaudeIntegration.ps1"
 if(-not (Test-Path -LiteralPath $configScript)){$claudeSourceStatus.Text=Tr "Файл настройки не найден";return}
 try{
  Invoke-HiddenProviderSetup $configScript $mode
  Update-SourceSettings
  Update-View
 }catch{$claudeSourceStatus.Text=Tr "Ошибка подключения"}
})
$openCodeSourceAction.Add_Click({
 $mode=[string]$openCodeSourceAction.Tag
 if($mode -notin @('Install','Remove')){return}
 $configScript=Join-Path $PSScriptRoot 'Configure-OpenCodeIntegration.ps1'
 if(-not (Test-Path -LiteralPath $configScript)){$openCodeSourceStatus.Text=Tr 'Файл настройки не найден';return}
 try{
  Invoke-HiddenProviderSetup $configScript $mode
  Update-SourceSettings
  Update-View
 }catch{$openCodeSourceStatus.Text=Tr 'Ошибка подключения';$openCodeSourceAction.ToolTip=Tr 'Не удалось подтвердить установку или совместимость OpenCode'}
})
$kimiSourceAction.Add_Click({
 if(-not $kimiSourceAction.IsEnabled){return}
 try{
  $path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'integrations\kimi-plugin'))
  if(-not [IO.Directory]::Exists($path)){throw 'Plugin folder unavailable.'}
  if($PreviewSources){$script:kimiPreviewCopied=$path}else{[Windows.Clipboard]::SetText($path)}
  $script:kimiCopyError=''
 }catch{$script:kimiCopyError='Не удалось скопировать путь.'}
 Update-KimiSourceSettings
})
$deepSeekProfileCombo.Add_SelectionChanged({
 if(-not $script:updatingDeepSeekControls){
  if($null -ne $script:deepSeekController){$script:deepSeekController.ActionError=''}
  Update-DeepSeekSourceSettings
 }
})
$deepSeekSourceAction.Add_Click({
 $mode=[string]$deepSeekSourceAction.Tag
 $profile=[string]$deepSeekProfileCombo.SelectedItem
 if($mode -notin @('Install','Remove') -or -not $profile -or $null -eq $script:deepSeekController){return}
 try{Request-DeepSeekProfileConnection $script:deepSeekController $profile ($mode -eq 'Install')}
 catch{$script:deepSeekController.ActionError='operation-failed'}
 Update-DeepSeekSourceSettings
})
$hermesProfileCombo.Add_SelectionChanged({
 if(-not $script:updatingHermesControls){
  $script:hermesCopyError=''
  if($null -ne $script:hermesController){$script:hermesController.ActionError=''}
  Update-HermesSourceSettings
 }
})
foreach($control in @($hermesEnableCommand,$hermesDisableCommand)){
 $copyBinding=[Windows.Input.CommandBinding]::new([Windows.Input.ApplicationCommands]::Copy)
 $copyBinding.Add_CanExecute({
  param($sender,$eventArgs)
  $eventArgs.CanExecute=$sender.IsReadOnly -and -not $sender.Selection.IsEmpty -and [bool]$sender.Selection.Text.TrimEnd([char[]]"`r`n")
  $eventArgs.Handled=$true
 })
 $copyBinding.Add_Executed({
  param($sender,$eventArgs)
  $value=[string]$sender.Selection.Text
  $value=$value.TrimEnd([char[]]"`r`n")
  try{
   if($value){
    if($PreviewSources){$script:hermesPreviewCopiedCommand=$value}else{[Windows.Clipboard]::SetText($value)}
    $script:hermesCopyError=''
   }
  }catch{$script:hermesCopyError='Не удалось скопировать команду.'}
  $eventArgs.Handled=$true
  Update-HermesSourceSettings
 })
 [void]$control.CommandBindings.Add($copyBinding)
}
$hermesSourceAction.Add_Click({
 if(-not $hermesSourceAction.IsEnabled -or $null -eq $script:hermesController){return}
 $selected=[string]$hermesProfileCombo.SelectedItem
 $matches=@($script:hermesController.Profiles | Where-Object {(Test-HermesUiProfile $_) -and [string]$_.Name -ceq $selected -and [string]$_.State -ceq 'absent'})
 if($matches.Count -ne 1){return}
 $profileId=[string]$matches[0].Id
 try{
  if($PreviewSources){$script:hermesPreviewRequest=$profileId}
  else{Request-HermesProfilePrepare $script:hermesController $profileId}
 }catch{$script:hermesController.ActionError='operation-failed'}
 Update-HermesSourceSettings
})
$closeButton.Add_Click({$window.Close()})
$compactCloseButton.Add_Click({$window.Close()})
$settingsCloseButton.Add_Click({$window.Close()})
$aboutCloseButton.Add_Click({$window.Close()})
$journalCloseButton.Add_Click({$window.Close()})
$windowFrame.Add_SizeChanged({Update-SquircleGeometry})
$tray=New-Object Windows.Forms.NotifyIcon; $tray.Icon=if($null -ne $script:applicationIcon){$script:applicationIcon}else{[Drawing.SystemIcons]::Application}; $tray.Text="AI task monitor"; $tray.Visible=$true; $tray.Add_DoubleClick({Restore-Window})
$menu=New-Object Windows.Forms.ContextMenuStrip; $script:trayShowMenu=$menu.Items.Add("Развернуть"); $script:trayExitMenu=$menu.Items.Add("Выход"); $script:trayShowMenu.Add_Click({Restore-Window;Set-CompactMode $false}); $script:trayExitMenu.Add_Click({$window.Close()}); $tray.ContextMenuStrip=$menu
$timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[TimeSpan]::FromSeconds(2); $timer.Add_Tick({Refresh-SystemTheme;Refresh-ActivityMotion;Update-View;if(-not $SnapshotFile -and $PreviewActiveTasks -lt 0){Schedule-ClaudeRetention;Invoke-UpdateCheckTick}}); $timer.Start(); $window.Add_Closed({$timer.Stop();if($script:claudeRetentionAvailable){[AITaskMonitor.Claude.Retention]::WaitForStop(2000)};Stop-UpdateCheck;if($null -ne $script:claudeLoopChannel){try{$script:claudeLoopChannel.Dispose()}catch{};$script:claudeLoopChannel=$null};if($null -ne $script:externalProviderController){try{Stop-ExternalProviderController $script:externalProviderController}catch{}};if($script:kimiModulesAvailable){Stop-KimiMonitorController $script:kimiController};if($script:hermesModulesAvailable -and -not $PreviewSources){try{Stop-HermesMonitorController $script:hermesController}catch{}};if($script:codexCloudModulesAvailable){Set-CodexCloudControllerEnabled $script:codexCloudController $false};$script:claudeLoopStates.Clear();$tray.Visible=$false;$tray.Dispose();if($null -ne $script:applicationIcon){$script:applicationIcon.Dispose()}})
if($script:codexCloudModulesAvailable -and -not $SnapshotFile -and $PreviewActiveTasks -lt 0 -and (Load-CodexCloudEnabled)){Set-CodexCloudControllerEnabled $script:codexCloudController $true}
$initialTheme=if($ThemeOverride){$ThemeOverride}else{Load-ThemeMode}
Apply-Theme $initialTheme $false
if($script:diagnosticModulesAvailable -and (($PreviewActiveTasks -lt 0 -and -not $SnapshotFile) -or $DiagnosticDirectory)){
 try{$script:diagnosticRuntime=New-DiagnosticRuntime -Directory $script:diagnosticDirectory -Since ([DateTimeOffset]$script:monitorStartedUtc) -Now ([DateTimeOffset]::UtcNow);$script:diagnosticError=""}
 catch{$script:diagnosticError="Журнал недоступен";if($PreviewStartupReadyFile){$script:previewDiagnosticFailure=$_.Exception.ToString()}}
}
$initialLanguage=if($LanguageOverride){$LanguageOverride}elseif($SnapshotFile -or $PreviewActiveTasks -ge 0){'ru'}else{Load-LanguageMode}
Apply-Language $initialLanguage $false
Schedule-ClaudeRetention
if($PreviewStartupReadyFile){
 $probe=[IO.File]::Open($probePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try{$probe.WriteByte(1)}finally{$probe.Dispose()}
 Start-Sleep -Milliseconds $PreviewStartupDelayMilliseconds
}
Refresh-ActivityMotion
Update-View
if($PreviewStartupReadyFile){
 $previewResult=[ordered]@{
  diagnosticModulesAvailable=$script:diagnosticModulesAvailable;diagnosticRuntimeAvailable=($null -ne $script:diagnosticRuntime)
  diagnosticFailure=$script:previewDiagnosticFailure;diagnosticStatus=$script:diagnosticError;claudeReaderAvailable=[bool]("AITaskMonitor.Claude.Reader" -as [type]);claudeReaderFailure=$script:previewReaderFailure
  claudeTaskCount=$script:lastClaudeTasks.Count;codexTaskCount=$script:lastCodexTasks.Count;sourceErrors=@($script:sourceErrors)
 }
 [IO.File]::WriteAllText(($probePath+".result.json"),($previewResult|ConvertTo-Json -Compress -Depth 4),[Text.UTF8Encoding]::new($false))
}
if($CompactMode){Set-CompactMode $true}
if($PreviewAbout){Show-AboutView}
if($PreviewUpdate){$script:availableUpdate=[PSCustomObject]@{Version='0.3.0-alpha';Url='https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0-alpha/AITaskMonitor.exe'};Show-PendingUpdate}
if ($SnapshotFile) {
 if($PreviewOffscreen){$window.WindowStartupLocation="Manual";$window.Left=-10000;$window.Top=-10000;$window.ShowActivated=$false;$window.ShowInTaskbar=$false}
 $window.Show(); $window.UpdateLayout()
 if($PreviewTabsUiTest){
  if($providerTabsPanel.Children.Count -ne 7 -or $providerTabsScroll.ScrollableWidth -le 0){throw 'The six-provider tab row must overflow in one scrollable row.'}
  $providerTabsScroll.ScrollToHorizontalOffset($providerTabsScroll.ScrollableWidth);$window.UpdateLayout()
  $endOffset=$providerTabsScroll.HorizontalOffset
  if($endOffset -le 0){throw 'The provider tab row did not scroll horizontally.'}
  $lastTab=@($providerTabsPanel.Children|Where-Object {[string]$_.Tag -eq 'opencode'}|Select-Object -First 1)
  if($lastTab.Count -ne 1){throw 'The last provider tab is missing.'}
  $lastTab[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$window.UpdateLayout()
  if($script:selectedProvider -ne 'opencode' -or @($script:lastTasks).Count -ne 1 -or $providerTabsScroll.HorizontalOffset -le 0){throw 'The last provider tab did not select its task while remaining visible.'}
  $expectedTitle=if($script:resolvedLanguage -eq 'en'){'OpenCode task'}else{'Задача OpenCode'}
  $expectedActivity=Tr 'Выполняет действие'
  if((Localized-TaskTitle $script:lastTasks[0]) -cne $expectedTitle -or (Localized-TaskActivity $script:lastTasks[0]) -cne $expectedActivity){throw 'The generated provider preview is not localized.'}
  Update-View;$window.UpdateLayout()
  if($providerTabsScroll.HorizontalOffset -le 0){throw 'Refreshing the tasks reset the horizontal tab scroll.'}
  Write-Output 'Provider tabs: overflow, selection and scroll preservation verified.'
 }
 if($PreviewPlanUiTest){
  if($script:resolvedLanguage -eq 'en'){
   if((Plan-StepCount 1) -cne '1 step' -or (Plan-StepCount 2) -cne '2 steps'){throw 'English step-count forms differ.'}
  }elseif((Plan-StepCount 1) -cne '1 этап' -or (Plan-StepCount 2) -cne '2 этапа' -or (Plan-StepCount 11) -cne '11 этапов' -or (Plan-StepCount 21) -cne '21 этап'){throw 'Russian step-count forms differ.'}
  function Find-PlanText($parent,[string]$expected){
   if($parent -is [Windows.Controls.TextBlock] -and $parent.Text -ceq $expected -and $parent.IsVisible){return $true}
   for($index=0;$index -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);$index++){
    if(Find-PlanText ([Windows.Media.VisualTreeHelper]::GetChild($parent,$index)) $expected){return $true}
   }
   return $false
  }
  $root=if($script:isCompact){$compactTasksPanel}else{$tasksPanel}
  $expectedProgress=if($script:resolvedLanguage -eq 'en'){'Step 5 of 8'}else{'Этап 5 из 8'}
  if(-not $PreviewPlanUnconfirmed -and -not (Find-PlanText $root $expectedProgress)){throw 'The current plan step is not displayed.'}
  if($PreviewPlanUnconfirmed -and (Find-PlanText $root $expectedProgress)){throw 'An unconfirmed plan must not claim a current step.'}
  if($PreviewPlanUnconfirmed){
   $expected=if($script:isCompact){Tr 'План не подтверждён'}else{(Tr 'План не подтверждён')+' · 8'+(Tr ' этапов')+' · '+$script:lastAllTasks[0].Updated.ToString('HH:mm')}
   if(-not (Find-PlanText $root $expected)){throw 'The previous plan is not visibly marked unconfirmed.'}
  }
  Write-Output 'Plan UI: current step and confirmation state verified.'
 }
 if($PreviewLanguageUiTest){
  $sourceTask=[PSCustomObject]@{Provider='codex';Title='Моя исходная задача';Activity='Моё исходное описание';ActivityGenerated=$false;Status='В работе'}
  Show-SettingsView
  $englishLanguageButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if((Load-LanguageMode) -ne 'en' -or $window.FindName('SettingsHeading').Text -cne 'Settings' -or $window.FindName('LanguageHeading').Text -cne 'Language'){throw 'English selection did not update and persist the settings UI.'}
  $englishPreview=@($script:lastAllTasks | Where-Object Id -eq 'preview-0')
  if($englishPreview.Count -ne 1 -or $englishPreview[0].Title -cne 'Create a task progress indicator'){throw 'The synthetic task did not follow the selected language.'}
  if((Localized-TaskTitle $sourceTask) -cne $sourceTask.Title -or (Localized-TaskActivity $sourceTask) -cne $sourceTask.Activity){throw 'Language selection changed source task text.'}
  Apply-Theme 'light' $true
  if((Load-LanguageMode) -ne 'en'){throw 'Saving a theme overwrote the language preference.'}
  $russianLanguageButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if((Load-LanguageMode) -ne 'ru' -or $window.FindName('SettingsHeading').Text -cne 'Настройки'){throw 'Russian selection did not update and persist the settings UI.'}
  $systemLanguageButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if((Load-LanguageMode) -ne 'system' -or $script:resolvedLanguage -ne (Resolve-Language 'system')){throw 'System language selection did not persist or resolve correctly.'}
  $claudeRetentionDaysCombo.SelectedIndex=29
  $claudeRetentionSizeCombo.SelectedIndex=99
  $retention=Load-ClaudeRetentionSettings
  if(-not $retention.Valid -or $retention.Days -ne 30 -or $retention.MaximumMB -ne 100 -or (Load-LanguageMode) -ne 'system'){throw 'Claude retention controls did not save independent values.'}
  Apply-Theme $initialTheme $false
  Apply-Language $initialLanguage $false
  Show-TasksView
  $window.UpdateLayout()
  Write-Output 'Language UI: live switching, system mode, persistence and untouched task text verified.'
 }
 if($PreviewMotionUiTest){
  function Find-MotionElement($parent,[string]$kind,[string]$expected){
   if($kind -eq "indicator" -and $parent -is [Windows.Controls.Canvas] -and $parent.Tag -ceq "ActivityIndicator" -and $parent.IsVisible){return $parent}
   if($kind -eq "text" -and $parent -is [Windows.Controls.TextBlock] -and $parent.Text -ceq $expected -and $parent.IsVisible){return $parent}
   for($index=0;$index -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);$index++){
    $found=Find-MotionElement ([Windows.Media.VisualTreeHelper]::GetChild($parent,$index)) $kind $expected
    if($null -ne $found){return $found}
   }
   return $null
  }
  $previewRoot=if($script:isCompact){$compactTasksPanel}else{$tasksPanel}
  $indicator=Find-MotionElement $previewRoot "indicator" ""
  $activity=Find-MotionElement $previewRoot "text" ([string]$script:lastAllTasks[0].Activity)
  $title=Find-MotionElement $previewRoot "text" ([string]$script:lastAllTasks[0].Title)
  if($null -eq $indicator -or $null -eq $activity -or $null -eq $title){throw "The task activity indicator, action or title is missing."}
  if($script:isCompact){
   if($title.FontSize -ne 16){throw "The compact task title must use a 16 DIP font."}
   $expectedLabel=Progress-Label $script:lastAllTasks[0]
   if($expectedLabel){$label=Find-MotionElement $previewRoot "text" $expectedLabel;if($null -eq $label -or $label.FontSize -ne 16){throw "The compact progress label must match the title font size."}}
  }
  if($script:isCompact -and $compactTasksPanel.Children[0].Children[0].Children.Count -ne 2){throw "The previous title indicator was not removed."}
  $mark=$indicator.Children[0];$geometry=$mark.Data
  $expectAnimation=[bool]$script:lastAllTasks[0].Active -and $script:motionEnabled
  if($geometry -isnot [Windows.Media.RectangleGeometry] -or $geometry.RadiusX -ne 2 -or $geometry.RadiusY -ne 2 -or -not $mark.RenderTransform.Value.IsIdentity){throw "The activity indicator must retain circular ends while moving."}
  if($geometry.HasAnimatedProperties -ne $expectAnimation){throw "The activity animation does not match task state."}
  $markPoint=$indicator.TranslatePoint([Windows.Point]::new(0,0),$window);$textPoint=$activity.TranslatePoint([Windows.Point]::new(0,0),$window);$titlePoint=$title.TranslatePoint([Windows.Point]::new(0,0),$window)
  if([Math]::Abs($indicator.Width-16) -gt 0.01 -or [Math]::Abs($indicator.Height-4) -gt 0.01 -or [Math]::Abs($markPoint.X-$titlePoint.X) -gt 0.5 -or [Math]::Abs(($markPoint.X+22)-$textPoint.X) -gt 0.5 -or $markPoint.Y -le $titlePoint.Y){throw "The 16 by 4 px activity indicator must align under the title and precede the action."}
  $opticalCenter=$textPoint.Y+[Math]::Min($activity.ActualHeight,$activity.LineHeight)/2+1
  if([Math]::Abs(($markPoint.Y+2)-$opticalCenter) -gt 1){throw "The activity indicator is not optically aligned with the first text line."}
  Write-Output "Activity motion UI: placement, task state and motion preference verified."
 }
 if($PreviewActivityUiTest){
  if($script:lastAllTasks.Count -ne 1 -or $script:lastAllTasks[0].Activity -ne (Preview-Text 'Проверяю стабильность снимков' 'Checking screenshot stability')){throw "The preview task did not expose its current activity."}
  $stepCount=@($script:lastAllTasks[0].Steps | Where-Object {$null -ne $_}).Count
  if($PreviewScenario -eq "planned" -and $stepCount -eq 0){throw "The planned preview has no steps."}
  if($PreviewScenario -eq "unplanned" -and ($stepCount -ne 0 -or $script:lastAllTasks[0].ProgressKind -ne "none")){throw "The unplanned preview invented a plan or percentage."}
  function Find-PreviewActivity($parent){
   if($parent -is [Windows.Controls.TextBlock] -and $parent.Text -eq (Preview-Text 'Проверяю стабильность снимков' 'Checking screenshot stability') -and $parent.IsVisible){return $true}
   for($index=0;$index -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);$index++){
    if(Find-PreviewActivity ([Windows.Media.VisualTreeHelper]::GetChild($parent,$index))){return $true}
   }
   return $false
  }
  if(-not (Find-PreviewActivity $(if($script:isCompact){$compactTasksPanel}else{$tasksPanel}))){throw "The current activity is not visible in the task view."}
  Write-Output "Activity UI: short current status and requested plan mode verified."
 }
 if($PreviewFocusUiTest){
  $PreviewUnconfirmed=$true;$script:fingerprint="";Update-View
  if($script:lastAllTasks.Count -ne 1 -or $script:lastAllTasks[0].Active){throw "The unconfirmed preview was not prepared."}
  $script:compactTaskId="preview-0";$script:selectedProvider="codex";$PreviewActiveTasks=2
  $script:fingerprint="";Update-View;$window.UpdateLayout()
  if($script:compactTaskId -ne "preview-1" -or $script:lastAllTasks[0].Id -ne "preview-1"){throw "A new task did not take compact focus and first position."}
  if($script:lastTasks.Count -ne 1 -or $script:lastTasks[0].Id -ne "preview-0"){throw "The expanded provider filter was not preserved."}
  $script:compactTaskId="preview-0";Update-View
  if($script:compactTaskId -ne "preview-0"){throw "A normal refresh changed the user's manual compact selection."}
  $script:compactTaskId="preview-1";Render-CompactTasks $script:lastAllTasks;$window.UpdateLayout()
  Write-Output "Compact focus UI: new task, provider isolation and manual selection verified."
 }
 if($PreviewUpdateUiTest){
  if($updateOverlay.Visibility -ne 'Visible' -or $updateVersionText.Text -ne 'Версия 0.3.0-alpha доступна для скачивания'){throw 'Update dialog content is incorrect.'}
  $updateLaterButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  Show-PendingUpdate
  if($updateOverlay.Visibility -ne 'Collapsed'){throw 'Dismissed update returned during this session.'}
  $script:dismissedUpdate='';Set-CompactMode $true;Show-PendingUpdate
  if($updateOverlay.Visibility -ne 'Collapsed'){throw 'Update appeared while compact.'}
  Set-CompactMode $false
  if($updateOverlay.Visibility -ne 'Visible'){throw 'Deferred update did not appear after expanding.'}
  $bad=[PSCustomObject]@{Version='9.0.0';Url='https://evil.example/setup.exe'}
  $script:availableUpdate=$bad;Invoke-UpdateDownload
  if($updateOpenError.Visibility -ne 'Visible'){throw 'Untrusted download URL was not rejected.'}
  $script:availableUpdate=$null;$script:dismissedUpdate='';$updateOverlay.Visibility='Collapsed'
  $previewJson='[{"tag_name":"v0.3.0-alpha","draft":false,"assets":[{"name":"app.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0-alpha/app.exe"}]}]'
  $previewFoundRelease=Find-PlatformUpdate $previewJson $script:currentVersion 'windows'
  $script:updateParser=[PowerShell]::Create()
  [void]$script:updateParser.AddScript('param($update) [PSCustomObject]@{Update=$update}').AddArgument($previewFoundRelease)
  $script:updateParserRequest=$script:updateParser.BeginInvoke()
  if(-not $script:updateParserRequest.AsyncWaitHandle.WaitOne(3000)){throw 'Synthetic update parser timed out.'}
  Invoke-UpdateCheckTick
  if($updateOverlay.Visibility -ne 'Visible' -or $script:availableUpdate.Version -ne '0.3.0-alpha'){throw 'Asynchronous release result did not reach the dialog.'}
  $window.UpdateLayout()
  Write-Output 'Update UI: asynchronous result, copy, link rejection, dismissal and compact deferral verified.'
 }
 if($PreviewAboutUiTest){
  $expectedVersion=$(if($script:resolvedLanguage -eq 'en'){'AI task monitor · version '}else{'AI task monitor · версия '})+$script:currentVersion.Replace('-',' ')
  $expectedProviders=if($script:resolvedLanguage -eq 'en'){'AI Task Monitor shows tasks and available progress information. Local sources: Codex, Claude Code, OpenCode, DeepSeek Harness, Kimi Code and Hermes Agent. Codex cloud tasks are also available with unconfirmed status.'}else{'AI Task Monitor показывает задачи и доступные сведения об их ходе. Локальные источники: Codex, Claude Code, OpenCode, DeepSeek Harness, Kimi Code и Hermes Agent. Для Codex также доступны облачные задачи с неподтверждённым статусом.'}
  if($aboutView.Visibility -ne "Visible" -or $aboutHeading.Text -ne (Tr 'О приложении') -or $aboutVersionText.Text -ne $expectedVersion -or
     $aboutProviders.Text -cne $expectedProviders){
   throw "The About page does not expose the expected content."
  }
  $aboutBackButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($settingsView.Visibility -ne "Visible" -or $aboutView.Visibility -ne "Collapsed"){throw "The About back action did not return to settings."}
  $feedbackEmailBox.SelectAll()
  if($feedbackEmailBox.Selection.Text.Trim() -cne 'truea.k.a.ru@gmail.com'){throw 'The feedback address cannot be selected for copying.'}
  $window.UpdateLayout()
  $emailFirst=$feedbackEmailLink.ContentStart.GetCharacterRect([Windows.Documents.LogicalDirection]::Forward)
  $emailLast=$feedbackEmailLink.ContentEnd.GetCharacterRect([Windows.Documents.LogicalDirection]::Backward)
  if($feedbackEmailBox.ActualWidth -lt 100 -or [Math]::Abs($emailFirst.Top-$emailLast.Top) -gt 1){throw 'The feedback address must remain on a single line.'}
  $copyPosition=$feedbackCopyButton.TranslatePoint([Windows.Point]::new(0,0),$settingsScroll)
  $emailEnd=$feedbackEmailBox.TranslatePoint([Windows.Point]::new($emailLast.Right,0),$settingsScroll)
  $glyphPosition=$feedbackCopyGlyph.TranslatePoint([Windows.Point]::new(0,0),$settingsScroll)
  $glyphTypeface=[Windows.Media.Typeface]::new($feedbackCopyGlyph.FontFamily,$feedbackCopyGlyph.FontStyle,$feedbackCopyGlyph.FontWeight,$feedbackCopyGlyph.FontStretch)
  $glyphMetrics=[Windows.Media.FormattedText]::new($feedbackCopyGlyph.Text,[Globalization.CultureInfo]::CurrentUICulture,[Windows.FlowDirection]::LeftToRight,$glyphTypeface,$feedbackCopyGlyph.FontSize,[Windows.Media.Brushes]::Black,[Windows.Media.VisualTreeHelper]::GetDpi($window).PixelsPerDip)
  $glyphInk=$glyphMetrics.BuildGeometry([Windows.Point]::new(0,0)).Bounds
  $glyphTextOffset=if($feedbackCopyGlyph.TextAlignment -eq [Windows.TextAlignment]::Center){($feedbackCopyGlyph.ActualWidth-$glyphMetrics.WidthIncludingTrailingWhitespace)/2}else{0}
  $glyphInkLeft=$glyphPosition.X+$glyphTextOffset+$glyphInk.Left
  $glyphInkCenter=$glyphInkLeft+$glyphInk.Width/2
  $glyphInkCenterY=$glyphPosition.Y+$glyphInk.Top+$glyphInk.Height/2
  if([Math]::Abs(($glyphInkLeft-$emailEnd.X)-16) -gt 2){throw 'The feedback copy icon must be 16 pixels from the email text.'}
  if([Math]::Abs($glyphInkCenter-($copyPosition.X+$feedbackCopyButton.ActualWidth/2)) -gt 1){throw 'The feedback copy icon must be centered in its button.'}
  if([Math]::Abs($glyphInkCenterY-($copyPosition.Y+$feedbackCopyButton.ActualHeight/2)) -gt 1){throw 'The feedback copy icon must be vertically centered in its button.'}
  if($feedbackCopyButton.ActualWidth -lt 24 -or $copyPosition.X -lt 0 -or $copyPosition.X+$feedbackCopyButton.ActualWidth -gt $settingsScroll.ViewportWidth+1){throw 'The feedback copy action is clipped.'}
  if([Windows.Automation.AutomationProperties]::GetName($feedbackCopyButton) -cne (Tr 'Скопировать адрес') -or -not $feedbackCopyButton.IsTabStop){throw 'The feedback copy action is not accessible.'}
  $script:previewClipboardText='';$script:previewClipboardFailure=$false
  $feedbackCopyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($script:previewClipboardText -cne 'truea.k.a.ru@gmail.com'){throw 'The copy action did not request the feedback address.'}
  $script:previewClipboardFailure=$true
  $feedbackCopyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($feedbackError.Visibility -ne 'Visible' -or $feedbackError.Text -cne (Tr 'Не удалось скопировать адрес. Выделите его и скопируйте вручную.')){throw 'A clipboard error was not shown.'}
  $script:previewClipboardFailure=$false;$feedbackError.Visibility='Collapsed'
  $script:previewFeedbackClicks=0
  $feedbackEmailLink.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
  if($script:previewFeedbackClicks -ne 1){throw 'The feedback address does not open the feedback action.'}
  if((Get-FeedbackUri) -notmatch '^mailto:truea\.k\.a\.ru@gmail\.com\?subject=' -or (Get-FeedbackUri) -match '&body='){throw "The feedback draft is not private or correctly addressed."}
  if($script:isStoreEdition){
   if(-not $aboutUpdatesText.Text.Contains('Microsoft Store') -or $aboutUpdatesText.Text.Contains('GitHub')){throw 'Store edition update description is incorrect.'}
   Invoke-UpdateCheckTick
   if($null -ne $script:updateCancellation -or $null -ne $script:updateRequest){throw 'Store edition must not request GitHub updates.'}
  }elseif(-not $aboutUpdatesText.Text.Contains('GitHub')){throw 'Standalone update description is incorrect.'}
  if($settingsView.Visibility -ne "Visible" -or $aboutView.Visibility -ne "Collapsed"){throw "Settings and About cannot be visible together."}
  $aboutSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($aboutView.Visibility -ne "Visible" -or $settingsView.Visibility -ne "Collapsed"){throw "The About entry did not open the page."}
  $window.Height=520; $window.UpdateLayout()
  $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
  $window.UpdateLayout()
  if($aboutScroll.ScrollableHeight -le 0){throw "About content must scroll in a small window."}
  $aboutScroll.ScrollToEnd();$window.UpdateLayout()
  if($aboutScroll.VerticalOffset -le 0){throw "About scrolling did not reach the content."}
  $window.Height=760; Show-AboutView; $window.UpdateLayout()
  Write-Output "About UI: content, navigation, isolation and small-window scrolling verified."
 }
 if($PreviewIconUiTest){
  if(-not $script:shellIdentityAvailable -or $null -eq $window.Icon){throw "Application icon or shell identity is unavailable."}
  $handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
  if([AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle,5) -cne [AITaskMonitor.Windows.AppShellIdentity]::AppId){throw "The application window has no taskbar identity."}
  if([AITaskMonitor.Windows.AppShellIdentity]::ReadProperty($handle,3) -cne ($iconPath+",0")){throw "The application window has no taskbar icon resource."}
  foreach($titleIconName in @("ExpandedTitleIcon","CompactTitleIcon")){
   $titleIcon=$window.FindName($titleIconName)
   if($titleIcon.Visibility -ne "Visible" -or $null -eq $titleIcon.Source -or $titleIcon.Width -ne 16 -or $titleIcon.Height -ne 16){throw "The title-bar icon is unavailable."}
  }
  Write-Output "Application icon: window identity and both title-bar icons verified in the real WPF view."
 }
 if($PreviewClaudeLoopUiTest){
  if($null -eq $script:claudeLoopChannel -or $null -eq $script:diagnosticRuntime){throw 'The synthetic Claude loop channel is unavailable.'}
  function Send-PreviewClaudeLoop([string]$session,[int]$number,[string]$kind){
   $testEvent=[PSCustomObject]@{
    session_id=$session;tool_use_id=('synthetic-'+$session+'-'+$number);tool_name='Bash';cwd='synthetic-private-project'
    tool_input=[PSCustomObject]@{command='synthetic-private-command'};is_interrupt=$false;error="Exit code 7`nsynthetic-private-output"
    hook_event_name=$(if($kind -eq 'start'){'PreToolUse'}else{'PostToolUseFailure'})
   }
   $hookStart=[Diagnostics.ProcessStartInfo]::new()
   $hookStart.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
   $hookStart.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'ClaudeTaskHook.ps1')+'" -LoopTestPipe '+$PreviewClaudeLoopPipe
   $hookStart.UseShellExecute=$false;$hookStart.CreateNoWindow=$true
   $hookStart.RedirectStandardInput=$true;$hookStart.RedirectStandardOutput=$true;$hookStart.RedirectStandardError=$true
   $hookStart.EnvironmentVariables['LOCALAPPDATA']=$previewDataPath
   $hookStart.EnvironmentVariables['AI_TASK_MONITOR_AUDIT']='1'
   $hookStart.EnvironmentVariables['AI_TASK_MONITOR_AUDIT_CHANNEL']='1'
   $hook=[Diagnostics.Process]::Start($hookStart)
   try{
    $hook.StandardInput.WriteLine(($testEvent|ConvertTo-Json -Compress -Depth 4));$hook.StandardInput.Close()
    if(-not $hook.WaitForExit(5000) -or $hook.ExitCode -ne 0 -or $hook.StandardOutput.ReadToEnd()){throw 'The synthetic Claude hook failed.'}
    $transportAudit=$hook.StandardError.ReadToEnd().Trim()
   }finally{$hook.Dispose()}
   $watch=[Diagnostics.Stopwatch]::StartNew()
   do{
    Sync-ClaudeLoopChannel
    if($script:claudeLoopStates.ContainsKey($session)){
     $state=$script:claudeLoopStates[$session]
     if(($kind -eq 'start' -and $state.InFlight.ContainsKey($testEvent.tool_use_id)) -or ($kind -eq 'failed' -and $state.Times.Count -eq $number)){return}
    }
    Start-Sleep -Milliseconds 15
   }while($watch.ElapsedMilliseconds -lt 2000)
   throw ('A synthetic Claude loop event was not applied: session='+$session+' kind='+$kind+' number='+$number+' transport='+$transportAudit)
  }
  for($number=1;$number -le 5;$number++){
   Send-PreviewClaudeLoop 'preview-1' $number 'start'
   Send-PreviewClaudeLoop 'preview-1' $number 'failed'
  }
  if(-not $script:claudeLoopStates['preview-1'].Warning){throw 'The Claude warning did not reach the task.'}
  if($PreviewActiveTasks -ge 3){
   for($number=1;$number -le 3;$number++){
    Send-PreviewClaudeLoop 'preview-2' $number 'start'
    Send-PreviewClaudeLoop 'preview-2' $number 'failed'
   }
   if($script:claudeLoopStates['preview-2'].Warning){throw 'A separate Claude session received the warning.'}
  }
  $script:fingerprint='';Update-View
  if($script:isCompact){$script:compactTaskId='preview-1';Render-CompactTasks $script:lastAllTasks}
  $window.UpdateLayout()
  $claudeTask=@($script:lastTasks|Where-Object {$_.Provider -eq 'claude' -and $_.Id -eq 'preview-1'})
  if($claudeTask.Count -ne 1 -or $null -eq (Get-LoopWarning $claudeTask[0])){throw 'The Claude task did not expose its warning.'}
  $realId=$claudeTask[0].PSObject.Copy();$realId.Id='claude:preview-1'
  if($null -eq (Get-LoopWarning $realId)){throw 'The real Claude task identifier did not expose its warning.'}
  $inactive=$claudeTask[0].PSObject.Copy();$inactive.Active=$false
  if($null -ne (Get-LoopWarning $inactive)){throw 'An unconfirmed task exposed a live warning.'}
  function Find-ClaudeLoopDismiss($parent){
   if($parent -is [Windows.Controls.Button] -and $parent.IsVisible -and [Windows.Automation.AutomationProperties]::GetName($parent).StartsWith('Скрыть предупреждение о возможном цикле')){return $parent}
   for($index=0;$index -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);$index++){
    $match=Find-ClaudeLoopDismiss ([Windows.Media.VisualTreeHelper]::GetChild($parent,$index))
    if($null -ne $match){return $match}
   }
   return $null
  }
  $dismiss=Find-ClaudeLoopDismiss $window
  if($null -eq $dismiss){throw 'The Claude warning action is not visible.'}
  $dismiss.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if(-not $script:claudeLoopStates['preview-1'].Dismissed -or $null -ne (Get-LoopWarning $claudeTask[0])){throw 'The Claude warning did not dismiss.'}
  $script:claudeLoopStates['preview-1'].Dismissed=$false;$script:fingerprint='';Update-View;$window.UpdateLayout()
  Write-Output 'Claude loop UI: warning, session isolation and dismissal verified.'
 }
 if($PreviewJournalRecoveryUiTest){
  Show-SettingsView
  Reveal-JournalSettings
  $window.UpdateLayout()
  if($null -ne $script:diagnosticRuntime -or -not $journalClearButton.IsEnabled){throw "A failed journal must leave the confirmed-clear action available."}
  if($JournalRecoverySnapshotFile){
   $recoveryWidth=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth));$recoveryHeight=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
   $recoveryBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($recoveryWidth,$recoveryHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
   $recoveryBitmap.Render($window)
   $recoveryEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
   $recoveryEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($recoveryBitmap))
   $recoveryStream=[IO.File]::Create($JournalRecoverySnapshotFile)
   try{$recoveryEncoder.Save($recoveryStream)}finally{$recoveryStream.Dispose()}
  }
  $journalClearButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($journalClearConfirmation.Visibility -ne "Visible"){throw "Journal clearing must require confirmation."}
  $journalConfirmClearButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($null -eq $script:diagnosticRuntime -or $script:diagnosticError -or $script:journalUiError){throw "Journal access did not recover after confirmed clearing."}
  Show-TasksView
  Write-Output "Journal recovery UI: confirmation and restored access verified."
 }
 if($PreviewLoopUiTest){
  if($PreviewActiveTasks -lt 1 -or -not $PreviewLoopWarning -or -not $DiagnosticDirectory -or $null -eq $script:diagnosticRuntime){throw "Loop UI tests require synthetic tasks and an isolated diagnostic directory."}
  function Find-VisibleLoopDismiss($parent){
   if($parent -is [Windows.Controls.Button] -and $parent.IsVisible -and [Windows.Automation.AutomationProperties]::GetName($parent).StartsWith("Скрыть предупреждение о возможном цикле")){return $parent}
   for($childIndex=0;$childIndex -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);$childIndex++){
    $match=Find-VisibleLoopDismiss ([Windows.Media.VisualTreeHelper]::GetChild($parent,$childIndex))
    if($null -ne $match){return $match}
   }
   return $null
  }
  $dismiss=Find-VisibleLoopDismiss $window
  if($null -eq $dismiss){throw "Visible loop warning action not found."}
  $dismiss.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if(-not $script:previewLoopDismissed -or $null -ne (Get-LoopWarning $script:lastTasks[0])){throw "Dismissing the loop warning did not update the task view."}
  $script:previewLoopDismissed=$false; $script:fingerprint=""; Update-View
  Show-SettingsView
  $loopThresholdCombo.SelectedIndex=0; $loopWindowCombo.SelectedIndex=0
  $saved=Get-DiagnosticSettings -Directory $script:diagnosticDirectory
  if($saved.LoopThreshold -ne 3 -or $saved.LoopWindowMinutes -ne 1){throw "Loop warning settings did not persist."}
  $loopThresholdCombo.SelectedIndex=7; $loopWindowCombo.SelectedIndex=29
  $saved=Get-DiagnosticSettings -Directory $script:diagnosticDirectory
  if($saved.LoopThreshold -ne 10 -or $saved.LoopWindowMinutes -ne 30){throw "Loop warning maximum settings did not persist."}
  $loopThresholdCombo.SelectedIndex=2; $loopWindowCombo.SelectedIndex=9
  Show-TasksView
  if($CompactMode){Set-CompactMode $true}
  $window.UpdateLayout()
  Write-Output "Loop warning UI: dismissal and configurable limits passed."
 }
 if($PreviewMotionDelayMilliseconds -gt 0){
  $motionFrame=New-Object Windows.Threading.DispatcherFrame
  $motionTimer=New-Object Windows.Threading.DispatcherTimer; $motionTimer.Interval=[TimeSpan]::FromMilliseconds($PreviewMotionDelayMilliseconds)
  $motionTimer.Add_Tick({$motionTimer.Stop();$motionFrame.Continue=$false});$motionTimer.Start();[Windows.Threading.Dispatcher]::PushFrame($motionFrame)
  $window.UpdateLayout()
 }
 $width=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth)); $height=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
 $bitmap.Render($window)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
 $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create($SnapshotFile)
 try {$encoder.Save($stream)} finally {$stream.Dispose()}
 if($HintSnapshotFile -and $null -ne $script:previewHintTarget -and $script:previewHintTarget.ToolTip){
  $hint=$script:previewHintTarget.ToolTip
  $hint.StaysOpen=$true
  $hint.IsOpen=$true
  $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
  Start-Sleep -Milliseconds 180
  $frameOrigin=$window.PointToScreen([Windows.Point]::new(0,0))
  $hintOrigin=$hint.PointToScreen([Windows.Point]::new(0,0))
  $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($window)
  $frameRight=$frameOrigin.X+($window.ActualWidth*$dpi.DpiScaleX)
  $frameBottom=$frameOrigin.Y+($window.ActualHeight*$dpi.DpiScaleY)
  $hintRight=$hintOrigin.X+($hint.ActualWidth*$dpi.DpiScaleX)
  $hintBottom=$hintOrigin.Y+($hint.ActualHeight*$dpi.DpiScaleY)
  $captureLeft=[int][Math]::Floor([Math]::Min($frameOrigin.X,$hintOrigin.X)-12)
  $captureTop=[int][Math]::Floor([Math]::Min($frameOrigin.Y,$hintOrigin.Y)-12)
  $captureRight=[int][Math]::Ceiling([Math]::Max($frameRight,$hintRight)+12)
  $captureBottom=[int][Math]::Ceiling([Math]::Max($frameBottom,$hintBottom)+12)
  $captureWidth=[Math]::Max(1,$captureRight-$captureLeft)
  $captureHeight=[Math]::Max(1,$captureBottom-$captureTop)
  $hintPixelWidth=[Math]::Max(1,[int][Math]::Ceiling($hint.ActualWidth*$dpi.DpiScaleX))
  $hintPixelHeight=[Math]::Max(1,[int][Math]::Ceiling($hint.ActualHeight*$dpi.DpiScaleY))
  $hintRender=[Windows.Media.Imaging.RenderTargetBitmap]::new($hintPixelWidth,$hintPixelHeight,96*$dpi.DpiScaleX,96*$dpi.DpiScaleY,[Windows.Media.PixelFormats]::Pbgra32)
  $hintRender.Render($hint)
  if($HintRawSnapshotFile){
   $rawEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
   $rawEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($hintRender))
   $rawStream=[IO.File]::Create($HintRawSnapshotFile)
   try{$rawEncoder.Save($rawStream)}finally{$rawStream.Dispose()}
  }
  $canvas=New-Object Windows.Media.DrawingVisual
  $drawing=$canvas.RenderOpen()
  try{
   $drawing.DrawRectangle((Brush "#111111"),$null,[Windows.Rect]::new(0,0,$captureWidth,$captureHeight))
   $drawing.DrawImage($bitmap,[Windows.Rect]::new($frameOrigin.X-$captureLeft,$frameOrigin.Y-$captureTop,$frameRight-$frameOrigin.X,$frameBottom-$frameOrigin.Y))
   $drawing.DrawImage($hintRender,[Windows.Rect]::new($hintOrigin.X-$captureLeft,$hintOrigin.Y-$captureTop,$hintRight-$hintOrigin.X,$hintBottom-$hintOrigin.Y))
  }finally{$drawing.Close()}
  $capture=[Windows.Media.Imaging.RenderTargetBitmap]::new($captureWidth,$captureHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
  $capture.Render($canvas)
  $captureEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
  $captureEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($capture))
  $memory=New-Object IO.MemoryStream
  try{
   $captureEncoder.Save($memory);$memory.Position=0
   $hintBitmap=[Drawing.Bitmap]::new($memory)
   $hintGraphics=[Drawing.Graphics]::FromImage($hintBitmap)
   try{
    $pointer=$script:previewHintTarget.PointToScreen([Windows.Point]::new($script:previewHintTarget.ActualWidth/2,$script:previewHintTarget.ActualHeight/2))
    $cursorSize=[Windows.Forms.SystemInformation]::CursorSize
    [Windows.Forms.Cursors]::Arrow.Draw($hintGraphics,[Drawing.Rectangle]::new([int]($pointer.X-$captureLeft),[int]($pointer.Y-$captureTop),$cursorSize.Width,$cursorSize.Height))
    $hintBitmap.Save($HintSnapshotFile,[Drawing.Imaging.ImageFormat]::Png)
   }finally{$hintGraphics.Dispose();$hintBitmap.Dispose()}
  }finally{$memory.Dispose();$hint.IsOpen=$false}
 }
 if($SettingsSnapshotFile -or $JournalDropdownSnapshotFile){
  Show-SettingsView
  if($PreviewCloudUiTest){
   if(-not $script:codexCloudModulesAvailable){throw 'Cloud UI fixture requires its runtime module.'}
   Set-CodexCloudControllerEnabled $script:codexCloudController $false
   Update-CodexCloudSourceSettings
   $codexCloudSourceAction.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   if(-not $script:codexCloudController.Enabled -or -not (Load-CodexCloudEnabled) -or $null -ne $script:codexCloudController.Request){throw 'Cloud opt-in did not save safely in the synthetic preview.'}
   $codexCloudSourceAction.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   if($script:codexCloudController.Enabled -or (Load-CodexCloudEnabled)){throw 'Cloud disconnect did not save in the synthetic preview.'}
   Write-Output 'Codex cloud: isolated opt-in and disconnect controls verified.'
  }
  if($PreviewCloudState){
   if(-not $script:codexCloudModulesAvailable){throw 'Cloud preview requires its runtime module.'}
   $script:codexCloudController.Enabled=$PreviewCloudState -ne 'disconnected'
   $script:codexCloudController.Scanned=$PreviewCloudState -in @('connected','partial')
   $script:codexCloudController.LastError=if($PreviewCloudState -eq 'error'){'unavailable'}else{''}
   $script:codexCloudController.Partial=$PreviewCloudState -eq 'partial'
   Update-CodexCloudSourceSettings
  }
  if($PreviewKimiUiTest){
   if(-not $script:kimiModulesAvailable){throw 'Kimi UI fixture requires its runtime module.'}
   $script:kimiController.Scanned=$true;$script:kimiController.LastError='';$script:kimiController.State='disconnected'
   Update-KimiSourceSettings
   if(-not $kimiSourceAction.IsEnabled -or $kimiSourceStatus.Text -cne (Tr 'Плагин не установлен')){throw 'Kimi manual installation action is incorrect.'}
   $script:kimiPreviewCopied=''
   $kimiSourceAction.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   if($script:kimiPreviewCopied -cne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'integrations\kimi-plugin'))){throw 'Kimi action did not copy the plugin path.'}
   $script:kimiController.State='connected';Update-KimiSourceSettings
   if($kimiSourceStatus.Text -cne (Tr 'Плагин включён')){throw 'Kimi enabled state is incorrect.'}
   $script:kimiController.State='disabled';Update-KimiSourceSettings
   if($kimiSourceStatus.Text -cne (Tr 'Плагин отключён')){throw 'Kimi disabled state is incorrect.'}
   $script:kimiController.LastError='operation-failed';Update-KimiSourceSettings
   if($kimiSourceAction.IsEnabled -or $kimiSourceError.Visibility -ne 'Visible'){throw 'Kimi error state is incorrect.'}
   Write-Output 'Kimi manual setup: isolated path action and source states verified.'
  }
  if($PreviewKimiState){
   if(-not $script:kimiModulesAvailable){throw 'Kimi preview requires its runtime module.'}
   $script:kimiController.Scanned=$true
   $script:kimiController.State=if($PreviewKimiState -eq 'error'){'disconnected'}else{$PreviewKimiState}
   $script:kimiController.LastError=if($PreviewKimiState -eq 'error'){'operation-failed'}else{''}
   Update-KimiSourceSettings
  }
  if($PreviewDeepSeekUiTest){
   if(-not $script:deepSeekModulesAvailable){throw 'DeepSeek UI fixture requires its runtime module.'}
   $script:deepSeekController.Scanned=$true;$script:deepSeekController.LastError=''
   $script:deepSeekController.Profiles=@([PSCustomObject]@{Name='Profile One';State='disconnected'},[PSCustomObject]@{Name='Profile Two';State='connected'},[PSCustomObject]@{Name='desktop';State='error';Error='operation-failed'})
   Update-DeepSeekSourceSettings
   $deepSeekProfileCombo.SelectedItem='Profile One'
   Update-DeepSeekSourceSettings
   if([string]$deepSeekSourceAction.Tag -cne 'Install' -or -not $deepSeekSourceAction.IsEnabled){throw 'DeepSeek disconnected profile action is incorrect.'}
   $deepSeekProfileCombo.SelectedItem='Profile Two'
   Update-DeepSeekSourceSettings
   if([string]$deepSeekSourceAction.Tag -cne 'Remove' -or -not $deepSeekSourceAction.IsEnabled){throw 'DeepSeek connected profile action is incorrect.'}
   $deepSeekProfileCombo.SelectedItem='desktop'
   Update-DeepSeekSourceSettings
   if($deepSeekSourceAction.IsEnabled -or $deepSeekSourceError.Visibility -ne 'Visible' -or $deepSeekSourceError.Text -cne (Tr 'Не удалось проверить профиль DeepSeek Harness.')){throw 'DeepSeek profile error is not shown accurately.'}
   $script:deepSeekController.Profiles[2].Error='unsupported-desktop'
   Update-DeepSeekSourceSettings
   if($deepSeekSourceAction.IsEnabled -or $deepSeekSourceError.Text -cne (Tr 'Профиль DeepSeek Desktop пока не поддерживается.')){throw 'The DeepSeek Desktop profile must be unavailable.'}
   if(-not $PreviewDeepSeekErrorUiTest){$deepSeekProfileCombo.SelectedItem='Profile Two';Update-DeepSeekSourceSettings}
  }
  if($PreviewHermesState -or $PreviewHermesUiTest){
   $previewHermesContext=[PSCustomObject]@{
    Python='C:\Users\Тест О''Брайен\.hermes\hermes-agent\venv\Scripts\python.exe'
    Assets='C:\Program Files\AI Task Monitor\integrations'
    Home='C:\Users\Тест О''Брайен\.hermes'
    Project='C:\Users\Тест О''Брайен\.hermes\hermes-agent'
   }
   $longHermesRoot='C:\Users\Тестовый Пользователь\'+('long-folder\'*5)+'.hermes'
   $longHermesContext=[PSCustomObject]@{
    Python=($longHermesRoot+'\hermes-agent\venv\Scripts\python.exe')
    Assets=('C:\Program Files\AI Task Monitor\'+('long-folder\'*5)+'integrations')
    Home=$longHermesRoot
    Project=($longHermesRoot+'\hermes-agent')
   }
   $script:hermesController=[PSCustomObject]@{
    Profiles=@(
     [PSCustomObject]@{Id='root';Name='default';State='absent';Enabled=$false;Scope='';Error=''},
     [PSCustomObject]@{Id='profile:work';Name='work';State='prepared';Enabled=$false;Scope=('a'*32);Error=''},
     [PSCustomObject]@{Id='profile:active';Name='active';State='prepared';Enabled=$true;Scope=('b'*32);Error=''},
     [PSCustomObject]@{Id=('profile:'+('a'*64));Name=('a'*64);State='prepared';Enabled=$false;Scope=('c'*32);Error=''},
     [PSCustomObject]@{Id='profile:broken';Name='broken';State='error';Enabled=$false;Scope='';Error='profile-unavailable'},
     [PSCustomObject]@{Id='profile:bad;command';Name='bad;command';State='absent';Enabled=$false;Scope='';Error=''},
     [PSCustomObject]@{Id='profile:root';Name='root';State='absent';Enabled=$false;Scope='';Error=''},
     [PSCustomObject]@{Id='profile:other';Name='work';State='absent';Enabled=$false;Scope='';Error=''}
    );Context=$previewHermesContext;Request=$null;Scanned=$true;LastError='';ActionError='';Seen=@{}
   }
   $script:hermesModulesAvailable=$true
   Update-HermesSourceSettings
   if($PreviewHermesUiTest){
    $testedVersion=if($script:resolvedLanguage -eq 'en'){'Tested with a source installation of Hermes Agent v0.22.7.'}else{'Проверено с исходной установкой Hermes Agent v0.22.7.'}
    if(-not $hermesSourceDescription.Text.EndsWith($testedVersion)){throw 'The tested Hermes source installation must be identified accurately.'}
    if(-not $hermesSourceDescription.Text.Contains('PowerShell') -or $hermesSourceDescription.Text.Contains('HERMES_HOME')){throw 'Hermes commands must be explained for PowerShell without manual environment changes.'}
    $restartHint=if($script:resolvedLanguage -eq 'en'){'After starting or reconnecting the monitor, wait until the selected profile says “Enabled locally”, then start or restart Hermes. Previous tasks are not shown.'}else{'После запуска или переподключения монитора дождитесь статуса «Включён локально» у выбранного профиля, затем запустите или перезапустите Hermes. Прежние задачи не показываются.'}
    if(-not $hermesSourceDescription.Text.Contains($restartHint)){throw 'Hermes restart and old-task behavior must be explained.'}
    $privacyHint=if($script:resolvedLanguage -eq 'en'){'Before starting the manager, the command checks local .env files, which may contain keys; the check itself does not save, display or transmit them.'}else{'Перед запуском менеджера команда локально проверяет файлы .env, которые могут содержать ключи; сама проверка не сохраняет, не выводит и не передаёт их.'}
    if(-not $hermesSourceDescription.Text.Contains($privacyHint)){throw 'Hermes must explain the local .env check before running the manager.'}
    function Test-HermesPreviewCommand([string]$command,[string]$profile,[string]$action){
     $tokens=$null;$errors=$null
     $tree=[Management.Automation.Language.Parser]::ParseInput($command,[ref]$tokens,[ref]$errors)
     $statements=@($tree.EndBlock.Statements)
     if($errors.Count -ne 0 -or $statements.Count -ne 1 -or $statements[0] -isnot [Management.Automation.Language.PipelineAst] -or @($statements[0].PipelineElements).Count -ne 1){throw 'The Hermes command is not a single PowerShell invocation.'}
     $invocation=$statements[0].PipelineElements[0]
     if($invocation -isnot [Management.Automation.Language.CommandAst] -or $invocation.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Ampersand -or @($invocation.Redirections).Count -ne 0){throw 'The Hermes command has an unexpected invocation shape.'}
     $elements=@($invocation.CommandElements)
     $expected=@($previewHermesContext.Python,'-I','-B',[IO.Path]::Combine($previewHermesContext.Assets,'hermes-manager.py'),$previewHermesContext.Home,$previewHermesContext.Project,$profile,$action)
     if($elements.Count -ne $expected.Count){throw 'The Hermes command has an unexpected argument count.'}
     for($index=0;$index -lt $expected.Count;$index++){
      $element=$elements[$index]
      $actual=if($element -is [Management.Automation.Language.StringConstantExpressionAst]){[string]$element.Value}elseif($element -is [Management.Automation.Language.CommandParameterAst] -and $null -eq $element.Argument){'-'+$element.ParameterName}else{throw 'The Hermes command contains an unsafe expression.'}
      if($actual -cne $expected[$index]){throw 'The Hermes command changed an argument.'}
     }
    }
    if($hermesProfileCombo.Items.Count -ne 5 -or $hermesSourceAction.IsEnabled -or $hermesSourceCommands.Visibility -ne 'Collapsed'){throw 'Unsafe profiles or an unselected action were exposed.'}
    $hermesProfileCombo.SelectedItem='default';Update-HermesSourceSettings
    if(-not $hermesSourceAction.IsEnabled -or $hermesSourceStatus.Text -cne (Tr 'Не подготовлен')){throw 'The unprepared profile cannot be prepared.'}
    if($hermesSourceCommands.Visibility -ne 'Collapsed'){throw 'Commands must not be shown before preparation.'}
    $script:hermesPreviewRequest=''
    $hermesSourceAction.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if($script:hermesPreviewRequest -cne 'root'){throw 'Preparation did not select the default profile.'}
    $script:hermesController.Profiles[0].State='prepared';Update-HermesSourceSettings
    Test-HermesPreviewCommand $hermesEnableRun.Text 'default' 'enable'
    Test-HermesPreviewCommand $hermesDisableRun.Text 'default' 'disable'
    $script:hermesController.Profiles[0].State='absent';Update-HermesSourceSettings
    $script:hermesController.Profiles+=@([PSCustomObject]@{Id='root';Name='default';State='absent';Enabled=$false;Scope='';Error=''})
    Update-HermesSourceSettings
    if($hermesSourceAction.IsEnabled -or $hermesSourceCommands.Visibility -ne 'Collapsed'){throw 'An ambiguous profile must not be prepared.'}
    $script:hermesController.Profiles=@($script:hermesController.Profiles | Select-Object -First 8)
    Update-HermesSourceSettings
    $hermesProfileCombo.SelectedItem='work';Update-HermesSourceSettings
    if($hermesSourceStatus.Text -cne (Tr 'Отключён локально') -or $hermesSourceAction.IsEnabled){throw 'The disabled prepared profile is not represented accurately.'}
    Test-HermesPreviewCommand $hermesEnableRun.Text 'work' 'enable'
    Test-HermesPreviewCommand $hermesDisableRun.Text 'work' 'disable'
    $script:hermesController.Context=[PSCustomObject]@{Python=$previewHermesContext.Python;Assets=$previewHermesContext.Assets;Home=($previewHermesContext.Home+[char]10);Project=$previewHermesContext.Project}
    Update-HermesSourceSettings
    if($hermesSourceCommands.Visibility -ne 'Collapsed' -or $hermesSourceError.Visibility -ne 'Visible'){throw 'An unsafe installation must not show commands.'}
    $hermesProfileCombo.SelectedItem='default';Update-HermesSourceSettings
    if($hermesSourceAction.IsEnabled -or $hermesSourceCommands.Visibility -ne 'Collapsed'){throw 'An unsafe installation must not permit preparation.'}
    $script:hermesController.Context=$previewHermesContext
    $hermesProfileCombo.SelectedItem='work';Update-HermesSourceSettings
    $window.UpdateLayout()
    $copyGesture=@([Windows.Input.ApplicationCommands]::Copy.InputGestures | Where-Object {$_.Key -eq [Windows.Input.Key]::C -and $_.Modifiers -eq [Windows.Input.ModifierKeys]::Control})
    $selectGesture=@([Windows.Input.ApplicationCommands]::SelectAll.InputGestures | Where-Object {$_.Key -eq [Windows.Input.Key]::A -and $_.Modifiers -eq [Windows.Input.ModifierKeys]::Control})
    if($copyGesture.Count -ne 1 -or $selectGesture.Count -ne 1){throw 'Standard keyboard shortcuts are unavailable.'}
    [void][Windows.Input.Keyboard]::Focus($hermesProfileCombo)
    if(-not $hermesProfileCombo.MoveFocus([Windows.Input.TraversalRequest]::new([Windows.Input.FocusNavigationDirection]::Next)) -or [Windows.Input.Keyboard]::FocusedElement -ne $hermesEnableCommand){throw 'The enable command is not reachable by keyboard navigation.'}
    if(-not $hermesEnableCommand.MoveFocus([Windows.Input.TraversalRequest]::new([Windows.Input.FocusNavigationDirection]::Next)) -or [Windows.Input.Keyboard]::FocusedElement -ne $hermesDisableCommand){throw 'The disable command is not reachable by keyboard navigation.'}
    function Test-HermesCommandSelection($control,$run){
     $expected=[string]$run.Text
     if(-not $control.IsReadOnly -or -not $control.Focusable -or -not $control.IsTabStop -or -not $control.IsHitTestVisible){throw 'A Hermes command is not available for selection.'}
     [void][Windows.Input.Keyboard]::Focus($control)
     if([Windows.Input.Keyboard]::FocusedElement -ne $control){throw 'A Hermes command did not receive keyboard focus.'}
     [Windows.Input.ApplicationCommands]::SelectAll.Execute($null,$control)
     if($control.Selection.Text.TrimEnd([char[]]"`r`n") -cne $expected -or -not [Windows.Input.ApplicationCommands]::Copy.CanExecute($null,$control)){throw 'A Hermes command cannot be selected and copied by keyboard.'}
     $script:hermesPreviewCopiedCommand=''
     [Windows.Input.ApplicationCommands]::Copy.Execute($null,$control)
     if($script:hermesPreviewCopiedCommand -cne $expected){throw 'Keyboard copy changed the command or added a newline.'}
     Update-HermesSourceSettings
     if($control.Selection.Text.TrimEnd([char[]]"`r`n") -cne $expected -or [Windows.Input.Keyboard]::FocusedElement -ne $control){throw 'Refreshing Hermes cleared the command selection or focus.'}
     $first=$run.ContentStart.GetCharacterRect([Windows.Documents.LogicalDirection]::Forward)
     $last=$run.ContentEnd.GetCharacterRect([Windows.Documents.LogicalDirection]::Backward)
     if($first.IsEmpty -or $last.IsEmpty){throw 'A Hermes command does not expose text positions for mouse selection.'}
     if($last.X -lt 0 -or $last.Y -lt 0 -or $last.X -gt $control.ActualWidth+1 -or $last.Y+$last.Height -gt $control.ActualHeight+1){throw 'A Hermes command is clipped.'}
     $from=$control.GetPositionFromPoint([Windows.Point]::new([Math]::Max(0,$first.X-1),$first.Y+$first.Height/2),$true)
     $to=$control.GetPositionFromPoint([Windows.Point]::new($last.X+$last.Width+1,$last.Y+$last.Height/2),$true)
     if($null -eq $from -or $null -eq $to){throw 'A Hermes command cannot be hit-tested for mouse selection.'}
     $control.Selection.Select($from,$to)
     if($control.Selection.Text.TrimEnd([char[]]"`r`n") -cne $expected -or -not [Windows.Input.ApplicationCommands]::Copy.CanExecute($null,$control)){throw 'Mouse-selected Hermes command text is incorrect.'}
     $script:hermesPreviewCopiedCommand=''
     [Windows.Input.ApplicationCommands]::Copy.Execute($null,$control)
     if($script:hermesPreviewCopiedCommand -cne $expected){throw 'Mouse selection copy changed the command or added a newline.'}
     $control.Selection.Select($run.ContentStart,$run.ContentStart)
    }
    foreach($pair in @(@($hermesEnableCommand,$hermesEnableRun),@($hermesDisableCommand,$hermesDisableRun))){Test-HermesCommandSelection $pair[0] $pair[1]}
    $hermesProfileCombo.SelectedItem=('a'*64);Update-HermesSourceSettings;$window.UpdateLayout()
    foreach($pair in @(@($hermesEnableCommand,$hermesEnableRun),@($hermesDisableCommand,$hermesDisableRun))){Test-HermesCommandSelection $pair[0] $pair[1]}
    $script:hermesController.Context=$longHermesContext;Update-HermesSourceSettings;$window.UpdateLayout()
    foreach($pair in @(@($hermesEnableCommand,$hermesEnableRun),@($hermesDisableCommand,$hermesDisableRun))){Test-HermesCommandSelection $pair[0] $pair[1]}
    $script:hermesController.Context=$previewHermesContext
    [Windows.Input.Keyboard]::ClearFocus()|Out-Null
    $hermesProfileCombo.SelectedItem='active';Update-HermesSourceSettings
    if($hermesSourceStatus.Text -cne (Tr 'Включён локально') -or $hermesSourceAction.IsEnabled){throw 'The enabled prepared profile is not represented accurately.'}
    Test-HermesPreviewCommand $hermesDisableRun.Text 'active' 'disable'
    $script:hermesController.Profiles[2].Enabled='unverified';Update-HermesSourceSettings
    if($hermesSourceCommands.Visibility -ne 'Collapsed' -or $hermesSourceError.Visibility -ne 'Visible'){throw 'An unverified enabled state must not show setup commands.'}
    $script:hermesController.Profiles[2].Enabled=$true
    $hermesProfileCombo.SelectedItem='broken';Update-HermesSourceSettings
    if($hermesSourceAction.IsEnabled -or $hermesSourceError.Visibility -ne 'Visible' -or $hermesSourceCommands.Visibility -ne 'Collapsed'){throw 'An unavailable profile must not show setup commands.'}
    $hermesProfileCombo.SelectedItem='default';$script:hermesController.Request=[PSCustomObject]@{Action='prepare'};Update-HermesSourceSettings
    if($hermesSourceAction.IsEnabled -or $hermesProfileCombo.IsEnabled -or $hermesSourceStatus.Text -cne (Tr 'Подготовка')){throw 'A pending preparation did not disable controls.'}
    $script:hermesController.Request=$null;$script:hermesController.LastError='operation-failed';Update-HermesSourceSettings
    if($hermesSourceAction.IsEnabled -or $hermesProfileCombo.IsEnabled -or $hermesSourceStatus.Text -cne (Tr 'Нет данных') -or $hermesSourceCommands.Visibility -ne 'Collapsed' -or $hermesSourceError.Visibility -ne 'Visible'){throw 'A failed scan must disable preparation and hide unverified commands.'}
    if(-not $hermesProfileCombo.Focusable -or -not $hermesSourceAction.Focusable -or [Windows.Automation.AutomationProperties]::GetName($hermesSourceAction) -notlike '*Hermes Agent'){throw 'Hermes controls are not accessible.'}
    $script:hermesController.LastError=''
    Write-Output 'Hermes manual setup: isolated profile selection, commands and source states verified.'
   }
   if($PreviewHermesState){
    $script:hermesController.LastError=''
    if($PreviewHermesState -eq 'long'){$script:hermesController.Context=$longHermesContext}else{$script:hermesController.Context=$previewHermesContext}
    $hermesProfileCombo.SelectedIndex=-1
    if($PreviewHermesState -ne 'unselected'){
     $name=switch($PreviewHermesState){'absent'{'default'} 'prepared'{'work'} 'enabled'{'active'} 'long'{('a'*64)} default{'broken'}}
     $hermesProfileCombo.SelectedItem=$name
    }
    Update-HermesSourceSettings
   }
  }
  if($PreviewSettingsBackHover){$settingsBackButton.Background=Brush $script:palette.Hover}
  $window.UpdateLayout()
  if($PreviewSources){
   $target=if($PreviewHermesState -or $PreviewHermesUiTest){$hermesSourceAction}elseif($PreviewKimiState -or $PreviewKimiUiTest){$kimiSourceAction}elseif($PreviewCloudState -or $PreviewCloudUiTest){$codexCloudSourceAction}else{$openCodeSourceAction}
   $targetY=if($PreviewHermesState -or $PreviewHermesUiTest){100}elseif($PreviewKimiState -or $PreviewKimiUiTest){180}elseif($PreviewCloudState -or $PreviewCloudUiTest){140}else{290}
   $point=$target.TranslatePoint([Windows.Point]::new(0,0),$settingsScroll)
   $settingsScroll.ScrollToVerticalOffset([Math]::Max(0,$settingsScroll.VerticalOffset+$point.Y-$targetY))
   $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$window.UpdateLayout()
  }
  if($PreviewHermesFocus){
   [void][Windows.Input.Keyboard]::Focus($hermesProfileCombo)
   if(-not $hermesProfileCombo.MoveFocus([Windows.Input.TraversalRequest]::new([Windows.Input.FocusNavigationDirection]::Next)) -or [Windows.Input.Keyboard]::FocusedElement -ne $hermesEnableCommand){throw 'The focused Hermes preview is not reachable by keyboard.'}
   if($PreviewHermesDisableSelection){
    if(-not $hermesEnableCommand.MoveFocus([Windows.Input.TraversalRequest]::new([Windows.Input.FocusNavigationDirection]::Next)) -or [Windows.Input.Keyboard]::FocusedElement -ne $hermesDisableCommand){throw 'The disable command is not reachable by keyboard.'}
    [Windows.Input.ApplicationCommands]::SelectAll.Execute($null,$hermesDisableCommand)
   }elseif($PreviewHermesSelection){[Windows.Input.ApplicationCommands]::SelectAll.Execute($null,$hermesEnableCommand)}
   else{$hermesEnableCommand.Selection.Select($hermesEnableRun.ContentStart,$hermesEnableRun.ContentStart)}
   $window.UpdateLayout()
  }
  if($PreviewJournalClearConfirmation){$journalClearConfirmation.Visibility="Visible";Update-JournalSettings;$window.UpdateLayout()}
  if($PreviewJournalSettings -or $PreviewJournalClearConfirmation -or $JournalDropdownSnapshotFile){
   Reveal-JournalSettings
  }
  if($PreviewLoopSettings){
   $point=$loopSettingsSection.TranslatePoint([Windows.Point]::new(0,0),$settingsScroll)
   $settingsScroll.ScrollToVerticalOffset([Math]::Max(0,$settingsScroll.VerticalOffset+$point.Y-90))
   $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$window.UpdateLayout()
  }
  if($PreviewSettingsEnd){$settingsScroll.ScrollToEnd();$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$window.UpdateLayout()}
  if($SettingsSnapshotFile){
   $settingsWidth=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth)); $settingsHeight=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
   $settingsBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($settingsWidth,$settingsHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32); $settingsBitmap.Render($window)
   $settingsEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder; $settingsEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($settingsBitmap)); $settingsStream=[IO.File]::Create($SettingsSnapshotFile)
   try{$settingsEncoder.Save($settingsStream)}finally{$settingsStream.Dispose()}
  }
  if($JournalDropdownSnapshotFile){
   $journalDaysCombo.IsDropDownOpen=$true;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
   $popup=$journalDaysCombo.Template.FindName("PART_Popup",$journalDaysCombo)
   if($null -eq $popup -or $null -eq $popup.Child){throw "Journal dropdown was not rendered."}
   $popup.Child.UpdateLayout();$popupWidth=[Math]::Max(1,[int][Math]::Ceiling($popup.Child.RenderSize.Width));$popupHeight=[Math]::Max(1,[int][Math]::Ceiling($popup.Child.RenderSize.Height))
   $popupBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($popupWidth,$popupHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$popupBitmap.Render($popup.Child)
   $popupEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$popupEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($popupBitmap));$popupStream=[IO.File]::Create($JournalDropdownSnapshotFile)
   try{$popupEncoder.Save($popupStream)}finally{$popupStream.Dispose();$journalDaysCombo.IsDropDownOpen=$false}
  }
 }
 if($JournalSnapshotFile){
  Show-JournalView
  if($PreviewJournalFilterTask -and $journalTaskFilter.Items.Count -gt 1){$journalTaskFilter.SelectedIndex=1;$script:journalFingerprint="";Render-Journal}
  $window.UpdateLayout()
  $journalWidth=[Math]::Max(1,[int][Math]::Ceiling($window.ActualWidth));$journalHeight=[Math]::Max(1,[int][Math]::Ceiling($window.ActualHeight))
  $journalBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($journalWidth,$journalHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$journalBitmap.Render($window)
  $journalEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$journalEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($journalBitmap));$journalStream=[IO.File]::Create($JournalSnapshotFile)
  try{$journalEncoder.Save($journalStream)}finally{$journalStream.Dispose()}
  if($JournalFilterDropdownSnapshotFile){
   $journalTaskFilter.IsDropDownOpen=$true;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
   $popup=$journalTaskFilter.Template.FindName("PART_Popup",$journalTaskFilter)
   if($null -eq $popup -or $null -eq $popup.Child){throw "Journal task filter was not rendered."}
   $popup.Child.UpdateLayout();$popupWidth=[Math]::Max(1,[int][Math]::Ceiling($popup.Child.RenderSize.Width));$popupHeight=[Math]::Max(1,[int][Math]::Ceiling($popup.Child.RenderSize.Height))
   $popupBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($popupWidth,$popupHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$popupBitmap.Render($popup.Child)
   $popupEncoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$popupEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($popupBitmap));$popupStream=[IO.File]::Create($JournalFilterDropdownSnapshotFile)
   try{$popupEncoder.Save($popupStream)}finally{$popupStream.Dispose();$journalTaskFilter.IsDropDownOpen=$false}
  }
 }
 $window.Close()
} else {
 $window.ShowDialog()|Out-Null
}

