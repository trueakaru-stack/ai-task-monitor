import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class CodexGroupingVisualTests: XCTestCase {
    @MainActor
    func testRenderSyntheticGroupedParent() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["RUNNER_OS"] == "macOS", env["AITM_MACOS_TEST_SANDBOX"] == "1",
              let rootPath = env["AITM_SYNTHETIC_TEST_ROOT"], let denied = env["AITM_CI_DENIED_FILE"],
              env["HOME"] == nil, env["CODEX_HOME"] == nil else {
            if env["AITM_SYNTHETIC_REQUIRED"] == "1" { throw CocoaError(.fileWriteNoPermission) }
            throw XCTSkip("Synthetic renders require the isolated hosted runner")
        }
        let probe = denied.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if probe >= 0 { Darwin.close(probe); throw CocoaError(.fileReadNoPermission) }
        guard errno == EACCES || errno == EPERM else { throw CocoaError(.fileReadNoPermission) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let runnerTemp = URL(fileURLWithPath: "/Users/runner/work/_temp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let parent = resolved.deletingLastPathComponent()
        guard root == resolved, resolved.lastPathComponent == "temp",
              parent.lastPathComponent.hasPrefix("aitm-card-tests."),
              parent.deletingLastPathComponent() == runnerTemp else { throw CocoaError(.fileWriteNoPermission) }
        let output = resolved.appendingPathComponent("grouping-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { AppLanguage.previewOverride = nil }
        let rootID = "019127f4-35ae-7c73-9e72-a10123456789"
        let ids = ["019127f4-35ae-7c73-9e72-a10123456780", "019127f4-35ae-7c73-9e72-a10123456781",
                   "019127f4-35ae-7c73-9e72-a10123456782"]
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            for dark in [false, true] {
                for compact in [false, true] {
                  for disclosureOpen in [false, true] {
                    let title = tr("Очень длинное название родительской задачи для проверки обрезки и подсказки",
                                   "A very long parent task title for checking truncation and its tooltip")
                    let parentTask = MonitoredTask(id: rootID, provider: .codex, title: title,
                        activity: tr("Проверяю сохранение основного действия", "Checking that the parent activity stays visible"),
                        isActive: true, progress: 50, progressKind: .exact,
                        steps: [TaskStep(title: tr("Первый этап", "First step"), status: .done),
                                TaskStep(title: tr("Второй этап", "Second step"), status: .active)],
                        updatedAt: Date())
                    let children = ids.enumerated().map { offset, id in
                        MonitoredTask(id: id, provider: .codex,
                            title: tr("Помощник \(offset + 1)", "Assistant \(offset + 1)"),
                            activity: tr("Статус не подтверждён", "Status unconfirmed"), isActive: false, progress: nil,
                            progressKind: .none, steps: [], updatedAt: Date(), isUnconfirmed: true,
                            lastKnownActivity: tr("Последнее проверенное действие \(offset + 1)", "Last observed action \(offset + 1)"))
                    }
                    let grouped = CodexTaskGrouping.project([parentTask] + children,
                        parents: [ids[0]: rootID, ids[1]: rootID, ids[2]: ids[0]], titles: [rootID: title])
                    let item = try XCTUnwrap(grouped.first)
                    XCTAssertEqual(grouped.count, 1)
                    XCTAssertEqual(item.codexAgentCount, 3)
                    XCTAssertEqual(item.title, title)
                    XCTAssertEqual(item.progress, parentTask.progress)
                    XCTAssertEqual(item.codexAgents?.count, 3)
                    XCTAssertEqual(item.codexAgents?.first?.activity,
                                   tr("Последнее проверенное действие 1", "Last observed action 1"))
                    let store = TaskStore(codexReader: CodexTaskReader(codexHome: resolved.appendingPathComponent("missing-codex")),
                                          claudeReader: ClaudeTaskReader(eventFile: resolved.appendingPathComponent("missing-claude")),
                                          previewTasks: grouped)
                    store.isCompact = compact
                    if disclosureOpen { store.toggleCodexGroup(rootID) }
                    XCTAssertEqual(store.isCodexGroupExpanded(rootID), disclosureOpen)
                    XCTAssertEqual(store.count(for: .all), 1)
                    let size = compact ? NSSize(width: 372, height: disclosureOpen ? 340 : 182) : NSSize(width: 560, height: 700)
                    let view = RootView().environmentObject(store).environment(\.colorScheme, dark ? .dark : .light)
                    let hosting = NSHostingView(rootView: view)
                    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    hosting.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = hosting
                    window.orderFrontRegardless()
                    hosting.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "grouped-\(language.rawValue)-\(dark ? "dark" : "light")-\(compact ? "compact" : "expanded")-\(disclosureOpen ? "open" : "closed").png"
                    let destination = output.appendingPathComponent(name).path
                    guard destination.hasPrefix(output.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
                    let descriptor = destination.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
                    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    try handle.write(contentsOf: bytes)
                    try handle.close()
                    window.close()
                  }
                }
            }
        }
    }
}
