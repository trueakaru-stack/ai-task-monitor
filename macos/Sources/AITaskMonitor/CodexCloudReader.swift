import CryptoKit
import Foundation

/// Parses the documented `codex cloud list --json` output without retaining summaries or URLs.
enum CodexCloudReader {
    enum Status: Equatable { case pending, terminal, unknown }
    struct Task: Equatable {
        let id: String
        let title: String?
        let status: Status
        let updatedAt: Date?
    }
    struct Page: Equatable {
        let tasks: [Task]
        let cursor: String?
    }
    enum Error: Swift.Error { case invalidResponse }

    private struct Response: Decodable {
        struct Item: Decodable {
            let id: String
            let title: String?
            let status: String?
            let updated_at: String?
        }
        let tasks: [Item]
        let cursor: String?
    }

    static func parse(_ data: Data) throws -> Page {
        guard data.count <= 1_048_576, let response = try? JSONDecoder().decode(Response.self, from: data),
              response.tasks.count <= 20 else { throw Error.invalidResponse }
        if let cursor = response.cursor {
            guard !cursor.isEmpty, cursor.utf8.count <= 1_024,
                  cursor.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw Error.invalidResponse }
        }
        var ids = Set<String>()
        let tasks = try response.tasks.map { item -> Task in
            guard !item.id.isEmpty, item.id.utf8.count <= 512,
                  item.id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  ids.insert(item.id).inserted else { throw Error.invalidResponse }
            let digest = SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined()
            let title: String?
            if let rawTitle = item.title {
                let scalars = rawTitle.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
                let normalized = FileHelpers.normalized(scalars, limit: 240)
                title = normalized.isEmpty ? nil : normalized
            } else { title = nil }
            let status: Status
            switch item.status {
            case "pending": status = .pending
            case "ready", "error": status = .terminal
            default: status = .unknown
            }
            let date = item.updated_at.flatMap { FileHelpers.isoDate($0) }
            return Task(id: "codex-cloud:" + String(digest.prefix(32)), title: title, status: status, updatedAt: date)
        }
        return Page(tasks: tasks, cursor: response.cursor)
    }
}
