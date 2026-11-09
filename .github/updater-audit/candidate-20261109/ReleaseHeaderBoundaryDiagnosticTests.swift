import Foundation
import XCTest
@testable import AITaskMonitor

// Diagnostic only: custom scheme + URLProtocol, no network or user profiles.
private final class BoundaryTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func mark(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
    func waitFor(_ names: Set<String>, seconds: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if !names.isDisjoint(with: snapshot()) { return true }
            // Keep the XCTest thread's run loop moving; do not assume all
            // Foundation callbacks arrive on a separate worker thread.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return !names.isDisjoint(with: snapshot())
    }
}

private final class BoundaryProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var trace: BoundaryTrace?
    static func install(_ newValue: BoundaryTrace?) { lock.lock(); trace = newValue; lock.unlock() }
    private static func mark(_ event: String) {
        lock.lock(); let current = trace; lock.unlock()
        current?.mark(event)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.mark("started")
        guard let url = request.url, url.scheme == "aitm-update-test", url.host == "fixture",
              ["/hold-one", "/hold-kib", "/hold-declared", "/finish"].contains(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        guard let sink = client else { Self.mark("no-client"); return }
        Self.mark("client-present")
        var fields = ["Retry-After": "172800"]
        if url.path == "/hold-declared" {
            fields["Content-Type"] = "application/json"
            fields["Content-Length"] = "2"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fields)!
        sink.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = url.path == "/hold-kib" ? Data(repeating: 0x20, count: 1024) : Data([0x20])
        sink.urlProtocol(self, didLoad: body)
        Self.mark("emitted")
        if url.path == "/finish" { sink.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { }
}

private final class BoundaryDirectDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let trace: BoundaryTrace
    init(_ trace: BoundaryTrace) { self.trace = trace }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        trace.mark("header")
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        trace.mark("completed")
    }
}

final class ReleaseHeaderBoundaryDiagnosticTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryProtocol.self]
        return ReleaseRequest.isolatedConfiguration(configuration)
    }

    // Observation only for stalled responses: a missing callback is printed,
    // not counted as a successful header-delivery test.
    private func run(_ path: String, direct: Bool) throws {
        let trace = BoundaryTrace()
        BoundaryProtocol.install(trace)
        defer { BoundaryProtocol.install(nil) }
        let url = try XCTUnwrap(URL(string: "aitm-update-test://fixture\(path)"))
        var session: URLSession?
        var request: ReleaseRequest?
        if direct {
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let delegate = BoundaryDirectDelegate(trace)
            let active = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: queue)
            session = active
            var input = URLRequest(url: url)
            input.httpShouldHandleCookies = false
            input.setValue("AI-Task-Monitor/0.3", forHTTPHeaderField: "User-Agent")
            input.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            active.dataTask(with: input).resume()
        } else {
            let active = ReleaseRequest(testURL: url, configuration: configuration()) { _ in trace.mark("completed") }
            active.attachResponseCollector(ReleaseResponseCollector { _ in trace.mark("header") })
            request = active
            try active.start()
        }
        defer { request?.cancel(); session?.invalidateAndCancel() }
        let emitted = trace.waitFor(["emitted", "no-client"], seconds: 5)
        let observed = trace.waitFor(["header"], seconds: 2)
        let beforeCancellation = trace.snapshot()
        if let request { request.cancel() } else { session?.invalidateAndCancel() }
        let completed = trace.waitFor(["completed"], seconds: 5)
        print("BOUNDARY_DIAG direct=\(direct) path=\(path) emitted=\(emitted) header_before_cancel=\(observed) completion=\(completed) events=\(beforeCancellation)")
        XCTAssertTrue(emitted, "The URLProtocol fixture did not reach emission.")
        XCTAssertTrue(beforeCancellation.contains("client-present"), "The URLProtocol client was nil.")
        XCTAssertFalse(beforeCancellation.contains("no-client"))
        if path == "/finish" { XCTAssertTrue(observed, "The completed control did not deliver a response.") }
        XCTAssertTrue(completed, "The diagnostic request did not finish after completion or cancellation.")
    }

    func testObserveURLSessionAndCandidateBoundaries() throws {
        for path in ["/hold-one", "/hold-kib", "/hold-declared", "/finish"] {
            try run(path, direct: true)
            try run(path, direct: false)
        }
    }

    func testCandidateCollectorWhenResponseDelegateIsCalledDirectly() throws {
        let trace = BoundaryTrace()
        let url = try XCTUnwrap(URL(string: "aitm-update-test://fixture/manual"))
        let config = configuration()
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url) // Never resumed; no transport is involved.
        let collector = ReleaseResponseCollector { _ in trace.mark("header") }
        let request = ReleaseRequest(testURL: url, configuration: config) { _ in trace.mark("completed") }
        request.attachResponseCollector(collector)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Retry-After": "172800"]))
        var disposition: URLSession.ResponseDisposition?
        request.urlSession(session, dataTask: task, didReceive: response) { disposition = $0 }
        XCTAssertEqual(disposition, .allow)
        XCTAssertTrue(trace.waitFor(["header"], seconds: 1))
        var captured: [ReleaseHTTPResponse] = []
        collector.seal { captured = $0 }
        XCTAssertEqual(captured.first?.retryAfter, "172800")
    }
}
