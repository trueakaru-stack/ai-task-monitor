import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexCloudReaderTests: XCTestCase {
    func testParsesOnlyRequiredFieldsAndPreservesUncertainStatuses() throws {
        let input = #"{"tasks":[{"id":"fixture-one","title":"Synthetic\n task","status":"pending","updated_at":"2026-11-05T09:01:00Z","summary":{"secret":"SYNTHETIC_SECRET"},"url":"https://example.invalid/private"},{"id":"fixture-two","title":null,"status":"ready"},{"id":"fixture-three","status":"error"},{"id":"fixture-four","status":"new-status"}],"cursor":"fixture-cursor"}"#
        let page = try CodexCloudReader.parse(Data(input.utf8))
        XCTAssertEqual(page.tasks.map(\.status), [.pending, .terminal, .terminal, .unknown])
        XCTAssertEqual(page.tasks.first?.title, "Synthetic task")
        XCTAssertEqual(page.cursor, "fixture-cursor")
        XCTAssertEqual(page.tasks.first?.updatedAt, FileHelpers.isoDate("2026-11-05T09:01:00Z"))
        XCTAssertTrue(page.tasks.allSatisfy { $0.id.hasPrefix("codex-cloud:") && !$0.id.contains("fixture") })
        XCTAssertFalse(String(describing: page).contains("SYNTHETIC_SECRET"))
        XCTAssertFalse(String(describing: page).contains("example.invalid"))
    }

    func testRejectsMalformedOversizedAndDuplicateItems() throws {
        XCTAssertThrowsError(try CodexCloudReader.parse(Data("not-json".utf8)))
        XCTAssertThrowsError(try CodexCloudReader.parse(Data(repeating: 0x20, count: 1_048_577)))
        let duplicate = #"{"tasks":[{"id":"same","status":"pending"},{"id":"same","status":"ready"}]}"#
        XCTAssertThrowsError(try CodexCloudReader.parse(Data(duplicate.utf8)))
        let tooMany = ["tasks": (0..<21).map { ["id": "fixture-\($0)", "status": "pending"] }]
        XCTAssertThrowsError(try CodexCloudReader.parse(JSONSerialization.data(withJSONObject: tooMany)))
    }

    func testClientPaginatesOnlySyntheticProcessOutput() throws {
        let script = #"""
        #!/bin/sh
        case "$*" in
          *fixture-next*) printf '%s' '{"tasks":[{"id":"fixture-two","status":"ready"}],"cursor":null}' ;;
          *) printf '%s' '{"tasks":[{"id":"fixture-one","title":"Synthetic task","status":"pending"}],"cursor":"fixture-next"}' ;;
        esac
        """#
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try writeExecutable(script, in: directory)
        let client = CodexCloudClient(executable: executable, environment: ["PATH": "/usr/bin:/bin"])
        let snapshot = try client.list()
        XCTAssertTrue(snapshot.complete)
        XCTAssertEqual(snapshot.tasks.map(\.status), [.pending, .terminal])
        XCTAssertEqual(snapshot.tasks.first?.title, "Synthetic task")
    }

    func testClientBoundsOutputAndTime() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tooMuch = try writeExecutable("#!/bin/sh\nexec /usr/bin/yes x\n", in: directory)
        let oversized = CodexCloudClient(executable: tooMuch, environment: ["PATH": "/usr/bin:/bin"], requestTimeout: 3)
        XCTAssertThrowsError(try oversized.list())
        let slow = try writeExecutable("#!/bin/sh\nwhile :; do :; done\n", in: directory, name: "slow")
        let timed = CodexCloudClient(executable: slow, environment: ["PATH": "/usr/bin:/bin"], requestTimeout: 0.25)
        let start = Date()
        XCTAssertThrowsError(try timed.list())
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func writeExecutable(_ text: String, in directory: URL, name: String = "codex") throws -> URL {
        let path = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
}
