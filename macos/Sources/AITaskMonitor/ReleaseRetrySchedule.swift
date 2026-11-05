import Darwin
import Foundation

struct ReleaseHTTPResponse {
    let status: Int
    var retryAfter: String? = nil
    var remaining: String? = nil
    var reset: String? = nil
    var serverDate: String? = nil
    var oversizedHeader = false

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
        func value(_ name: String) -> String? {
            guard let result = response.value(forHTTPHeaderField: name) else { return nil }
            if result.utf8.count <= 128 { return result }
            // Preserve long finite decimal hints without retaining an unbounded header.
            let digits = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["Retry-After", "X-RateLimit-Remaining", "X-RateLimit-Reset"].contains(name),
               !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) {
                let significant = digits.drop(while: { $0 == "0" })
                if significant.count <= 309 { return significant.isEmpty ? "0" : String(significant) }
            }
            oversized = true
            return nil
        }
        retryAfter = value("Retry-After")
        remaining = value("X-RateLimit-Remaining")
        reset = value("X-RateLimit-Reset")
        serverDate = value("Date")
        oversizedHeader = oversized
    }
}

enum ReleaseRetryHeaders {
    private static let fallback = ReleaseRetrySchedule.malformedStateDelay

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decimal(_ text: String) -> TimeInterval? {
        guard !text.isEmpty, text.utf8.count <= 309,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Double(text), value.isFinite, value >= 0,
              value.nextUp.isFinite else { return nil }
        // Rounding up cannot shorten an exactly specified server delay.
        return value.nextUp
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

    /// Invalid or unrepresentable hints use a conservative 24-hour fallback;
    /// finite server delays are never shortened by a local maximum.
    static func minimumDelay(for response: ReleaseHTTPResponse, now: Date) -> TimeInterval {
        let date = response.serverDate.flatMap { httpDate(trimmed($0), now: now) }
        let reference = date ?? now
        var wait: TimeInterval = response.oversizedHeader ? fallback : 0
        if let raw = response.retryAfter {
            let text = trimmed(raw)
            if let value = decimal(text) {
                wait = max(wait, value)
            } else if let absolute = httpDate(text, now: reference) {
                let value = absolute.timeIntervalSince(reference)
                // Without a usable server Date, local wall time cannot establish
                // an absolute server deadline reliably. Keep a bounded fallback.
                if date == nil { wait = max(wait, fallback) }
                if value.isFinite { wait = max(wait, max(0, value).nextUp) }
                else { wait = max(wait, fallback) }
            } else {
                wait = max(wait, fallback)
            }
        }
        let isLimitResponse = response.status == 403 || response.status == 429
        let remaining = response.remaining.map(trimmed)
        let validRemaining = remaining.map { !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }
        let remainingIsZero = remaining.map { !$0.isEmpty && $0.utf8.allSatisfy({ $0 == 48 }) } == true
        if isLimitResponse, let raw = response.reset, remaining == nil || remainingIsZero || validRemaining == false {
            if let value = decimal(trimmed(raw)) {
                let interval = value - reference.timeIntervalSince1970
                if date == nil { wait = max(wait, fallback) }
                if interval.isFinite { wait = max(wait, max(0, interval).nextUp) }
                else { wait = max(wait, fallback) }
            } else {
                wait = max(wait, fallback)
            }
        }
        if isLimitResponse, validRemaining == false {
            wait = max(wait, fallback)
        }
        return wait.isFinite ? wait : fallback
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
    private var lease: ReleaseScheduleFileStore.Lease?
    private var storageFailed = false
    private var loadedSharedState = false
    private var loadedDefaults = false
    private var waitingForStorageRetry = false
    private var startedMonotonic: TimeInterval
    private var startedShared: UInt64?
    private(set) var delay: TimeInterval
    private(set) var rateFailures: Int

    init(defaults: UserDefaults, clock: ReleaseRetryClock, fileStore: ReleaseScheduleFileStore? = nil) {
        self.defaults = defaults
        self.clock = clock
        self.fileStore = fileStore
        self.startedMonotonic = clock.monotonic()
        self.startedShared = clock.sharedMonotonic?()
        self.delay = 0
        self.rateFailures = 0
    }

    private func loadDefaultsIfNeeded() {
        guard !loadedDefaults else { return }
        loadedDefaults = true
        guard let raw = defaults.object(forKey: Self.defaultsKey) else { return }
        restore(raw)
    }

    private func restore(_ raw: Any) {
        guard let data = raw as? Data,
              let saved = try? JSONDecoder().decode(ReleaseRetryCheckpoint.self, from: data),
              saved.wallStarted.isFinite, saved.delay.isFinite, saved.delay >= 0,
              (0...6).contains(saved.rateFailures) else {
            setDelay(Self.malformedStateDelay, rateFailures: 0)
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
            setDelay(Self.malformedStateDelay, rateFailures: 0)
            return
        }
        let boundedElapsed = min(saved.delay, max(0, elapsed))
        var remaining = max(0, saved.delay - boundedElapsed)
        if remaining > 0 && boundedElapsed > 0 {
            remaining = min(saved.delay, remaining.nextUp)
        }
        setDelay(remaining, rateFailures: saved.rateFailures)
    }

    var isDue: Bool {
        if let before = startedShared, let now = clock.sharedMonotonic?() {
            return Self.conservativeSeconds(from: before, to: now) >= delay
        }
        let elapsed = clock.monotonic() - startedMonotonic
        return elapsed.isFinite && elapsed >= 0 && elapsed >= delay
    }

    private var remainingDelay: TimeInterval {
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
                if let data = try acquired.read() { restore(data) }
                else { _ = setDelay(remainingDelay, rateFailures: rateFailures) }
                loadedSharedState = true
                guard !storageFailed, isDue else { if !storageFailed { lease = nil }; return false }
            } catch {
                lease = nil
                _ = setDelay(Self.malformedStateDelay, rateFailures: rateFailures)
                waitingForStorageRetry = true
                return false
            }
        }
        guard setDelay(Self.ordinaryFailureDelay, rateFailures: rateFailures) else { return false }
        return true
    }

    func succeeded() {
        _ = setDelay(Self.dailyDelay, rateFailures: 0)
        if !storageFailed { lease = nil }
    }

    func failed(_ response: ReleaseHTTPResponse? = nil) {
        let rateLimited = response?.status == 403 || response?.status == 429
        let nextFailures = rateLimited ? min(6, rateFailures + 1) : rateFailures
        var wait = Self.ordinaryFailureDelay
        if rateLimited {
            wait = min(Self.dailyDelay, Self.ordinaryFailureDelay * pow(2, Double(nextFailures - 1)))
        }
        if let response {
            wait = max(wait, ReleaseRetryHeaders.minimumDelay(for: response, now: clock.wall()))
        }
        _ = setDelay(wait, rateFailures: nextFailures)
        if !storageFailed { lease = nil }
    }

    func abandon() {
        if !storageFailed { lease = nil }
    }

    @discardableResult private func setDelay(_ requested: TimeInterval, rateFailures: Int) -> Bool {
        let safeDelay = requested.isFinite && requested >= 0 ? requested : Self.malformedStateDelay
        let wall = clock.wall().timeIntervalSince1970
        let mono = clock.monotonic()
        let shared = clock.sharedMonotonic?()
        delay = safeDelay
        self.rateFailures = rateFailures
        startedMonotonic = mono.isFinite ? mono : 0
        startedShared = shared
        guard wall.isFinite, let data = try? JSONEncoder().encode(
            ReleaseRetryCheckpoint(wallStarted: wall, delay: safeDelay, rateFailures: rateFailures, sharedStarted: shared)
        ) else { storageFailed = true; return false }
        if let lease {
            do { try lease.write(data) }
            catch { storageFailed = true; return false }
        }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }
}
