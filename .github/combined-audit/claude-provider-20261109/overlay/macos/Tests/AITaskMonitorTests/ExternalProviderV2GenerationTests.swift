import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderV2GenerationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-generation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    func testIndependentScopesAndRandomGeneration() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ExternalProviderV2Scope(provider: "deepseek", scope: String(repeating: "a", count: 32))
        let second = ExternalProviderV2Scope(provider: "deepseek", scope: String(repeating: "b", count: 32))
        let one = try ExternalProviderV2GenerationFile.randomValue(), two = try ExternalProviderV2GenerationFile.randomValue()
        XCTAssertNotEqual(one, two)
        let writer = ExternalProviderV2GenerationFile(directory: directory)
        try writer.replace([first: one, second: two])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("generations-v2.json"))) as? [String: Any])
        var values = try XCTUnwrap(object["generations"] as? [String: String])
        XCTAssertEqual(values["deepseek:" + first.scope], one); XCTAssertEqual(values["deepseek:" + second.scope], two)
        let newer = try ExternalProviderV2GenerationFile.randomValue()
        try writer.replace([first: newer, second: two])
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("generations-v2.json"))) as? [String: Any])
        values = try XCTUnwrap(object["generations"] as? [String: String])
        XCTAssertEqual(values["deepseek:" + first.scope], newer); XCTAssertEqual(values["deepseek:" + second.scope], two)
    }

    func testSymlinkAndHardLinkDestinationAreNotOverwritten() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("synthetic-foreign"), destination = directory.appendingPathComponent("generations-v2.json")
        let secret = Data("synthetic-preserve".utf8)
        try secret.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let scope = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        let writer = ExternalProviderV2GenerationFile(directory: directory)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        XCTAssertThrowsError(try writer.replace([scope: String(repeating: "a", count: 32)]))
        XCTAssertEqual(try Data(contentsOf: target), secret)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.linkItem(at: target, to: destination)
        XCTAssertThrowsError(try writer.replace([scope: String(repeating: "a", count: 32)]))
        XCTAssertEqual(try Data(contentsOf: target), secret)
    }
}
