import Foundation
import Darwin
import XCTest
@testable import AITaskMonitor

func codexSyntheticDirectory(prefix: String) throws -> URL {
    let env = ProcessInfo.processInfo.environment
    let base: URL
    if env["AITM_MACOS_TEST_SANDBOX"] == "1" || env["AITM_SYNTHETIC_REQUIRED"] == "1" {
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["RUNNER_OS"] == "macOS", env["AITM_MACOS_TEST_SANDBOX"] == "1",
              env["HOME"] == nil, env["CODEX_HOME"] == nil,
              let configured = env["AITM_SYNTHETIC_TEST_ROOT"], let denied = env["AITM_CI_DENIED_FILE"] else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let probe = denied.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        if probe >= 0 { Darwin.close(probe); throw CocoaError(.fileWriteNoPermission) }
        guard errno == EACCES || errno == EPERM else { throw CocoaError(.fileWriteNoPermission) }
        let supplied = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        let resolved = supplied.resolvingSymlinksInPath().standardizedFileURL
        let runnerTemp = URL(fileURLWithPath: "/Users/runner/work/_temp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let container = resolved.deletingLastPathComponent()
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard supplied == resolved, resolved.lastPathComponent == "temp",
              container.lastPathComponent.hasPrefix("aitm-card-tests."),
              container.deletingLastPathComponent() == runnerTemp,
              values.isDirectory == true, values.isSymbolicLink == false else {
            throw CocoaError(.fileWriteNoPermission)
        }
        base = resolved
    } else {
        base = FileManager.default.temporaryDirectory
    }
    guard !prefix.isEmpty, prefix.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
    }) else { throw CocoaError(.fileWriteNoPermission) }
    let root = base.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    guard root.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL else {
        throw CocoaError(.fileWriteNoPermission)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

@MainActor
func waitForCodexRead(_ store: TaskStore, timeout: TimeInterval = 5,
                      file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while store.testCodexReadInFlight && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertFalse(store.testCodexReadInFlight, "The source read did not finish", file: file, line: line)
}
