import CoreFoundation
import CryptoKit
import Foundation

enum CodexToolEventKind: String {
    case commandStarted, commandFinished, fileStarted, fileFinished
}

struct CodexToolEvent {
    let id: String
    let kind: CodexToolEventKind
    let time: Date
    let command: [String]?
    let workingDirectory: String?
    let status: String
    let exitCode: Int?
}

enum CodexToolEventParser {
    static func parse(tail: String, since: Date, now: Date) -> [CodexToolEvent] {
        var result: [CodexToolEvent] = []
        for line in tail.split(whereSeparator: \.isNewline) where line.contains("item_started") || line.contains("item_completed") {
            guard line.utf8.count <= 1_048_576, let record = FileHelpers.jsonObject(line),
                  record.string("type") == "event_msg", let payload = record.object("payload"),
                  let item = payload.object("item"), let time = FileHelpers.isoDate(record["timestamp"]),
                  time >= since, time <= now.addingTimeInterval(300) else { continue }
            let eventType = payload.string("type")
            let itemType = item.string("type")
            let kind: CodexToolEventKind
            switch (eventType, itemType) {
            case ("item_started", "CommandExecution"): kind = .commandStarted
            case ("item_completed", "CommandExecution"): kind = .commandFinished
            case ("item_started", "FileChange"): kind = .fileStarted
            case ("item_completed", "FileChange"): kind = .fileFinished
            default: continue
            }
            let id = item.string("id")
            guard !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy({
                (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || $0.value == 45 || $0.value == 95
            }) else { continue }
            var code: Int?
            if let number = item["exit_code"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
               number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) {
                code = number.intValue
            }
            result.append(CodexToolEvent(id: id, kind: kind, time: time, command: item["command"] as? [String],
                                         workingDirectory: item["cwd"] as? String, status: item.string("status"), exitCode: code))
        }
        return Array(result.suffix(4_096))
    }
}

struct LoopWarning: Codable, Equatable {
    let threshold: Int
    let windowMinutes: Int

    var description: String {
        tr("Возможный цикл: одна команда завершилась с одинаковым кодом ошибки не менее \(threshold) раз за \(windowMinutes) мин.", "Possible loop: one command failed with the same code at least \(threshold) times in \(windowMinutes) min.")
    }
}

struct LoopDetector {
    private let key = SymmetricKey(size: .bits256)
    private var fingerprint: Data?
    private var exitCode: Int?
    private var times: [Date] = []
    private var seen: Set<Data> = []
    private var seenOrder: [Data] = []
    private(set) var threshold: Int
    private(set) var windowMinutes: Int
    private(set) var dismissed = false

    init(threshold: Int = 5, windowMinutes: Int = 10) {
        self.threshold = threshold
        self.windowMinutes = windowMinutes
    }

    var warning: LoopWarning? {
        guard times.count >= threshold, !dismissed else { return nil }
        return LoopWarning(threshold: threshold, windowMinutes: windowMinutes)
    }

    mutating func configure(threshold: Int, windowMinutes: Int) {
        guard (3...10).contains(threshold), (1...30).contains(windowMinutes) else { return }
        if self.threshold != threshold || self.windowMinutes != windowMinutes {
            resetSequence()
            self.threshold = threshold
            self.windowMinutes = windowMinutes
        }
    }

    mutating func dismiss() { if warning != nil { dismissed = true } }

    mutating func refresh(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(windowMinutes) * 60)
        times.removeAll { $0 < cutoff }
        if times.count < threshold { dismissed = false }
    }

    mutating func consume(_ event: CodexToolEvent, now: Date) -> DiagnosticEventType? {
        let eventKey = digest("event\0\(event.kind.rawValue)\0\(event.id)")
        guard seen.insert(eventKey).inserted else { return nil }
        seenOrder.append(eventKey)
        if seenOrder.count > 4_096 { seen.remove(seenOrder.removeFirst()) }
        switch event.kind {
        case .fileStarted:
            return .toolStarted
        case .fileFinished:
            resetSequence()
            return .toolFinished
        case .commandStarted:
            let started = commandFingerprint(event)
            if started == nil || (fingerprint != nil && fingerprint != started) { resetSequence() }
            return .toolStarted
        case .commandFinished:
            guard event.status == "failed", let code = event.exitCode, code != 0 else {
                resetSequence()
                return .toolFinished
            }
            guard let current = commandFingerprint(event) else {
                resetSequence()
                return .toolFailed
            }
            if fingerprint != current || exitCode != code || (times.last.map { event.time < $0 } ?? false) {
                resetSequence()
                fingerprint = current
                exitCode = code
            }
            let cutoff = event.time.addingTimeInterval(-Double(windowMinutes) * 60)
            times.removeAll { $0 < cutoff }
            if times.count < threshold { dismissed = false }
            times.append(event.time)
            if times.count > 10 { times.removeFirst(times.count - 10) }
            refresh(now: now)
            return .toolFailed
        }
    }

    mutating func finishTurn() { resetSequence() }

    private mutating func resetSequence() {
        fingerprint = nil
        exitCode = nil
        times.removeAll()
        dismissed = false
    }

    private func commandFingerprint(_ event: CodexToolEvent) -> Data? {
        guard let command = event.command, !command.isEmpty, command.count <= 256,
              let directory = event.workingDirectory, directory.utf8.count <= 32_768 else { return nil }
        var value = "\(directory.utf8.count):\(directory)"
        for argument in command {
            guard argument.utf8.count <= 32_768, value.utf8.count + argument.utf8.count <= 131_072 else { return nil }
            value += "\(argument.utf8.count):\(argument)"
        }
        return digest("command\0" + value)
    }

    private func digest(_ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key))
    }
}
