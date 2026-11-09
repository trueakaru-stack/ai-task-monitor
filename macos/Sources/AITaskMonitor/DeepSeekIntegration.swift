import Foundation

struct DeepSeekProfile: Decodable, Identifiable, Equatable {
    let name: String
    let state: String
    let scope: String?
    let error: String?
    var id: String { name }
}

struct DeepSeekIntegrationError: Error { let code: String }

enum DeepSeekIntegration {
    struct Context {
        let node: URL
        let home: URL
        let assets: URL
        let installAnchor: URL
        let pnpmScript: URL
        var environment: [String: String]? = nil
        var bridge: URL { assets.appendingPathComponent("deepseek-setup.mjs") }
    }

    private struct Response<Value: Decodable>: Decodable {
        let ok: Bool
        let result: Value?
        let error: String?
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment,
                         assets: URL? = Bundle.main.resourceURL?.appendingPathComponent("integrations", isDirectory: true)) -> Context? {
        let manager = FileManager.default
        guard let assets else { return nil }
        let assetDirectory = assets.resolvingSymlinksInPath().standardizedFileURL
        guard manager.fileExists(atPath: assetDirectory.appendingPathComponent("deepseek-setup.mjs").path) else { return nil }
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home.appendingPathComponent(".nvm/current/bin").path, home.appendingPathComponent(".volta/bin").path,
               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        func executable(_ name: String) -> URL? {
            for directory in path {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
                if manager.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            return nil
        }
        guard let node = executable("node"), let dsh = executable("dsh"), let pnpm = executable("pnpm") else { return nil }
        let dshBin = dsh.resolvingSymlinksInPath().standardizedFileURL
        let pnpmBin = pnpm.resolvingSymlinksInPath().standardizedFileURL
        guard dshBin.lastPathComponent == "bin.js", dshBin.deletingLastPathComponent().lastPathComponent == "lib",
              ["pnpm.mjs", "pnpm.cjs"].contains(pnpmBin.lastPathComponent),
              pnpmBin.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
        let anchor = dshBin.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")
        let dshHome: URL
        if let custom = environment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            guard custom.hasPrefix("/") else { return nil }
            dshHome = URL(fileURLWithPath: custom, isDirectory: true).standardizedFileURL
        } else { dshHome = home.appendingPathComponent(".dsh", isDirectory: true) }
        guard manager.fileExists(atPath: anchor.path) else { return nil }
        return Context(node: node, home: dshHome, assets: assetDirectory, installAnchor: anchor.resolvingSymlinksInPath().standardizedFileURL, pnpmScript: pnpmBin)
    }

    static func profiles(_ context: Context) throws -> [DeepSeekProfile] {
        let value: [DeepSeekProfile] = try perform(context, action: "list")
        guard value.filter({ $0.state == "connected" }).count <= 256, Set(value.map(\.name)).count == value.count, value.allSatisfy({ profile in
            guard !profile.name.isEmpty, ["connected", "disconnected", "partial", "error"].contains(profile.state) else { return false }
            if profile.state == "connected" { return validScope(profile.scope) }
            return profile.scope == nil
        }) else { throw DeepSeekIntegrationError(code: "invalid-response") }
        return value
    }

    static func setConnected(_ connect: Bool, profile: String, context: Context) throws {
        let state: String = try perform(context, action: connect ? "connect" : "disconnect", profile: profile)
        guard state == (connect ? "connected" : "disconnected") else { throw DeepSeekIntegrationError(code: "invalid-response") }
    }

    static func validScope(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 32 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func perform<Value: Decodable>(_ context: Context, action: String, profile: String? = nil) throws -> Value {
        var request: [String: String] = ["action": action, "home": context.home.path,
                                         "installAnchor": context.installAnchor.path, "pnpmScript": context.pnpmScript.path]
        if let profile { request["profile"] = profile; request["assets"] = context.assets.path }
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = context.node
        process.arguments = [context.bridge.path]
        process.currentDirectoryURL = context.assets
        process.environment = context.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            defer { try? input.fileHandleForWriting.close() }
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard data.count <= 131_072,
                  let response = try? JSONDecoder().decode(Response<Value>.self, from: data) else {
                throw DeepSeekIntegrationError(code: "invalid-response")
            }
            guard response.ok, process.terminationStatus == 0, let result = response.result else {
                let code = response.error ?? "operation-failed"
                throw DeepSeekIntegrationError(code: code)
            }
            return result
        } catch let error as DeepSeekIntegrationError { throw error }
        catch { throw DeepSeekIntegrationError(code: "operation-failed") }
    }
}
