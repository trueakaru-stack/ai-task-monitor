import CryptoKit
import Foundation

// Only the live monitor owns these values. Neither the key, digest nor tool ID
// belongs in a persistent event, settings file or diagnostic journal.
struct ClaudePhaseEvidence {
    private struct Entry {
        let session: String
        let toolID: String
        var ambiguous: Bool
    }
    private var key: Data?
    private var entries: [String: Entry] = [:]
    private(set) var poisoned = false
    private let maximumEntries = 8192

    mutating func start(key: Data) {
        guard !poisoned, key.count == 32 else { invalidate(); return }
        self.key = key
        entries.removeAll(keepingCapacity: false)
    }

    mutating func invalidate() {
        key = nil
        entries.removeAll(keepingCapacity: false)
        poisoned = true
    }

    mutating func observe(session: String, toolID: String, fingerprint: String) {
        guard !poisoned, key != nil, ClaudeLoopInput.validID(session), ClaudeLoopInput.validID(toolID),
              Self.validDigest(fingerprint) else { invalidate(); return }
        if var prior = entries[fingerprint] {
            // Even identical repeated frames may correspond to two writes.
            prior.ambiguous = true
            entries[fingerprint] = prior
            return
        }
        guard entries.count < maximumEntries else { invalidate(); return }
        entries[fingerprint] = Entry(session: session, toolID: toolID, ambiguous: false)
    }

    func fingerprint(_ event: [String: Any]) -> String? {
        guard !poisoned, let key, JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              data.count <= 1_048_576 else { return nil }
        return Self.digest(data, key: key)
    }

    func toolID(fingerprint: String, session: String) -> String? {
        guard !poisoned, let entry = entries[fingerprint], !entry.ambiguous,
              entry.session.utf8.elementsEqual(session.utf8) else { return nil }
        return entry.toolID
    }

    static func digest(_ data: Data, key: Data) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        let hex = Array("0123456789abcdef".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(64)
        for byte in digest { result.append(hex[Int(byte >> 4)]); result.append(hex[Int(byte & 15)]) }
        return String(decoding: result, as: UTF8.self)
    }

    static func validDigest(_ value: String) -> Bool {
        let bytes = Array(value.utf8.prefix(65))
        return bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
