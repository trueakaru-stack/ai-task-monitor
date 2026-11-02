import Foundation

enum FileHelpers {
    static func tail(of url: URL, maximumBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let count = min(UInt64(maximumBytes), length)
        try handle.seek(toOffset: length - count)
        let data = try handle.read(upToCount: Int(count)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return nil }
        return object
    }

    static func normalized(_ value: String, limit: Int = 1_024) -> String {
        let compact = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(max(1, limit - 1))) + "…"
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}
