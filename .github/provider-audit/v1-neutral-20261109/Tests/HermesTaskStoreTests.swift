import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

private final class HermesInspectionFixture {
    private let lock = NSLock()
    private var profiles: Result<[HermesProfile], Error>
    private var prepared: [String] = []
    private var shouldFailNextPreparation = false
    private let rootScope: String
    private var reads = 0

    init(_ profiles: [HermesProfile], rootScope: String) {
        self.profiles = .success(profiles)
        self.rootScope = rootScope
    }
    func read() throws -> [HermesProfile] { lock.lock(); defer { lock.unlock() }; reads += 1; return try profiles.get() }
    func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
    func set(_ value: Result<[HermesProfile], Error>) { lock.lock(); profiles = value; lock.unlock() }
    func prepare(_ profile: HermesProfile) throws {
        lock.lock(); defer { lock.unlock() }
        if shouldFailNextPreparation {
            shouldFailNextPreparation = false
            throw HermesIntegrationError(code: "operation-failed")
        }
        let current = try profiles.get()
        guard profile.id == "root", profile.state == "absent" else { throw HermesIntegrationError(code: "invalid-profile") }
        prepared.append(profile.id)
        profiles = .success(current.map { $0.id == profile.id
            ? HermesProfile(id: "root", name: "default", state: "prepared", scope: rootScope, error: nil, enabled: false) : $0 })
    }
    func failNextPreparation() { lock.lock(); defer { lock.unlock() }; shouldFailNextPreparation = true }
    func setRootEnabled(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let current = try profiles.get()
        profiles = .success(current.map { $0.id == "root"
            ? HermesProfile(id: "root", name: "default", state: "prepared", scope: rootScope, error: nil, enabled: enabled) : $0 })
    }
    func calls() -> [String] { lock.lock(); defer { lock.unlock() }; return prepared }
}

final class HermesTaskStoreTests: XCTestCase {
    @MainActor
    func testOnlyPreparedProfilesCanSupplyEventsAndScanFailureIsUnconfirmed() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-hermes-store-" + UUID().uuidString, isDirectory: true)
        let socketDirectory = "/private/tmp/aitm-hermes-channel-\(UUID().uuidString)"
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var runtime: ExternalProviderRuntime?
        defer {
            runtime?.stop()
            try? manager.removeItem(at: URL(fileURLWithPath: socketDirectory))
            try? manager.removeItem(at: root)
        }
        let rootScope = String(repeating: "a", count: 32), workScope = String(repeating: "b", count: 32)
        let absentRoot = HermesProfile(id: "root", name: "default", state: "absent", scope: nil, error: nil)
        let disabledRoot = HermesProfile(id: "root", name: "default", state: "prepared", scope: rootScope, error: nil, enabled: false)
        let preparedWork = HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: workScope, error: nil, enabled: true)
        let fixture = HermesInspectionFixture([disabledRoot, preparedWork], rootScope: rootScope)
        let context = HermesIntegration.Context(python: root.appendingPathComponent("python"), home: root,
                                                 project: root.appendingPathComponent("project"), assets: root)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("codex")),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("claude.jsonl")),
                              journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")),
                              enableExternalProviders: true, openCodeConnection: { .connected },
                              makeExternalRuntime: {
                                  let value = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: socketDirectory))
                                  runtime = value
                                  return value
                              }, inspectKimiConnection: { throw KimiIntegrationError(code: "installation-unconfirmed") },
                              discoverHermesContext: { context }, inspectHermesProfiles: { _ in try fixture.read() },
                              prepareHermesProfile: { profile, _ in try fixture.prepare(profile) }, hermesScanInterval: 0.1)
        func wait(_ message: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline && !condition() {
                store.refresh()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertTrue(condition(), message)
        }
        func send(_ session: String, epoch: UInt64) throws {
            let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: socketDirectory + "/events.sock"))
            defer { Darwin.close(descriptor) }
            let tick = DispatchTime.now().uptimeNanoseconds
            XCTAssertLessThanOrEqual(epoch, tick)
            let body = Data(#"{"version":1,"provider":"hermes","session":"\#(session)","kind":"started","turn":"turn-\#(epoch)","epoch":\#(epoch),"tick":\#(tick)}"#.utf8)
            let count = body.count
            let header = Data([UInt8(count & 255), UInt8((count >> 8) & 255), UInt8((count >> 16) & 255), UInt8((count >> 24) & 255)])
            XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
            XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
        }
        wait("Profiles did not load") { store.hermesProfiles.count == 2 && runtime != nil }
        var epoch = DispatchTime.now().uptimeNanoseconds
        try send(rootScope + "_disabled", epoch: epoch)
        try send(workScope + "_work", epoch: epoch)
        wait("Prepared profile event did not arrive") { store.tasks.contains { $0.provider == .hermes } }
        XCTAssertEqual(store.tasks.filter { $0.provider == .hermes }.count, 1)
        XCTAssertTrue(try XCTUnwrap(store.tasks.first { $0.provider == .hermes }).isActive)
        fixture.set(.failure(HermesIntegrationError(code: "operation-failed")))
        wait("Failed check did not mark the source uncertain") { store.unavailableSources.contains(.hermes) }
        XCTAssertTrue(try XCTUnwrap(store.tasks.first { $0.provider == .hermes }).isUnconfirmed)
        let absentWork = HermesProfile(id: "profile:work", name: "work", state: "absent", scope: nil, error: nil)
        fixture.set(.success([absentRoot, absentWork]))
        wait("Removed bundles left a task visible") { !store.tasks.contains { $0.provider == .hermes } && !store.unavailableSources.contains(.hermes) }
        XCTAssertNotNil(runtime, "Other providers must keep their channel")
        store.selectedHermesProfile = "root"
        wait("Prepare did not become available") { store.hermesCanPrepare }
        XCTAssertNil(store.hermesEnableCommand, "Do not offer activation before the plugin is prepared")
        XCTAssertNil(store.hermesDisableCommand, "Do not offer removal before the plugin is prepared")
        fixture.failNextPreparation()
        store.prepareHermes()
        wait("Preparation failure was not shown") { !store.hermesSetupInProgress && !store.hermesMessage.isEmpty }
        store.selectedHermesProfile = "profile:work"
        XCTAssertTrue(store.hermesMessage.isEmpty, "A preparation error must not follow another profile")
        store.selectedHermesProfile = "root"
        wait("Prepare did not recover") { store.hermesCanPrepare }
        store.prepareHermes()
        wait("Prepared profile was not rescanned") { store.hermesSelectedProfile?.state == "prepared" }
        XCTAssertEqual(fixture.calls(), ["root"])
        XCTAssertEqual(store.hermesSelectedProfile?.enabled, false)
        XCTAssertEqual(store.hermesStatusMessage, tr("Плагин подготовлен; включите его в Hermes", "Plugin prepared; enable it in Hermes"))
        XCTAssertNotNil(store.hermesEnableCommand)
        XCTAssertNotNil(store.hermesDisableCommand)
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes }, "Preparation alone is not an agent event")
        try send(rootScope + "_before-enable", epoch: epoch)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes }, "A prepared but disabled profile must be ignored")
        try fixture.setRootEnabled(true)
        wait("Enabled profile was not detected") { store.hermesSelectedProfile?.enabled == true }
        XCTAssertEqual(store.hermesStatusMessage, tr("Плагин включён в локальных настройках", "Plugin enabled in local settings"))
        epoch = DispatchTime.now().uptimeNanoseconds
        try send(workScope + "_old", epoch: epoch)
        try send(rootScope + "_new", epoch: epoch)
        wait("New enabled profile event did not arrive") { store.tasks.contains { $0.provider == .hermes } }
        XCTAssertEqual(store.tasks.filter { $0.provider == .hermes }.count, 1)
        try fixture.setRootEnabled(false)
        wait("Disabling the plugin left a task visible") {
            store.hermesSelectedProfile?.enabled == false && !store.tasks.contains { $0.provider == .hermes }
        }
        try send(rootScope + "_after-disable", epoch: epoch)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes }, "Disabled profile events must be discarded")
    }

    @MainActor
    func testRejectedDuplicateRosterStaysClosedAfterValidRescan() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-hermes-invalid-" + UUID().uuidString, isDirectory: true)
        let socketDirectory = "/private/tmp/aitm-hermes-invalid-sock-\(UUID().uuidString)"
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var runtime: ExternalProviderRuntime?
        defer {
            runtime?.stop()
            try? manager.removeItem(at: URL(fileURLWithPath: socketDirectory))
            try? manager.removeItem(at: root)
        }
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        let rootProfile = HermesProfile(id: "root", name: "default", state: "prepared", scope: a, error: nil, enabled: true)
        let work = HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: b, error: nil, enabled: true)
        let duplicate = HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: a, error: nil, enabled: true)
        let fixture = HermesInspectionFixture([rootProfile, work], rootScope: a)
        let context = HermesIntegration.Context(python: root.appendingPathComponent("python"), home: root,
                                                 project: root.appendingPathComponent("project"), assets: root)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("codex")),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("claude.jsonl")),
                              journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")),
                              enableExternalProviders: true, openCodeConnection: { .connected },
                              makeExternalRuntime: {
                                  let value = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: socketDirectory))
                                  runtime = value
                                  return value
                              }, inspectKimiConnection: { throw KimiIntegrationError(code: "installation-unconfirmed") },
                              discoverHermesContext: { context }, inspectHermesProfiles: { _ in try fixture.read() },
                              hermesScanInterval: 0.1)
        func wait(_ message: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline && !condition() {
                store.refresh()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertTrue(condition(), message)
        }
        func send(_ json: String) throws {
            let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: socketDirectory + "/events.sock"))
            defer { Darwin.close(descriptor) }
            let body = Data(json.utf8), n = body.count
            let header = Data([UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8((n >> 24) & 255)])
            XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
            XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
        }
        wait("Initial profiles not loaded") { store.hermesProfiles.count == 2 && runtime != nil }
        let epoch = DispatchTime.now().uptimeNanoseconds
        try send(#"{"version":1,"provider":"hermes","session":"\#(a)_old","kind":"started","epoch":\#(epoch),"tick":\#(epoch + 1)}"#)
        try send(#"{"version":1,"provider":"opencode","session":"other","kind":"started"}"#)
        wait("Initial tasks missing") { store.tasks.contains { $0.id == "hermes:\(a)_old" } && store.tasks.contains { $0.id == "opencode:other" } }
        fixture.set(.success([rootProfile, duplicate]))
        wait("Rejected roster did not hide old task") { store.unavailableSources.contains(.hermes) && !store.tasks.contains { $0.provider == .hermes } }
        XCTAssertTrue(store.tasks.contains { $0.id == "opencode:other" && $0.isActive })
        let before = fixture.readCount()
        fixture.set(.success([rootProfile, work]))
        wait("Valid roster was not scanned") { fixture.readCount() > before && !store.hermesScanInProgress }
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes }, "The rejected conflict must not be forgotten.")
        XCTAssertTrue(store.unavailableSources.contains(.hermes))
        XCTAssertTrue(store.tasks.contains { $0.id == "opencode:other" && $0.isActive })
    }
}
