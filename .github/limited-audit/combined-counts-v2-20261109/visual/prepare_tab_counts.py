"""Prepare only a synthetic tab-counter preview in a disposable source copy."""
from pathlib import Path
import sys

source = Path(sys.argv[1]) / "Sources/AITaskMonitor/SnapshotRenderer.swift"
text = source.read_text(encoding="utf-8")

def replace_once(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit("Unexpected SnapshotRenderer preview anchor")
    text = text.replace(old, new)

anchor = '            if ProcessInfo.processInfo.environment["AITM_CLAUDE_PLAN_PREVIEW_ONLY"] == "1" {'
branch = r'''            if ProcessInfo.processInfo.environment["AITM_TAB_COUNT_PREVIEW_ONLY"] == "1" {
                for language in [AppLanguage.ru, .en] {
                    AppLanguage.previewOverride = language
                    for mode in [AppearanceMode.dark, .light] {
                        for state in ["mixed", "unconfirmed"] {
                            for filter in [ProviderFilter.all, .codex, .claude] {
                                let name = "tabs-\(language.rawValue)-\(mode.rawValue)-\(state)-\(filter.rawValue)"
                                try render(name: name, mode: mode, compact: false, settings: false,
                                           outputDirectory: outputDirectory, tabCountFixture: state,
                                           tabCountFilter: filter)
                            }
                        }
                    }
                }
                return 0
            }
'''
replace_once(anchor, branch + anchor)
replace_once('partialCodex: Bool = false) throws {',
             'partialCodex: Bool = false, tabCountFixture: String? = nil, tabCountFilter: ProviderFilter = .all) throws {')
old = '        let store: TaskStore\n        if claudePlanFixture || codexPlanFixture {'
new = r'''        let store: TaskStore
        if let state = tabCountFixture {
            let codexUnknown = MonitoredTask(id: "codex-cloud:synthetic", provider: .codex,
                title: tr("Облачная задача", "Cloud task"), activity: tr("Статус не подтверждён", "Status unconfirmed"),
                isActive: false, progress: nil, progressKind: .none, steps: [], updatedAt: Date(),
                isUnconfirmed: true, planConfirmed: false)
            let claudeUnknown = MonitoredTask(id: "claude:synthetic-unknown", provider: .claude,
                title: tr("Задача Claude Code", "Claude Code task"), activity: tr("Статус не подтверждён", "Status unconfirmed"),
                isActive: false, progress: nil, progressKind: .none, steps: [], updatedAt: Date(),
                isUnconfirmed: true, planConfirmed: false)
            var fixtures = [codexUnknown, claudeUnknown]
            if state == "mixed" {
                fixtures.append(MonitoredTask(id: "codex:synthetic-active", provider: .codex,
                    title: tr("Локальная задача", "Local task"), activity: tr("Выполняет действие", "Performing an action"),
                    isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: Date()))
                fixtures.append(MonitoredTask(id: "claude:synthetic-active", provider: .claude,
                    title: tr("Активная задача Claude Code", "Active Claude Code task"), activity: tr("Выполняет действие", "Performing an action"),
                    isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: Date()))
            }
            store = TaskStore(previewTasks: fixtures)
        } else if claudePlanFixture || codexPlanFixture {'''
replace_once(old, new)
replace_once('        if partialCodex { store.setPreviewCodexPartial() }',
             '        if tabCountFixture != nil { store.selectedProvider = tabCountFilter }\n        if partialCodex { store.setPreviewCodexPartial() }')
source.write_bytes(text.encode("utf-8"))
print("Prepared synthetic tab-counter preview")
