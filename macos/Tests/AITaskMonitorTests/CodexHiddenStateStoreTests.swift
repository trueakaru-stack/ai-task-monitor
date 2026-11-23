import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

/// These tests write only beneath the explicitly isolated hosted-runner root.
final class CodexHiddenStateStoreTests: XCTestCase {
    private let threadA = "019127f4-35ae-7c73-9e72-a10123456789"
    private let threadB = "019127f4-35ae-7c73-9e72-a10123456780"
    private let homeA = String(repeating: "a", count: 64)
    private let homeB = String(repeating: "b", count: 64)
    private let pathA = String(repeating: "c", count: 64)
    private let pathB = String(repeating: "d", count: 64)
    private let stateName = "codex-uncertain-endings-v1.json"
    private let lockName = "codex-uncertain-endings-v1.lock"

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["RUNNER_OS"] == "macOS", env["AITM_MACOS_TEST_SANDBOX"] == "1",
              let rootPath = env["AITM_SYNTHETIC_TEST_ROOT"], let denied = env["AITM_CI_DENIED_FILE"] else {
            if env["AITM_SYNTHETIC_REQUIRED"] == "1" { throw CocoaError(.fileWriteNoPermission) }
            throw XCTSkip("Hidden-state tests require the isolated hosted-runner fixture")
        }
        guard env["HOME"] == nil, env["CODEX_HOME"] == nil else { throw CocoaError(.fileWriteNoPermission) }
        let probe = denied.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        if probe >= 0 { Darwin.close(probe); throw CocoaError(.fileWriteNoPermission) }
        guard errno == EACCES || errno == EPERM else { throw CocoaError(.fileWriteNoPermission) }
        let base = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let resolved = base.resolvingSymlinksInPath().standardizedFileURL
        let runnerTemp = URL(fileURLWithPath: "/Users/runner/work/_temp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let container = resolved.deletingLastPathComponent()
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard base == resolved, resolved.lastPathComponent == "temp",
              container.lastPathComponent.hasPrefix("aitm-card-tests."),
              container.deletingLastPathComponent() == runnerTemp,
              values.isDirectory == true, values.isSymbolicLink == false else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let root = resolved.appendingPathComponent("aitm-hidden-state-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func key(_ thread: String, _ source: String? = nil) -> CodexHiddenKey {
        CodexHiddenKey(codexHomeID: source ?? homeA, threadID: thread)
    }

    private func record(_ key: CodexHiddenKey, turn: String? = "turn-a", path: String? = nil,
                        device: UInt64? = nil, inode: UInt64? = nil) -> CodexHiddenRecord {
        CodexHiddenRecord(key: key, turnID: turn, rolloutPathDigest: path, device: device, inode: inode)
    }

    func testRoundTripAndCompareAndSwapPreserveOtherSources() throws {
        try withRoot { root in
            let store = CodexHiddenStateStore(directory: root.appendingPathComponent("store"))
            XCTAssertTrue(try store.load().isEmpty)
            let first = try store.insert(record(key(threadA), path: pathA, device: 7, inode: 9))
            let otherThread = try store.insert(record(key(threadB), turn: nil))
            let otherHome = try store.insert(record(key(threadA, homeB), turn: nil))
            let loaded = try store.load()
            XCTAssertEqual(loaded.count, 3)
            XCTAssertEqual(loaded[first.key], first)
            XCTAssertFalse(try store.remove(key: first.key, expectedRevision: otherThread.revision))
            XCTAssertEqual(try store.load().count, 3)
            XCTAssertTrue(try store.remove(key: first.key, expectedRevision: first.revision))
            let remaining = try store.load()
            XCTAssertEqual(remaining.count, 2)
            XCTAssertEqual(remaining[otherThread.key], otherThread)
            XCTAssertEqual(remaining[otherHome.key], otherHome)
            XCTAssertFalse(try store.remove(key: first.key, expectedRevision: first.revision))
        }
    }

    func testConflictingInsertKeepsHiddenWithUnknownProvenance() throws {
        try withRoot { root in
            let store = CodexHiddenStateStore(directory: root.appendingPathComponent("store"))
            let original = try store.insert(record(key(threadA), path: pathA, device: 7, inode: 9))
            let incoming = record(key(threadA), turn: "turn-b", path: pathB, device: 7, inode: 10)
            let merged = try store.insert(incoming)
            XCTAssertNotEqual(merged.revision, original.revision)
            XCTAssertNotEqual(merged.revision, incoming.revision)
            XCTAssertNil(merged.turnID)
            XCTAssertNil(merged.rolloutPathDigest)
            XCTAssertNil(merged.device)
            XCTAssertNil(merged.inode)
            XCTAssertEqual(try store.load()[merged.key], merged)
            XCTAssertFalse(try store.remove(key: original.key, expectedRevision: original.revision))
            XCTAssertTrue(try store.remove(key: merged.key, expectedRevision: merged.revision))
        }
    }

    func testRepeatedHideInvalidatesEarlierRevisionAndUnknownCannotBeUpgraded() throws {
        try withRoot { root in
            let store = CodexHiddenStateStore(directory: root.appendingPathComponent("store"))
            let initial = try store.insert(record(key(threadA), turn: nil))
            let repeated = try store.insert(initial)
            XCTAssertNotEqual(initial.revision, repeated.revision)
            XCTAssertFalse(try store.remove(key: initial.key, expectedRevision: initial.revision))
            // A stale caller may replay the original record after another hide.
            // It must not restore the original revision (an ABA race).
            let replay = try store.insert(initial)
            XCTAssertNotEqual(replay.revision, initial.revision)
            XCTAssertNotEqual(replay.revision, repeated.revision)
            XCTAssertFalse(try store.remove(key: initial.key, expectedRevision: initial.revision))
            XCTAssertFalse(try store.remove(key: repeated.key, expectedRevision: repeated.revision))
            let newEvidence = record(key(threadA), path: pathA, device: 7, inode: 9)
            let merged = try store.insert(newEvidence)
            XCTAssertNil(merged.turnID)
            XCTAssertNil(merged.rolloutPathDigest)
            XCTAssertNil(merged.device)
            XCTAssertNil(merged.inode)
            XCTAssertFalse(try store.remove(key: repeated.key, expectedRevision: repeated.revision))
            XCTAssertFalse(try store.remove(key: replay.key, expectedRevision: replay.revision))
            XCTAssertEqual(try store.load()[merged.key], merged)
        }
    }

    func testIncompleteIdentityAndUnexpectedIdentifiersAreRejected() throws {
        try withRoot { root in
            let store = CodexHiddenStateStore(directory: root.appendingPathComponent("store"))
            XCTAssertThrowsError(try store.insert(record(key(threadA), path: pathA, device: 7))) {
                XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid)
            }
            XCTAssertThrowsError(try store.insert(record(CodexHiddenKey(codexHomeID: "not-a-digest", threadID: threadA)))) {
                XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid)
            }
            XCTAssertThrowsError(try store.insert(record(key("not-a-thread-id")))) {
                XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid)
            }
            XCTAssertThrowsError(try store.insert(record(key(threadA), turn: "message with spaces"))) {
                XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid)
            }
            XCTAssertThrowsError(try store.remove(key: key(threadA), expectedRevision: "not-a-revision")) {
                XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid)
            }
            XCTAssertTrue(try store.load().isEmpty)
        }
    }

    func testDuplicateAndUnexpectedJSONKeysFailWithoutOverwritingData() throws {
        try withRoot { root in
            let directory = root.appendingPathComponent("store")
            let store = CodexHiddenStateStore(directory: directory)
            let saved = try store.insert(record(key(threadA)))
            let file = directory.appendingPathComponent(stateName)
            let original = try Data(contentsOf: file)
            let text = try XCTUnwrap(String(data: original, encoding: .utf8))
            XCTAssertTrue(text.contains("\"version\":1"))
            let duplicate = Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1").utf8)
            try duplicate.write(to: file)
            XCTAssertEqual(chmod(file.path, mode_t(0o600)), 0)
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid) }
            XCTAssertThrowsError(try store.insert(saved)) { XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid) }
            XCTAssertEqual(try Data(contentsOf: file), duplicate)
            let unexpected = Data((String(text.dropLast()) + ",\"extra\":1}").utf8)
            try unexpected.write(to: file)
            XCTAssertEqual(chmod(file.path, mode_t(0o600)), 0)
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid) }
            XCTAssertEqual(try Data(contentsOf: file), unexpected)
        }
    }

    func testOversizedStateIsRejectedWithoutReplacingIt() throws {
        try withRoot { root in
            let directory = root.appendingPathComponent("store")
            let store = CodexHiddenStateStore(directory: directory)
            _ = try store.load()
            let file = directory.appendingPathComponent(stateName)
            let data = Data(repeating: 0x20, count: 524_289)
            try data.write(to: file)
            XCTAssertEqual(chmod(file.path, mode_t(0o600)), 0)
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .invalid) }
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testSymlinkedStateAndLockAreNeverFollowed() throws {
        try withRoot { root in
            let directory = root.appendingPathComponent("store")
            let store = CodexHiddenStateStore(directory: directory)
            _ = try store.load()
            let target = root.appendingPathComponent("sentinel")
            let contents = Data("synthetic sentinel".utf8)
            try contents.write(to: target)
            let state = directory.appendingPathComponent(stateName)
            try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
            XCTAssertThrowsError(try store.insert(record(key(threadA))))
            XCTAssertEqual(try Data(contentsOf: target), contents)
            try FileManager.default.removeItem(at: state)
            let lock = directory.appendingPathComponent(lockName)
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: target), contents)
        }
    }

    func testSymlinkedParentAndHardlinkedStateAreRejected() throws {
        try withRoot { root in
            let actual = root.appendingPathComponent("actual")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
            let unsafe = CodexHiddenStateStore(directory: alias.appendingPathComponent("child"))
            XCTAssertThrowsError(try unsafe.load())
            XCTAssertFalse(FileManager.default.fileExists(atPath: actual.appendingPathComponent("child").path))

            let directory = root.appendingPathComponent("store")
            let store = CodexHiddenStateStore(directory: directory)
            _ = try store.insert(record(key(threadA)))
            let state = directory.appendingPathComponent(stateName)
            let hardlink = root.appendingPathComponent("hardlink")
            XCTAssertEqual(link(state.path, hardlink.path), 0)
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .unsafe) }
        }
    }

    func testBusyLockThrowsAndDoesNotChangeState() throws {
        try withRoot { root in
            let directory = root.appendingPathComponent("store")
            let store = CodexHiddenStateStore(directory: directory)
            let saved = try store.insert(record(key(threadA)))
            let lock = directory.appendingPathComponent(lockName)
            let fd = open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try store.insert(record(key(threadB)))) {
                XCTAssertEqual($0 as? CodexHiddenStateStore.Failure, .busy)
            }
            XCTAssertEqual(flock(fd, LOCK_UN), 0)
            XCTAssertEqual(try store.load(), [saved.key: saved])
            _ = try store.insert(record(key(threadB)))
            XCTAssertEqual(try store.load().count, 2)
        }
    }

    func testSourceIdentifiersAreStableAndDistinctWithoutPersistingPaths() throws {
        try withRoot { root in
            let first = root.appendingPathComponent("source-a")
            let second = root.appendingPathComponent("source-b")
            let firstID = CodexHiddenKey.homeIdentifier(for: first)
            XCTAssertEqual(firstID, CodexHiddenKey.homeIdentifier(for: first))
            XCTAssertNotEqual(firstID, CodexHiddenKey.homeIdentifier(for: second))
            XCTAssertNotEqual(firstID, CodexHiddenKey.rolloutPathIdentifier(for: first))
            let store = CodexHiddenStateStore(directory: root.appendingPathComponent("store"))
            let key = CodexHiddenKey(codexHomeID: firstID, threadID: threadA)
            _ = try store.insert(record(key, turn: nil))
            let text = try String(contentsOf: root.appendingPathComponent("store").appendingPathComponent(stateName), encoding: .utf8)
            XCTAssertFalse(text.contains(first.path))
            XCTAssertFalse(text.contains(second.path))
            XCTAssertTrue(text.contains(firstID))
        }
    }
}
