import Foundation

struct ReleaseVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ input: String) {
        guard input.utf8.count <= 80 else { return nil }
        let text = input.hasPrefix("v") ? String(input.dropFirst()) : input
        let pieces = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        func number(_ value: Substring) -> Int? {
            guard !value.isEmpty, value.utf8.count <= 5,
                  value.utf8.allSatisfy({ (48...57).contains($0) }),
                  value.count == 1 || value.first != "0" else { return nil }
            return Int(value)
        }
        guard let major = number(numbers[0]), let minor = number(numbers[1]), let patch = number(numbers[2]) else { return nil }
        var pre: [String] = []
        if pieces.count == 2 {
            pre = pieces[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pre.allSatisfy({ part in
                !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } &&
                    !(part.count > 1 && part.first == "0" && part.utf8.allSatisfy { (48...57).contains($0) })
            }) else { return nil }
        }
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = pre
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            if index >= lhs.prerelease.count { return true }
            if index >= rhs.prerelease.count { return false }
            let a = lhs.prerelease[index], b = rhs.prerelease[index]
            if a == b { continue }
            let an = a.utf8.allSatisfy { (48...57).contains($0) }
            let bn = b.utf8.allSatisfy { (48...57).contains($0) }
            if an && bn { return a.count == b.count ? a < b : a.count < b.count }
            if an != bn { return an }
            return a < b
        }
        return false
    }
}

struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let url: URL
}

enum ReleaseSelector {
    static let maximumBytes = 1_048_576
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let draft: Bool
        let assets: [Asset]
    }

    static func trustedURL(_ value: String, tag: String, asset: String, platform: String) -> URL? {
        let safeTag = tag.utf8.count <= 80 && !tag.isEmpty && tag.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
        }
        let safeAsset = !asset.isEmpty && asset.utf8.count <= 128 && asset.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
        let suffixes = platform == "macos" ? [".dmg", ".pkg"] : platform == "windows" ? [".exe", ".msi"] : []
        guard safeTag, safeAsset, suffixes.contains(where: { asset.lowercased().hasSuffix($0) }) else { return nil }
        let expected = "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/\(tag)/\(asset)"
        guard value == expected, let url = URL(string: expected), url.host == "github.com", url.scheme == "https" else { return nil }
        return url
    }

    static func inspect(data: Data, currentVersion: String, platform: String = "macos") -> (valid: Bool, update: AvailableUpdate?) {
        guard data.count <= maximumBytes, let current = ReleaseVersion(currentVersion),
              let releases = try? JSONDecoder().decode([Release].self, from: data) else { return (false, nil) }
        var best = current
        var update: AvailableUpdate?
        for release in releases where !release.draft {
            guard let version = ReleaseVersion(release.tag_name), best < version else { continue }
            for asset in release.assets {
                if let url = trustedURL(asset.browser_download_url, tag: release.tag_name, asset: asset.name, platform: platform) {
                    update = AvailableUpdate(version: release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name, url: url)
                    best = version
                    break
                }
            }
        }
        return (true, update)
    }

    static func select(data: Data, currentVersion: String, platform: String = "macos") -> AvailableUpdate? {
        inspect(data: data, currentVersion: currentVersion, platform: platform).update
    }
}

enum ReleaseRequestOutcome {
    case success(Data)
    case httpFailure(ReleaseHTTPResponse)
    case transportFailure
    case oversized
    case cancelled
}

/// A receipt begins before header parsing. Sealing waits asynchronously for
/// receipts that began first; receipts that begin after sealing are ignored.
/// No storage or header parsing occurs while this lock is held.
final class ReleaseResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var sealed = false
    private var hints: [ReleaseHTTPResponse] = []
    private var exceeded = false
    private var completion: (([ReleaseHTTPResponse]) -> Void)?
    private let maximumHints = 8
    private let onHint: (ReleaseHTTPResponse) -> Void

    init(onHint: @escaping (ReleaseHTTPResponse) -> Void) { self.onHint = onHint }

    func beginCapture() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !sealed else { return false }
        pending += 1
        return true
    }

    func finishCapture(_ hint: ReleaseHTTPResponse) {
        lock.lock()
        guard pending > 0 else { lock.unlock(); return }
        var publish: ReleaseHTTPResponse?
        if hints.count < maximumHints { hints.append(hint); publish = hint }
        else if !exceeded {
            var uninspectable = ReleaseHTTPResponse(status: 200)
            uninspectable.retryAfterRequiresBlock = true
            hints.append(uninspectable)
            publish = uninspectable
            exceeded = true
        }
        lock.unlock()
        // Queue incremental persistence before allowing sealing to complete.
        // This callback does not execute under the collector lock.
        if let publish { onHint(publish) }
        lock.lock()
        pending -= 1
        let callback = sealed && pending == 0 ? completion : nil
        if callback != nil { completion = nil }
        let snapshot = callback == nil ? [] : hints
        lock.unlock()
        callback?(snapshot)
    }

    func seal(_ done: @escaping ([ReleaseHTTPResponse]) -> Void) {
        lock.lock()
        guard !sealed else { lock.unlock(); return }
        sealed = true
        if pending == 0 {
            let snapshot = hints
            lock.unlock()
            done(snapshot)
        } else {
            completion = done
            lock.unlock()
        }
    }
}

protocol ReleaseRequesting: AnyObject {
    func attachResponseCollector(_ collector: ReleaseResponseCollector)
    // A thrown start must mean no task was started and no callback can follow.
    // Once start returns, completion denotes the task's terminal callback.
    func start() throws
    func cancel()
}

// Factory construction must not start a task; a thrown factory/start has no
// later callback. After a successful start, completion is the terminal callback.
typealias ReleaseRequestFactory = (@escaping (ReleaseRequestOutcome) -> Void) throws -> any ReleaseRequesting

enum ReleaseRequestStartError: Error {
    case alreadyStartedOrCancelled
}

// One unauthenticated, bounded request. All mutable state is protected by lock.
final class ReleaseRequest: NSObject, URLSessionDataDelegate, ReleaseRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var started = false
    private var finished = false
    private var cancelled = false
    private var sawSuccess = false
    private var exceededLimit = false
    private var httpFailure: ReleaseHTTPResponse?
    private var responseCollector: ReleaseResponseCollector?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let endpoint: URL
    private let makeConfiguration: () -> URLSessionConfiguration
    private let completion: (ReleaseRequestOutcome) -> Void
    #if DEBUG
    private let beforeCaptureHook: (() -> Void)?
    private let cancelHook: (() -> Void)?
    #endif

    init(completion: @escaping (ReleaseRequestOutcome) -> Void) {
        endpoint = URL(string: "https://api.github.com/repos/trueakaru-stack/ai-task-monitor/releases?per_page=100")!
        makeConfiguration = { .ephemeral }
        self.completion = completion
        #if DEBUG
        beforeCaptureHook = nil
        cancelHook = nil
        #endif
    }

    #if DEBUG
    init(testURL: URL, configuration: URLSessionConfiguration,
         beforeCapture: (() -> Void)? = nil, didCancel: (() -> Void)? = nil,
         completion: @escaping (ReleaseRequestOutcome) -> Void) {
        endpoint = testURL
        makeConfiguration = { configuration }
        self.completion = completion
        beforeCaptureHook = beforeCapture
        cancelHook = didCancel
    }
    #endif

    func attachResponseCollector(_ collector: ReleaseResponseCollector) {
        lock.lock(); defer { lock.unlock() }
        guard !started && !cancelled && !finished else { return }
        responseCollector = collector
    }

    private func capture(_ response: HTTPURLResponse) -> ReleaseHTTPResponse {
        #if DEBUG
        beforeCaptureHook?()
        #endif
        lock.lock()
        let collector = responseCollector
        let accepted = collector?.beginCapture() == true
        lock.unlock()
        let hint = ReleaseHTTPResponse(response)
        if accepted { collector?.finishCapture(hint) }
        return hint
    }

    static func isolatedConfiguration(_ config: URLSessionConfiguration) -> URLSessionConfiguration {
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        return config
    }

    func start() throws {
        lock.lock()
        guard !started && !cancelled && !finished else {
            lock.unlock()
            throw ReleaseRequestStartError.alreadyStartedOrCancelled
        }
        started = true
        let config = Self.isolatedConfiguration(makeConfiguration())
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: endpoint)
        request.httpShouldHandleCookies = false
        request.setValue("AI-Task-Monitor/0.3", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    static func challengeDisposition(_ method: String, isProxy: Bool) -> URLSession.AuthChallengeDisposition {
        method == NSURLAuthenticationMethodServerTrust || isProxy ? .performDefaultHandling : .cancelAuthenticationChallenge
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(Self.challengeDisposition(challenge.protectionSpace.authenticationMethod,
                                                    isProxy: challenge.protectionSpace.isProxy()), nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(Self.challengeDisposition(challenge.protectionSpace.authenticationMethod,
                                                    isProxy: challenge.protectionSpace.isProxy()), nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let hint = capture(response)
        lock.lock(); httpFailure = hint; lock.unlock()
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        let hint = capture(response)
        if response.statusCode != 200 {
            lock.lock(); httpFailure = hint; lock.unlock()
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(ReleaseSelector.maximumBytes) else {
            lock.lock(); exceededLimit = true; lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.lock(); sawSuccess = true; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let tooLarge = chunk.count > ReleaseSelector.maximumBytes - data.count
        if tooLarge { exceededLimit = true } else { data.append(chunk) }
        lock.unlock()
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result: ReleaseRequestOutcome
        if cancelled { result = .cancelled }
        else if let httpFailure { result = .httpFailure(httpFailure) }
        else if exceededLimit { result = .oversized }
        else if error != nil || !sawSuccess { result = .transportFailure }
        else { result = .success(data) }
        let oldSession = self.session
        self.session = nil
        self.task = nil
        data.removeAll()
        lock.unlock()
        completion(result)
        oldSession?.finishTasksAndInvalidate()
    }

    func cancel() {
        // Keep the delegate/session alive until this task reaches its terminal
        // callback; callbacks already in flight may contain retry headers.
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
        #if DEBUG
        if active != nil { cancelHook?() }
        #endif
    }
}
