import Darwin
import Foundation
import Security

enum ExternalProviderV2GenerationError: Error { case unsafeFile, io, invalid, random }

// The monitor owns one bounded map, rather than accumulating a file per old
// profile. Producers read their generation once when their plugin loads.
final class ExternalProviderV2GenerationFile {
    let directory: URL
    private let name = "generations-v2.json"

    init(directory: URL) { self.directory = directory }

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ExternalProviderV2GenerationError.random
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func replace(_ generations: [ExternalProviderV2Scope: String]) throws {
        guard generations.count <= 257,
              generations.allSatisfy({ $0.key.valid && ExternalProviderV2Scope.hex($0.value) }) else {
            throw ExternalProviderV2GenerationError.invalid
        }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (directoryInfo.st_mode & mode_t(0o077)) == 0 else { throw ExternalProviderV2GenerationError.unsafeFile }
        let entries = Dictionary(uniqueKeysWithValues: generations.map { ($0.key.provider + ":" + $0.key.scope, $0.value) })
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 2, "generations": entries], options: [.sortedKeys])
        guard bytes.count <= 65_536 else { throw ExternalProviderV2GenerationError.invalid }
        let destination = directory.appendingPathComponent(name).path
        var previous = stat()
        if lstat(destination, &previous) == 0 {
            guard Self.regular(previous) else { throw ExternalProviderV2GenerationError.unsafeFile }
        } else if errno != ENOENT { throw ExternalProviderV2GenerationError.io }
        let temporary = directory.appendingPathComponent(".generations-v2-" + UUID().uuidString + ".tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ExternalProviderV2GenerationError.io }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(temporary) }
        var created = stat()
        guard fstat(fd, &created) == 0, Self.regular(created) else { throw ExternalProviderV2GenerationError.unsafeFile }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary, destination) == 0 else { throw ExternalProviderV2GenerationError.io }
        var installed = stat()
        guard lstat(destination, &installed) == 0, Self.regular(installed),
              installed.st_dev == created.st_dev, installed.st_ino == created.st_ino else {
            throw ExternalProviderV2GenerationError.unsafeFile
        }
    }

    private static func regular(_ value: stat) -> Bool {
        value.st_uid == geteuid() && value.st_nlink == 1 &&
            (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) && (value.st_mode & mode_t(0o077)) == 0
    }
}
