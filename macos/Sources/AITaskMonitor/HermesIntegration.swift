import CryptoKit
import Darwin
import Foundation

struct HermesProfile: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let state: String
    let scope: String?
    let error: String?
    let enabled: Bool?

    init(id: String, name: String, state: String, scope: String?, error: String?, enabled: Bool? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.scope = scope
        self.error = error
        self.enabled = enabled
    }

    var commandProfile: String? {
        if id == "root", name == "default" { return "default" }
        guard id == "profile:" + name, HermesIntegration.validProfileName(name) else { return nil }
        return name
    }
}

struct HermesIntegrationError: Error { let code: String }

enum HermesIntegration {
    struct Context {
        let python: URL
        let home: URL
        let project: URL
        let assets: URL
        var environment: [String: String]? = nil
        var managed: Bool = false
        var bridge: URL { assets.appendingPathComponent("hermes-setup.py") }
    }

    private struct Response<Value: Decodable>: Decodable {
        let ok: Bool
        let result: Value?
        let error: String?
    }

    private static func physicalURL(_ url: URL, directory: Bool = false) -> URL? {
        guard let resolved = url.path.withCString({ Darwin.realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: directory)
    }

    private static func plainDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return physicalURL(url, directory: true)?.path == url.path &&
            FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    // Read only bounded installation metadata. Never open Hermes credentials or profile contents.
    private static func readFacts(_ url: URL) -> Data? {
        var before = stat()
        guard url.path.withCString({ lstat($0, &before) }) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_size >= 0, before.st_size <= 1_048_576,
              physicalURL(url)?.path == url.path else { return nil }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino, (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        var result = Data()
        while true {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            guard result.count + count <= 1_048_576 else { return nil }
            result.append(contentsOf: bytes.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == opened.st_size,
              after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else { return nil }
        return result
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment,
                         resources: URL? = Bundle.main.resourceURL) -> Context? {
        let manager = FileManager.default
        guard let resources,
              let assets = physicalURL(resources.appendingPathComponent("integrations", isDirectory: true), directory: true),
              manager.fileExists(atPath: assets.appendingPathComponent("hermes-setup.py").path),
              manager.fileExists(atPath: assets.appendingPathComponent("hermes-manager.py").path),
              manager.fileExists(atPath: assets.appendingPathComponent("provider_bundle.py").path) else { return nil }
        let rawHome = environment["HERMES_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested: URL
        if let rawHome, !rawHome.isEmpty {
            guard rawHome.hasPrefix("/") else { return nil }
            requested = URL(fileURLWithPath: rawHome, isDirectory: true)
        } else { requested = home.appendingPathComponent(".hermes", isDirectory: true) }
        let requestedRoot = requested.deletingLastPathComponent().lastPathComponent == "profiles"
            ? requested.deletingLastPathComponent().deletingLastPathComponent() : requested
        guard let root = physicalURL(requestedRoot, directory: true) else { return nil }
        let project = root.appendingPathComponent("hermes-agent", isDirectory: true)
        guard plainDirectory(project),
              manager.fileExists(atPath: root.appendingPathComponent("config.yaml").path),
              manager.fileExists(atPath: project.appendingPathComponent("hermes_cli/middleware.py").path) else { return nil }

        let digest = SHA256.hash(data: Data(project.path.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let install = root.appendingPathComponent("installs/\(key)", isDirectory: true)
        let facts = install.appendingPathComponent("facts.json")
        var factsInfo = stat()
        let factsStatus = facts.path.withCString { lstat($0, &factsInfo) }
        let venv: URL
        if factsStatus == 0 {
            guard plainDirectory(install), let data = readFacts(facts),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let packages = object["packages"] as? [String: Any],
                  let entry = packages["venv"] as? [String: Any],
                  let path = entry["environment"] as? String, path.hasPrefix("/") else { return nil }
            let generations = install.appendingPathComponent("environments", isDirectory: true)
            let candidate = URL(fileURLWithPath: path, isDirectory: true)
            guard plainDirectory(generations), plainDirectory(candidate),
                  candidate.path.hasPrefix(generations.path + "/") else { return nil }
            venv = candidate
        } else {
            guard errno == ENOENT else { return nil }
            guard let candidate = ["venv", ".venv"].map({ project.appendingPathComponent($0, isDirectory: true) })
                .first(where: { plainDirectory($0) }) else { return nil }
            venv = candidate
        }
        let python = venv.appendingPathComponent("bin/python3")
        guard manager.fileExists(atPath: venv.appendingPathComponent("pyvenv.cfg").path),
              manager.isExecutableFile(atPath: python.path) else { return nil }
        let managedDirectory = !(environment["HERMES_MANAGED_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let backend = (environment["HERMES_CONFIG_BACKEND"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let managed = managedDirectory || (!backend.isEmpty && backend != "file")
        return Context(python: python, home: root, project: project, assets: assets, managed: managed)
    }

    static func validProfileName(_ name: String) -> Bool {
        guard !["hermes", "default", "test", "tmp", "root", "sudo"].contains(name) else { return false }
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first,
              (48...57).contains(first) || (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    private static func shellPath(_ url: URL) -> String? {
        let path = url.path
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(_ profile: HermesProfile, context: Context, enable: Bool) -> String? {
        guard let name = profile.commandProfile,
              let python = shellPath(context.python),
              let launcher = shellPath(context.assets.appendingPathComponent("hermes-manager.py")),
              let home = shellPath(context.home), let project = shellPath(context.project) else { return nil }
        return "\(python) -I -B \(launcher) \(home) \(project) '\(name)' '\(enable ? "enable" : "disable")'"
    }

    static func validProfiles(_ profiles: [HermesProfile]) -> Bool {
        guard (1...256).contains(profiles.count), Set(profiles.map(\.id)).count == profiles.count,
              profiles.contains(where: { $0.id == "root" }) else { return false }
        var scopes: Set<String> = []
        return profiles.allSatisfy { profile in
            guard profile.commandProfile != nil else { return false }
            switch profile.state {
            case "prepared":
                guard profile.error == nil, profile.enabled != nil,
                      DeepSeekIntegration.validScope(profile.scope), let scope = profile.scope else { return false }
                return scopes.insert(scope).inserted
            case "absent": return profile.scope == nil && profile.error == nil && profile.enabled == nil
            case "error": return profile.scope == nil && profile.error != nil && profile.enabled == nil
            default: return false
            }
        }
    }

    static func profiles(_ context: Context, timeout: TimeInterval = 15) throws -> [HermesProfile] {
        let value: [HermesProfile] = try perform(context, action: "list", timeout: timeout)
        guard validProfiles(value) else { throw HermesIntegrationError(code: "invalid-response") }
        return value
    }

    static func prepare(_ profile: HermesProfile, context: Context, timeout: TimeInterval = 15) throws {
        guard profile.commandProfile != nil else { throw HermesIntegrationError(code: "invalid-profile") }
        let result: String = try perform(context, action: "prepare", profile: profile.id, timeout: timeout)
        guard result == "prepared" else { throw HermesIntegrationError(code: "invalid-response") }
    }

    private static func perform<Value: Decodable>(_ context: Context, action: String, profile: String? = nil,
                                                  timeout: TimeInterval) throws -> Value {
        var request: [String: Any] = ["action": action, "home": context.home.path, "project": context.project.path,
                                      "assets": context.assets.path, "managed": context.managed]
        if let profile { request["profile"] = profile }
        let inputData = try JSONSerialization.data(withJSONObject: request)
        guard inputData.count <= 8_192, timeout > 0 else { throw HermesIntegrationError(code: "invalid-request") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = context.python
        process.arguments = ["-I", "-S", "-B", context.bridge.path]
        process.currentDirectoryURL = context.assets
        process.environment = context.environment ?? ["PATH": "/usr/bin:/bin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Fill the bounded request while the read end is still owned by this process.
        // A bridge that exits immediately must not cause a SIGPIPE in the app.
        do {
            try input.fileHandleForWriting.write(contentsOf: inputData)
            try input.fileHandleForWriting.close()
            try process.run()
        } catch { throw HermesIntegrationError(code: "operation-failed") }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw HermesIntegrationError(code: "operation-failed") }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data(), eof = false
        while true {
            guard Date() < deadline else { throw HermesIntegrationError(code: "operation-failed") }
            if eof {
                if !process.isRunning { break }
                usleep(20_000)
                continue
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                throw HermesIntegrationError(code: "operation-failed")
            }
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard data.count + count <= 131_072 else { throw HermesIntegrationError(code: "invalid-response") }
                    data.append(contentsOf: bytes.prefix(count))
                } else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { throw HermesIntegrationError(code: "operation-failed") }
            } else if !process.isRunning { break }
        }
        guard let response = try? JSONDecoder().decode(Response<Value>.self, from: data) else { throw HermesIntegrationError(code: "invalid-response") }
        guard response.ok, process.terminationStatus == 0, let result = response.result else {
            throw HermesIntegrationError(code: response.error ?? "operation-failed")
        }
        return result
    }
}
