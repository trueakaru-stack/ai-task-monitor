import XCTest
@testable import AITaskMonitor

final class PreviewLocalizationTests: XCTestCase {
    @MainActor func testSyntheticExamplesFollowSelectedLanguage() throws {
        defer { AppLanguage.previewOverride = nil }
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            let preview = TaskStore.preview()
            let first = try XCTUnwrap(preview.tasks.first)
            let second = try XCTUnwrap(preview.tasks.dropFirst().first)
            if language == .ru {
                XCTAssertEqual(first.title, "Создать индикатор прогресса задач")
                XCTAssertEqual(first.steps.first?.title, "Собрать модель активных задач")
                XCTAssertEqual(second.title, "Задача Claude Code")
            } else {
                XCTAssertEqual(first.title, "Create a task progress indicator")
                XCTAssertEqual(first.steps.first?.title, "Build the active task model")
                XCTAssertEqual(second.title, "Claude Code task")
            }
            XCTAssertEqual(TaskStore.loopPreview().tasks.first?.title, first.title)
            XCTAssertEqual(TaskStore.journalPreview().journalTaskNames.values.first, first.title)
        }
    }

    @MainActor func testSuppliedTaskTextIsNotTranslated() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let originalTitle = "Исходное название задачи"
        let originalActivity = "Исходный ход выполнения"
        let task = MonitoredTask(id: "synthetic-original", provider: .codex, title: originalTitle,
                                 activity: originalActivity, isActive: true, progress: nil,
                                 progressKind: .none, steps: [], updatedAt: Date())
        let store = TaskStore(previewTasks: [task])
        XCTAssertEqual(try XCTUnwrap(store.tasks.first).title, originalTitle)
        XCTAssertEqual(try XCTUnwrap(store.tasks.first).activity, originalActivity)
    }
}
