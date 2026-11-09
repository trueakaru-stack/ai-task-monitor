import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderV2SyntheticIPCTests: XCTestCase {
    private func wait(_ message: String, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail(message)
    }

    func testTwoSyntheticProfilesUseRealLocalChannel() throws {
        let environment = ProcessInfo.processInfo.environment
        let node = try XCTUnwrap(environment["AITM_TEST_NODE"])
        let script = try XCTUnwrap(environment["AITM_V2_DEEPSEEK_FIXTURE"])
        XCTAssertTrue(node.hasPrefix("/")); XCTAssertTrue(script.hasPrefix("/"))
        let path = "/private/tmp/aitm-provider-\(UUID().uuidString)"
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        let first = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        let other = ExternalProviderV2Scope(provider: "deepseek", scope: b)
        let runtime = try ExternalProviderV2Runtime(directory: path)
        var children: [Process] = [], inputs: [Pipe] = []
        defer {
            for input in inputs { try? input.fileHandleForWriting.close() }
            for child in children { if child.isRunning { child.terminate(); child.waitUntilExit() } }
            _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path)
        }
        try runtime.setScopes([first, other])
        for scope in [a, b] {
            let child = Process(), input = Pipe()
            child.executableURL = URL(fileURLWithPath: node); child.arguments = [script, path, scope]
            child.environment = [:]; child.standardInput = input
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); children.append(child); inputs.append(input)
        }
        try wait("Both synthetic plugins should be visible before the action") {
            let tasks = runtime.snapshot()
            return runtime.canAcknowledge(first) && runtime.canAcknowledge(other) &&
                tasks.contains { $0.id == "deepseek:" + a + "_work" && $0.isUnconfirmed } &&
                tasks.contains { $0.id == "deepseek:" + b + "_work" && $0.isUnconfirmed }
        }
        XCTAssertTrue(runtime.acknowledge(first))
        try inputs[0].fileHandleForWriting.write(contentsOf: Data("fresh\n".utf8))
        try wait("The selected profile should receive a new live status") {
            let tasks = runtime.snapshot()
            return tasks.contains { $0.id == "deepseek:" + a + "_work" && $0.isActive } &&
                tasks.contains { $0.id == "deepseek:" + b + "_work" && $0.isUnconfirmed }
        }
        let beforeLate = runtime.testUnconfirmedFrames
        try inputs[0].fileHandleForWriting.write(contentsOf: Data("late\n".utf8))
        try wait("A late unconfirmed terminal should not remove the active task") {
            let tasks = runtime.snapshot()
            return runtime.testUnconfirmedFrames > beforeLate &&
                tasks.contains { $0.id == "deepseek:" + a + "_work" && $0.isActive }
        }
        XCTAssertTrue(runtime.acknowledge(other))
        try inputs[1].fileHandleForWriting.write(contentsOf: Data("fresh\n".utf8))
        try wait("Confirming the neighbour should not invalidate the first profile") {
            let tasks = runtime.snapshot()
            return tasks.contains { $0.id == "deepseek:" + a + "_work" && $0.isActive } &&
                tasks.contains { $0.id == "deepseek:" + b + "_work" && $0.isActive }
        }
    }
}
