# AI Task Monitor

[Русский](#русский) · [English](#english)

## Русский

AI Task Monitor — бесплатное приложение для Windows и macOS, которое показывает задачи Codex и Claude Code в одном окне. В карточке отображаются доступное действие и, если агент опубликовал план, его этапы и доля выполненных этапов. Если данных недостаточно, процент скрыт; приблизительная оценка помечается `≈`.

Компактное окно остаётся поверх других окон и позволяет переключаться между задачами. Настройки, локальный диагностический журнал и предупреждение о возможном цикле доступны в полном окне.

Альфа-сборки размещены в [GitHub Releases](https://github.com/trueakaru-stack/ai-task-monitor/releases). Установщик Windows не имеет доверенной цифровой подписи; сборка macOS подписана ad hoc и не нотарифицирована. Перед установкой проверьте SHA-256. Обратная связь: truea.k.a.ru@gmail.com.

Данные задач обрабатываются локально; подробности приведены в [политике конфиденциальности](PRIVACY.md). [Лицензия](LICENSE) разрешает бесплатное использование, включая внутреннюю работу организаций, ограничивает монетизацию продуктов с кодом и требует уведомить правообладателя при первом использовании или изменении кода. Для запуска приложения уведомление не требуется; лицензия не одобрена OSI как open source.

## English

AI Task Monitor is a source-available desktop utility for viewing active Codex and Claude Code tasks in one compact window.

The application shows the current action and displays progress only when it can be supported by available task data. When a task publishes a plan, AI Task Monitor shows completed, current, and upcoming steps, keeps five steps visible in each card, and lets the user scroll through the rest. Without a plan, the current activity remains visible, but step details and a reliable percentage may be unavailable.

Exact progress is shown as a number, estimated progress uses `≈`, and activity without a reliable estimate has no percentage or progress bar. Settings are available only in the expanded window; compact mode is reserved for monitoring.

## Current status

Windows and macOS alpha releases are available through GitHub Releases. The native macOS implementation is developed in the `macos` branch; branch contents and published builds may differ. Windows may show a SmartScreen warning; the macOS alpha is ad-hoc signed but not notarized.

- `main` contains public documentation and reviewed screenshots.
- `windows` contains the current Windows 11 implementation.
- `macos` contains the native SwiftUI implementation and reproducible disk-image workflow.

## Screenshots

| Expanded | Compact | Settings |
| --- | --- | --- |
| ![Expanded dark](screenshots/expanded-dark.png) | ![Compact dark](screenshots/compact-dark.png) | ![Settings dark](screenshots/settings-dark.png) |
| ![Expanded light](screenshots/expanded-light.png) | ![Compact light](screenshots/compact-light.png) | ![Settings light](screenshots/settings-light.png) |

## Privacy

Task information is processed locally. AI Task Monitor does not upload task titles, actions, plans, or logs. The app checks GitHub for platform-specific updates at startup and daily while open; GitHub receives the request and IP address. Feedback opens a user-controlled email draft. Read [PRIVACY.md](PRIVACY.md) for the exact local data paths and behavior.

## Independence

AI Task Monitor is an independent project. It is not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic. Codex and Claude Code are referenced only to identify compatible task sources.

## Releases

Download published alpha packages from [GitHub Releases](https://github.com/trueakaru-stack/ai-task-monitor/releases). Verify the accompanying SHA-256 value before opening a package.

The Windows package is unsigned. The macOS package is ad-hoc signed but not notarized with an Apple Developer ID. Both are intended for alpha testing. Trusted public builds still require clean-machine installation and removal tests, malware scanning, and platform signing credentials.

## License

The [source-available license](LICENSE) permits free use, including internal workplace use, while restricting monetization of products containing the code. People who use or modify the code must send a first-use notice; simply running the application does not require a notice. This is not an OSI-approved open-source license.

