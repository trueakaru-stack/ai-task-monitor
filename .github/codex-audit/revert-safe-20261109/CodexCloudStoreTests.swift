import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexCloudStoreTests: XCTestCase {
    @MainActor
    func testCloudOptInFailurePartialAndDisconnectKeepLocalTaskAccurate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-cloud-store-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent("codex")
        let sessions = codexHome.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let suite = "aitm-cloud-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try #"{"id":"019127f4-35ae-7c73-9e72-a10123456009","thread_name":"Local fixture"}"#.appending("\n").write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let rollout = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-019127f4-35ae-7c73-9e72-a10123456009.jsonl")
        try "".write(to: rollout, atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        mode=$(cat "$AITM_FIXTURE_DIR/mode")
        printf x > "$AITM_FIXTURE_DIR/started"
        case "$mode" in
          failure) exit 1 ;;
          slow) while :; do :; done ;;
          terminal) printf '%s' '{"tasks":[{"id":"cloud-one","status":"error"}],"cursor":null}' ;;
          partial)
            case "$*" in *'--cursor 2'*) n=2;; *'--cursor 3'*) n=3;; *'--cursor 4'*) n=4;; *'--cursor 5'*) n=5;; *) n=1;; esac
            next=$((n+1))
            printf '{"tasks":[{"id":"other-%s","status":"pending"}],"cursor":"%s"}' "$n" "$next" ;;
          *) printf '%s' '{"tasks":[{"id":"cloud-one","title":"Cloud fixture","status":"pending"}],"cursor":null}' ;;
        esac
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let mode = root.appendingPathComponent("mode")
        let started = root.appendingPathComponent("started")
        try "pending".write(to: mode, atomically: true, encoding: .utf8)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: codexHome),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("claude.jsonl")),
                              journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")),
                              enableCodexCloud: true, codexCloudDefaults: defaults, codexCloudInterval: 0.15,
                              makeCodexCloudClient: { CodexCloudClient(executable: executable, environment: ["PATH": "/usr/bin:/bin", "AITM_FIXTURE_DIR": root.path]) })
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(1))
        try "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".write(to: rollout, atomically: true, encoding: .utf8)
        store.refresh()
        XCTAssertTrue(store.tasks.contains { $0.id == "019127f4-35ae-7c73-9e72-a10123456009" && $0.isActive })
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))

        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while !condition() && Date() < deadline {
                store.refresh()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertTrue(condition())
        }
        store.setCodexCloudEnabled(true)
        waitFor { store.tasks.contains { $0.id.hasPrefix("codex-cloud:") } }
        let cloud = try XCTUnwrap(store.tasks.first { $0.id.hasPrefix("codex-cloud:") })
        XCTAssertTrue(cloud.isUnconfirmed)
        XCTAssertFalse(cloud.isActive)
        XCTAssertNil(cloud.progress)
        XCTAssertEqual(store.count(for: .codex), 1)
        XCTAssertTrue(defaults.bool(forKey: "codexCloudEnabled"))

        try "failure".write(to: mode, atomically: true, encoding: .utf8)
        waitFor { store.codexCloudFailed }
        XCTAssertTrue(store.tasks.contains { $0.id == cloud.id && $0.isUnconfirmed })
        XCTAssertTrue(store.tasks.contains { $0.id == "019127f4-35ae-7c73-9e72-a10123456009" && $0.isActive })
        try "partial".write(to: mode, atomically: true, encoding: .utf8)
        waitFor { store.codexCloudPartial && !store.codexCloudFailed }
        XCTAssertTrue(store.tasks.contains { $0.id == cloud.id && $0.isUnconfirmed })
        try "terminal".write(to: mode, atomically: true, encoding: .utf8)
        waitFor { !store.codexCloudPartial && !store.codexCloudFailed && !store.tasks.contains { $0.id.hasPrefix("codex-cloud:") } }
        XCTAssertTrue(store.tasks.contains { $0.id == "019127f4-35ae-7c73-9e72-a10123456009" && $0.isActive })

        try "slow".write(to: mode, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: started)
        waitFor { FileManager.default.fileExists(atPath: started.path) }
        store.setCodexCloudEnabled(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(defaults.bool(forKey: "codexCloudEnabled"))
        XCTAssertFalse(store.codexCloudEnabled)
        XCTAssertFalse(store.tasks.contains { $0.id.hasPrefix("codex-cloud:") })
        XCTAssertTrue(store.tasks.contains { $0.id == "019127f4-35ae-7c73-9e72-a10123456009" && $0.isActive })
    }
}
