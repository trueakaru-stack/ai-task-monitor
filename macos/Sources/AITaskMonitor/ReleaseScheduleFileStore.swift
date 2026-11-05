import Darwin
import Foundation

/// A cross-process lease and an updater-only checkpoint, separate from other preferences.
/// The lease is held until the response, timeout, or cancellation is accounted for.
final class ReleaseScheduleFileStore {
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func acquire() throws -> Lease? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Failure.unsafe }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR, directoryInfo.st_uid == geteuid() else {
            Darwin.close(directoryFD)
            throw Failure.unsafe
        }
        let lockFD = openat(directoryFD, "release-update.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard lockFD >= 0 else { Darwin.close(directoryFD); throw Failure.unsafe }
        do { try Self.verifyFile(lockFD) } catch {
            Darwin.close(lockFD); Darwin.close(directoryFD); throw error
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            Darwin.close(lockFD); Darwin.close(directoryFD)
            if busy { return nil }
            throw Failure.io
        }
        return Lease(directoryFD: directoryFD, lockFD: lockFD)
    }

    enum Failure: Error { case unsafe, invalid, io }

    private static func verifyFile(_ fd: Int32) throws {
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(), information.st_nlink == 1 else { throw Failure.unsafe }
    }

    final class Lease {
        private let directoryFD: Int32
        private let lockFD: Int32
        private static let stateName = "release-update-retry-v2.json"

        fileprivate init(directoryFD: Int32, lockFD: Int32) {
            self.directoryFD = directoryFD
            self.lockFD = lockFD
        }

        func read() throws -> Data? {
            let fd = openat(directoryFD, Self.stateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { if errno == ENOENT { return nil }; throw Failure.io }
            defer { Darwin.close(fd) }
            try ReleaseScheduleFileStore.verifyFile(fd)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 4096 else { throw Failure.invalid }
            let readFD = dup(fd)
            guard readFD >= 0 else { throw Failure.io }
            let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 4097), data.count == Int(info.st_size) else { throw Failure.io }
            return data
        }

        func write(_ data: Data) throws {
            guard !data.isEmpty, data.count <= 4096 else { throw Failure.invalid }
            let existing = openat(directoryFD, Self.stateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if existing >= 0 {
                defer { Darwin.close(existing) }
                try ReleaseScheduleFileStore.verifyFile(existing)
            } else if errno != ENOENT { throw Failure.unsafe }
            let temporary = ".release-update-\(UUID().uuidString).tmp"
            let fd = openat(directoryFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw Failure.io }
            var renamed = false
            defer { Darwin.close(fd); if !renamed { _ = unlinkat(directoryFD, temporary, 0) } }
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { bytes in
                    Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure.io }
                offset += written
            }
            guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, Self.stateName) == 0 else { throw Failure.io }
            renamed = true
        }

        deinit { _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD); Darwin.close(directoryFD) }
    }
}
