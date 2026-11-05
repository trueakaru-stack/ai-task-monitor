import Foundation
import XCTest
@testable import AITaskMonitor

final class HermesObserverStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ session: String, _ kind: String, _ tick: UInt64, _ epoch: UInt64,
                       request: String = "", turn: String = "") throws -> ExternalProviderEvent {
        var body: [String: Any] = ["version": 1, "provider": "hermes", "session": session,
                                   "kind": kind, "tick": tick, "epoch": epoch]
        if !request.isEmpty { body["request"] = request }
        if !turn.isEmpty { body["turn"] = turn }
        return try XCTUnwrap(ExternalProviderEventParser.parse(JSONSerialization.data(withJSONObject: body)))
    }

    func testConcurrentApprovalsAndOutOfOrderEvents() throws {
        let store = ExternalProviderStateStore()
        let base = DispatchTime.now().uptimeNanoseconds - 1_000_000_000
        let epoch = base - 1_000
        XCTAssertTrue(store.apply(try event("s", "started", base + 1, epoch, turn: "turn_1"), now: now))
        XCTAssertTrue(store.apply(try event("s", "waiting", base + 2, epoch, request: "a"), now: now))
        XCTAssertTrue(store.apply(try event("s", "active", base + 3, epoch), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "waiting")
        XCTAssertTrue(store.apply(try event("s", "waiting", base + 4, epoch, request: "b"), now: now))
        XCTAssertTrue(store.apply(try event("s", "unknown", base + 5, epoch, request: "a"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "waiting")
        XCTAssertTrue(store.apply(try event("other", "started", base + 1, epoch, turn: "turn_2"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == "other" }?.status, "active")
        XCTAssertTrue(store.apply(try event("s", "unknown", base + 7, epoch, request: "b"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == "s" }?.status, "unknown")

        let reordered = ExternalProviderStateStore()
        XCTAssertTrue(reordered.apply(try event("s", "started", base + 1, epoch, turn: "turn_1"), now: now))
        XCTAssertTrue(reordered.apply(try event("s", "unknown", base + 5, epoch, request: "a"), now: now))
        XCTAssertFalse(reordered.apply(try event("s", "waiting", base + 2, epoch, request: "a"), now: now))
        XCTAssertTrue(reordered.apply(try event("s", "active", base + 4, epoch), now: now))
        XCTAssertEqual(reordered.snapshot(now: now).first?.status, "unknown")

        let ended = ExternalProviderStateStore()
        XCTAssertTrue(ended.apply(try event("s", "started", base + 1, epoch, turn: "turn_1"), now: now))
        XCTAssertTrue(ended.apply(try event("s", "idle", base + 3, epoch, turn: "turn_1"), now: now))
        XCTAssertFalse(ended.apply(try event("s", "active", base + 2, epoch), now: now))
        XCTAssertTrue(ended.snapshot(now: now).isEmpty)

        let conflict = ExternalProviderStateStore()
        XCTAssertTrue(conflict.apply(try event("s", "started", base + 1, epoch, turn: "turn_1"), now: now))
        XCTAssertTrue(conflict.apply(try event("s", "waiting", base + 2, epoch, request: "a"), now: now))
        XCTAssertTrue(conflict.apply(try event("s", "idle", base + 3, epoch, turn: "turn_1"), now: now))
        XCTAssertEqual(conflict.snapshot(now: now).first?.status, "unknown")

        let bounded = ExternalProviderStateStore()
        for index in 0..<64 {
            let index = UInt64(index)
            XCTAssertTrue(bounded.apply(try event("s", "waiting", base + 10 + 2 * index, epoch, request: "r\(index)"), now: now))
            XCTAssertTrue(bounded.apply(try event("s", "unknown", base + 11 + 2 * index, epoch, request: "r\(index)"), now: now))
        }
        XCTAssertTrue(bounded.apply(try event("s", "waiting", base + 500, epoch, request: "overflow"), now: now))
        XCTAssertEqual(bounded.snapshot(now: now).first?.status, "unknown")
    }

    func testGapAndReconnectRejectOldObserverEvenWhenCallbackRunsLate() throws {
        let store = ExternalProviderStateStore()
        let base = DispatchTime.now().uptimeNanoseconds - 1_000_000_000
        let epoch = base - 1_000
        XCTAssertTrue(store.apply(try event("s", "started", base + 1, epoch, turn: "turn_1"), now: now))
        XCTAssertTrue(store.apply(try event("s", "gap", base + 2, epoch), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "unknown")
        XCTAssertFalse(store.apply(try event("s", "started", base + 1, epoch, turn: "turn_1"), now: now))
        XCTAssertFalse(store.apply(try event("s", "started", DispatchTime.now().uptimeNanoseconds, epoch, turn: "turn_2"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "unknown")
        Thread.sleep(forTimeInterval: 0.002)
        let newEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event("s", "started", newEpoch + 1, newEpoch, turn: "turn_1"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "active")
        XCTAssertFalse(store.apply(try event("s", "active", DispatchTime.now().uptimeNanoseconds, epoch), now: now))

        let reconnect = ExternalProviderStateStore()
        reconnect.retainProviders(["hermes"])
        Thread.sleep(forTimeInterval: 0.002)
        let oldEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(reconnect.apply(try event("s", "started", oldEpoch + 1, oldEpoch, turn: "turn_1"), now: now))
        reconnect.retainProviders([])
        reconnect.retainProviders(["hermes"])
        XCTAssertFalse(reconnect.apply(try event("s", "started", DispatchTime.now().uptimeNanoseconds, oldEpoch, turn: "turn_2"), now: now))
        XCTAssertTrue(reconnect.snapshot(now: now).isEmpty)
    }

    func testAlreadyRunningObserverIsHiddenAndRecoversAfterRestart() throws {
        let store = ExternalProviderStateStore()
        let oldEpoch = DispatchTime.now().uptimeNanoseconds
        let oldTick = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.002)
        let scope = String(repeating: "f", count: 32), session = scope + "_session"
        store.retainProviders(["hermes"])
        store.retainSessionScopes(provider: "hermes", scopes: [scope])
        XCTAssertFalse(store.apply(try event(session, "started", oldTick, oldEpoch, turn: "turn_1"), now: now))
        for kind in ["started", "waiting", "idle", "failed", "interrupted", "completed", "unknown"] {
            Thread.sleep(forTimeInterval: 0.001)
            XCTAssertFalse(store.apply(try event(session, kind, DispatchTime.now().uptimeNanoseconds, oldEpoch), now: now))
            XCTAssertTrue(store.snapshot(now: now).isEmpty)
        }
        Thread.sleep(forTimeInterval: 0.002)
        let newEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event(session, "started", newEpoch + 1, newEpoch, turn: "turn_1"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "active")
    }

    func testOldTerminalEventsDoNotCreateOrReviveTasksAndDuplicatesDoNotUpdate() throws {
        let unseen = ExternalProviderStateStore()
        let oldEpoch = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.002)
        unseen.retainProviders(["hermes"])
        XCTAssertFalse(unseen.apply(try event("s", "idle", DispatchTime.now().uptimeNanoseconds, oldEpoch), now: now))
        XCTAssertTrue(unseen.snapshot(now: now).isEmpty)

        let closed = ExternalProviderStateStore()
        let closedEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(closed.apply(try event("s", "started", closedEpoch + 1, closedEpoch, turn: "turn"), now: now))
        Thread.sleep(forTimeInterval: 0.001)
        XCTAssertTrue(closed.apply(try event("s", "idle", DispatchTime.now().uptimeNanoseconds, closedEpoch, turn: "turn"), now: now))
        closed.markGap(provider: "hermes")
        Thread.sleep(forTimeInterval: 0.001)
        XCTAssertFalse(closed.apply(try event("s", "active", DispatchTime.now().uptimeNanoseconds, closedEpoch), now: now))
        XCTAssertTrue(closed.snapshot(now: now).isEmpty)

        let duplicate = ExternalProviderStateStore()
        Thread.sleep(forTimeInterval: 0.001)
        duplicate.retainProviders(["hermes"])
        Thread.sleep(forTimeInterval: 0.001)
        let duplicateEpoch = DispatchTime.now().uptimeNanoseconds
        let duplicateEvent = try event("s", "started", duplicateEpoch + 1, duplicateEpoch, turn: "turn_duplicate")
        XCTAssertTrue(duplicate.apply(duplicateEvent, now: now))
        XCTAssertEqual(duplicate.snapshot(now: now).first?.status, "active")
        XCTAssertFalse(duplicate.apply(duplicateEvent, now: now.addingTimeInterval(600)))
        XCTAssertEqual(duplicate.snapshot(now: now.addingTimeInterval(600)).first?.updatedAt, now)
    }

    func testNewObserverCanReportARealWaitingRequestAfterOldObserverIsRejected() throws {
        let store = ExternalProviderStateStore()
        let oldEpoch = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.001)
        store.retainProviders(["hermes"])
        Thread.sleep(forTimeInterval: 0.001)
        XCTAssertFalse(store.apply(try event("s", "active", DispatchTime.now().uptimeNanoseconds, oldEpoch), now: now))
        XCTAssertTrue(store.snapshot(now: now).isEmpty)
        let newEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event("s", "waiting", newEpoch + 1, newEpoch, request: "request_a"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "waiting")
    }

    func testLateTurnEventsCannotReviveOrCloseAnotherTurn() throws {
        let base = DispatchTime.now().uptimeNanoseconds - 1_000_000_000
        let epoch = base - 1_000
        let late = ExternalProviderStateStore()
        XCTAssertTrue(late.apply(try event("s", "started", base + 1, epoch, turn: "old"), now: now))
        XCTAssertTrue(late.apply(try event("s", "idle", base + 2, epoch, turn: "old"), now: now))
        XCTAssertFalse(late.apply(try event("s", "started", base + 3, epoch, turn: "old"), now: now))
        XCTAssertFalse(late.apply(try event("s", "active", base + 4, epoch, turn: "old"), now: now))
        XCTAssertFalse(late.apply(try event("s", "waiting", base + 5, epoch, request: "a", turn: "old"), now: now))
        XCTAssertFalse(late.apply(try event("s", "idle", base + 6, epoch), now: now))
        XCTAssertTrue(late.snapshot(now: now).isEmpty)

        let newTurnUnknown = ExternalProviderStateStore()
        XCTAssertTrue(newTurnUnknown.apply(try event("s", "started", base + 1, epoch, turn: "old"), now: now))
        XCTAssertTrue(newTurnUnknown.apply(try event("s", "idle", base + 2, epoch, turn: "old"), now: now))
        XCTAssertTrue(newTurnUnknown.apply(try event("s", "started", base + 3, epoch, turn: "new"), now: now))
        XCTAssertTrue(newTurnUnknown.apply(try event("s", "idle", base + 4, epoch), now: now))
        XCTAssertEqual(newTurnUnknown.snapshot(now: now).first?.status, "unknown")

        let terminalFirst = ExternalProviderStateStore()
        XCTAssertTrue(terminalFirst.apply(try event("s", "idle", base + 2, epoch, turn: "old"), now: now))
        XCTAssertFalse(terminalFirst.apply(try event("s", "started", base + 3, epoch, turn: "old"), now: now))
        XCTAssertTrue(terminalFirst.snapshot(now: now).isEmpty)

        let terminalAfterConnect = ExternalProviderStateStore()
        terminalAfterConnect.retainProviders(["hermes"])
        Thread.sleep(forTimeInterval: 0.002)
        let connectedEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(terminalAfterConnect.apply(try event("unseen", "idle", connectedEpoch + 1, connectedEpoch, turn: "closed"), now: now))
        XCTAssertTrue(terminalAfterConnect.snapshot(now: now).isEmpty)
        XCTAssertFalse(terminalAfterConnect.apply(try event("unseen", "started", connectedEpoch + 2, connectedEpoch, turn: "closed"), now: now))
        XCTAssertTrue(terminalAfterConnect.snapshot(now: now).isEmpty)
        XCTAssertTrue(terminalAfterConnect.apply(try event("unseen", "started", connectedEpoch + 3, connectedEpoch, turn: "new"), now: now))
        XCTAssertEqual(terminalAfterConnect.snapshot(now: now).first?.status, "active")

        let existingUnknown = ExternalProviderStateStore()
        existingUnknown.retainProviders(["hermes"])
        Thread.sleep(forTimeInterval: 0.001)
        let existingOldEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(existingUnknown.apply(try event("s", "idle", existingOldEpoch + 1, existingOldEpoch), now: now))
        let existingNewEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(existingUnknown.apply(try event("s", "idle", existingNewEpoch + 1, existingNewEpoch, turn: "closed"), now: now))
        XCTAssertEqual(existingUnknown.snapshot(now: now).first?.status, "unknown")

        let terminalLate = ExternalProviderStateStore()
        XCTAssertTrue(terminalLate.apply(try event("s", "started", base + 3, epoch, turn: "old"), now: now))
        XCTAssertTrue(terminalLate.apply(try event("s", "idle", base + 2, epoch, turn: "old"), now: now))
        XCTAssertFalse(terminalLate.apply(try event("s", "started", base + 4, epoch, turn: "old"), now: now))
        XCTAssertTrue(terminalLate.snapshot(now: now).isEmpty)

        let different = ExternalProviderStateStore()
        XCTAssertTrue(different.apply(try event("s", "started", base + 1, epoch, turn: "old"), now: now))
        XCTAssertTrue(different.apply(try event("s", "started", base + 2, epoch, turn: "new"), now: now))
        XCTAssertTrue(different.apply(try event("s", "idle", base + 3, epoch, turn: "old"), now: now))
        XCTAssertEqual(different.snapshot(now: now).first?.status, "active")
        XCTAssertFalse(different.apply(try event("s", "started", base + 4, epoch, turn: "old"), now: now))
        XCTAssertEqual(different.snapshot(now: now).first?.status, "active")

        let newTool = ExternalProviderStateStore()
        XCTAssertTrue(newTool.apply(try event("s", "started", base + 1, epoch, turn: "old"), now: now))
        XCTAssertTrue(newTool.apply(try event("s", "idle", base + 2, epoch, turn: "old"), now: now))
        XCTAssertTrue(newTool.apply(try event("s", "active", base + 3, epoch, turn: "new"), now: now))
        XCTAssertEqual(newTool.snapshot(now: now).first?.status, "active")
        XCTAssertTrue(newTool.apply(try event("s", "idle", base + 4, epoch, turn: "new"), now: now))
        XCTAssertTrue(newTool.snapshot(now: now).isEmpty)

        let ambiguousTool = ExternalProviderStateStore()
        XCTAssertTrue(ambiguousTool.apply(try event("s", "started", base + 1, epoch, turn: "current"), now: now))
        XCTAssertTrue(ambiguousTool.apply(try event("s", "active", base + 2, epoch, turn: "other"), now: now))
        XCTAssertEqual(ambiguousTool.snapshot(now: now).first?.status, "unknown")

        let missing = ExternalProviderStateStore()
        XCTAssertTrue(missing.apply(try event("s", "idle", base + 1, epoch), now: now))
        XCTAssertEqual(missing.snapshot(now: now).first?.status, "unknown")
        XCTAssertTrue(missing.apply(try event("s", "active", base + 2, epoch), now: now))
        XCTAssertEqual(missing.snapshot(now: now).first?.status, "unknown")

        let bounded = ExternalProviderStateStore()
        XCTAssertTrue(bounded.apply(try event("s", "started", base + 1, epoch, turn: "current"), now: now))
        for index in 0..<65 {
            XCTAssertTrue(bounded.apply(try event("s", "idle", base + 10 + UInt64(index), epoch, turn: "past\(index)"), now: now))
        }
        XCTAssertEqual(bounded.snapshot(now: now).first?.status, "unknown")
        XCTAssertTrue(bounded.apply(try event("s", "active", base + 100, epoch, turn: "current"), now: now))
        XCTAssertEqual(bounded.snapshot(now: now).first?.status, "unknown")
    }

    func testPythonAndSwiftUseTheSameMonotonicClock() throws {
        let before = DispatchTime.now().uptimeNanoseconds
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-B", "-c", "import time; print(time.monotonic_ns())"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let after = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(process.terminationStatus, 0)
        let value = try XCTUnwrap(UInt64(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertGreaterThanOrEqual(value + 1_000_000, before)
        XCTAssertLessThanOrEqual(value, after + 1_000_000)
    }

    func testProfileGapsAndReconnectionRemainIsolated() throws {
        let store = ExternalProviderStateStore()
        let scopeA = String(repeating: "a", count: 32), scopeB = String(repeating: "b", count: 32)
        let sessionA = scopeA + "_s", sessionB = scopeB + "_s"
        store.retainProviders(["hermes"])
        store.retainSessionScopes(provider: "hermes", scopes: [scopeA, scopeB])
        Thread.sleep(forTimeInterval: 0.002)
        let epoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event(sessionA, "started", epoch + 1, epoch, turn: "turn_a"), now: now))
        XCTAssertTrue(store.apply(try event(sessionB, "started", epoch + 1, epoch, turn: "turn_b"), now: now))
        store.markSessionScopesGap(provider: "hermes", scopes: [scopeA])
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == sessionA }?.status, "unknown")
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == sessionB }?.status, "active")
        XCTAssertFalse(store.apply(try event(sessionA, "active", DispatchTime.now().uptimeNanoseconds, epoch), now: now))
        XCTAssertTrue(store.apply(try event(sessionB, "active", DispatchTime.now().uptimeNanoseconds, epoch), now: now))
        store.markSessionScopesGap(provider: "hermes", scopes: [])
        Thread.sleep(forTimeInterval: 0.002)
        let freshEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event(sessionA, "started", freshEpoch + 1, freshEpoch, turn: "turn_fresh"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == sessionA }?.status, "active")
        store.retainSessionScopes(provider: "hermes", scopes: [scopeB])
        store.retainSessionScopes(provider: "hermes", scopes: [scopeA, scopeB])
        XCTAssertFalse(store.apply(try event(sessionA, "active", DispatchTime.now().uptimeNanoseconds, freshEpoch), now: now))
    }

    func testObserverMustStartAfterScopeAuthorization() throws {
        let store = ExternalProviderStateStore()
        let scope = String(repeating: "a", count: 32), session = scope + "_s"
        store.retainProviders(["hermes"])
        let preScanEpoch = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.001)
        store.retainSessionScopes(provider: "hermes", scopes: [scope])
        XCTAssertFalse(store.apply(try event(session, "started", DispatchTime.now().uptimeNanoseconds, preScanEpoch, turn: "before_scan"), now: now))
        XCTAssertTrue(store.snapshot(now: now).isEmpty)
        Thread.sleep(forTimeInterval: 0.001)
        let postScanEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event(session, "started", postScanEpoch + 1, postScanEpoch, turn: "after_scan"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "active")
    }

    func testOldAndUntaggedGapsCannotInvalidateNewGlobalObserver() throws {
        let store = ExternalProviderStateStore()
        store.retainProviders(["hermes"])
        let oldEpoch = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.001)
        store.retainProviders([])
        store.retainProviders(["hermes"])
        Thread.sleep(forTimeInterval: 0.001)
        let epoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event("s", "started", DispatchTime.now().uptimeNanoseconds, epoch, turn: "current"), now: now))
        XCTAssertFalse(store.apply(try event("s", "gap", DispatchTime.now().uptimeNanoseconds, oldEpoch), now: now))
        XCTAssertFalse(store.apply(try event("s", "gap", DispatchTime.now().uptimeNanoseconds + 3_000_000_000, oldEpoch), now: now))
        let legacy = try XCTUnwrap(ExternalProviderEventParser.parse(Data(#"{"version":1,"provider":"hermes","session":"s","kind":"gap"}"#.utf8)))
        XCTAssertFalse(store.apply(legacy, now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "active")
    }

    func testScopedGapsRespectReconnectAndKeepOtherProfilesActive() throws {
        let store = ExternalProviderStateStore()
        let scopeA = String(repeating: "a", count: 32), scopeB = String(repeating: "b", count: 32)
        let sessionA = scopeA + "_s", sessionB = scopeB + "_s"
        store.retainProviders(["hermes"])
        store.retainSessionScopes(provider: "hermes", scopes: [scopeA, scopeB])
        Thread.sleep(forTimeInterval: 0.001)
        let oldEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event(sessionA, "started", DispatchTime.now().uptimeNanoseconds, oldEpoch, turn: "old_a"), now: now))
        XCTAssertTrue(store.apply(try event(sessionB, "started", DispatchTime.now().uptimeNanoseconds, oldEpoch, turn: "old_b"), now: now))
        store.retainSessionScopes(provider: "hermes", scopes: [scopeB])
        store.retainSessionScopes(provider: "hermes", scopes: [scopeA, scopeB])
        Thread.sleep(forTimeInterval: 0.001)
        let newEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event(sessionA, "started", DispatchTime.now().uptimeNanoseconds, newEpoch, turn: "new_a"), now: now))
        XCTAssertFalse(store.apply(try event(scopeA + "_unknown", "gap", DispatchTime.now().uptimeNanoseconds, oldEpoch), now: now))
        XCTAssertFalse(store.apply(try event(sessionA, "gap", DispatchTime.now().uptimeNanoseconds + 3_000_000_000, oldEpoch), now: now))
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == sessionA }?.status, "active")
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == sessionB }?.status, "active")
        XCTAssertTrue(store.apply(try event(scopeA + "_unknown", "gap", DispatchTime.now().uptimeNanoseconds, newEpoch), now: now))
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == sessionA }?.status, "unknown")
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == sessionB }?.status, "active")
        XCTAssertFalse(store.apply(try event(sessionA, "active", DispatchTime.now().uptimeNanoseconds, newEpoch, turn: "new_a"), now: now))
        XCTAssertTrue(store.apply(try event(sessionB, "active", DispatchTime.now().uptimeNanoseconds, oldEpoch, turn: "old_b"), now: now))
        Thread.sleep(forTimeInterval: 0.001)
        let recoveredEpoch = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(store.apply(try event(sessionA, "started", DispatchTime.now().uptimeNanoseconds, recoveredEpoch, turn: "recovered"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == sessionA }?.status, "active")
    }

    func testInvalidMetadataIsRejected() {
        for value in [
            #"{"version":1,"provider":"hermes","session":"s","kind":"waiting","tick":true,"epoch":1,"request":"a"}"#,
            #"{"version":1,"provider":"hermes","session":"s","kind":"waiting","tick":1,"epoch":2,"request":"a"}"#,
            #"{"version":1,"provider":"hermes","session":"s","kind":"active","tick":2,"epoch":1,"request":"a"}"#,
            #"{"version":1,"provider":"opencode","session":"s","kind":"active","tick":2,"epoch":1}"#
        ] { XCTAssertNil(ExternalProviderEventParser.parse(Data(value.utf8))) }
    }
}
