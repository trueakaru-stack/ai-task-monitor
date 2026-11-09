import Darwin
import Foundation

struct ReleaseHTTPResponse {
    let status: Int
    var retryAfter: String? = nil
    var remaining: String? = nil
    var reset: String? = nil
    var serverDate: String? = nil
    var oversizedHeader = false
    var retryAfterRequiresBlock = false
    var resetRequiresBlock = false

    init(status: Int, retryAfter: String? = nil, remaining: String? = nil,
         reset: String? = nil, serverDate: String? = nil, oversizedHeader: Bool = false) {
        self.status = status
        self.retryAfter = retryAfter
        self.remaining = remaining
        self.reset = reset
        self.serverDate = serverDate
        self.oversizedHeader = oversizedHeader
    }

    init(_ response: HTTPURLResponse) {
        status = response.statusCode
        var oversized = false
        var retryOverflow = false
        var resetOverflow = false
        func value(_ name: String) -> String? {
            guard let result = response.value(forHTTPHeaderField: name) else { return nil }
            // Inspect no more than the bounded prefix before trimming or copying.
            // Foundation may already have allocated the original header string.
            let limit = name == "Date" ? 128 : ReleaseRetryHeaders.maximumHeaderBytes
            if result.utf8.prefix(limit + 1).count > limit {
                if name == "Retry-After" { retryOverflow = true }
                else if name == "X-RateLimit-Reset" { resetOverflow = true }
                else { oversized = true }
                return nil
            }
            if result.utf8.count <= 128 { return result }
            // Preserve long finite decimal hints without retaining an unbounded header.
            let digits = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["Retry-After", "X-RateLimit-Remaining", "X-RateLimit-Reset"].contains(name),
               !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) {
                let significant = digits.drop(while: { $0 == "0" })
                // Only zero versus positive matters for remaining; retain neither
                // an enormous counter nor a misleading missing value.
                if name == "X-RateLimit-Remaining" { return significant.isEmpty ? "0" : "1" }
                if significant.count <= 309 { return significant.isEmpty ? "0" : String(significant) }
                if name == "Retry-After" { retryOverflow = true; return nil }
                if name == "X-RateLimit-Reset" { resetOverflow = true; return nil }
            }
            if name == "Retry-After" || name == "X-RateLimit-Reset" {
                // Preserve bounded comma-joined values for the list parser.
                if result.utf8.count <= ReleaseRetryHeaders.maximumHeaderBytes { return result }
                // A bounded parser cannot rule out a long valid delay beyond
                // its input limit. Fail closed for the affected hint.
                if name == "Retry-After" { retryOverflow = true } else { resetOverflow = true }
                return nil
            }
            if name == "X-RateLimit-Remaining", result.utf8.count <= ReleaseRetryHeaders.maximumHeaderBytes {
                return result
            }
            oversized = true
            return nil
        }
        retryAfter = value("Retry-After")
        remaining = value("X-RateLimit-Remaining")
        reset = value("X-RateLimit-Reset")
        serverDate = value("Date")
        oversizedHeader = oversized
        retryAfterRequiresBlock = retryOverflow
        resetRequiresBlock = resetOverflow
    }
}

enum ReleaseRetryHeaders {
    private static let fallback = ReleaseRetrySchedule.malformedStateDelay
    static let maximumHeaderBytes = 65_536
    private static let maximumComponents = 512

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum DecimalValue {
        case value(TimeInterval), tooLarge, invalid
    }

    private static func decimal(_ text: String) -> DecimalValue {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return .invalid }
        let significant = text.drop(while: { $0 == "0" })
        guard significant.count <= 309 else { return .tooLarge }
        let normalized = significant.isEmpty ? "0" : String(significant)
        guard let value = Double(normalized), value.isFinite, value.nextUp.isFinite else { return .tooLarge }
        // Rounding up cannot shorten an exactly specified server delay.
        return .value(value.nextUp)
    }

    private static func httpDate(_ text: String, now: Date) -> Date? {
        let weekday = "(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)"
        let month = "(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
        let time = "[0-9]{2}:[0-9]{2}:[0-9]{2}"
        let formats = [
            ("^\(weekday), [0-9]{2} \(month) [0-9]{4} \(time) GMT$", "EEE, dd MMM yyyy HH:mm:ss 'GMT'"),
            ("^(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), [0-9]{2}-\(month)-[0-9]{2} \(time) GMT$", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'"),
            ("^\(weekday) \(month)  ?[0-9]{1,2} \(time) [0-9]{4}$", "EEE MMM d HH:mm:ss yyyy")
        ]
        for (pattern, format) in formats where text.range(of: pattern, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if format == "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
               let window = formatter.calendar.date(byAdding: .year, value: -50, to: now) {
                formatter.twoDigitStartDate = window
            }
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Split combined fields without splitting the comma inside an HTTP-date.
    /// Nil means the input cannot be safely inspected within bounded resources.
    private static func values(_ raw: String, dates: Bool, now: Date) -> [String]? {
        if raw.utf8.prefix(maximumHeaderBytes + 1).count > maximumHeaderBytes { return nil }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= maximumComponents * 2 else { return nil }
        let weekdays: Set<String> = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
                                     "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        var result: [String] = []
        var index = 0
        while index < parts.count {
            let first = trimmed(String(parts[index]))
            if dates, weekdays.contains(first), index + 1 < parts.count {
                let candidate = trimmed(first + "," + String(parts[index + 1]))
                if httpDate(candidate, now: now) != nil {
                    result.append(candidate)
                    index += 2
                } else {
                    result.append(first)
                    index += 1
                }
            } else {
                result.append(first)
                index += 1
            }
            guard result.count <= maximumComponents else { return nil }
        }
        return result
    }

    /// Ordinary invalid hints use a 24-hour fallback. Infinity signals either an
    /// unrepresentable numeric delay or a list too large to inspect safely.
    static func minimumDelay(for response: ReleaseHTTPResponse, now: Date) -> TimeInterval {
        let date = response.serverDate.flatMap {
            $0.utf8.prefix(129).count <= 128 ? httpDate(trimmed($0), now: now) : nil
        }
        let reference = date ?? now
        var wait: TimeInterval = response.oversizedHeader ? fallback : 0
        if response.retryAfterRequiresBlock { wait = .infinity }
        if let raw = response.retryAfter {
            if let components = values(raw, dates: true, now: reference) {
                for text in components {
                    switch decimal(text) {
                    case .value(let value):
                        wait = max(wait, value)
                    case .tooLarge:
                        wait = .infinity
                    case .invalid:
                        if let absolute = httpDate(text, now: reference) {
                            let value = absolute.timeIntervalSince(reference)
                            // Without a usable server Date, local wall time cannot establish
                            // an absolute server deadline reliably. Keep a bounded fallback.
                            if date == nil { wait = max(wait, fallback) }
                            if value.isFinite { wait = max(wait, max(0, value).nextUp) }
                            else if value == .infinity { wait = .infinity }
                            else { wait = max(wait, fallback) }
                        } else {
                            wait = max(wait, fallback)
                        }
                    }
                }
            } else { wait = .infinity }
        }
        var remainingOverLimit = false
        let remaining = response.remaining.flatMap { raw -> String? in
            if raw.utf8.prefix(maximumHeaderBytes + 1).count > maximumHeaderBytes {
                remainingOverLimit = true
                return nil
            }
            return trimmed(raw)
        }
        var applyReset = remaining == nil
        var invalidRemaining = remainingOverLimit
        if let remaining {
            if let components = values(remaining, dates: false, now: reference),
               components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) {
                // If any combined value is zero, keep the conservative reset.
                applyReset = components.contains { $0.utf8.allSatisfy({ $0 == 48 }) }
            } else {
                applyReset = true
                invalidRemaining = true
            }
        }
        // A successful response can exhaust the budget too. Preserve the
        // existing 403/429 scope and extend it to 200 responses.
        let considersReset = response.status == 200 || response.status == 403 || response.status == 429
        if considersReset, applyReset {
            if response.resetRequiresBlock { wait = .infinity }
            if let raw = response.reset {
                if let components = values(raw, dates: false, now: reference) {
                    for text in components {
                        switch decimal(text) {
                        case .value(let value):
                            let interval = value - reference.timeIntervalSince1970
                            if date == nil { wait = max(wait, fallback) }
                            if interval.isFinite { wait = max(wait, max(0, interval).nextUp) }
                            else if interval == .infinity { wait = .infinity }
                            else { wait = max(wait, fallback) }
                        case .tooLarge:
                            wait = .infinity
                        case .invalid:
                            wait = max(wait, fallback)
                        }
                    }
                } else { wait = .infinity }
            }
        }
        if considersReset, invalidRemaining {
            wait = max(wait, fallback)
        }
        return wait.isNaN ? fallback : wait
    }
}

/// Wall time interprets absolute HTTP hints. Shared raw monotonic time carries
/// delays across updater instances and cannot be shortened by wall-clock jumps.
struct ReleaseRetryClock {
    let wall: () -> Date
    let monotonic: () -> TimeInterval
    let sharedMonotonic: (() -> UInt64)?

    init(wall: @escaping () -> Date, monotonic: @escaping () -> TimeInterval,
         sharedMonotonic: (() -> UInt64)? = nil) {
        self.wall = wall
        self.monotonic = monotonic
        self.sharedMonotonic = sharedMonotonic
    }

    static func system() -> ReleaseRetryClock {
        let sharedClock = { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
        let systemClock = { Double(sharedClock()) / 1_000_000_000 }
        return ReleaseRetryClock(wall: { Date() }, monotonic: systemClock, sharedMonotonic: sharedClock)
    }
}

struct ReleaseRetryCheckpoint: Codable {
    let wallStarted: TimeInterval
    let delay: TimeInterval
    let rateFailures: Int
    var sharedStarted: UInt64? = nil
    var blockAutomaticRetry: Bool? = nil
}

/// Persists only scheduling metadata. It does not persist headers or response data.
final class ReleaseRetrySchedule {
    static let defaultsKey = "releaseRetryScheduleV1"
    static let ordinaryFailureDelay: TimeInterval = 60 * 60
    static let dailyDelay: TimeInterval = 24 * 60 * 60
    static let malformedStateDelay: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let clock: ReleaseRetryClock
    private let fileStore: ReleaseScheduleFileStore?
    private let writeShared: (ReleaseScheduleFileStore.Lease, Data) throws -> Void
    private var lease: ReleaseScheduleFileStore.Lease?
    private var storageFailed = false
    private var loadedSharedState = false
    private var loadedDefaults = false
    private var waitingForStorageRetry = false
    private var startedMonotonic: TimeInterval
    private var startedShared: UInt64?
    private(set) var delay: TimeInterval
    private(set) var rateFailures: Int
    private(set) var blockedByUnrepresentableHint = false

    init(defaults: UserDefaults, clock: ReleaseRetryClock, fileStore: ReleaseScheduleFileStore? = nil,
         writeShared: @escaping (ReleaseScheduleFileStore.Lease, Data) throws -> Void = { try $0.write($1) }) {
        self.defaults = defaults
        self.clock = clock
        self.fileStore = fileStore
        self.writeShared = writeShared
        self.startedMonotonic = clock.monotonic()
        self.startedShared = clock.sharedMonotonic?()
        self.delay = 0
        self.rateFailures = 0
    }

    private func loadDefaultsIfNeeded() {
        guard !loadedDefaults else { return }
        loadedDefaults = true
        guard let raw = defaults.object(forKey: Self.defaultsKey) else { return }
        // A shared-store caller must not write an old defaults snapshot while
        // another instance holds the shared lease and is saving a newer hint.
        restore(raw, persist: fileStore == nil)
    }

    private func restore(_ raw: Any, persist: Bool = true) {
        guard let data = raw as? Data,
              let saved = try? JSONDecoder().decode(ReleaseRetryCheckpoint.self, from: data),
              saved.wallStarted.isFinite, saved.delay.isFinite, saved.delay >= 0,
              (0...6).contains(saved.rateFailures) else {
            setDelay(max(remainingDelay, Self.malformedStateDelay), rateFailures: rateFailures, persist: persist)
            return
        }
        if saved.blockAutomaticRetry == true || blockedByUnrepresentableHint {
            _ = setDelay(.infinity, rateFailures: saved.rateFailures, persist: persist)
            return
        }
        let wallNow = clock.wall().timeIntervalSince1970
        let elapsed: TimeInterval
        if fileStore != nil {
            // CLOCK_MONOTONIC_RAW counts time since boot, including sleep. If
            // reboot reset it, zero is a conservative elapsed-time lower bound.
            if let before = saved.sharedStarted, let now = clock.sharedMonotonic?() {
                elapsed = Self.conservativeSeconds(from: before, to: now)
            } else {
                // Old checkpoints have no shareable monotonic timestamp.
                elapsed = 0
            }
        } else {
            elapsed = wallNow - saved.wallStarted
        }
        guard wallNow.isFinite, elapsed.isFinite else {
            setDelay(max(remainingDelay, Self.malformedStateDelay), rateFailures: rateFailures, persist: persist)
            return
        }
        let boundedElapsed = min(saved.delay, max(0, elapsed))
        var remaining = max(0, saved.delay - boundedElapsed)
        if remaining > 0 && boundedElapsed > 0 {
            remaining = min(saved.delay, remaining.nextUp)
        }
        // Defaults and shared file can represent different successful writes.
        // An older copy must not shorten a newer outstanding server delay.
        setDelay(max(remainingDelay, remaining), rateFailures: max(rateFailures, saved.rateFailures), persist: persist)
    }

    var isDue: Bool {
        guard !blockedByUnrepresentableHint else { return false }
        if let before = startedShared, let now = clock.sharedMonotonic?() {
            return Self.conservativeSeconds(from: before, to: now) >= delay
        }
        let elapsed = clock.monotonic() - startedMonotonic
        return elapsed.isFinite && elapsed >= 0 && elapsed >= delay
    }

    private var remainingDelay: TimeInterval {
        if blockedByUnrepresentableHint { return .infinity }
        let elapsed: TimeInterval
        if let before = startedShared, let now = clock.sharedMonotonic?() {
            elapsed = Self.conservativeSeconds(from: before, to: now)
        } else {
            elapsed = clock.monotonic() - startedMonotonic
        }
        guard elapsed.isFinite, elapsed > 0 else { return delay }
        let remaining = max(0, delay - min(delay, elapsed))
        return remaining > 0 ? min(delay, remaining.nextUp) : 0
    }

    private static func conservativeSeconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end > start else { return 0 }
        let nanoseconds = end - start
        let whole = nanoseconds / 1_000_000_000
        let fraction = nanoseconds % 1_000_000_000
        let seconds = Double(whole) + Double(fraction) / 1_000_000_000
        return max(0, seconds.nextDown.nextDown)
    }

    /// Save a minimum delay before starting the request, including if startup fails.
    func beginIfDue() -> Bool {
        loadDefaultsIfNeeded()
        guard !storageFailed else { return false }
        if waitingForStorageRetry {
            guard isDue else { return false }
            waitingForStorageRetry = false
        }
        if fileStore == nil && !isDue { return false }
        if let fileStore {
            guard !loadedSharedState || isDue else { return false }
            do {
                guard let acquired = try fileStore.acquire() else { return false }
                lease = acquired
                // Re-read defaults after acquiring the lease: this instance may
                // have first seen an older checkpoint while the lease was busy.
                // Read both copies before publishing the merged checkpoint.
                if let raw = defaults.object(forKey: Self.defaultsKey) { restore(raw, persist: false) }
                if let data = try acquired.read() { restore(data, persist: false) }
                _ = setDelay(remainingDelay, rateFailures: rateFailures)
                loadedSharedState = true
                guard !storageFailed, isDue else { if !storageFailed { lease = nil }; return false }
            } catch {
                lease = nil
                _ = setDelay(max(remainingDelay, Self.malformedStateDelay), rateFailures: rateFailures, persist: false)
                waitingForStorageRetry = true
                return false
            }
        }
        guard setDelay(Self.ordinaryFailureDelay, rateFailures: rateFailures) else { return false }
        return true
    }

    private func delayIncludingHints(_ initial: TimeInterval, _ hints: [ReleaseHTTPResponse]) -> TimeInterval {
        var wait = initial
        for hint in hints {
            wait = max(wait, ReleaseRetryHeaders.minimumDelay(for: hint, now: clock.wall()))
        }
        return wait
    }

    /// Called on the serial storage queue while the current request holds its
    /// lease. A later hint may extend but cannot shorten the outstanding wait.
    func recordHint(_ hint: ReleaseHTTPResponse) {
        let current = remainingDelay
        let extended = delayIncludingHints(current, [hint])
        if extended > current { _ = setDelay(extended, rateFailures: rateFailures) }
    }

    func succeeded(_ hints: [ReleaseHTTPResponse] = []) {
        _ = setDelay(delayIncludingHints(max(remainingDelay, Self.dailyDelay), hints), rateFailures: 0)
        if !storageFailed { lease = nil }
    }

    func failed(_ response: ReleaseHTTPResponse? = nil, hints: [ReleaseHTTPResponse] = []) {
        let rateLimited = response?.status == 403 || response?.status == 429 ||
            hints.contains { $0.status == 403 || $0.status == 429 }
        let nextFailures = rateLimited ? min(6, rateFailures + 1) : rateFailures
        var wait = Self.ordinaryFailureDelay
        if rateLimited {
            wait = min(Self.dailyDelay, Self.ordinaryFailureDelay * pow(2, Double(nextFailures - 1)))
        }
        if let response {
            wait = max(wait, ReleaseRetryHeaders.minimumDelay(for: response, now: clock.wall()))
        }
        wait = delayIncludingHints(max(remainingDelay, wait), hints)
        _ = setDelay(wait, rateFailures: nextFailures)
        if !storageFailed { lease = nil }
    }

    func abandon(_ hints: [ReleaseHTTPResponse] = []) {
        if !hints.isEmpty {
            _ = setDelay(delayIncludingHints(remainingDelay, hints), rateFailures: rateFailures)
        }
        if !storageFailed { lease = nil }
    }

    @discardableResult private func setDelay(_ requested: TimeInterval, rateFailures: Int, persist: Bool = true) -> Bool {
        let block = blockedByUnrepresentableHint || requested == .infinity
        // Finite delay keeps the checkpoint decodable by older builds.
        let safeDelay = block ? TimeInterval.greatestFiniteMagnitude :
            (requested.isFinite && requested >= 0 ? requested : Self.malformedStateDelay)
        let wall = clock.wall().timeIntervalSince1970
        let mono = clock.monotonic()
        let shared = clock.sharedMonotonic?()
        delay = safeDelay
        blockedByUnrepresentableHint = block
        self.rateFailures = rateFailures
        startedMonotonic = mono.isFinite ? mono : 0
        startedShared = shared
        guard persist else { return true }
        guard wall.isFinite, let data = try? JSONEncoder().encode(
            ReleaseRetryCheckpoint(wallStarted: wall, delay: safeDelay, rateFailures: rateFailures,
                                   sharedStarted: shared, blockAutomaticRetry: block ? true : nil)
        ) else { storageFailed = true; return false }
        // Attempt the independent copy first so a shared-file write error does
        // not skip even this best-effort save. UserDefaults provides no fsync
        // guarantee; a storage failure remains fail-closed in this process.
        defaults.set(data, forKey: Self.defaultsKey)
        if let lease {
            do { try writeShared(lease, data) }
            catch { storageFailed = true; return false }
        }
        return true
    }
}
