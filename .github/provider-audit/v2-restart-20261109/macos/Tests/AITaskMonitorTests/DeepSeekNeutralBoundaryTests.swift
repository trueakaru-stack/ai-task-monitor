import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// Only synthetic sockets, profiles and events. Requires macOS XCTest.
final class DeepSeekNeutralBoundaryTests: XCTestCase {
    private enum FixtureError: Error { case unavailable }
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)

    private func send(_ value: [String: Any], directory: URL) throws {
        let socket = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory.path + "/events.sock"))
        defer { Darwin.close(socket) }
        let body = try JSONSerialization.data(withJSONObject: value), length = body.count
        let header = Data([UInt8(length & 255), UInt8((length >> 8) & 255),
                           UInt8((length >> 16) & 255), UInt8((length >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(socket, data: header + body))
        XCTAssertEqual(ClaudeLoopSocket.read(socket, count: 1), Data([0x06]))
    }

    private func event(_ provider: String, _ session: String, _ kind: String) -> [String: Any] {
        ["version": 1, "provider": provider, "session": session, "kind": kind]
    }

    private func plan(_ provider: String, _ session: String) -> [String: Any] {
        ["version": 1, "provider": provider, "session": session, "kind": "plan",
         "steps": [["title": "SYNTHETIC_FOREIGN_PLAN", "status": "done"]]]
    }

    private func neutral(_ tasks: [MonitoredTask], _ session: String, file: StaticString = #filePath,
                         line: UInt = #line) throws {
        let task = try XCTUnwrap(tasks.first { $0.id == "deepseek-unassigned:" + session }, file: file, line: line)
        XCTAssertTrue(task.isUnconfirmed, file: file, line: line)
        XCTAssertFalse(task.isActive, file: file, line: line)
        XCTAssertFalse(task.isWaiting, file: file, line: line)
        XCTAssertFalse(task.planConfirmed, file: file, line: line)
        XCTAssertNil(task.progress, file: file, line: line)
        XCTAssertTrue(task.steps.isEmpty, file: file, line: line)
        XCTAssertFalse(task.title.contains("SYNTHETIC_FOREIGN_PLAN"), file: file, line: line)
        XCTAssertFalse(task.activity.contains("SYNTHETIC_FOREIGN_PLAN"), file: file, line: line)
        XCTAssertFalse(tasks.contains { $0.id == "deepseek:" + session }, file: file, line: line)
    }

    func testUnownedThenClaimedSameSessionCannotBecomeConfirmedOrClose() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-neutral-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory.path))
        defer { runtime.stop() }
        let shared = a + "_shared", healthy = b + "_healthy"
        _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        try send(event("deepseek", healthy, "active"), directory: directory)
        try send(event("deepseek", shared, "active"), directory: directory)
        try send(plan("deepseek", shared), directory: directory)
        var tasks = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        try neutral(tasks, shared)
        XCTAssertTrue(try XCTUnwrap(tasks.first { $0.id == "deepseek:" + healthy }).isActive)

        // The sender prepared these old v1 messages before the roster changed.
        let delayedActive = event("deepseek", shared, "active")
        let delayedPlan = plan("deepseek", shared)
        let delayedTerminal = event("deepseek", shared, "completed")
        _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
        try send(delayedActive, directory: directory)
        try send(delayedPlan, directory: directory)
        tasks = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
        try neutral(tasks, shared)
        XCTAssertTrue(try XCTUnwrap(tasks.first { $0.id == "deepseek:" + healthy }).isActive)
        try send(delayedTerminal, directory: directory)
        tasks = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
        try neutral(tasks, shared)
        XCTAssertTrue(try XCTUnwrap(tasks.first { $0.id == "deepseek:" + healthy }).isActive)

        let disabled = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]],
                                        deepSeekDisabledScopes: [a])
        XCTAssertFalse(disabled.contains { $0.id == "deepseek-unassigned:" + shared })
        XCTAssertTrue(try XCTUnwrap(disabled.first { $0.id == "deepseek:" + healthy }).isActive)
        let restored = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
        try neutral(restored, shared)
        let saved = runtime.parkState(markTransportGap: false).snapshot(now: Date())
        XCTAssertTrue(try XCTUnwrap(saved.first { $0.session == shared }).steps.isEmpty)
    }

    func testAmbiguousFormerCardAndLaterEventsNeverExposePlan() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-neutral-ambiguous-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory.path))
        defer { runtime.stop() }
        let session = a + "_same", neighbour = b + "_neighbour"
        _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
        try send(event("deepseek", session, "active"), directory: directory)
        try send(plan("deepseek", session), directory: directory)
        try send(event("deepseek", neighbour, "active"), directory: directory)
        let old = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
        XCTAssertEqual(old.first { $0.id == "deepseek:" + session }?.steps.first?.title, "SYNTHETIC_FOREIGN_PLAN")
        var tasks = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]],
            uncertainScopes: [.deepseek: [a]], ambiguousScopes: [.deepseek: [a]], deepSeekHistoryLost: true)
        try neutral(tasks, session)
        XCTAssertTrue(try XCTUnwrap(tasks.first { $0.id == "deepseek:" + neighbour }).isActive)
        try send(plan("deepseek", session), directory: directory)
        try send(event("deepseek", session, "active"), directory: directory)
        try send(event("deepseek", session, "completed"), directory: directory)
        tasks = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]], deepSeekHistoryLost: true)
        try neutral(tasks, session)
        XCTAssertTrue(try XCTUnwrap(tasks.first { $0.id == "deepseek:" + neighbour }).isActive)
    }

    func testNewSessionInPreviouslyUnassignedScopeAlsoStaysNeutral() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-neutral-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory.path))
        defer { runtime.stop() }
        _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        try send(event("deepseek", a + "_old", "completed"), directory: directory)
        XCTAssertTrue(runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]]).isEmpty)
        _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
        try send(event("deepseek", a + "_new", "active"), directory: directory)
        try send(plan("deepseek", a + "_new"), directory: directory)
        try neutral(runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]]), a + "_new")
    }

    func testOpenCodeReconnectDropsOldAndLatePlanWithoutAffectingNeighbour() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-neutral-open-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory.path))
        defer { runtime.stop() }
        _ = runtime.snapshot(allowed: [.deepseek, .opencode], profileScopes: [.deepseek: [b]])
        try send(event("deepseek", b + "_healthy", "active"), directory: directory)
        try send(event("opencode", "one", "active"), directory: directory)
        try send(plan("opencode", "one"), directory: directory)
        _ = runtime.snapshot(allowed: [.deepseek, .opencode], profileScopes: [.deepseek: [b]])
        _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        _ = runtime.snapshot(allowed: [.deepseek, .opencode], profileScopes: [.deepseek: [b]])
        try send(plan("opencode", "one"), directory: directory)
        try send(event("opencode", "one", "completed"), directory: directory)
        let tasks = runtime.snapshot(allowed: [.deepseek, .opencode], profileScopes: [.deepseek: [b]])
        let open = try XCTUnwrap(tasks.first { $0.id == "opencode:one" })
        XCTAssertTrue(open.isUnconfirmed)
        XCTAssertFalse(open.planConfirmed)
        XCTAssertNil(open.progress)
        XCTAssertTrue(open.steps.isEmpty)
        XCTAssertTrue(try XCTUnwrap(tasks.first { $0.id == "deepseek:" + b + "_healthy" }).isActive)
    }

    #if DEBUG
    @MainActor
    func testAmbiguousFallbackRemovesTitlesAndKeepsNeighbourVisible() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-neutral-fallback-" + UUID().uuidString)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("codex")),
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("events")),
            previewTasks: [], openCodeConnection: { .connected },
            makeExternalRuntime: { throw FixtureError.unavailable })
        let initial = [DeepSeekProfile(name: "A", state: "connected", scope: a, error: nil),
                       DeepSeekProfile(name: "B", state: "connected", scope: b, error: nil)]
        let changed = [DeepSeekProfile(name: "A", state: "connected", scope: String(repeating: "c", count: 32), error: nil),
                       initial[1]]
        let old = MonitoredTask(id: "deepseek:" + a + "_old", provider: .deepseek,
            title: "SYNTHETIC_FOREIGN_PLAN", activity: "SYNTHETIC_FOREIGN_PLAN", isActive: true,
            progress: 100, progressKind: .exact,
            steps: [TaskStep(title: "SYNTHETIC_FOREIGN_PLAN", status: .done)], updatedAt: Date())
        let neighbour = MonitoredTask(id: "deepseek:" + b + "_good", provider: .deepseek,
            title: "neighbour", activity: "", isActive: true, progress: nil, progressKind: .none,
            steps: [], updatedAt: Date())
        let result = store.testExternalFallback(previous: [old, neighbour], deepSeekRosters: [initial, changed])
        try neutral(result.0, a + "_old")
        XCTAssertTrue(result.0.contains { $0.id == "deepseek:" + b + "_good" })
    }

    @MainActor
    func testOtherProviderPartialDoesNotHideFirstNeutralDeepSeekCard() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-neutral-neighbour-gap-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory.path))
        defer { runtime.stop() }
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: directory.appendingPathComponent("codex")),
            claudeReader: ClaudeTaskReader(eventFile: directory.appendingPathComponent("events")),
            previewTasks: [], openCodeConnection: { .partial }, makeExternalRuntime: { runtime })
        let roster = [DeepSeekProfile(name: "B", state: "connected", scope: b, error: nil)]
        _ = store.testExternalFallback(previous: [], deepSeekRosters: [roster])
        try send(event("deepseek", a + "_unassigned", "active"), directory: directory)
        try send(event("deepseek", b + "_healthy", "active"), directory: directory)
        let result = store.testExternalFallback(previous: [], deepSeekRosters: [roster])
        try neutral(result.0, a + "_unassigned")
        XCTAssertTrue(try XCTUnwrap(result.0.first { $0.id == "deepseek:" + b + "_healthy" }).isActive)
    }
    #endif
}
