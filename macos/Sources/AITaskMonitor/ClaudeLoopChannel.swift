import CryptoKit
import Darwin
import Foundation

private enum ClaudeLoopSocketError: Error { case unavailable }

enum ClaudeLoopSocket {
    static let maximumFrame = 4096

    static func directory(profile: URL, create: Bool) throws -> String {
        let digest = SHA256.hash(data: Data(profile.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let path = "/private/tmp/aitm-loop-\(geteuid())-\(suffix)"
        if create {
            let result = path.withCString { mkdir($0, mode_t(0o700)) }
            if result != 0 && errno != EEXIST { throw ClaudeLoopSocketError.unavailable }
        }
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0,
              info.st_uid == geteuid(), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (info.st_mode & mode_t(0o077)) == 0 else { throw ClaudeLoopSocketError.unavailable }
        return path
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ClaudeLoopSocketError.unavailable }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        return address
    }

    static func nonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(descriptor, &user, &group) == 0 && user == geteuid()
    }

    static func suppressSigpipe(_ descriptor: Int32) -> Bool {
        var enabled: Int32 = 1
        return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    static func wait(_ descriptor: Int32, _ events: Int16, milliseconds: Int32) -> Bool {
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        return poll(&item, nfds_t(1), milliseconds) > 0 && (item.revents & events) != 0
    }

    static func deadline(milliseconds: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
    }

    static func remaining(_ deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return 0 }
        return Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
    }

    static func read(_ descriptor: Int32, count: Int, milliseconds: UInt64 = 600) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        let limit = deadline(milliseconds: milliseconds)
        while offset < bytes.count {
            let timeout = remaining(limit)
            guard timeout > 0, wait(descriptor, Int16(POLLIN), milliseconds: timeout) else { return nil }
            let available = bytes.count - offset
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(descriptor, buffer.baseAddress!.advanced(by: offset), available, 0)
            }
            if received > 0 { offset += received }
            else if received == 0 || (errno != EAGAIN && errno != EINTR) { return nil }
        }
        return Data(bytes)
    }

    static func write(_ descriptor: Int32, data: Data, milliseconds: UInt64 = 600) -> Bool {
        var offset = 0
        let limit = deadline(milliseconds: milliseconds)
        while offset < data.count {
            let timeout = remaining(limit)
            guard timeout > 0, wait(descriptor, Int16(POLLOUT), milliseconds: timeout) else { return false }
            let sent = data.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if sent > 0 { offset += sent }
            else if sent == 0 || (errno != EAGAIN && errno != EINTR) { return false }
        }
        return true
    }

    static func connect(path: String, milliseconds: Int32 = 600) -> Int32? {
        guard var address = try? Self.address(path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        guard nonblocking(descriptor), suppressSigpipe(descriptor) else { Darwin.close(descriptor); return nil }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN,
                  wait(descriptor, Int16(POLLOUT), milliseconds: milliseconds) else {
                Darwin.close(descriptor)
                return nil
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                Darwin.close(descriptor)
                return nil
            }
        }
        guard peerIsCurrentUser(descriptor) else { Darwin.close(descriptor); return nil }
        return descriptor
    }

    // Only a definite refusal proves that no listener owns this pathname.
    static func isStaleSocket(path: String) -> Bool {
        guard var address = try? Self.address(path) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard nonblocking(descriptor) else { return false }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result != 0 && errno == ECONNREFUSED
    }
}

enum ClaudeLoopClient {
    static func send(_ input: [String: Any], profile: URL = AppPaths.supportDirectory) {
        guard let prepared = ClaudeLoopInput.classify(input),
              let directory = try? ClaudeLoopSocket.directory(profile: profile, create: false),
              let descriptor = ClaudeLoopSocket.connect(path: directory + "/events.sock") else { return }
        defer { Darwin.close(descriptor) }
        guard var key = ClaudeLoopSocket.read(descriptor, count: 32) else { return }
        defer { key.resetBytes(in: 0..<key.count) }
        guard let body = prepared.payload(key: key) else { return }
        let length = body.count
        let header = Data([UInt8(length & 0xff), UInt8((length >> 8) & 0xff),
                           UInt8((length >> 16) & 0xff), UInt8((length >> 24) & 0xff)])
        _ = ClaudeLoopSocket.write(descriptor, data: header + body)
    }
}

final class ClaudeLoopChannel {
    struct Batch { let gap: Bool; let events: [ClaudeLoopEvent] }
    private struct Endpoint {
        let listener: Int32
        let ownership: Int32
        let socketPath: String
        let device: dev_t
        let inode: ino_t
    }

    private let endpoint: Endpoint
    private var key: Data
    private let stateLock = NSLock()
    private let stopped = DispatchSemaphore(value: 0)
    private var stopping = false
    private var finished = false
    private var gap = false
    private var events: [ClaudeLoopEvent] = []

    init(profile: URL = AppPaths.supportDirectory) throws {
        endpoint = try Self.openEndpoint(profile: profile)
        key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        DispatchQueue(label: "com.aitaskmonitor.claude-loop", qos: .utility).async { self.serve() }
    }

    func drain() -> Batch {
        stateLock.lock()
        defer { stateLock.unlock() }
        let batch = Batch(gap: gap, events: events)
        events.removeAll(keepingCapacity: true)
        gap = false
        return batch
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
            key.resetBytes(in: 0..<key.count)
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
            guard ClaudeLoopSocket.wait(endpoint.listener, Int16(POLLIN), milliseconds: 100) else {
                Thread.sleep(forTimeInterval: 0.025)
                continue
            }
            let client = accept(endpoint.listener, nil, nil)
            if client < 0 { markGap(); Thread.sleep(forTimeInterval: 0.025); continue }
            if ClaudeLoopSocket.nonblocking(client), ClaudeLoopSocket.suppressSigpipe(client),
               ClaudeLoopSocket.peerIsCurrentUser(client) {
                receive(client)
            } else { markGap() }
            Darwin.close(client)
        }
    }

    private func receive(_ client: Int32) {
        guard ClaudeLoopSocket.write(client, data: key, milliseconds: 400),
              let prefix = ClaudeLoopSocket.read(client, count: 4, milliseconds: 400) else {
            markGap(); return
        }
        let bytes = [UInt8](prefix)
        let length = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
        guard length >= 2, length <= ClaudeLoopSocket.maximumFrame,
              let payload = ClaudeLoopSocket.read(client, count: length, milliseconds: 400),
              let event = ClaudeLoopPayload.parse(payload) else { markGap(); return }
        stateLock.lock()
        if events.count >= 2048 { events.removeAll(keepingCapacity: true); gap = true }
        events.append(event)
        stateLock.unlock()
    }

    private func markGap() {
        stateLock.lock()
        events.removeAll(keepingCapacity: true)
        gap = true
        stateLock.unlock()
    }

    private static func openEndpoint(profile: URL) throws -> Endpoint {
        let directory = try ClaudeLoopSocket.directory(profile: profile, create: true)
        let lockPath = directory + "/owner.lock"
        let ownership = lockPath.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600)) }
        guard ownership >= 0 else { throw ClaudeLoopSocketError.unavailable }
        var ownsLock = false
        var listener: Int32 = -1
        var createdSocket: (device: dev_t, inode: ino_t)?
        let socketPath = directory + "/events.sock"
        do {
            var lockInfo = stat()
            guard fstat(ownership, &lockInfo) == 0, lockInfo.st_uid == geteuid(),
                  (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  (lockInfo.st_mode & mode_t(0o077)) == 0,
                  flock(ownership, LOCK_EX | LOCK_NB) == 0 else { throw ClaudeLoopSocketError.unavailable }
            ownsLock = true
            var previous = stat()
            if socketPath.withCString({ lstat($0, &previous) }) == 0 {
                guard previous.st_uid == geteuid(),
                      (previous.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { throw ClaudeLoopSocketError.unavailable }
                guard ClaudeLoopSocket.isStaleSocket(path: socketPath) else { throw ClaudeLoopSocketError.unavailable }
                var confirmed = stat()
                guard socketPath.withCString({ lstat($0, &confirmed) }) == 0,
                      confirmed.st_dev == previous.st_dev, confirmed.st_ino == previous.st_ino,
                      confirmed.st_uid == geteuid(), (confirmed.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
                      socketPath.withCString({ unlink($0) }) == 0 else { throw ClaudeLoopSocketError.unavailable }
            } else if errno != ENOENT { throw ClaudeLoopSocketError.unavailable }
            var address = try ClaudeLoopSocket.address(socketPath)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0, ClaudeLoopSocket.nonblocking(listener) else { throw ClaudeLoopSocketError.unavailable }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw ClaudeLoopSocketError.unavailable }
            var info = stat()
            guard socketPath.withCString({ lstat($0, &info) }) == 0, info.st_uid == geteuid(),
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { throw ClaudeLoopSocketError.unavailable }
            createdSocket = (info.st_dev, info.st_ino)
            guard socketPath.withCString({ chmod($0, mode_t(0o600)) }) == 0,
                  listen(listener, 32) == 0 else { throw ClaudeLoopSocketError.unavailable }
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
