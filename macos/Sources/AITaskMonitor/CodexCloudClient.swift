import Darwin
import Foundation

/// Invokes only the installed Codex CLI; credentials remain owned by Codex.
final class CodexCloudClient {
    struct Snapshot {
        let tasks: [CodexCloudReader.Task]
        let complete: Bool
    }
    enum Failure: Error { case unavailable, invalidResponse, cancelled }

    private let executable: URL
    private let environment: [String: String]?
    private let requestTimeout: TimeInterval
    private let totalTimeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(executable: URL, environment: [String: String]? = nil, requestTimeout: TimeInterval = 12, totalTimeout: TimeInterval = 30) {
        self.executable = executable
        self.environment = environment
        self.requestTimeout = requestTimeout
        self.totalTimeout = totalTimeout
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
            "/Applications/Codex.app/Contents/Resources"
        ]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        if let current, current.isRunning { kill(current.processIdentifier, SIGKILL) }
    }

    func list() throws -> Snapshot {
        var cursor: String?
        var seenCursors = Set<String>()
        var seenIDs = Set<String>()
        var tasks: [CodexCloudReader.Task] = []
        let deadline = Date().addingTimeInterval(totalTimeout)
        for _ in 0..<5 {
            var arguments = ["cloud", "list", "--json", "--limit", "20"]
            if let cursor { arguments += ["--cursor", cursor] }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure.unavailable }
            let data = try run(arguments, timeout: min(remaining, requestTimeout))
            let page: CodexCloudReader.Page
            do { page = try CodexCloudReader.parse(data) }
            catch { throw Failure.invalidResponse }
            for task in page.tasks {
                guard seenIDs.insert(task.id).inserted else { throw Failure.invalidResponse }
                tasks.append(task)
            }
            cursor = page.cursor
            guard let next = cursor else { return Snapshot(tasks: tasks, complete: true) }
            guard seenCursors.insert(next).inserted else { throw Failure.invalidResponse }
        }
        return Snapshot(tasks: tasks, complete: cursor == nil)
    }

    private func run(_ arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        lock.lock()
        if cancelled { lock.unlock(); throw Failure.cancelled }
        self.process = process
        do { try process.run(); lock.unlock() }
        catch { self.process = nil; lock.unlock(); throw Failure.unavailable }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
            lock.lock(); self.process = nil; lock.unlock()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw Failure.unavailable
        }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var eof = false
        while true {
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { throw Failure.cancelled }
            if Date() >= deadline {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw Failure.unavailable
            }
            if eof {
                if !process.isRunning { break }
                usleep(20_000)
                continue
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 200)
            if result < 0 {
                if errno == EINTR { continue }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw Failure.unavailable
            }
            if result > 0 {
                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard data.count + count <= 1_048_576 else {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        throw Failure.invalidResponse
                    }
                    data.append(contentsOf: bytes.prefix(count))
                } else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { throw Failure.unavailable }
            } else if !process.isRunning {
                break
            }
        }
        guard process.terminationStatus == 0 else { throw Failure.unavailable }
        return data
    }
}
