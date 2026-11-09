import Foundation
import XCTest
@testable import AITaskMonitor

/// Intercepts every request in this session; it never performs network I/O.
private final class SyntheticReleaseURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedPaths: [String] = []
    private static var sensitiveHeadersSeen = false
    private static var startObserver: ((String) -> Void)?
    private static var responseObserver: ((String) -> Void)?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recordedPaths = []
        sensitiveHeadersSeen = false
        startObserver = nil
        responseObserver = nil
    }
    static func observeStart(_ observer: @escaping (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        startObserver = observer
    }
    static func observeResponse(_ observer: @escaping (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        responseObserver = observer
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
        guard ["/ok", "/ok-hint", "/hold-hint", "/ok-reset", "/hold-reset", "/denied", "/timeout", "/redirect", "/rate-limit",
               "/declared-oversized", "/stream-oversized", "/oversized-hint"].contains(url.path) else {
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
        if url.path == "/ok-hint" || url.path == "/hold-hint" { headers["Retry-After"] = "172800" }
        if url.path == "/ok-reset" || url.path == "/hold-reset" {
            headers["X-RateLimit-Remaining"] = "0"
            headers["X-RateLimit-Reset"] = "172800"
            headers["Date"] = "Thu, 01 Jan 1970 00:00:00 GMT"
        }
        if url.path == "/oversized-hint" { headers["Retry-After"] = "172800" }
        if url.path == "/declared-oversized" || url.path == "/oversized-hint" { headers["Content-Length"] = String(ReleaseSelector.maximumBytes + 1) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/hold-hint" || url.path == "/hold-reset" {
            // Supply a partial body, but deliberately never finish the response.
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 1024))
        }
        Self.lock.lock(); let responseObserver = Self.responseObserver; Self.lock.unlock()
        responseObserver?(url.path)
        if url.path == "/hold-hint" || url.path == "/hold-reset" { return }
        if url.path == "/stream-oversized" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: ReleaseSelector.maximumBytes + 1))
        } else if status == 200 && url.path != "/declared-oversized" {
            client?.urlProtocol(self, didLoad: Data("[]".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { } // This fixture owns no external resources.
}

private final class SyntheticDrainClock {
    var wall = Date(timeIntervalSince1970: 0)
    var monotonic: TimeInterval = 0
    var clock: ReleaseRetryClock { ReleaseRetryClock(wall: { self.wall }, monotonic: { self.monotonic }) }
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

    func testSuccessReportsHeaderBeforeCompletion() throws {
        SyntheticReleaseURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticReleaseURLProtocol.self]
        let received = expectation(description: "synthetic header observed")
        let completed = expectation(description: "synthetic body completed")
        let guardLock = NSLock()
        var hint: ReleaseHTTPResponse?
        var outcome: ReleaseRequestOutcome?
        let collector = ReleaseResponseCollector { value in
            guardLock.lock(); hint = value; guardLock.unlock()
            received.fulfill()
        }
        let request = ReleaseRequest(testURL: URL(string: "aitm-update-test://fixture/ok-hint")!, configuration: configuration) {
            outcome = $0
            completed.fulfill()
        }
        request.attachResponseCollector(collector)
        try request.start()
        wait(for: [received, completed], timeout: 5, enforceOrder: true)
        guardLock.lock(); let captured = hint; guardLock.unlock()
        XCTAssertEqual(captured?.status, 200)
        XCTAssertEqual(captured?.retryAfter, "172800")
        guard case .success(let data) = try XCTUnwrap(outcome) else { return XCTFail("Expected a synthetic success.") }
        XCTAssertEqual(data, Data("[]".utf8))
    }

    func testHeaderBeforeCancellationRemainsInCollector() throws {
        SyntheticReleaseURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticReleaseURLProtocol.self]
        let started = expectation(description: "synthetic hold-hint started")
        let emitted = expectation(description: "synthetic hold-hint response and partial body emitted")
        let received = expectation(description: "synthetic header observed")
        let completed = expectation(description: "synthetic cancellation completed")
        SyntheticReleaseURLProtocol.observeStart { if $0 == "/hold-hint" { started.fulfill() } }
        SyntheticReleaseURLProtocol.observeResponse { if $0 == "/hold-hint" { emitted.fulfill() } }
        let collector = ReleaseResponseCollector { _ in received.fulfill() }
        let guardLock = NSLock()
        var outcome: ReleaseRequestOutcome?
        let request = ReleaseRequest(testURL: URL(string: "aitm-update-test://fixture/hold-hint")!, configuration: configuration) {
            guardLock.lock(); outcome = $0; guardLock.unlock()
            completed.fulfill()
        }
        request.attachResponseCollector(collector)
        try request.start()
        wait(for: [started, emitted, received], timeout: 5)
        guardLock.lock(); let outcomeBeforeCancellation = outcome; guardLock.unlock()
        XCTAssertNil(outcomeBeforeCancellation, "The incomplete response must not complete before cancellation.")
        request.cancel()
        wait(for: [completed], timeout: 5)
        guardLock.lock(); let result = outcome; guardLock.unlock()
        guard case .cancelled = try XCTUnwrap(result) else { return XCTFail("Expected cancellation.") }
        var captured: [ReleaseHTTPResponse] = []
        collector.seal { captured = $0 }
        XCTAssertEqual(captured.first?.retryAfter, "172800")
    }

    @MainActor func testTimeoutBeforeRealDelegateCaptureWaitsForTerminal() throws {
        SyntheticReleaseURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticReleaseURLProtocol.self]
        let entered = expectation(description: "response callback entered before capture")
        let cancelled = expectation(description: "task cancellation invoked")
        let terminal = expectation(description: "task terminal callback delivered")
        let unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() }
        let suite = "AITaskMonitor.synthetic-delegate-drain." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SyntheticDrainClock()
        let schedule = ReleaseRetrySchedule(defaults: defaults, clock: clock.clock)
        var fireDeadline: (() -> Void)?
        var starts = 0, deliveries = 0
        let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: { completion in
            starts += 1
            return ReleaseRequest(testURL: URL(string: "aitm-update-test://fixture/hold-hint")!, configuration: configuration,
                                  beforeCapture: { entered.fulfill(); _ = unblock.wait(timeout: .now() + 20) },
                                  didCancel: { cancelled.fulfill() }) { outcome in
                completion(outcome)
                terminal.fulfill()
            }
        }, scheduleDeadline: { fire in fireDeadline = fire; return {} }, executeStorage: { $0() },
           executeParser: { $0() }) { _ in deliveries += 1 }
        coordinator.check()
        wait(for: [entered], timeout: 5)
        try XCTUnwrap(fireDeadline)()
        wait(for: [cancelled], timeout: 5)
        clock.monotonic = 3_601
        clock.wall = Date(timeIntervalSince1970: 3_601)
        coordinator.check()
        XCTAssertEqual(starts, 1, "The unacknowledged cancellation must prevent a retry.")
        unblock.signal()
        wait(for: [terminal], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThanOrEqual(schedule.delay, 172_800, "The response that entered before cancellation must be saved.")
        XCTAssertEqual(deliveries, 0)
        coordinator.stop()
    }

    func testOversizedBodyStillReportsHeader() throws {
        SyntheticReleaseURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticReleaseURLProtocol.self]
        let received = expectation(description: "synthetic header observed")
        let completed = expectation(description: "synthetic oversized response completed")
        let collector = ReleaseResponseCollector { _ in received.fulfill() }
        var outcome: ReleaseRequestOutcome?
        let request = ReleaseRequest(testURL: URL(string: "aitm-update-test://fixture/oversized-hint")!, configuration: configuration) {
            outcome = $0
            completed.fulfill()
        }
        request.attachResponseCollector(collector)
        try request.start()
        wait(for: [received, completed], timeout: 5, enforceOrder: true)
        guard case .oversized = try XCTUnwrap(outcome) else { return XCTFail("Expected an oversized response.") }
        var captured: [ReleaseHTTPResponse] = []
        collector.seal { captured = $0 }
        XCTAssertEqual(captured.first?.retryAfter, "172800")
    }

    func testSuccessfulAndCancelled200ResponsesReportZeroRemainingReset() throws {
        for path in ["/ok-reset", "/hold-reset"] {
            SyntheticReleaseURLProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SyntheticReleaseURLProtocol.self]
            let started = expectation(description: "synthetic reset protocol started \(path)")
            let emitted = expectation(description: "synthetic reset response emitted \(path)")
            let received = expectation(description: "synthetic reset observed \(path)")
            let completed = expectation(description: "synthetic response completed \(path)")
            SyntheticReleaseURLProtocol.observeStart { if $0 == path { started.fulfill() } }
            SyntheticReleaseURLProtocol.observeResponse { if $0 == path { emitted.fulfill() } }
            let guardLock = NSLock()
            var hint: ReleaseHTTPResponse?
            var outcome: ReleaseRequestOutcome?
            let collector = ReleaseResponseCollector { value in
                guardLock.lock(); hint = value; guardLock.unlock()
                received.fulfill()
            }
            let request = ReleaseRequest(testURL: URL(string: "aitm-update-test://fixture\(path)")!, configuration: configuration) {
                guardLock.lock(); outcome = $0; guardLock.unlock()
                completed.fulfill()
            }
            request.attachResponseCollector(collector)
            try request.start()
            wait(for: [started, emitted, received], timeout: 5)
            if path == "/hold-reset" {
                guardLock.lock(); let outcomeBeforeCancellation = outcome; guardLock.unlock()
                XCTAssertNil(outcomeBeforeCancellation, "The incomplete response must not complete before cancellation.")
                request.cancel()
            }
            wait(for: [completed], timeout: 5)
            guardLock.lock(); let captured = hint; let result = outcome; guardLock.unlock()
            let header = try XCTUnwrap(captured)
            XCTAssertEqual(header.status, 200)
            XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: header, now: Date(timeIntervalSince1970: 0)), 172_800)
            if path == "/hold-reset" {
                guard case .cancelled = try XCTUnwrap(result) else { return XCTFail("Expected synthetic cancellation.") }
            } else {
                guard case .success = try XCTUnwrap(result) else { return XCTFail("Expected synthetic success.") }
            }
        }
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
