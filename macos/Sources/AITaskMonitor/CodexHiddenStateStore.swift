import CryptoKit
import Darwin
import Foundation

/// Opaque identifiers only. The digests distinguish sources; they are not
/// anonymisation and must not be logged or used as evidence of activity.
struct CodexHiddenKey: Hashable, Codable {
    let codexHomeID: String
    let threadID: String

    static func homeIdentifier(for directory: URL) -> String {
        digest("codex-home\0" + directory.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    static func rolloutPathIdentifier(for file: URL) -> String {
        digest("codex-rollout-path\0" + file.standardizedFileURL.path)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CodexHiddenRecord: Codable, Equatable {
    let key: CodexHiddenKey
    let revision: String
    let turnID: String?
    let rolloutPathDigest: String?
    let device: UInt64?
    let inode: UInt64?

    init(key: CodexHiddenKey, revision: String = UUID().uuidString.lowercased(),
         turnID: String? = nil, rolloutPathDigest: String? = nil,
         device: UInt64? = nil, inode: UInt64? = nil) {
        self.key = key
        self.revision = revision
        self.turnID = turnID
        self.rolloutPathDigest = rolloutPathDigest
        self.device = device
        self.inode = inode
    }
}

/// A separate, bounded checkpoint. Operations cooperate through one stable
/// lock file; neither messages nor titles are stored in this file.
final class CodexHiddenStateStore {
    enum Failure: Error, Equatable { case unsafe, invalid, busy, io }

    private struct Document: Codable {
        let version: Int
        let records: [CodexHiddenRecord]
    }

    private static let stateName = "codex-uncertain-endings-v1.json"
    private static let lockName = "codex-uncertain-endings-v1.lock"
    private static let maximumRecords = 1_024
    private static let maximumBytes = 524_288
    private let directory: URL

    init(directory: URL = AppPaths.supportDirectory) {
        self.directory = directory
    }

    func load() throws -> [CodexHiddenKey: CodexHiddenRecord] {
        try withLease { directoryFD, _ in try Self.read(directoryFD) }
    }

    @discardableResult
    func insert(_ record: CodexHiddenRecord) throws -> CodexHiddenRecord {
        guard Self.valid(record) else { throw Failure.invalid }
        return try withLease { directoryFD, lockFD in
            var records = try Self.read(directoryFD)
            let old = records[record.key]
            var revision = UUID().uuidString.lowercased()
            while revision == record.revision || revision == (old?.revision ?? "") {
                revision = UUID().uuidString.lowercased()
            }
            let conflicts = old.map { !Self.sameProvenance($0, record) } ?? false
            // Every insertion invalidates outstanding CAS operations, even if
            // a caller replays a record from an older read. Conflicting or
            // incomplete evidence must not upgrade an unknown history.
            let next = CodexHiddenRecord(key: record.key, revision: revision,
                                         turnID: conflicts ? nil : record.turnID,
                                         rolloutPathDigest: conflicts ? nil : record.rolloutPathDigest,
                                         device: conflicts ? nil : record.device,
                                         inode: conflicts ? nil : record.inode)
            records[record.key] = next
            try Self.write(records, directoryFD: directoryFD, lockFD: lockFD)
            return next
        }
    }

    func remove(key: CodexHiddenKey, expectedRevision: String) throws -> Bool {
        guard Self.valid(key), Self.validRevision(expectedRevision) else { throw Failure.invalid }
        return try withLease { directoryFD, lockFD in
            var records = try Self.read(directoryFD)
            guard let old = records[key], old.revision == expectedRevision else { return false }
            records.removeValue(forKey: key)
            try Self.write(records, directoryFD: directoryFD, lockFD: lockFD)
            return true
        }
    }

    private static func sameProvenance(_ first: CodexHiddenRecord, _ second: CodexHiddenRecord) -> Bool {
        first.turnID == second.turnID && first.rolloutPathDigest == second.rolloutPathDigest &&
            first.device == second.device && first.inode == second.inode
    }

    private static func valid(_ record: CodexHiddenRecord) -> Bool {
        guard valid(record.key), validRevision(record.revision) else { return false }
        if let turn = record.turnID {
            let bytes = turn.utf8
            guard !bytes.isEmpty, bytes.count <= 256, bytes.allSatisfy({ byte in
                (48...57).contains(byte) || (65...90).contains(byte) ||
                    (97...122).contains(byte) || byte == 45 || byte == 95 || byte == 58
            }) else { return false }
        }
        let identityCount = [record.rolloutPathDigest != nil, record.device != nil, record.inode != nil]
            .filter { $0 }.count
        guard identityCount == 0 || identityCount == 3 else { return false }
        if let digest = record.rolloutPathDigest, !lowercaseHexDigest(digest) { return false }
        return true
    }

    private static func valid(_ key: CodexHiddenKey) -> Bool {
        lowercaseHexDigest(key.codexHomeID) && validUUID(key.threadID)
    }

    private static func validRevision(_ value: String) -> Bool {
        validUUID(value) && Array(value.utf8)[14] == 52 // UUID version 4
    }

    private static func validUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36, let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString.lowercased() == value
    }

    private static func lowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func withLease<T>(_ body: (Int32, Int32) throws -> T) throws -> T {
        let directoryFD = try openDirectory()
        defer { Darwin.close(directoryFD) }
        let lockFD = openat(directoryFD, Self.lockName, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                            mode_t(0o600))
        guard lockFD >= 0 else { throw Failure.unsafe }
        defer { Darwin.close(lockFD) }
        try Self.verifyPrivateFile(lockFD)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.busy }
            throw Failure.io
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        try Self.verifyLock(directoryFD: directoryFD, lockFD: lockFD)
        return try body(directoryFD, lockFD)
    }

    /// Open every component relative to a pinned parent without following links.
    /// Only the final application directory may be created here.
    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL else { throw Failure.unsafe }
        let path = directory.standardizedFileURL.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else { throw Failure.unsafe }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Failure.io }
        for (index, component) in components.enumerated() {
            var next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if next < 0 && errno == ENOENT && index == components.count - 1 {
                let created = component.withCString { mkdirat(current, $0, mode_t(0o700)) }
                if created != 0 && errno != EEXIST { Darwin.close(current); throw Failure.io }
                next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            }
            Darwin.close(current)
            guard next >= 0 else { throw Failure.unsafe }
            current = next
        }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else {
            Darwin.close(current)
            throw Failure.unsafe
        }
        return current
    }

    private static func verifyPrivateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, (info.st_mode & 0o077) == 0 else {
            throw Failure.unsafe
        }
    }

    private static func verifyLock(directoryFD: Int32, lockFD: Int32) throws {
        var locked = stat()
        guard fstat(lockFD, &locked) == 0 else { throw Failure.io }
        let check = openat(directoryFD, lockName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard check >= 0 else { throw Failure.unsafe }
        defer { Darwin.close(check) }
        try verifyPrivateFile(check)
        var current = stat()
        guard fstat(check, &current) == 0, current.st_dev == locked.st_dev,
              current.st_ino == locked.st_ino else { throw Failure.unsafe }
    }

    private static func read(_ directoryFD: Int32) throws -> [CodexHiddenKey: CodexHiddenRecord] {
        let fd = openat(directoryFD, stateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return [:] }
            throw Failure.unsafe
        }
        defer { Darwin.close(fd) }
        try verifyPrivateFile(fd)
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size > 0,
              before.st_size <= off_t(maximumBytes) else { throw Failure.invalid }
        var data = Data(count: Int(before.st_size))
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.io }
            offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.io }
        try verifyPrivateFile(fd)
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) } catch { throw Failure.invalid }
        guard document.version == 1, document.records.count <= maximumRecords,
              document.records.allSatisfy({ valid($0) }), try encode(document.records) == data else { throw Failure.invalid }
        var result: [CodexHiddenKey: CodexHiddenRecord] = [:]
        for record in document.records {
            guard result.updateValue(record, forKey: record.key) == nil else { throw Failure.invalid }
        }
        return result
    }

    /// Canonical re-encoding also rejects duplicate or unexpected JSON keys,
    /// null variants, alternate representations and non-canonical ordering.
    private static func encode(_ records: [CodexHiddenRecord]) throws -> Data {
        guard records.count <= maximumRecords else { throw Failure.invalid }
        let ordered = records.sorted {
            if $0.key.codexHomeID != $1.key.codexHomeID { return $0.key.codexHomeID < $1.key.codexHomeID }
            return $0.key.threadID < $1.key.threadID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(Document(version: 1, records: ordered)) } catch { throw Failure.invalid }
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.invalid }
        return data
    }

    private static func write(_ records: [CodexHiddenKey: CodexHiddenRecord], directoryFD: Int32, lockFD: Int32) throws {
        let data = try encode(Array(records.values))
        let temporary = ".codex-uncertain-\(UUID().uuidString.lowercased()).tmp"
        let fd = openat(directoryFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(0o600))
        guard fd >= 0 else { throw Failure.io }
        var renamed = false
        defer { Darwin.close(fd); if !renamed { _ = unlinkat(directoryFD, temporary, 0) } }
        try verifyPrivateFile(fd)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.io }
            offset += count
        }
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw Failure.io
        }
        try verifyLock(directoryFD: directoryFD, lockFD: lockFD)
        guard renameat(directoryFD, temporary, directoryFD, stateName) == 0 else { throw Failure.io }
        renamed = true
    }
}
