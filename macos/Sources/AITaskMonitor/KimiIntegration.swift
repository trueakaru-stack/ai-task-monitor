import Darwin
import Foundation

struct KimiConnection: Decodable, Equatable {
    let state: String
    let scope: String?
}

struct KimiIntegrationError: Error { let code: String }

enum KimiIntegration {
    struct Context {
        let node: URL
        let home: URL
        let assets: URL
        let installAnchor: URL
        var environment: [String: String]? = nil
        var bridge: URL { assets.deletingLastPathComponent().appendingPathComponent("kimi-setup.mjs") }
    }

    private struct Response: Decodable {
        let ok: Bool
        let result: KimiConnection?
        let error: String?
    }

    static func pluginDirectory(resources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let resources else { return nil }
        let directory = resources.appendingPathComponent("integrations/kimi-plugin", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return directory
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment,
                         resources: URL? = Bundle.main.resourceURL) -> Context? {
        let manager = FileManager.default
        guard let assets = pluginDirectory(resources: resources),
              manager.fileExists(atPath: assets.deletingLastPathComponent().appendingPathComponent("kimi-setup.mjs").path) else { return nil }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            home.appendingPathComponent(".nvm/current/bin").path, home.appendingPathComponent(".volta/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"
        ]
        func executable(_ name: String) -> URL? {
            for path in paths {
                let candidate = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
                if manager.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            return nil
        }
        guard let node = executable("node"), let kimi = executable("kimi") else { return nil }
        let binary = kimi.resolvingSymlinksInPath().standardizedFileURL
        guard binary.lastPathComponent == "main.mjs", binary.deletingLastPathComponent().lastPathComponent == "dist" else { return nil }
        let anchor = binary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")
        guard manager.fileExists(atPath: anchor.path) else { return nil }
        let kimiHome: URL
        if let custom = environment["KIMI_CODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            guard custom.hasPrefix("/") else { return nil }
            kimiHome = URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
        } else { kimiHome = home.appendingPathComponent(".kimi-code", isDirectory: true) }
        return Context(node: node, home: kimiHome, assets: assets, installAnchor: anchor)
    }

    static func inspect(_ context: Context, timeout: TimeInterval = 15) throws -> KimiConnection {
        let request = ["home": context.home.path, "assets": context.assets.path, "installAnchor": context.installAnchor.path]
        let inputData = try JSONSerialization.data(withJSONObject: request)
        guard inputData.count <= 8_192, timeout > 0 else { throw KimiIntegrationError(code: "invalid-request") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = context.node
        process.arguments = [context.bridge.path]
        process.currentDirectoryURL = context.assets
        process.environment = context.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw KimiIntegrationError(code: "operation-failed") }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: inputData)
            try input.fileHandleForWriting.close()
        } catch { throw KimiIntegrationError(code: "operation-failed") }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw KimiIntegrationError(code: "operation-failed") }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data(), eof = false
        while true {
            guard Date() < deadline else { throw KimiIntegrationError(code: "operation-failed") }
            if eof {
                if !process.isRunning { break }
                usleep(20_000)
                continue
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                throw KimiIntegrationError(code: "operation-failed")
            }
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard data.count + count <= 131_072 else { throw KimiIntegrationError(code: "invalid-response") }
                    data.append(contentsOf: bytes.prefix(count))
                } else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { throw KimiIntegrationError(code: "operation-failed") }
            } else if !process.isRunning { break }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw KimiIntegrationError(code: "invalid-response") }
        guard response.ok, process.terminationStatus == 0, let result = response.result else {
            throw KimiIntegrationError(code: response.error ?? "operation-failed")
        }
        guard ["connected", "disabled", "disconnected"].contains(result.state),
              (result.state == "connected" ? DeepSeekIntegration.validScope(result.scope) : result.scope == nil) else {
            throw KimiIntegrationError(code: "invalid-response")
        }
        return result
    }
}
