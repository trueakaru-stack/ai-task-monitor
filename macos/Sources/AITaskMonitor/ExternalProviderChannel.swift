import Darwin
import Foundation

private enum ExternalProviderChannelError: Error { case unavailable }

final class ExternalProviderChannel {
    struct Batch { let gap: Bool; let events: [ExternalProviderEvent] }
    private struct Endpoint {
        let listener: Int32
        let ownership: Int32
        let socketPath: String
        let device: dev_t
        let inode: ino_t
    }

    private let endpoint: Endpoint
    private let stateLock = NSLock()
    private let stopped = DispatchSemaphore(value: 0)
    private var stopping = false
    private var finished = false
    private var gap = false
    private var events: [ExternalProviderEvent] = []
    private var allowed: [String: UInt64] = [:]
    private var permissionSequence: UInt64 = 0
    private var acceptedCount: UInt64 = 0
    private static let knownProviders: Set<String> = ["kimi", "deepseek", "hermes", "opencode"]

    init(directory: String? = nil) throws {
        endpoint = try Self.openEndpoint(directory: directory ?? "/private/tmp/aitm-provider-\(geteuid())")
        DispatchQueue(label: "com.aitaskmonitor.external-providers", qos: .utility).async { self.serve() }
    }

    // Authorization is checked when a connection is accepted and when its
    // event is queued. Reconnection creates a new generation for that provider.
    func setAllowedProviders(_ providers: Set<String>) {
        let requested = providers.intersection(Self.knownProviders)
        stateLock.lock()
        defer { stateLock.unlock() }
        for provider in Array(allowed.keys) where !requested.contains(provider) {
            allowed.removeValue(forKey: provider)
        }
        for provider in requested where allowed[provider] == nil {
            permissionSequence &+= 1
            allowed[provider] = permissionSequence
        }
        events.removeAll { allowed[$0.provider] == nil }
    }

    func drain() -> Batch {
        stateLock.lock()
        defer { stateLock.unlock() }
        let batch = Batch(gap: gap, events: events)
        events.removeAll(keepingCapacity: true)
        gap = false
        return batch
    }

    var acceptedConnections: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acceptedCount
    }

    @discardableResult
    func stop() -> Bool {
        stateLock.lock()
        let wasStopping = stopping
        stopping = true
        let alreadyFinished = finished
        stateLock.unlock()
        if alreadyFinished { return true }
        if wasStopping { return false }
        return stopped.wait(timeout: .now() + 2) == .success
    }

    private func serve() {
        defer {
            Darwin.close(endpoint.listener)
            var current = stat()
            if endpoint.socketPath.withCString({ lstat($0, &current) }) == 0,
               current.st_uid == geteuid(), (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
               current.st_dev == endpoint.device, current.st_ino == endpoint.inode {
                _ = endpoint.socketPath.withCString { unlink($0) }
            }
            _ = flock(endpoint.ownership, LOCK_UN)
            Darwin.close(endpoint.ownership)
            stateLock.lock()
            finished = true
            stateLock.unlock()
            stopped.signal()
        }
        while true {
            stateLock.lock()
            let shouldStop = stopping
            stateLock.unlock()
            if shouldStop { break }
            guard ClaudeLoopSocket.wait(endpoint.listener, Int16(POLLIN), milliseconds: 100) else { continue }
            let client = accept(endpoint.listener, nil, nil)
            if client < 0 { markGap(); Thread.sleep(forTimeInterval: 0.025); continue }
            stateLock.lock()
            let allowedAtAccept = allowed
            acceptedCount &+= 1
            stateLock.unlock()
            if ClaudeLoopSocket.nonblocking(client), ClaudeLoopSocket.suppressSigpipe(client),
               ClaudeLoopSocket.peerIsCurrentUser(client) { receive(client, allowedAtAccept: allowedAtAccept) }
            else { markGap() }
            Darwin.close(client)
        }
    }

    private func receive(_ client: Int32, allowedAtAccept: [String: UInt64]) {
        guard let prefix = ClaudeLoopSocket.read(client, count: 4, milliseconds: 400) else { markGap(); return }
        let bytes = [UInt8](prefix)
        let length = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
        guard length >= 2, length <= 65_536,
              let payload = ClaudeLoopSocket.read(client, count: length, milliseconds: 400),
              var event = ExternalProviderEventParser.parse(payload) else { markGap(); return }
        event.receivedAt = Date()
        stateLock.lock()
        let authorized = allowedAtAccept[event.provider].map { allowed[event.provider] == $0 } ?? false
        if authorized {
            if events.count >= 1_024 { events.removeAll(keepingCapacity: true); gap = true }
            events.append(event)
        }
        stateLock.unlock()
        // Confirm only after the frame has been parsed and accepted or filtered.
        if !ClaudeLoopSocket.write(client, data: Data([0x06]), milliseconds: 100), authorized { markGap() }
    }

    private func markGap() {
        stateLock.lock()
        events.removeAll(keepingCapacity: true)
        gap = true
        stateLock.unlock()
    }

    private static func openEndpoint(directory: String) throws -> Endpoint {
        let made = directory.withCString { mkdir($0, mode_t(0o700)) }
        if made != 0 && errno != EEXIST { throw ExternalProviderChannelError.unavailable }
        var directoryInfo = stat()
        guard directory.withCString({ lstat($0, &directoryInfo) }) == 0,
              directoryInfo.st_uid == geteuid(), (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (directoryInfo.st_mode & mode_t(0o077)) == 0 else { throw ExternalProviderChannelError.unavailable }
        let lockPath = directory + "/owner.lock"
        let ownership = lockPath.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600)) }
        guard ownership >= 0 else { throw ExternalProviderChannelError.unavailable }
        var ownsLock = false
        var listener: Int32 = -1
        var createdSocket: (device: dev_t, inode: ino_t)?
        let socketPath = directory + "/events.sock"
        do {
            var lockInfo = stat()
            guard fstat(ownership, &lockInfo) == 0, lockInfo.st_uid == geteuid(),
                  (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), (lockInfo.st_mode & mode_t(0o077)) == 0,
                  flock(ownership, LOCK_EX | LOCK_NB) == 0 else { throw ExternalProviderChannelError.unavailable }
            ownsLock = true
            var previous = stat()
            if socketPath.withCString({ lstat($0, &previous) }) == 0 {
                guard previous.st_uid == geteuid(), (previous.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
                      ClaudeLoopSocket.isStaleSocket(path: socketPath) else { throw ExternalProviderChannelError.unavailable }
                var confirmed = stat()
                guard socketPath.withCString({ lstat($0, &confirmed) }) == 0,
                      confirmed.st_dev == previous.st_dev, confirmed.st_ino == previous.st_ino,
                      confirmed.st_uid == geteuid(), (confirmed.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
                      socketPath.withCString({ unlink($0) }) == 0 else { throw ExternalProviderChannelError.unavailable }
            } else if errno != ENOENT { throw ExternalProviderChannelError.unavailable }
            var address = try ClaudeLoopSocket.address(socketPath)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0, ClaudeLoopSocket.nonblocking(listener) else { throw ExternalProviderChannelError.unavailable }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw ExternalProviderChannelError.unavailable }
            var info = stat()
            guard socketPath.withCString({ lstat($0, &info) }) == 0, info.st_uid == geteuid(),
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { throw ExternalProviderChannelError.unavailable }
            createdSocket = (info.st_dev, info.st_ino)
            guard socketPath.withCString({ chmod($0, mode_t(0o600)) }) == 0,
                  listen(listener, 32) == 0 else { throw ExternalProviderChannelError.unavailable }
            return Endpoint(listener: listener, ownership: ownership, socketPath: socketPath,
                            device: info.st_dev, inode: info.st_ino)
        } catch {
            if listener >= 0 { Darwin.close(listener) }
            var current = stat()
            if let createdSocket, socketPath.withCString({ lstat($0, &current) }) == 0,
               current.st_uid == geteuid(), (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
               current.st_dev == createdSocket.device, current.st_ino == createdSocket.inode {
                _ = socketPath.withCString { unlink($0) }
            }
            if ownsLock { _ = flock(ownership, LOCK_UN) }
            Darwin.close(ownership)
            throw error
        }
    }
}
