import Foundation

struct DiagnosticTaskReference {
    let source: TaskProvider
    let id: String
    let title: String
}

struct DiagnosticView {
    let events: [DiagnosticEvent]
    let taskNames: [String: String]
}

final class DiagnosticWorker {
    private let journal: DiagnosticJournal
    private let queue = DispatchQueue(label: "AI Task Monitor diagnostic journal", qos: .utility)
    private var pending: [DiagnosticInput] = []
    private var lostEvents = false

    init(journal: DiagnosticJournal) { self.journal = journal }

    func load(completion: @escaping (Result<DiagnosticSettings, Error>) -> Void) {
        queue.async {
            do {
                let settings = try self.journal.loadSettings()
                _ = try self.journal.read()
                completion(.success(settings))
            } catch { completion(.failure(error)) }
        }
    }

    func save(_ settings: DiagnosticSettings, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do { try self.journal.saveSettings(settings); completion(.success(())) }
            catch { completion(.failure(error)) }
        }
    }

    func update(_ inputs: [DiagnosticInput], references: [DiagnosticTaskReference]?, now: Date = Date(),
                completion: @escaping (Result<DiagnosticView?, Error>) -> Void) {
        queue.async {
            if self.pending.count + inputs.count > 10_000 {
                self.lostEvents = true
            } else {
                self.pending.append(contentsOf: inputs)
            }
            do {
                if !self.pending.isEmpty {
                    try self.journal.append(self.pending, now: now)
                    self.pending.removeAll()
                }
                let events = try self.journal.read(now: now)
                if self.lostEvents { throw WorkerError.eventOverflow }
                guard let references else { completion(.success(nil)); return }
                var names: [String: String] = [:]
                for reference in references {
                    if let key = try? self.journal.taskKey(source: reference.source, taskID: reference.id) {
                        names[key] = reference.title
                    }
                }
                completion(.success(DiagnosticView(events: events, taskNames: names)))
            } catch { completion(.failure(error)) }
        }
    }

    func clear(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try self.journal.clear()
                self.pending.removeAll()
                self.lostEvents = false
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    private enum WorkerError: LocalizedError {
        case eventOverflow
        var errorDescription: String? { tr("Журнал был недоступен слишком долго; часть событий не сохранена.", "The journal was unavailable for too long; some events were not saved.") }
    }
}
