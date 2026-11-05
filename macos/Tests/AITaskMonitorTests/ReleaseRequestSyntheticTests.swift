import Foundation
import XCTest
@testable import AITaskMonitor

/// Intercepts every request in this session; it never performs network I/O.
private final class SyntheticReleaseURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedPaths: [String] = []
    private static var sensitiveHeadersSeen = false
    private static var startObserver: ((String) -> Void)?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recordedPaths = []
        sensitiveHeadersSeen = false
        startObserver = nil
    }
    static func observeStart(_ observer: @escaping (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        startObserver = observer
    }
    static func snapshot() -> (paths: [String], sensitiveHeaders: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (recordedPaths, sensitiveHeadersSeen)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        Self.lock.lock()
        let path = url?.path ?? ""
        Self.recordedPaths.append(path)
        Self.sensitiveHeadersSeen = Self.sensitiveHeadersSeen ||
            ["Cookie", "Authorization", "Proxy-Authorization"].contains { request.value(forHTTPHeaderField: $0) != nil }
        let observer = Self.startObserver
        Self.lock.unlock()
        observer?(path)
        guard let url, url.scheme == "aitm-update-test", url.host == "fixture" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // Leave this request pending until the cancellation test stops it.
        if url.path == "/hold" { return }
        guard ["/ok", "/denied", "/timeout", "/redirect", "/rate-limit",
               "/declared-oversized", "/stream-oversized"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if url.path == "/denied" || url.path == "/timeout" {
            let code: URLError.Code = url.path == "/denied" ? .userAuthenticationRequired : .timedOut
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        if url.path == "/redirect" {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": "aitm-update-test://fixture/never"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "aitm-update-test://fixture/never")!),
                                redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status = url.path == "/rate-limit" ? 403 : 200
        var headers: [String: String] = [:]
        if status == 403 { headers = ["Retry-After": "7200", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "7200"] }
        if url.path == "/declared-oversized" { headers["Content-Length"] = String(ReleaseSelector.maximumBytes + 1) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/stream-oversized" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: ReleaseSelector.maximumBytes + 1))
        } else if status == 200 && url.path != "/declared-oversized" {
            client?.urlProtocol(self, didLoad: Data("[]".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { } // This fixture owns no external resources.
}

final class ReleaseRequestSyntheticTests: XCTestCase {
    private func run(_ path: String) throws -> ReleaseRequestOutcome {
        SyntheticReleaseURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyntheticReleaseURLProtocol.self]
        let completed = expectation(description: "synthetic request completed")
        var outcome: ReleaseRequestOutcome?
        let request = ReleaseRequest(testURL: URL(string: "aitm-update-test://fixture\(path)")!, configuration: config) { result in
            outcome = result
            completed.fulfill()
        }
        try request.start()
        wait(for: [completed], timeout: 5)
        return try XCTUnwrap(outcome)
    }

    func testConfigurationKeepsSystemProxyAndDelegatesProxyChallenges() {
        let configuration = URLSessionConfiguration.ephemeral
        XCTAssertNil(configuration.connectionProxyDictionary)
        let isolated = ReleaseRequest.isolatedConfiguration(configuration)
        XCTAssertNil(isolated.connectionProxyDictionary)
        XCTAssertNil(isolated.urlCredentialStorage)
        XCTAssertNil(isolated.httpCookieStorage)
        XCTAssertNil(isolated.urlCache)
        XCTAssertFalse(isolated.httpShouldSetCookies)
        XCTAssertEqual(isolated.timeoutIntervalForRequest, 12)
        XCTAssertEqual(isolated.timeoutIntervalForResource, 15)
        XCTAssertEqual(ReleaseRequest.challengeDisposition(NSURLAuthenticationMethodServerTrust, isProxy: false), .performDefaultHandling)
        XCTAssertEqual(ReleaseRequest.challengeDisposition(NSURLAuthenticationMethodHTTPBasic, isProxy: false), .cancelAuthenticationChallenge)
        XCTAssertEqual(ReleaseRequest.challengeDisposition(NSURLAuthenticationMethodHTTPBasic, isProxy: true), .performDefaultHandling)
        XCTAssertEqual(ReleaseRequest.challengeDisposition(NSURLAuthenticationMethodNTLM, isProxy: true), .performDefaultHandling)
        let proxySpace = URLProtectionSpace(proxyHost: "fixture", port: 8080, type: NSURLProtectionSpaceHTTPProxy,
                                            realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertTrue(proxySpace.isProxy())
        XCTAssertEqual(ReleaseRequest.challengeDisposition(proxySpace.authenticationMethod, isProxy: proxySpace.isProxy()), .performDefaultHandling)
    }

    func testSuccessUsesSyntheticTransportWithoutSensitiveHeaders() throws {
        guard case .success(let data) = try run("/ok") else { return XCTFail("Expected a synthetic success.") }
        XCTAssertEqual(data, Data("[]".utf8))
        let snapshot = SyntheticReleaseURLProtocol.snapshot()
        XCTAssertEqual(snapshot.paths, ["/ok"])
        XCTAssertFalse(snapshot.sensitiveHeaders)
    }

    func testRateLimitPreservesHeadersAndAccessDeniedIsFailure() throws {
        guard case .httpFailure(let response) = try run("/rate-limit") else { return XCTFail("Expected a synthetic 403.") }
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.retryAfter, "7200")
        XCTAssertEqual(response.remaining, "0")
        XCTAssertEqual(response.reset, "7200")
        guard case .transportFailure = try run("/denied") else { return XCTFail("Expected synthetic access failure.") }
        guard case .transportFailure = try run("/timeout") else { return XCTFail("Expected synthetic timeout.") }
    }

    func testDeclaredAndStreamedBodiesOverOneMegabyteAreRejected() throws {
        guard case .oversized = try run("/declared-oversized") else { return XCTFail("Expected declared body to be rejected.") }
        guard case .oversized = try run("/stream-oversized") else { return XCTFail("Expected streamed body to be rejected.") }
    }

    func testRedirectIsRejectedBeforeSecondRequest() throws {
        guard case .httpFailure(let response) = try run("/redirect") else { return XCTFail("Expected redirect rejection.") }
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(SyntheticReleaseURLProtocol.snapshot().paths, ["/redirect"])
    }

    func testCancellationFinishesAnInFlightSyntheticRequest() throws {
        SyntheticReleaseURLProtocol.reset()
        defer { SyntheticReleaseURLProtocol.reset() }
        let started = expectation(description: "synthetic protocol started")
        let completed = expectation(description: "cancel completed")
        SyntheticReleaseURLProtocol.observeStart { if $0 == "/hold" { started.fulfill() } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticReleaseURLProtocol.self]
        var outcome: ReleaseRequestOutcome?
        let request = ReleaseRequest(testURL: URL(string: "aitm-update-test://fixture/hold")!, configuration: configuration) {
            outcome = $0
            completed.fulfill()
        }
        try request.start()
        wait(for: [started], timeout: 5)
        request.cancel()
        wait(for: [completed], timeout: 5)
        guard case .cancelled = try XCTUnwrap(outcome) else { return XCTFail("Expected a cancelled request.") }
    }
}
