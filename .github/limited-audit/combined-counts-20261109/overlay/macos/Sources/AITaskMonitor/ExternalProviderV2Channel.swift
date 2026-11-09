import Darwin
import Dispatch
import Foundation

private enum ExternalProviderV2ChannelError: Error { case unavailable }

// Separate endpoint preserves the old v1 framing and its single-byte ACK.
final class ExternalProviderV2Channel {
    private struct Endpoint {
        let listener: Int32
        let ownership: Int32
        let socketPath: String
        let device: dev_t
        let inode: ino_t
    }

    let broker: ExternalProviderV2Broker
    private let endpoint: Endpoint
    private let lock = NSLock()
    private let stopped = DispatchSemaphore(value: 0)
    private let clients = DispatchGroup()
    private var activeClients = 0
    private var stopping = false
    private var finished = false

    init(directory: String? = nil, broker: ExternalProviderV2Broker = ExternalProviderV2Broker()) throws {
        self.broker = broker
        endpoint = try Self.openEndpoint(directory: directory ?? "/private/tmp/aitm-provider-\(geteuid())")
        DispatchQueue(label: "com.aitaskmonitor.external-providers-v2", qos: .utility).async { self.serve() }
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping || finished
    }

    @discardableResult
    func stop() -> Bool {
        lock.lock()
        let wasStopping = stopping
        stopping = true
        let alreadyFinished = finished
        lock.unlock()
        broker.invalidateAll()
        if alreadyFinished { return true }
        if wasStopping { return false }
        return stopped.wait(timeout: .now() + 2) == .success
    }

    private func serve() {
        defer {
            Darwin.close(endpoint.listener)
            _ = clients.wait(timeout: .now() + 1)
            var current = stat()
            if endpoint.socketPath.withCString({ lstat($0, &current) }) == 0,
               current.st_uid == geteuid(), (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
               current.st_dev == endpoint.device, current.st_ino == endpoint.inode {
                _ = endpoint.socketPath.withCString { unlink($0) }
            }
            _ = flock(endpoint.ownership, LOCK_UN)
            Darwin.close(endpoint.ownership)
            lock.lock(); finished = true; lock.unlock()
            broker.invalidateAll()
            stopped.signal()
        }
        while true {
            lock.lock(); let shouldStop = stopping; lock.unlock()
            if shouldStop { break }
            guard ClaudeLoopSocket.wait(endpoint.listener, Int16(POLLIN), milliseconds: 100) else { continue }
            let descriptor = accept(endpoint.listener, nil, nil)
            if descriptor < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { broker.invalidateAll() }
                continue
            }
            lock.lock()
            let acceptClient = !stopping && activeClients < 64
            if acceptClient { activeClients += 1; clients.enter() }
            lock.unlock()
            guard acceptClient else { Darwin.close(descriptor); broker.invalidateAll(); continue }
            DispatchQueue.global(qos: .utility).async {
                self.serveClient(descriptor)
                self.lock.lock(); self.activeClients -= 1; self.lock.unlock()
                self.clients.leave()
            }
        }
    }

    private func serveClient(_ client: Int32) {
        defer { Darwin.close(client) }
        guard ClaudeLoopSocket.nonblocking(client), ClaudeLoopSocket.suppressSigpipe(client),
              ClaudeLoopSocket.peerIsCurrentUser(client) else { return }
        guard let prefix = ClaudeLoopSocket.read(client, count: 4, milliseconds: 400) else {
            broker.invalidateAll(); return
        }
        let bytes = [UInt8](prefix)
        let length = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
        guard length >= 2, length <= 65_536,
              let payload = ClaudeLoopSocket.read(client, count: length, milliseconds: 400) else {
            broker.invalidateAll(); return
        }
        broker.receiveResponding(payload, now: DispatchTime.now().uptimeNanoseconds) { reply in
            guard let body = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]),
                  (2...4096).contains(body.count) else { return false }
            let count = UInt32(body.count)
            let header = Data([UInt8(count & 255), UInt8((count >> 8) & 255),
                               UInt8((count >> 16) & 255), UInt8((count >> 24) & 255)])
            return ClaudeLoopSocket.write(client, data: header + body, milliseconds: 400)
        }
    }

    private static func openEndpoint(directory: String) throws -> Endpoint {
        let made = directory.withCString { mkdir($0, mode_t(0o700)) }
        if made != 0 && errno != EEXIST { throw ExternalProviderV2ChannelError.unavailable }
        var directoryInfo = stat()
        guard directory.withCString({ lstat($0, &directoryInfo) }) == 0,
              directoryInfo.st_uid == geteuid(), (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (directoryInfo.st_mode & mode_t(0o077)) == 0 else { throw ExternalProviderV2ChannelError.unavailable }
        let lockPath = directory + "/owner-v2.lock"
        let ownership = lockPath.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600)) }
        guard ownership >= 0 else { throw ExternalProviderV2ChannelError.unavailable }
        var ownsLock = false, listener: Int32 = -1
        var created: (device: dev_t, inode: ino_t)?
        let socketPath = directory + "/events-v2.sock"
        do {
            var lockInfo = stat()
            guard fstat(ownership, &lockInfo) == 0, lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1,
                  (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), (lockInfo.st_mode & mode_t(0o077)) == 0,
                  flock(ownership, LOCK_EX | LOCK_NB) == 0 else { throw ExternalProviderV2ChannelError.unavailable }
            ownsLock = true
            var previous = stat()
            if socketPath.withCString({ lstat($0, &previous) }) == 0 {
                guard previous.st_uid == geteuid(), (previous.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
                      ClaudeLoopSocket.isStaleSocket(path: socketPath) else { throw ExternalProviderV2ChannelError.unavailable }
                var confirmed = stat()
                guard socketPath.withCString({ lstat($0, &confirmed) }) == 0,
                      confirmed.st_dev == previous.st_dev, confirmed.st_ino == previous.st_ino,
                      confirmed.st_uid == geteuid(), (confirmed.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
                      socketPath.withCString({ unlink($0) }) == 0 else { throw ExternalProviderV2ChannelError.unavailable }
            } else if errno != ENOENT { throw ExternalProviderV2ChannelError.unavailable }
            var address = try ClaudeLoopSocket.address(socketPath)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0, ClaudeLoopSocket.nonblocking(listener) else { throw ExternalProviderV2ChannelError.unavailable }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw ExternalProviderV2ChannelError.unavailable }
            var info = stat()
            guard socketPath.withCString({ lstat($0, &info) }) == 0, info.st_uid == geteuid(),
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { throw ExternalProviderV2ChannelError.unavailable }
            created = (info.st_dev, info.st_ino)
            guard socketPath.withCString({ chmod($0, mode_t(0o600)) }) == 0,
                  listen(listener, 32) == 0 else { throw ExternalProviderV2ChannelError.unavailable }
            return Endpoint(listener: listener, ownership: ownership, socketPath: socketPath, device: info.st_dev, inode: info.st_ino)
        } catch {
            if listener >= 0 { Darwin.close(listener) }
            var current = stat()
            if let created, socketPath.withCString({ lstat($0, &current) }) == 0,
               current.st_uid == geteuid(), (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
               current.st_dev == created.device, current.st_ino == created.inode {
                _ = socketPath.withCString { unlink($0) }
            }
            if ownsLock { _ = flock(ownership, LOCK_UN) }
            Darwin.close(ownership)
            throw error
        }
    }
}
