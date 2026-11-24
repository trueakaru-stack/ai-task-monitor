import CryptoKit
import Darwin
import Foundation

// The empty marker names contain only SHA-256 of a bounded session ID. They
// are never removed automatically: a reused ID has no proven new generation.
enum ClaudeHookLossEvidence {
    struct Scope: Equatable {
        var hashes: Set<String> = []
        var global = false
        var hasLoss: Bool { global || !hashes.isEmpty }
    }

    private static let prefix = "claude-loss-v1-"
    private static let suffix = ".flag"
    private static let globalName = prefix + "global" + suffix
    private static let maximumMarkers = 4_096
    private static let maximumVisited = 8_192

    static func hash(session: String) -> String? {
        let bytes = Data(session.utf8)
        guard !bytes.isEmpty, bytes.count <= 256 else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(sessionKey: String) -> String? {
        guard sessionKey.hasPrefix("~") else { return hash(session: sessionKey) }
        let hex = Array(sessionKey.dropFirst().utf8)
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.count <= 512 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let value = UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(value)
        }
        guard let session = String(bytes: bytes, encoding: .utf8) else { return nil }
        return hash(session: session)
    }

    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return descriptor
    }

    static func inspect(directory: URL) throws -> Scope {
        let descriptor = try openDirectory(directory)
        guard let stream = fdopendir(descriptor) else {
            let reason = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(reason))
        }
        defer { closedir(stream) }
        var scope = Scope()
        var visited = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                break
            }
            visited += 1
            if visited > maximumVisited { scope.global = true; break }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { scope.global = true; break }
            if name == globalName { scope.global = true; continue }
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let digest = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            let valid = digest.utf8.count == 64 && digest.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
            guard valid else { scope.global = true; continue }
            scope.hashes.insert(digest)
            if scope.hashes.count > maximumMarkers { scope.global = true; break }
        }
        return scope
    }

    // `global` is mandatory once journal mutation may have started: another
    // session's data may have been damaged by a partial write or rotation.
    @discardableResult
    static func record(directory: URL, session: String, global: Bool) -> Bool {
        guard let observed = try? inspect(directory: directory), let descriptor = try? openDirectory(directory) else { return false }
        defer { Darwin.close(descriptor) }
        let digest = global ? nil : hash(session: session)
        let target: String
        if observed.global || digest == nil || (!observed.hashes.contains(digest!) && observed.hashes.count >= maximumMarkers) {
            target = globalName
        } else {
            target = prefix + digest! + suffix
        }
        let created = target.withCString {
            openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        if created >= 0 { Darwin.close(created); return true }
        return errno == EEXIST
    }
}
