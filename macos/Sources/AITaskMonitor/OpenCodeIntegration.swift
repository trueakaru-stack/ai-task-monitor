import CryptoKit
import Darwin
import Foundation

enum OpenCodeIntegrationError: Error { case invalidPath, conflict, modified, missingResources, unverifiedVersion }

enum OpenCodeIntegration {
    typealias State = ExternalProviderConnectionState
    private static let owner = "AI Task Monitor OpenCode v1"
    private static let files = ["provider-events.mjs", "provider-observers.mjs", "provider-transport.mjs"]

    private struct Manifest: Codable {
        let owner: String
        let files: [String: String]
        let shim: String
    }

    private struct Paths {
        let home: URL
        let config: URL
        let source: URL
        let plugins: URL
        let folder: URL
        let shim: URL
        let manifest: URL

        init(home: URL) {
            self.home = home
            config = home.appendingPathComponent(".config", isDirectory: true)
            source = config.appendingPathComponent("opencode", isDirectory: true)
            plugins = source.appendingPathComponent("plugins", isDirectory: true)
            folder = source.appendingPathComponent("ai-task-monitor-data", isDirectory: true)
            shim = plugins.appendingPathComponent("ai-task-monitor.js")
            manifest = folder.appendingPathComponent("manifest.json")
        }
    }

    static func state(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> State {
        let paths = Paths(home: home)
        try checkPaths(paths)
        let manager = FileManager.default
        let folderExists = manager.fileExists(atPath: paths.folder.path)
        let shimExists = manager.fileExists(atPath: paths.shim.path)
        let manifest = try folderExists ? readOwnedManifest(paths) : nil
        if folderExists && manifest == nil { throw OpenCodeIntegrationError.conflict }
        if folderExists && shimExists { return .connected }
        return folderExists || shimExists ? .partial : .disconnected
    }

    static func setConnected(_ connect: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             assets: URL? = nil, fixtureVersion: String? = nil) throws {
        if connect {
            let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let fixtureHome = home.resolvingSymlinksInPath().standardizedFileURL.path
            if assets != nil || fixtureVersion != nil {
                guard assets != nil, fixtureHome.hasPrefix(temporaryRoot + "/"),
                      supports(version: fixtureVersion ?? "1.18.29") else { throw OpenCodeIntegrationError.unverifiedVersion }
            } else {
                guard home.resolvingSymlinksInPath().standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL else {
                    throw OpenCodeIntegrationError.invalidPath
                }
                let versions = try installedVersions(home: home)
                guard !versions.isEmpty, versions.allSatisfy(supports(version:)) else { throw OpenCodeIntegrationError.unverifiedVersion }
            }
        }
        let paths = Paths(home: home)
        let manager = FileManager.default
        try checkPaths(paths)
        let folderExists = manager.fileExists(atPath: paths.folder.path)
        let shimExists = manager.fileExists(atPath: paths.shim.path)
        let existing = try folderExists ? readOwnedManifest(paths) : nil
        if folderExists && existing == nil { throw OpenCodeIntegrationError.conflict }
        if !connect {
            if shimExists && existing == nil { throw OpenCodeIntegrationError.conflict }
            if shimExists { try manager.removeItem(at: paths.shim) }
            if folderExists { try removeOwnedFolder(paths) }
            return
        }
        let assetDirectory = assets ?? Bundle.main.resourceURL?.appendingPathComponent("integrations", isDirectory: true)
        guard let assetDirectory else { throw OpenCodeIntegrationError.missingResources }
        let entry = assetDirectory.appendingPathComponent("opencode-entry.js")
        guard manager.fileExists(atPath: entry.path), files.allSatisfy({ manager.fileExists(atPath: assetDirectory.appendingPathComponent($0).path) }) else {
            throw OpenCodeIntegrationError.missingResources
        }
        if folderExists && shimExists {
            guard let existing, try digest(entry) == existing.shim,
                  try files.allSatisfy({ try digest(assetDirectory.appendingPathComponent($0)) == existing.files[$0] }) else {
                throw OpenCodeIntegrationError.modified
            }
            return
        }
        guard !folderExists && !shimExists else { throw OpenCodeIntegrationError.conflict }
        try manager.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
        try checkPaths(paths)
        let stage = paths.source.appendingPathComponent(".aitm-stage-" + UUID().uuidString, isDirectory: true)
        let temporaryShim = paths.plugins.appendingPathComponent(".aitm-entry-" + UUID().uuidString + ".tmp")
        guard stage.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else { throw OpenCodeIntegrationError.conflict }
        var stageInfo = stat()
        guard stage.path.withCString({ lstat($0, &stageInfo) }) == 0,
              stageInfo.st_uid == geteuid(), (stageInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw OpenCodeIntegrationError.invalidPath
        }
        var created: [URL] = []
        var moved = false
        var shimCreated = false
        defer {
            if shimCreated { try? manager.removeItem(at: temporaryShim) }
            var current = stat()
            if stage.path.withCString({ lstat($0, &current) }) == 0,
               current.st_uid == geteuid(), (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
               current.st_dev == stageInfo.st_dev, current.st_ino == stageInfo.st_ino {
                for item in created { try? manager.removeItem(at: item) }
                try? manager.removeItem(at: stage)
            }
        }
        do {
            var hashes: [String: String] = [:]
            for name in files {
                let target = stage.appendingPathComponent(name)
                try manager.copyItem(at: assetDirectory.appendingPathComponent(name), to: target)
                created.append(target)
                hashes[name] = try digest(target)
            }
            let marker = Manifest(owner: owner, files: hashes, shim: try digest(entry))
            let stagedManifest = stage.appendingPathComponent("manifest.json")
            try JSONEncoder().encode(marker).write(to: stagedManifest, options: .withoutOverwriting)
            created.append(stagedManifest)
            try manager.copyItem(at: entry, to: temporaryShim)
            shimCreated = true
            try checkPaths(paths)
            try manager.moveItem(at: stage, to: paths.folder)
            moved = true
            try manager.moveItem(at: temporaryShim, to: paths.shim)
            shimCreated = false
        } catch {
            if moved && !manager.fileExists(atPath: paths.shim.path) { try? removeOwnedFolder(paths) }
            throw error
        }
    }

    static func supports(version: String) -> Bool {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"(?i)^opencode\s+"#, with: "", options: .regularExpression)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.count <= 5 && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2]) else { return false }
        return major == 2 || (major == 1 && (minor > 18 || (minor == 18 && patch >= 29)))
    }

    static func hasPotentialInstallation(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        !installedExecutables(home: home).isEmpty
    }

    private static func installedExecutables(home: URL) -> Set<String> {
        let manager = FileManager.default
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home.appendingPathComponent(".opencode/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        return Set(paths.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("opencode").path }
            .filter { manager.isExecutableFile(atPath: $0) })
    }

    private static func installedVersions(home: URL) throws -> [String] {
        let executables = installedExecutables(home: home)
        var versions: [String] = []
        for executable in executables {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--version"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch { throw OpenCodeIntegrationError.unverifiedVersion }
            guard exited.wait(timeout: .now() + 3) == .success else {
                if process.isRunning { process.terminate() }
                if exited.wait(timeout: .now() + 1) != .success {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    _ = exited.wait(timeout: .now() + 1)
                }
                throw OpenCodeIntegrationError.unverifiedVersion
            }
            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw OpenCodeIntegrationError.unverifiedVersion
            }
            var bytes = [UInt8](repeating: 0, count: 81)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard process.terminationStatus == 0,
                  count > 0, count <= 80,
                  let version = String(bytes: bytes.prefix(count), encoding: .utf8),
                  supports(version: version) else { throw OpenCodeIntegrationError.unverifiedVersion }
            versions.append(version.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return versions
    }

    private static func checkPaths(_ paths: Paths) throws {
        for url in [paths.home, paths.config, paths.source, paths.plugins, paths.folder, paths.shim, paths.manifest] {
            var info = stat()
            if url.path.withCString({ lstat($0, &info) }) == 0 {
                if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) { throw OpenCodeIntegrationError.invalidPath }
            } else if errno != ENOENT { throw OpenCodeIntegrationError.invalidPath }
        }
    }

    private static func readOwnedManifest(_ paths: Paths) throws -> Manifest? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.manifest.path) else { return nil }
        let names = try manager.contentsOfDirectory(atPath: paths.folder.path)
        guard Set(names) == Set(files + ["manifest.json"]) else { throw OpenCodeIntegrationError.modified }
        for name in names {
            var info = stat()
            let item = paths.folder.appendingPathComponent(name)
            guard item.path.withCString({ lstat($0, &info) }) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw OpenCodeIntegrationError.invalidPath }
        }
        let data = try Data(contentsOf: paths.manifest)
        guard data.count <= 8_192, let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.owner == owner, Set(manifest.files.keys) == Set(files),
              manifest.shim.range(of: #"^[A-F0-9]{64}$"#, options: .regularExpression) != nil else { throw OpenCodeIntegrationError.modified }
        for name in files {
            guard let expected = manifest.files[name], expected.range(of: #"^[A-F0-9]{64}$"#, options: .regularExpression) != nil,
                  try digest(paths.folder.appendingPathComponent(name)) == expected else { throw OpenCodeIntegrationError.modified }
        }
        if manager.fileExists(atPath: paths.shim.path), try digest(paths.shim) != manifest.shim { throw OpenCodeIntegrationError.modified }
        return manifest
    }

    private static func removeOwnedFolder(_ paths: Paths) throws {
        guard try readOwnedManifest(paths) != nil else { throw OpenCodeIntegrationError.conflict }
        for name in files { try FileManager.default.removeItem(at: paths.folder.appendingPathComponent(name)) }
        try FileManager.default.removeItem(at: paths.manifest)
        try FileManager.default.removeItem(at: paths.folder)
    }

    private static func digest(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
