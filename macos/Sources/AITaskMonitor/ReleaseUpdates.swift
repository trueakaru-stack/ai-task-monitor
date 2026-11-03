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

struct AvailableUpdate: Equatable {
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

    static func select(data: Data, currentVersion: String, platform: String = "macos") -> AvailableUpdate? {
        guard data.count <= maximumBytes, let current = ReleaseVersion(currentVersion),
              let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
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
        return update
    }
}

// A single unauthenticated, bounded GitHub request. Delegate callbacks run on a serial queue.
final class ReleaseRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var data = Data()
    private var finished = false
    private var session: URLSession?
    private let completion: (Data?) -> Void

    init(completion: @escaping (Data?) -> Void) { self.completion = completion }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/trueakaru-stack/ai-task-monitor/releases?per_page=100")!)
        request.setValue("AI-Task-Monitor/0.3", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= Int64(ReleaseSelector.maximumBytes) else { completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= ReleaseSelector.maximumBytes else { dataTask.cancel(); return }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }; finished = true
        completion(error == nil ? data : nil)
        self.session?.finishTasksAndInvalidate(); self.session = nil
        data.removeAll()
    }

    func cancel() { session?.invalidateAndCancel() }
}
