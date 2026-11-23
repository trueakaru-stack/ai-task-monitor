import XCTest
@testable import AITaskMonitor

@MainActor
final class CompactSourceWarningTests: XCTestCase {
    func testCodexPartialIsVisibleOnlyInExpandedMode() {
        defer { AppLanguage.previewOverride = nil }
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            let store = TaskStore.preview()
            let originalTasks = store.tasks
            store.setPreviewCodexPartial()

            XCTAssertEqual(store.unavailableMessage, language == .ru
                ? "Часть данных Codex недоступна" : "Some Codex data is unavailable")
            XCTAssertEqual(store.compactUnavailableMessage, "")
            XCTAssertEqual(store.tasks, originalTasks, "Changing warning presentation must not change task data")
        }
    }

    func testEmptyCompactViewDoesNotClaimNoActiveTasksWhenCodexIsPartial() {
        defer { AppLanguage.previewOverride = nil }
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            let store = TaskStore(previewTasks: [])
            XCTAssertEqual(store.compactEmptyMessage, language == .ru
                ? "Активных задач нет" : "No active tasks")
            store.setPreviewCodexPartial()
            XCTAssertEqual(store.compactEmptyMessage, language == .ru
                ? "Нет отображаемых задач" : "No tasks to display")
            XCTAssertFalse(store.unavailableMessage.isEmpty)
        }
    }

    func testOtherSourceWarningsRemainWhenCodexIsPartial() {
        defer { AppLanguage.previewOverride = nil }
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            let store = TaskStore(previewTasks: [])
            store.testSetExternalAvailability(previous: [], unavailable: [.claude, .deepseek],
                                              partiallyUnavailable: [.deepseek])
            let otherWarnings = language == .ru
                ? "Нет данных от Claude Code. Часть данных DeepSeek Harness недоступна"
                : "No data from Claude Code. Some DeepSeek Harness data is unavailable"
            XCTAssertEqual(store.unavailableMessage, otherWarnings)
            store.setPreviewCodexPartial()
            let codexWarning = language == .ru
                ? "Часть данных Codex недоступна" : "Some Codex data is unavailable"
            XCTAssertEqual(store.unavailableMessage, otherWarnings + ". " + codexWarning)
            XCTAssertEqual(store.compactUnavailableMessage, otherWarnings)
            XCTAssertEqual(store.compactEmptyMessage, otherWarnings)
        }
    }

    func testFullyUnavailableCodexIsNeverHidden() {
        defer { AppLanguage.previewOverride = nil }
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            let store = TaskStore(previewTasks: [])
            store.testSetExternalAvailability(previous: [], unavailable: [.codex, .claude])
            store.setPreviewCodexPartial()
            let expected = language == .ru
                ? "Нет данных от Codex, Claude Code" : "No data from Codex, Claude Code"
            XCTAssertEqual(store.unavailableMessage, expected)
            XCTAssertEqual(store.compactUnavailableMessage, expected)
            XCTAssertEqual(store.compactEmptyMessage, expected)
        }
    }
}
