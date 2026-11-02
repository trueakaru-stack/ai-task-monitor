import CryptoKit
import Darwin
import Foundation
import Security

struct DiagnosticSettings: Codable, Equatable {
    var retentionDays = 7
    var maximumMB = 10
    var loopThreshold = 5
    var loopWindowMinutes = 10

    var isValid: Bool {
        (1...7).contains(retentionDays) && (1...10).contains(maximumMB) &&
        (3...10).contains(loopThreshold) && (1...30).contains(loopWindowMinutes)
    }
}

enum DiagnosticEventType: String, Codable {
    case taskObserved = "task_observed"
    case taskUnconfirmed = "task_unconfirmed"
    case taskCompleted = "task_completed"
    case taskInterrupted = "task_interrupted"
    case sourceUnavailable = "source_unavailable"
    case sourceRecovered = "source_recovered"
    case toolStarted = "tool_started"
    case toolFinished = "tool_finished"
    case toolFailed = "tool_failed"

    var isSourceEvent: Bool { self == .sourceUnavailable || self == .sourceRecovered }

    var title: String {
        switch self {
        case .taskObserved: return "Задача обнаружена"
        case .taskUnconfirmed: return "Статус не подтверждён"
        case .taskCompleted: return "Работа завершена"
        case .taskInterrupted: return "Работа прервана"
        case .sourceUnavailable: return "Источник недоступен"
        case .sourceRecovered: return "Источник восстановлен"
        case .toolStarted: return "Действие началось"
        case .toolFinished: return "Действие завершено"
        case .toolFailed: return "Ошибка действия"
        }
    }
}

struct DiagnosticInput {
    let source: TaskProvider
    let taskID: String?
    let type: DiagnosticEventType
    let time: Date
}

struct DiagnosticEvent: Codable, Identifiable, Equatable {
    let version: Int
    let time: Date
    let source: TaskProvider
    let task: String?
    let type: DiagnosticEventType
    let id: UUID
}

final class DiagnosticJournal {
    let directory: URL
    private let settingsName = "settings-v1.json"
    private let journalName = "events-v1.jsonl"
    private let keyName = "key-v1.bin"
    private let lockName = "journal.lock"
    private let header = "{\"format\":\"ai-task-monitor-diagnostics\",\"version\":1}\n"
    private let maximumExistingBytes = 11_000_000
    private let fileManager = FileManager.default

    init(directory: URL = AppPaths.supportDirectory.appendingPathComponent("diagnostics", isDirectory: true)) {
        self.directory = directory
    }

    func loadSettings() throws -> DiagnosticSettings {
        try locked { try readSettings() }
    }

    func saveSettings(_ settings: DiagnosticSettings) throws {
        guard settings.isValid else { throw JournalError.invalidSettings }
        try locked {
            _ = try readSettings()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try atomicWrite(encoder.encode(settings), name: settingsName)
        }
    }

    func taskKey(source: TaskProvider, taskID: String) throws -> String {
        guard isSafeTaskID(taskID) else { throw JournalError.invalidEvent }
        return try locked { try makeTaskKey(source: source, taskID: taskID, key: loadKey()) }
    }

    func append(_ inputs: [DiagnosticInput], now: Date = Date()) throws {
        try locked {
            let settings = try readSettings()
            var events = try readEvents()
            let key = try loadKey()
            for input in inputs {
                let task: String?
                if input.type.isSourceEvent {
                    guard input.taskID == nil else { throw JournalError.invalidEvent }
                    task = nil
                } else {
                    guard let id = input.taskID, isSafeTaskID(id) else { throw JournalError.invalidEvent }
                    task = try makeTaskKey(source: input.source, taskID: id, key: key)
                }
                events.append(DiagnosticEvent(version: 1, time: input.time, source: input.source, task: task, type: input.type, id: UUID()))
            }
            try writeEvents(events, settings: settings, now: now)
        }
    }

    func read(now: Date = Date()) throws -> [DiagnosticEvent] {
        try locked {
            let settings = try readSettings()
            let events = try readEvents()
            let retained = try retainedEvents(events, settings: settings, now: now)
            if retained != events { try writeEvents(retained, settings: settings, now: now) }
            return retained
        }
    }

    func clear() throws {
        try locked {
            _ = try readEvents()
            try atomicWrite(Data(header.utf8), name: journalName)
        }
    }

    private func readSettings() throws -> DiagnosticSettings {
        guard let data = try safeRead(name: settingsName, maximumBytes: 16_384) else { return DiagnosticSettings() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["retentionDays", "maximumMB", "loopThreshold", "loopWindowMinutes"]) else {
            throw JournalError.foreignFile
        }
        let settings = try JSONDecoder().decode(DiagnosticSettings.self, from: data)
        guard settings.isValid else { throw JournalError.invalidSettings }
        return settings
    }

    private func readEvents() throws -> [DiagnosticEvent] {
        guard let data = try safeRead(name: journalName, maximumBytes: maximumExistingBytes) else { return [] }
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(header), text.hasSuffix("\n") else {
            throw JournalError.foreignFile
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [DiagnosticEvent] = []
        for line in text.dropFirst(header.count).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { throw JournalError.foreignFile }
            let keys = Set(object.keys)
            let required: Set<String> = ["version", "time", "source", "type", "id"]
            guard required.isSubset(of: keys), keys.isSubset(of: required.union(["task"])) else { throw JournalError.foreignFile }
            let event = try decoder.decode(DiagnosticEvent.self, from: lineData)
            guard event.version == 1,
                  (event.type.isSourceEvent ? event.task == nil : isSafeTaskKey(event.task)) else { throw JournalError.foreignFile }
            events.append(event)
        }
        return events
    }

    private func retainedEvents(_ events: [DiagnosticEvent], settings: DiagnosticSettings, now: Date) throws -> [DiagnosticEvent] {
        guard settings.isValid else { throw JournalError.invalidSettings }
        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        let ordered = events.filter { $0.time >= cutoff }.sorted { $0.time < $1.time }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var selected: [DiagnosticEvent] = []
        var used = Data(header.utf8).count
        let limit = settings.maximumMB * 1_000_000
        for event in ordered.reversed() {
            let count = try encoder.encode(event).count + 1
            if used + count > limit { break }
            used += count
            selected.append(event)
        }
        return Array(selected.reversed())
    }

    private func writeEvents(_ events: [DiagnosticEvent], settings: DiagnosticSettings, now: Date) throws {
        let selected = try retainedEvents(events, settings: settings, now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data(header.utf8)
        for event in selected {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try atomicWrite(data, name: journalName)
    }

    private func makeTaskKey(source: TaskProvider, taskID: String, key: Data) throws -> String {
        guard key.count == 32, isSafeTaskID(taskID) else { throw JournalError.invalidEvent }
        let message = Data((source.rawValue + "\0" + taskID).utf8)
        return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func loadKey() throws -> Data {
        if let existing = try safeRead(name: keyName, maximumBytes: 32) {
            guard existing.count == 32 else { throw JournalError.foreignFile }
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw JournalError.randomFailure }
        let data = Data(bytes)
        try atomicWrite(data, name: keyName)
        return data
    }

    private func isSafeTaskID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || $0.value == 45 || $0.value == 95
        }
    }

    private func isSafeTaskKey(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try prepareDirectory()
        let path = directory.appendingPathComponent(lockName).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw JournalError.fileAccess }
        defer { Darwin.close(descriptor) }
        try validateRegularFile(descriptor)
        guard flock(descriptor, LOCK_EX) == 0 else { throw JournalError.fileAccess }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func prepareDirectory() throws {
        var information = stat()
        if lstat(directory.path, &information) != 0 {
            guard errno == ENOENT else { throw JournalError.fileAccess }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &information) == 0 else { throw JournalError.fileAccess }
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), information.st_uid == getuid(),
              information.st_mode & mode_t(0o077) == 0 else { throw JournalError.unsafePermissions }
    }

    private func validateRegularFile(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_uid == getuid(),
              information.st_nlink == 1, information.st_mode & mode_t(0o077) == 0 else { throw JournalError.unsafePermissions }
    }

    private func safeRead(name: String, maximumBytes: Int) throws -> Data? {
        let path = directory.appendingPathComponent(name).path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw JournalError.fileAccess
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try validateRegularFile(descriptor)
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_size >= 0,
              information.st_size <= Int64(maximumBytes) else { throw JournalError.foreignFile }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw JournalError.foreignFile }
        return data
    }

    private func atomicWrite(_ data: Data, name: String) throws {
        let destination = directory.appendingPathComponent(name).path
        var information = stat()
        if lstat(destination, &information) == 0 {
            guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_uid == getuid(),
                  information.st_nlink == 1, information.st_mode & mode_t(0o077) == 0 else { throw JournalError.unsafePermissions }
        } else if errno != ENOENT { throw JournalError.fileAccess }
        let temporary = directory.appendingPathComponent(".journal-" + UUID().uuidString + ".tmp").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw JournalError.fileAccess }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary, destination) == 0 else { throw JournalError.fileAccess }
    }

    private enum JournalError: LocalizedError {
        case fileAccess, unsafePermissions, foreignFile, invalidSettings, invalidEvent, randomFailure
        var errorDescription: String? { "Не удалось безопасно открыть диагностический журнал." }
    }
}
