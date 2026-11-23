import Foundation

/// A bounded preflight for metadata that becomes an identity relationship.
/// JSONSerialization still validates the JSON itself after this check.
enum CodexUniqueJSONKeys {
    static func accepts(_ data: Data) -> Bool {
        guard data.count <= 65_536 else { return false }
        var scanner = Scanner(bytes: Array(data))
        guard scanner.value(depth: 0) else { return false }
        scanner.whitespace()
        return scanner.position == scanner.bytes.count
    }

    private struct Scanner {
        let bytes: [UInt8]
        var position = 0

        mutating func whitespace() {
            while position < bytes.count && [0x20, 0x09, 0x0a, 0x0d].contains(bytes[position]) { position += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            whitespace()
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        mutating func stringRange() -> Range<Int>? {
            whitespace()
            let start = position
            guard position < bytes.count, bytes[position] == 0x22 else { return nil }
            position += 1
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 0x22 { return start..<position }
                if byte < 0x20 { return nil }
                if byte == 0x5c {
                    guard position < bytes.count else { return nil }
                    position += 1
                }
            }
            return nil
        }

        mutating func value(depth: Int) -> Bool {
            guard depth <= 64 else { return false }
            whitespace()
            guard position < bytes.count else { return false }
            switch bytes[position] {
            case 0x7b:
                position += 1
                if consume(0x7d) { return true }
                var keys: Set<String> = []
                repeat {
                    guard let range = stringRange(),
                          let key = try? JSONDecoder().decode(String.self, from: Data(bytes[range])),
                          keys.insert(key).inserted, consume(0x3a), value(depth: depth + 1) else { return false }
                    if consume(0x7d) { return true }
                } while consume(0x2c)
                return false
            case 0x5b:
                position += 1
                if consume(0x5d) { return true }
                repeat {
                    guard value(depth: depth + 1) else { return false }
                    if consume(0x5d) { return true }
                } while consume(0x2c)
                return false
            case 0x22:
                return stringRange() != nil
            default:
                let start = position
                while position < bytes.count && ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[position]) {
                    position += 1
                }
                return position > start
            }
        }
    }
}
