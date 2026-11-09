import Foundation

// JSONSerialization alone does not expose repeated object members. Reject
// those, ill-formed UTF-8 and unpaired escaped surrogates before deriving any
// session identity or successful-observation signal.
enum ClaudeJSONValidation {
    struct TopLevelMember {
        let valueRange: Range<Int>?
        let closingBrace: Int
        let hasMembers: Bool
    }

    static func object(_ data: Data, maximumBytes: Int = 1_048_576) -> [String: Any]? {
        guard !data.isEmpty, data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else { return nil }
        var parser = Parser(bytes: Array(data))
        guard parser.validate(), let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return nil }
        return object
    }

    // Used for settings edits so unrelated top-level bytes, including exact
    // foreign numbers, are not parsed and serialized again.
    static func topLevelMember(_ data: Data, named name: String) -> TopLevelMember? {
        guard object(data) != nil else { return nil }
        var parser = Parser(bytes: Array(data))
        return parser.topLevelMember(named: name)
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0
        var remainingKeys = 4096

        mutating func validate() -> Bool {
            whitespace()
            guard value(depth: 0) else { return false }
            whitespace()
            return offset == bytes.count
        }

        mutating func topLevelMember(named wanted: String) -> TopLevelMember? {
            whitespace()
            guard consume(0x7b) else { return nil }
            whitespace()
            if offset < bytes.count && bytes[offset] == 0x7d {
                return TopLevelMember(valueRange: nil, closingBrace: offset, hasMembers: false)
            }
            var found: Range<Int>?
            while true {
                whitespace()
                guard let range = stringRange(), let name = decodedKey(range) else { return nil }
                whitespace()
                guard consume(0x3a) else { return nil }
                whitespace()
                let start = offset
                guard value(depth: 1) else { return nil }
                if name.utf8.elementsEqual(wanted.utf8) { found = start..<offset }
                whitespace()
                if offset < bytes.count && bytes[offset] == 0x7d {
                    return TopLevelMember(valueRange: found, closingBrace: offset, hasMembers: true)
                }
                guard consume(0x2c) else { return nil }
            }
        }

        mutating func whitespace() {
            while offset < bytes.count && [0x20, 0x09, 0x0a, 0x0d].contains(bytes[offset]) { offset += 1 }
        }

        mutating func value(depth: Int) -> Bool {
            guard depth <= 32 else { return false }
            whitespace()
            guard offset < bytes.count else { return false }
            switch bytes[offset] {
            case 0x7b: return object(depth: depth + 1)
            case 0x5b: return array(depth: depth + 1)
            case 0x22: return stringRange() != nil
            default:
                let start = offset
                while offset < bytes.count && ![0x2c, 0x5d, 0x7d, 0x20, 0x09, 0x0a, 0x0d].contains(bytes[offset]) { offset += 1 }
                return offset > start
            }
        }

        mutating func object(depth: Int) -> Bool {
            guard depth <= 32 else { return false }
            offset += 1
            whitespace()
            if consume(0x7d) { return true }
            var keys = Set<String>()
            while true {
                whitespace()
                guard remainingKeys > 0, let range = stringRange(), range.count <= 4098,
                      let key = decodedKey(range), keys.insert(key).inserted else { return false }
                remainingKeys -= 1
                whitespace()
                guard consume(0x3a), value(depth: depth) else { return false }
                whitespace()
                if consume(0x7d) { return true }
                guard consume(0x2c) else { return false }
            }
        }

        mutating func array(depth: Int) -> Bool {
            guard depth <= 32 else { return false }
            offset += 1
            whitespace()
            if consume(0x5d) { return true }
            while true {
                guard value(depth: depth) else { return false }
                whitespace()
                if consume(0x5d) { return true }
                guard consume(0x2c) else { return false }
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1
            return true
        }

        mutating func stringRange() -> Range<Int>? {
            let start = offset
            guard consume(0x22) else { return nil }
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == 0x22 { return start..<offset }
                if byte < 0x20 { return nil }
                if byte != 0x5c { continue }
                guard offset < bytes.count else { return nil }
                let escape = bytes[offset]
                offset += 1
                if [0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(escape) { continue }
                guard escape == 0x75, let scalar = hex4() else { return nil }
                if (0xd800...0xdbff).contains(scalar) {
                    guard consume(0x5c), consume(0x75), let low = hex4(), (0xdc00...0xdfff).contains(low) else { return nil }
                } else if (0xdc00...0xdfff).contains(scalar) { return nil }
            }
            return nil
        }

        mutating func hex4() -> Int? {
            guard offset <= bytes.count, bytes.count - offset >= 4 else { return nil }
            var result = 0
            for _ in 0..<4 {
                let value = bytes[offset]
                offset += 1
                let digit: Int
                if (0x30...0x39).contains(value) { digit = Int(value - 0x30) }
                else if (0x41...0x46).contains(value) { digit = Int(value - 0x41) + 10 }
                else if (0x61...0x66).contains(value) { digit = Int(value - 0x61) + 10 }
                else { return nil }
                result = result * 16 + digit
            }
            return result
        }

        func decodedKey(_ range: Range<Int>) -> String? {
            let body = bytes[(range.lowerBound + 1)..<(range.upperBound - 1)]
            if !body.contains(0x5c) { return String(bytes: body, encoding: .utf8) }
            var wrapped = Data([0x5b])
            wrapped.append(contentsOf: bytes[range])
            wrapped.append(0x5d)
            guard let values = try? JSONSerialization.jsonObject(with: wrapped) as? [String] else { return nil }
            return values.first
        }
    }
}
