import Foundation
import XCTest
@testable import AITaskMonitor

/// Only synthetic custom-scheme requests are handled; no external transport is used.
private final class RedirectDiagnosticProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var paths: [String] = []

    static func reset() { lock.lock(); paths = []; lock.unlock() }
    static func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        Self.lock.lock(); Self.paths.append(url.path); Self.lock.unlock()
        guard url.scheme == "aitm-update-test", url.host == "fixture",
              ["/finished-redirect", "/raw-302"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let target = URL(string: "aitm-update-test://fixture/never")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": target.absoluteString])!
        if url.path == "/finished-redirect" {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        } else {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

final class ReleaseRedirectDiagnosticTests: XCTestCase {
    private func run(_ path: String) throws -> ReleaseRequestOutcome {
        RedirectDiagnosticProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectDiagnosticProtocol.self]
        let completed = expectation(description: "synthetic redirect completion")
        let stateLock = NSLock()
        var outcome: ReleaseRequestOutcome?
        var accepting = true
        let request = ReleaseRequest(testURL: URL(string: "aitm-update-test://fixture\(path)")!,
                                     configuration: configuration) {
            stateLock.lock()
            guard accepting else { stateLock.unlock(); return }
            outcome = $0
            stateLock.unlock()
            completed.fulfill()
        }
        try request.start()
        wait(for: [completed], timeout: 3)
        stateLock.lock(); accepting = false; let result = outcome; stateLock.unlock()
        request.cancel()
        return try XCTUnwrap(result)
    }

    func testFinishedRedirectNotification() throws {
        guard case .httpFailure(let response) = try run("/finished-redirect") else {
            return XCTFail("Finished synthetic redirect did not deliver a 302 failure.")
        }
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(RedirectDiagnosticProtocol.snapshot(), ["/finished-redirect"])
    }

    func testRaw302Response() throws {
        guard case .httpFailure(let response) = try run("/raw-302") else {
            return XCTFail("Synthetic 302 response was not rejected.")
        }
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(RedirectDiagnosticProtocol.snapshot(), ["/raw-302"])
    }

    func testRedirectDelegateDeclinesFollowUp() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectDiagnosticProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "aitm-update-test://fixture/start")!
        let next = URLRequest(url: URL(string: "aitm-update-test://fixture/never")!)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": next.url!.absoluteString])!
        let task = session.dataTask(with: original)
        let completed = expectation(description: "synthetic delegate completion")
        var outcome: ReleaseRequestOutcome?
        let request = ReleaseRequest(testURL: original, configuration: configuration) {
            outcome = $0
            completed.fulfill()
        }
        var decisionMade = false
        request.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) { decision in
            decisionMade = true
            XCTAssertNil(decision)
        }
        XCTAssertTrue(decisionMade)
        request.urlSession(session, task: task, didCompleteWithError: nil)
        wait(for: [completed], timeout: 2)
        guard case .httpFailure(let failure) = try XCTUnwrap(outcome) else { return XCTFail("Expected synthetic 302 failure.") }
        XCTAssertEqual(failure.status, 302)
    }
}
