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
    private struct AcceptedClient {
        let descriptor: Int32
        let allowedAtAccept: [String: UInt64]
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
    private var pendingClients: [AcceptedClient] = []
    private var quarantinedProviders: Set<String> = []
    private let pendingCapacity: Int
    private static let knownProviders: Set<String> = ["kimi", "deepseek", "hermes", "opencode"]

    #if DEBUG
    private let testBeforeAccept: (() -> Void)?

    init(directory: String? = nil, testBeforeAccept: (() -> Void)? = nil, testPendingCapacity: Int = 128) throws {
        self.testBeforeAccept = testBeforeAccept
        pendingCapacity = max(1, min(128, testPendingCapacity))
        endpoint = try Self.openEndpoint(directory: directory ?? "/private/tmp/aitm-provider-\(geteuid())")
        DispatchQueue(label: "com.aitaskmonitor.external-providers", qos: .utility).async { self.serve() }
    }
    #else
    init(directory: String? = nil) throws {
        pendingCapacity = 128
        endpoint = try Self.openEndpoint(directory: directory ?? "/private/tmp/aitm-provider-\(geteuid())")
        DispatchQueue(label: "com.aitaskmonitor.external-providers", qos: .utility).async { self.serve() }
    }
    #endif

    // Authorization is checked when a connection is accepted and when its
    // event is queued. Reconnection creates a new generation for that provider.
    func setAllowedProviders(_ providers: Set<String>) {
        let requested = providers.intersection(Self.knownProviders)
        stateLock.lock()
        defer { stateLock.unlock() }
        let current = Set(allowed.keys)
        let changed = current.symmetricDifference(requested)
        if !changed.isEmpty && !stopping && !finished {
            // Claim connections already in the listener queue under the old
            // permissions before publishing the new generation. No frame is
            // read here, and the number of accepted descriptors is bounded.
            let oldAllowed = allowed
            while pendingClients.count < pendingCapacity {
                let descriptor = accept(endpoint.listener, nil, nil)
                if descriptor < 0 {
                    if errno != EAGAIN && errno != EWOULDBLOCK {
                        quarantinedProviders.formUnion(changed)
                        if errno != EINTR { gap = true }
                    }
                    break
                }
                pendingClients.append(AcceptedClient(descriptor: descriptor, allowedAtAccept: oldAllowed))
                acceptedCount &+= 1
            }
            // If the cap was reached, reject changed providers until the
            // remaining backlog has actually drained. Neighbours remain enabled.
            if pendingClients.count >= pendingCapacity { quarantinedProviders.formUnion(changed) }
        }
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

    var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping || finished
    }

    #if DEBUG
    var testQuarantinedProviders: Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return quarantinedProviders
    }
    #endif

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
            stateLock.lock()
            let abandoned = pendingClients
            pendingClients.removeAll()
            stateLock.unlock()
            for client in abandoned { Darwin.close(client.descriptor) }
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
            let queued = pendingClients.isEmpty ? nil : pendingClients.removeFirst()
            if queued == nil && !quarantinedProviders.isEmpty {
                var item = pollfd(fd: endpoint.listener, events: Int16(POLLIN), revents: 0)
                // An error or interruption is not proof that backlog is empty.
                if poll(&item, nfds_t(1), 0) == 0 { quarantinedProviders.removeAll() }
            }
            stateLock.unlock()
            if shouldStop { if let queued { Darwin.close(queued.descriptor) }; break }
            if let queued { serveClient(queued); continue }
            guard ClaudeLoopSocket.wait(endpoint.listener, Int16(POLLIN), milliseconds: 100) else { continue }
            #if DEBUG
            testBeforeAccept?()
            #endif
            stateLock.lock()
            let client: AcceptedClient?
            var acceptFailure = false
            if stopping { client = nil }
            else if !pendingClients.isEmpty { client = pendingClients.removeFirst() }
            else {
                let descriptor = accept(endpoint.listener, nil, nil)
                if descriptor >= 0 {
                    client = AcceptedClient(descriptor: descriptor, allowedAtAccept: allowed)
                    acceptedCount &+= 1
                } else {
                    acceptFailure = errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR
                    client = nil
                }
            }
            stateLock.unlock()
            if let client { serveClient(client) }
            else if acceptFailure { markGap(); Thread.sleep(forTimeInterval: 0.025) }
        }
    }

    private func serveClient(_ client: AcceptedClient) {
        let descriptor = client.descriptor
        defer { Darwin.close(descriptor) }
        if ClaudeLoopSocket.nonblocking(descriptor), ClaudeLoopSocket.suppressSigpipe(descriptor),
           ClaudeLoopSocket.peerIsCurrentUser(descriptor) { receive(descriptor, allowedAtAccept: client.allowedAtAccept) }
        else { markGap() }
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
        let authorized = (allowedAtAccept[event.provider].map { allowed[event.provider] == $0 } ?? false) &&
            !quarantinedProviders.contains(event.provider) && !stopping && !finished
        if authorized {
            if events.count >= 1_024 { events.removeAll(keepingCapacity: true); gap = true }
            events.append(event)
            // The descriptor is nonblocking. Commit and the one-byte ACK share
            // this lock with revocation so a rejected frame is never ACKed.
            var acknowledgement: UInt8 = 0x06
            let written = withUnsafePointer(to: &acknowledgement) { Darwin.write(client, $0, 1) }
            if written != 1 { events.removeAll(keepingCapacity: true); gap = true }
        }
        stateLock.unlock()
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
